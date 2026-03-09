import AppKit
import Foundation

enum DetectedPasteboardContent {
    case text(text: String, sourceApp: String?, sourceAppBundleId: String?)
    case image(data: Data, isAnimated: Bool, sourceApp: String?, sourceAppBundleId: String?)
    case files(urls: [URL], sourceApp: String?, sourceAppBundleId: String?)
}

@MainActor
final class PasteboardMonitor {
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
    private var lastActivityTime = Date()
    private var sleepMonitoring: SystemSleepMonitoring = .notMonitoring

    init(
        pasteboard: PasteboardProtocol,
        workspace: WorkspaceProtocol,
        onDetection: @escaping @MainActor (DetectedPasteboardContent) -> Void
    ) {
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onDetection = onDetection
        self.lastChangeCount = pasteboard.changeCount
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
                try? await Task.sleep(for: .milliseconds(self.adaptivePollingInterval()))
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
                self?.lastActivityTime = Date()
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

    private func adaptivePollingInterval() -> Int {
        let idleTime = Date().timeIntervalSince(lastActivityTime)

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return 2000
        }

        switch idleTime {
        case ..<5:
            return 250
        case ..<30:
            return 500
        case ..<120:
            return 1000
        default:
            return 1500
        }
    }

    private func checkForChanges() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }

        lastChangeCount = currentCount
        lastActivityTime = Date()

        let settings = AppSettings.shared
        let sourceAppBundleID = workspace.frontmostApplication?.bundleIdentifier

        if settings.isAppIgnored(bundleId: sourceAppBundleID) {
            return
        }

        if settings.ignoreConfidentialContent {
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            if pasteboard.data(forType: concealedType) != nil {
                return
            }
        }

        if settings.ignoreTransientContent {
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            if pasteboard.data(forType: transientType) != nil {
                return
            }
        }

        let sourceApp = workspace.frontmostApplication?.localizedName

        let fileURLs = pasteboard.readFileURLs()
        if !fileURLs.isEmpty {
            onDetection(.files(urls: fileURLs, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
            return
        }

        let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
        if let gifData = pasteboard.data(forType: gifType) {
            onDetection(.image(data: gifData, isAnimated: true, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
            return
        }

        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let rawData = pasteboard.data(forType: type) {
                onDetection(.image(data: rawData, isAnimated: false, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
                return
            }
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        onDetection(.text(text: text, sourceApp: sourceApp, sourceAppBundleId: sourceAppBundleID))
    }
}
