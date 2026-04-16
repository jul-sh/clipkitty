import AppKit

public enum SyntheticPasteBehavior {
    case copyOnly
    case paste(targetApp: NSRunningApplication)
}

enum RemoteDesktopApp: CaseIterable, Equatable {
    case microsoftRemoteDesktop
    case royalTSX

    static func detect(bundleIdentifier: String?, localizedName: String?) -> RemoteDesktopApp? {
        for candidate in allCases {
            if candidate.matches(bundleIdentifier: bundleIdentifier, localizedName: localizedName) {
                return candidate
            }
        }
        return nil
    }

    private func matches(bundleIdentifier: String?, localizedName: String?) -> Bool {
        switch self {
        case .microsoftRemoteDesktop:
            if let bundleIdentifier,
               bundleIdentifier.hasPrefix("com.microsoft.rdc")
            {
                return true
            }
            if let localizedName {
                switch true {
                case localizedName.localizedCaseInsensitiveContains("Microsoft Remote Desktop"),
                     localizedName.localizedCaseInsensitiveContains("Windows App"):
                    return true
                default:
                    break
                }
            }
            return false
        case .royalTSX:
            if let bundleIdentifier,
               bundleIdentifier.localizedCaseInsensitiveContains("RoyalTSX")
            {
                return true
            }
            if let localizedName,
               localizedName.localizedCaseInsensitiveContains("Royal TSX")
            {
                return true
            }
            return false
        }
    }
}

@MainActor
public final class AppActivationService {
    private let workspace: WorkspaceProtocol

    public init(workspace: WorkspaceProtocol = NSWorkspace.shared) {
        self.workspace = workspace
    }

    public func frontmostApplication() -> NSRunningApplication? {
        workspace.frontmostApplication
    }

    public func activate(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        app.activate()
    }

    #if ENABLE_SYNTHETIC_PASTE
        public func syntheticPasteBehavior(for targetApp: NSRunningApplication?) -> SyntheticPasteBehavior {
            guard let targetApp, !targetApp.isTerminated else {
                return .copyOnly
            }

            // RDP clients lazily sync clipboard contents and can leave modifiers stuck
            // if we immediately synthesize Cmd+V, so fall back to manual paste.
            if RemoteDesktopApp.detect(
                bundleIdentifier: targetApp.bundleIdentifier,
                localizedName: targetApp.localizedName
            ) != nil {
                return .copyOnly
            }

            return .paste(targetApp: targetApp)
        }

        public func simulatePaste(to targetApp: NSRunningApplication) {
            guard !targetApp.isTerminated else { return }

            Task {
                for _ in 0 ..< 50 {
                    guard !targetApp.isTerminated else { return }
                    if workspace.frontmostApplication == targetApp {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }

                await MainActor.run {
                    guard let source = CGEventSource(stateID: .hidSystemState) else {
                        return
                    }

                    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
                        return
                    }
                    keyDown.flags = .maskCommand
                    keyDown.post(tap: .cgSessionEventTap)

                    guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                        return
                    }
                    keyUp.flags = .maskCommand
                    keyUp.post(tap: .cgSessionEventTap)
                }
            }
        }
    #endif
}
