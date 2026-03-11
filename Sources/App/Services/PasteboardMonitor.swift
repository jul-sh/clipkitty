import AppKit
import Foundation

enum DetectedPasteboardContent {
    case text(text: String, sourceApp: String?, sourceAppBundleId: String?)
    case image(data: Data, isAnimated: Bool, sourceApp: String?, sourceAppBundleId: String?)
    case files(urls: [URL], sourceApp: String?, sourceAppBundleId: String?)
}

@MainActor
final class PasteboardMonitor {
    enum PollingMode: Equatable {
        case active
        case idle
        case deepIdle

        static func mode(
            forIdleDuration idleDuration: Duration
        ) -> PollingMode {
            switch idleDuration {
            case ..<.seconds(30):
                return .active
            case ..<.seconds(300):
                return .idle
            default:
                return .deepIdle
            }
        }

        var intervalMilliseconds: Int {
            switch self {
            case .active:
                return 200
            case .idle:
                return 750
            case .deepIdle:
                return 2_000
            }
        }

        func adjustedForLowPowerMode() -> PollingMode {
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
            guard case .monitoring(let sleepObserver, let wakeObserver, _) = self else { return }
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
            case .monitoring(_, _, let isAsleep):
                return isAsleep
            }
        }
    }

    private let pasteboard: PasteboardProtocol
    private let workspace: WorkspaceProtocol
    private let onDetection: @MainActor (DetectedPasteboardContent) -> Void

    private var lastChangeCount: Int
    private var pollingTask: Task<Void, Never>?
    private var lastDetectionTime: ContinuousClock.Instant
    private var sleepMonitoring: SystemSleepMonitoring = .notMonitoring

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let legacyFileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    init(
        pasteboard: PasteboardProtocol,
        workspace: WorkspaceProtocol,
        onDetection: @escaping @MainActor (DetectedPasteboardContent) -> Void
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onDetection = onDetection
        self.lastChangeCount = pasteboard.changeCount
        self.lastDetectionTime = ContinuousClock.now - .seconds(30)
    }

    func start() {
        pollingTask?.cancel()
        setupSystemObservers()

        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if self.sleepMonitoring.isAsleep {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }

                self.checkForChanges()
                try? await Task.sleep(for: .milliseconds(self.currentPollingMode().intervalMilliseconds))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        removeSystemObservers()
    }

    func acknowledgeLocalWrite(changeCount: Int) {
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
            }
        }

        sleepMonitoring = .monitoring(
            sleepObserver: sleepObserver,
            wakeObserver: wakeObserver,
            isAsleep: false
        )
    }

    private func removeSystemObservers() {
        guard case .monitoring(let sleepObserver, let wakeObserver, _) = sleepMonitoring else { return }
        workspace.notificationCenter.removeObserver(sleepObserver)
        workspace.notificationCenter.removeObserver(wakeObserver)
        sleepMonitoring = .notMonitoring
    }

    static func pollingMode(
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

        let settings = AppSettings.shared
        let availableTypes = Set(pasteboard.types() ?? [])
        guard !availableTypes.isEmpty else { return }

        let sourceApplication = workspace.frontmostApplication
        let sourceAppBundleID = sourceApplication?.bundleIdentifier

        if settings.isAppIgnored(bundleId: sourceAppBundleID) {
            return
        }

        if settings.ignoreConfidentialContent, availableTypes.contains(Self.concealedType) {
            return
        }

        if settings.ignoreTransientContent, availableTypes.contains(Self.transientType) {
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
