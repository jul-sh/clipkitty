import ClipKittyRust
import Foundation

#if ENABLE_LINK_PREVIEWS
    import CoreGraphics
    import Darwin
    import ImageIO
    @preconcurrency import LinkPresentation

    /// Fetches link metadata using Apple's LinkPresentation framework
    @MainActor
    public final class LinkMetadataFetcher {
        /// In-flight fetch tasks keyed by item ID (prevents duplicate fetches)
        private var activeFetches: [String: Task<LinkMetadataPayload?, Never>] = [:]

        public init() {}

        /// Fetch metadata for a URL, caching by item ID to prevent duplicate requests
        public func fetchMetadata(for url: String, itemId: String) async -> LinkMetadataPayload? {
            // Return if already fetching
            if let existingTask = activeFetches[itemId] {
                return await existingTask.value
            }

            guard let urlObj = URL(string: url) else { return nil }

            // SSRF guard: refuse to fetch previews for URLs that resolve, at the
            // literal/hostname layer, to private, loopback, link-local, or
            // cloud-metadata endpoints. LPMetadataProvider exposes no resolve hook,
            // so DNS-rebinding / resolved-IP SSRF (a hostname that resolves to an
            // internal address at fetch time) remains a residual limitation; this
            // blocks the obvious literal-IP and .local/localhost cases only.
            guard LinkMetadataHostGuard.isFetchable(urlObj) else { return nil }

            let task = Task<LinkMetadataPayload?, Never> { @MainActor in
                let provider = LPMetadataProvider()
                // Title/basic metadata only. Disabling subresources cuts the
                // tracking-beacon and subresource-SSRF surface (the provider will
                // not fetch arbitrary images/scripts referenced by the page).
                provider.shouldFetchSubresources = false

                do {
                    let metadata = try await provider.startFetchingMetadata(for: urlObj)
                    return await Self.convert(metadata)
                } catch {
                    return nil
                }
            }

            activeFetches[itemId] = task
            let result = await task.value
            activeFetches.removeValue(forKey: itemId)

            return result
        }

        private static func convert(_ metadata: LPLinkMetadata) async -> LinkMetadataPayload? {
            let title = metadata.title

            // LPMetadataProvider doesn't directly expose og:description
            let description: String? = nil

            // Fetch image data and clamp to 3:2 aspect ratio (no taller)
            var imageData: Data?
            if let imageProvider = metadata.imageProvider {
                let rawData: Data? = await withCheckedContinuation { continuation in
                    imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                imageData = rawData.flatMap { Self.clampImageTo3x2($0) } ?? rawData
            }

            // Return nil if we got nothing useful
            switch (title, imageData) {
            case (nil, nil):
                return nil
            case (let t?, nil):
                return .titleOnly(title: t, description: description)
            case (nil, let img?):
                return .imageOnly(imageData: img, description: description)
            case let (t?, img?):
                return .titleAndImage(title: t, imageData: img, description: description)
            }
        }

        /// Crop image to at most 3:2 aspect ratio, center-cropping excess height.
        private static func clampImageTo3x2(_ data: Data) -> Data? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let w = CGFloat(cgImage.width)
            let h = CGFloat(cgImage.height)
            guard w > 0, h > 0 else { return nil }

            let minRatio: CGFloat = 3.0 / 2.0
            let ratio = w / h
            guard ratio < minRatio else { return nil } // already wide enough

            let croppedH = w / minRatio
            let cropY = (h - croppedH) / 2.0
            let cropRect = CGRect(x: 0, y: cropY, width: w, height: croppedH)

            guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

            let jpegData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                jpegData as CFMutableData, "public.jpeg" as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(dest, cropped, [
                kCGImageDestinationLossyCompressionQuality: 0.85,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return jpegData as Data
        }
    }

    /// Blocks link-preview fetches whose host is a private/loopback/link-local/
    /// unique-local address or a `.local`/loopback/cloud-metadata hostname.
    ///
    /// This is an SSRF mitigation for the preview fetcher: it prevents a copied
    /// URL from steering `LPMetadataProvider` at internal services (e.g. the
    /// cloud-metadata endpoint or a LAN device). It inspects the literal host in
    /// the URL only. Because `LPMetadataProvider` offers no resolve hook, a
    /// hostname that resolves to an internal address at fetch time
    /// (DNS-rebinding / resolved-IP SSRF) is not caught here and remains a
    /// residual limitation.
    enum LinkMetadataHostGuard {
        /// Returns `false` when the URL's host looks internal and must not be fetched.
        static func isFetchable(_ url: URL) -> Bool {
            guard let host = url.host, !host.isEmpty else {
                // No host to reason about (e.g. a bare path); nothing to fetch.
                return false
            }
            return !isBlockedHost(host)
        }

        private static func isBlockedHost(_ rawHost: String) -> Bool {
            // Normalise: strip IPv6 literal brackets and a trailing dot, lowercase.
            var host = rawHost.lowercased()
            if host.hasPrefix("["), host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            if host.hasSuffix(".") {
                host = String(host.dropLast())
            }

            // Literal IP addresses: check numeric ranges directly.
            if let v4 = ipv4Octets(host) {
                return isPrivateIPv4(v4)
            }
            if let v6 = ipv6Bytes(host) {
                return isPrivateIPv6(v6)
            }

            // Hostnames: block the obvious internal names. Full DNS-resolution-time
            // SSRF is out of scope (see type doc).
            if host == "localhost" || host.hasSuffix(".localhost") {
                return true
            }
            if host.hasSuffix(".local") {
                return true
            }
            return false
        }

        // MARK: - IPv4

        /// Parses a dotted-quad IPv4 literal into four octets, or nil if not one.
        private static func ipv4Octets(_ host: String) -> (UInt8, UInt8, UInt8, UInt8)? {
            var addr = in_addr()
            guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
                return nil
            }
            let raw = addr.s_addr.bigEndian
            return (
                UInt8((raw >> 24) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8(raw & 0xFF)
            )
        }

        private static func isPrivateIPv4(_ octets: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
            let (a, b, _, _) = octets
            // 0.0.0.0/8 (this-network / unspecified)
            if a == 0 { return true }
            // 127.0.0.0/8 (loopback)
            if a == 127 { return true }
            // 10.0.0.0/8 (private)
            if a == 10 { return true }
            // 172.16.0.0/12 (private)
            if a == 172, (16 ... 31).contains(b) { return true }
            // 192.168.0.0/16 (private)
            if a == 192, b == 168 { return true }
            // 169.254.0.0/16 (link-local, includes 169.254.169.254 cloud metadata)
            if a == 169, b == 254 { return true }
            return false
        }

        // MARK: - IPv6

        /// Parses an IPv6 literal into its 16 bytes, or nil if not one.
        private static func ipv6Bytes(_ host: String) -> [UInt8]? {
            var addr = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
                return nil
            }
            return withUnsafeBytes(of: &addr) { Array($0) }
        }

        private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
            guard bytes.count == 16 else { return false }

            // ::1 loopback
            if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] == 1 {
                return true
            }
            // :: unspecified
            if bytes.allSatisfy({ $0 == 0 }) {
                return true
            }
            // fc00::/7 unique local (first 7 bits == 1111110)
            if bytes[0] & 0xFE == 0xFC {
                return true
            }
            // fe80::/10 link-local (first 10 bits == 1111111010)
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
                return true
            }
            // IPv4-mapped ::ffff:0:0/96 — validate the embedded IPv4 against v4 rules.
            let mappedPrefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
            if Array(bytes[0 ..< 12]) == mappedPrefix {
                return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            // IPv4-compatible ::0:0/96 (deprecated) with an embedded internal v4.
            if bytes[0 ..< 12].allSatisfy({ $0 == 0 }) {
                return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return false
        }
    }
#endif
