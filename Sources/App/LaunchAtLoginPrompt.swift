import AppKit
import SwiftUI

private struct PromptBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
    }
}

private struct LaunchAtLoginPromptView: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.orange)

            Text("Launch at Login")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Button("Enable") {
                onEnable()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 4)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .modifier(PromptBackgroundModifier())
    }
}

@MainActor
final class LaunchAtLoginPrompt {
    private var window: NSWindow?
    var onEnable: (() -> Void)?
    var onDismiss: (() -> Void)?

    func show(relativeTo panelFrame: NSRect) {
        let view = LaunchAtLoginPromptView(
            onEnable: { [weak self] in
                self?.onEnable?()
                self?.hide()
            },
            onDismiss: { [weak self] in
                self?.onDismiss?()
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        if let existingWindow = window {
            existingWindow.contentView = hostingView
            positionWindow(existingWindow, size: fittingSize, relativeTo: panelFrame)
            existingWindow.orderFront(nil)
            return
        }

        let promptWindow = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        promptWindow.level = .floating
        promptWindow.backgroundColor = .clear
        promptWindow.isOpaque = false
        promptWindow.hasShadow = true
        promptWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        promptWindow.contentView = hostingView
        promptWindow.ignoresMouseEvents = false

        positionWindow(promptWindow, size: fittingSize, relativeTo: panelFrame)

        // Animate in
        promptWindow.alphaValue = 0
        var startFrame = promptWindow.frame
        startFrame.origin.y += 10
        promptWindow.setFrame(startFrame, display: false)
        promptWindow.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var endFrame = promptWindow.frame
            endFrame.origin.y -= 10
            promptWindow.animator().setFrame(endFrame, display: true)
            promptWindow.animator().alphaValue = 1
        }

        window = promptWindow
    }

    func hide() {
        guard let window else { return }
        self.window = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var endFrame = window.frame
            endFrame.origin.y += 10
            window.animator().setFrame(endFrame, display: true)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    private func positionWindow(_ window: NSWindow, size: NSSize, relativeTo panelFrame: NSRect) {
        // Position below the panel, aligned to the left edge
        let x = panelFrame.minX
        let y = panelFrame.minY - size.height - 8
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
