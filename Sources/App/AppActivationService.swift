import AppKit

@MainActor
final class AppActivationService {
    private let workspace: WorkspaceProtocol

    init(workspace: WorkspaceProtocol = NSWorkspace.shared) {
        self.workspace = workspace
    }

    func frontmostApplication() -> NSRunningApplication? {
        workspace.frontmostApplication
    }

    func activate(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        app.activate()
    }

    func simulatePaste(to targetApp: NSRunningApplication?) {
        guard let targetApp, !targetApp.isTerminated else {
            return
        }

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
}
