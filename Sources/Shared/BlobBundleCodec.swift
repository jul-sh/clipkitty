#if ENABLE_SYNC

    import CloudKit
    import Foundation

    /// Pure-function codec for blob bundle extraction/injection.
    /// Shared between macOS and iOS sync engines.
    enum BlobBundleCodec {

        /// Recursively extract non-empty `_base64` JSON fields into a blob bundle,
        /// returning the stripped JSON and the bundle.
        static func extractBase64Bundle(from jsonString: String) -> (String, BlobBundle)? {
            guard let jsonData = jsonString.data(using: .utf8),
                  var root = try? JSONSerialization.jsonObject(with: jsonData)
            else { return nil }

            var entries: [BlobBundleEntry] = []

            func walk(_ value: inout Any, path: [BlobPathComponent]) {
                if var dict = value as? [String: Any] {
                    for key in dict.keys.sorted() {
                        if let base64Value = dict[key] as? String,
                           key.hasSuffix("_base64"),
                           !base64Value.isEmpty,
                           Data(base64Encoded: base64Value) != nil
                        {
                            entries.append(
                                BlobBundleEntry(
                                    path: path + [.key(key)],
                                    base64Value: base64Value
                                )
                            )
                            dict[key] = ""
                            continue
                        }

                        if var child = dict[key] {
                            walk(&child, path: path + [.key(key)])
                            dict[key] = child
                        }
                    }
                    value = dict
                    return
                }

                if var array = value as? [Any] {
                    for index in array.indices {
                        var child = array[index]
                        walk(&child, path: path + [.index(index)])
                        array[index] = child
                    }
                    value = array
                }
            }

            walk(&root, path: [])

            guard !entries.isEmpty,
                  let strippedData = try? JSONSerialization.data(withJSONObject: root),
                  let strippedString = String(data: strippedData, encoding: .utf8)
            else { return nil }

            return (strippedString, BlobBundle(entries: entries))
        }

        /// Inject blob bundle entries back into a JSON string.
        static func inject(
            blobBundle: BlobBundle,
            into jsonString: String
        ) throws -> String {
            guard let jsonData = jsonString.data(using: .utf8) else {
                throw BlobBundleError.invalidUTF8
            }

            var root = try JSONSerialization.jsonObject(with: jsonData)
            for entry in blobBundle.entries {
                guard setJSONValue(
                    entry.base64Value,
                    at: entry.path,
                    in: &root
                ) else {
                    throw BlobBundleError.injectionFailed(
                        path: pathDescription(entry.path)
                    )
                }
            }

            let resultData = try JSONSerialization.data(withJSONObject: root)
            guard let resultString = String(data: resultData, encoding: .utf8) else {
                throw BlobBundleError.invalidUTF8
            }
            return resultString
        }

        /// Write a blob bundle to a temporary file, returning its URL.
        static func writeBlobBundle(_ bundle: BlobBundle) throws -> URL {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".json")
            let data = try JSONEncoder().encode(bundle)
            try data.write(to: tempURL)
            return tempURL
        }

        /// Read and decode a blob bundle from a CKAsset.
        static func readBlobBundle(from asset: CKAsset) throws -> BlobBundle {
            guard let fileURL = asset.fileURL else {
                throw BlobBundleError.missingAssetFileURL
            }
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(BlobBundle.self, from: data)
        }

        /// Remove temporary blob bundle files.
        static func cleanupTemporaryFiles(_ urls: [URL]) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // MARK: - Internal

        @discardableResult
        private static func setJSONValue(
            _ value: String,
            at path: [BlobPathComponent],
            in node: inout Any
        ) -> Bool {
            guard let component = path.first else { return false }

            switch component {
            case let .key(key):
                guard var dict = node as? [String: Any] else { return false }
                if path.count == 1 {
                    dict[key] = value
                    node = dict
                    return true
                }
                guard var child = dict[key] else { return false }
                guard setJSONValue(value, at: Array(path.dropFirst()), in: &child) else {
                    return false
                }
                dict[key] = child
                node = dict
                return true

            case let .index(index):
                guard var array = node as? [Any], array.indices.contains(index) else {
                    return false
                }
                if path.count == 1 {
                    array[index] = value
                    node = array
                    return true
                }
                var child = array[index]
                guard setJSONValue(value, at: Array(path.dropFirst()), in: &child) else {
                    return false
                }
                array[index] = child
                node = array
                return true
            }
        }

        static func pathDescription(_ path: [BlobPathComponent]) -> String {
            if path.isEmpty { return "$" }
            return "$" + path.map { component in
                switch component {
                case let .key(key): return ".\(key)"
                case let .index(index): return "[\(index)]"
                }
            }.joined()
        }
    }

    // MARK: - Errors

    enum BlobBundleError: LocalizedError {
        case invalidUTF8
        case missingAssetFileURL
        case injectionFailed(path: String)

        var errorDescription: String? {
            switch self {
            case .invalidUTF8:
                return "JSON string was not valid UTF-8"
            case .missingAssetFileURL:
                return "CloudKit asset did not provide a file URL"
            case let .injectionFailed(path):
                return "Blob bundle injection failed at path \(path)"
            }
        }
    }

#endif
