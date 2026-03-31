import AppKit
import Foundation

public enum DetectedPasteboardContent {
    case text(text: String, sourceApp: String?, sourceAppBundleId: String?)
    case image(data: Data, isAnimated: Bool, sourceApp: String?, sourceAppBundleId: String?)
    case files(urls: [URL], sourceApp: String?, sourceAppBundleId: String?)
}

@MainActor
public final class PasteboardMonitor {
    public enum PollingMode: Equatable {
        case active
        case idle
        case deepIdle

        public static func mode(
            forIdleDuration idleDuration: Duration
        ) -> PollingMode {
            if idleDuration < .seconds(30) {
                return .active
            } else if idleDuration < .seconds(300) {
                return .idle
            } else {
                return .deepIdle
            }
        }

        public var intervalMilliseconds: Int {
            switch self {
            case .active:
                return 200
            case .idle:
                return 750
            case .deepIdle:
                return 1500
            }
        }

        public func adjustedForLowPowerMode() -> PollingMode {
            switch self {
            case .active:
                return .idle
            case .idle:
                return .deepIdle
            case .deepIdle:
                return self
            }
        }
    }

    private enum SystemSleepMonitoring {
        case notMonitoring
        case monitoring(sleepObserver: NSObjectProtocol, wakeObserver: NSObjectProtocol, isAsleep: Bool)

        mutating func setAsleep(_ asleep: Bool) {
            guard case let .monitoring(sleepObserver, wakeObserver, _) = self else { return }
            self = .monitoring(
                sleepObserver: sleepObserver,
                wakeObserver: wakeObserver,
                isAsleep: asleep
            )
        }

        var isAsleep: Bool {
            switch self {
            case .notMonitoring:
                return false
            case let .monitoring(_, _, isAsleep):
                return isAsleep
            }
        }
    }

    /// Configuration for content filtering, injected from the app layer.
    public struct FilterConfiguration {
        public let isAppIgnored: (String?) -> Bool
        public let ignoreConfidentialContent: Bool
        public let ignoreTransientContent: Bool

        public init(
            isAppIgnored: @escaping (String?) -> Bool,
            ignoreConfidentialContent: Bool,
            ignoreTransientContent: Bool
        ) {
            self.isAppIgnored = isAppIgnored
            self.ignoreConfidentialContent = ignoreConfidentialContent
            self.ignoreTransientContent = ignoreTransientContent
        }
    }

    private let pasteboard: PasteboardProtocol
    private let workspace: WorkspaceProtocol
    private let onDetection: @MainActor (DetectedPasteboardContent) -> Void
    private let filterConfiguration: @MainActor () -> FilterConfiguration

    private var lastChangeCount: Int
    private var pollingTask: Task<Void, Never>?
    private var lastDetectionTime: ContinuousClock.Instant
    private var sleepMonitoring: SystemSleepMonitoring = .notMonitoring
    private var wakeContinuation: AsyncStream<Void>.Continuation?

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let legacyFileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    public init(
        pasteboard: PasteboardProtocol,
        workspace: WorkspaceProtocol,
        filterConfiguration: @escaping @MainActor () -> FilterConfiguration,
        onDetection: @escaping @MainActor (DetectedPasteboardContent) -> Void
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.filterConfiguration = filterConfiguration
        self.onDetection = onDetection
        lastChangeCount = pasteboard.changeCount
        lastDetectionTime = ContinuousClock.now - .seconds(30)
    }

    public func start() {
        pollingTask?.cancel()
        setupSystemObservers()

        let (wakeStream, wakeContinuation) = AsyncStream.makeStream(of: Void.self)
        self.wakeContinuation = wakeContinuation

        pollingTask = Task { @MainActor [weak self] in
            var wakeIterator = wakeStream.makeAsyncIterator()

            while !Task.isCancelled {
                guard let self else { return }

                if self.sleepMonitoring.isAsleep {
                    _ = await wakeIterator.next()
                    continue
                }

                self.checkForChanges()
                try? await Task.sleep(for: .milliseconds(self.currentPollingMode().intervalMilliseconds))
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        wakeContinuation?.finish()
        wakeContinuation = nil
        removeSystemObservers()
    }

    public func acknowledgeLocalWrite(changeCount: Int) {
        lastChangeCount = changeCount
    }

    private func setupSystemObservers() {
        let nc = workspace.notificationCenter

        let sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleepMonitoring.setAsleep(true)
            }
        }

        let wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleepMonitoring.setAsleep(false)
                self?.lastDetectionTime = ContinuousClock.now
                self?.wakeContinuation?.yield()
            }
        }

        sleepMonitoring = .monitoring(
            sleepObserver: sleepObserver,
            wakeObserver: wakeObserver,
            isAsleep: false
        )
    }

    private func removeSystemObservers() {
        guard case let .monitoring(sleepObserver, wakeObserver, _) = sleepMonitoring else { return }
        workspace.notificationCenter.removeObserver(sleepObserver)
        workspace.notificationCenter.removeObserver(wakeObserver)
        sleepMonitoring = .notMonitoring
    }

    public static func pollingMode(
        now: ContinuousClock.Instant,
        lastDetectionTime: ContinuousClock.Instant,
        isLowPowerModeEnabled: Bool
    ) -> PollingMode {
        let idleDuration = lastDetectionTime.duration(to: now)
        let baseMode = PollingMode.mode(forIdleDuration: idleDuration)

        if isLowPowerModeEnabled {
            return baseMode.adjustedForLowPowerMode()
        }
        return baseMode
    }

    private func currentPollingMode() -> PollingMode {
        Self.pollingMode(
            now: ContinuousClock.now,
            lastDetectionTime: lastDetectionTime,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private func checkForChanges() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }

        lastChangeCount = currentCount
        lastDetectionTime = ContinuousClock.now

        let filter = filterConfiguration()
        let availableTypes = Set(pasteboard.types() ?? [])
        guard !availableTypes.isEmpty else { return }

        let sourceApplication = workspace.frontmostApplication
        let sourceAppBundleID = sourceApplication?.bundleIdentifier

        if filter.isAppIgnored(sourceAppBundleID) {
            return
        }

        if filter.ignoreConfidentialContent, availableTypes.contains(Self.concealedType) {
            return
        }

        if filter.ignoreTransientContent, availableTypes.contains(Self.transientType) {
            return
        }

        let sourceApp = sourceApplication?.localizedName

        if availableTypes.contains(.fileURL) || availableTypes.contains(Self.legacyFileNamesType) {
            let fileURLs = pasteboard.readFileURLs()
            if !fileURLs.isEmpty {
                onDetection(.files(urls: fileURLs, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
                return
            }
        }

        if availableTypes.contains(Self.gifType), let gifData = pasteboard.data(forType: Self.gifType) {
            onDetection(.image(data: gifData, isAnimated: true, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
            return
        }

        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            guard availableTypes.contains(type) else { continue }
            if let rawData = pasteboard.data(forType: type) {
                onDetection(.image(data: rawData, isAnimated: false, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
                return
            }
        }

        guard availableTypes.contains(.string) else { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        onDetection(.text(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
    }
}
