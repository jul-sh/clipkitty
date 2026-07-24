import SwiftUI

/// A horizontal allotment bar that sets the storage limit and visualizes how
/// much of it is already used.
///
/// The draggable handle sets the limit on a logarithmic scale; the filled
/// region grows from the left toward the handle as history accumulates. When
/// the fill reaches the handle the allotted space is full and the oldest
/// items are overwritten in place, the same way the underlying storage
/// recycles itself.
public struct StorageBarView: View {
    @Binding private var limitGB: Double
    private let usedBytes: Int64
    private let scale: StorageLimitScale
    private let onEditingEnded: () -> Void

    @State private var isDragging = false

    public init(
        limitGB: Binding<Double>,
        usedBytes: Int64,
        scale: StorageLimitScale = StorageLimitScale(),
        onEditingEnded: @escaping () -> Void = {}
    ) {
        _limitGB = limitGB
        self.usedBytes = usedBytes
        self.scale = scale
        self.onEditingEnded = onEditingEnded
    }

    private let trackHeight: CGFloat = 26
    private let handleWidth: CGFloat = 9
    private let handleOvershoot: CGFloat = 5

    private var limitPosition: Double {
        scale.position(forGB: limitGB)
    }

    /// How much of the allotted space is used, in `0...1`.
    private var usedFraction: Double {
        let limitBytes = Utilities.bytes(fromGB: limitGB)
        guard limitBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(limitBytes), 0), 1)
    }

    private var isFull: Bool {
        usedFraction >= 0.999
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Utilities.formatBytes(usedBytes))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if isFull {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(String(localized: "of \(Self.formatGB(limitGB))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }

            GeometryReader { proxy in
                track(width: proxy.size.width)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: proxy.size.width))
            }
            .frame(height: trackHeight + handleOvershoot * 2)

            HStack {
                Text(Self.formatGB(scale.minGB))
                Spacer(minLength: 0)
                Text(Self.formatGB(scale.maxGB))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .animation(isDragging ? nil : .snappy(duration: 0.35), value: limitGB)
        .animation(.snappy(duration: 0.45), value: usedBytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Storage Limit")))
        .accessibilityValue(
            Text(
                String(
                    localized:
                    "\(Self.formatGB(limitGB)) limit, \(Utilities.formatBytes(usedBytes)) used"
                )
            )
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                limitGB = scale.adjusting(limitGB, by: 1)
            case .decrement:
                limitGB = scale.adjusting(limitGB, by: -1)
            @unknown default:
                return
            }
            onEditingEnded()
        }
        .help(String(localized: "Drag to set the storage limit"))
    }

    // MARK: - Pieces

    private func track(width: CGFloat) -> some View {
        let allotmentWidth = allotmentWidth(in: width)
        let fillWidth = fillWidth(allotmentWidth: allotmentWidth)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(.quaternary.opacity(0.5))
                .frame(height: trackHeight)

            Capsule()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: allotmentWidth, height: trackHeight)

            if fillWidth > 0 {
                Capsule()
                    .fill(fillGradient)
                    .frame(width: fillWidth, height: trackHeight)
            }

            handle
                .position(
                    x: allotmentWidth - handleWidth / 2 - 2,
                    y: trackHeight / 2 + handleOvershoot
                )
        }
        .frame(height: trackHeight + handleOvershoot * 2)
    }

    private var handle: some View {
        Capsule()
            .fill(.background)
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: handleWidth, height: trackHeight + handleOvershoot * 2)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .scaleEffect(isDragging ? 1.1 : 1)
            .animation(.snappy(duration: 0.2), value: isDragging)
    }

    private var fillGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.45), Color.accentColor],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private static func formatGB(_ gb: Double) -> String {
        gb >= 1
            ? String(localized: "\(gb, specifier: "%.0f") GB")
            : String(localized: "\(gb, specifier: "%.1f") GB")
    }

    // MARK: - Geometry

    /// Width of the allotted region: from the left edge to the handle. Never
    /// narrower than the capsule's end caps so it stays visually coherent.
    private func allotmentWidth(in width: CGFloat) -> CGFloat {
        let minWidth = trackHeight
        return minWidth + (width - minWidth) * limitPosition
    }

    /// Width of the usage fill inside the allotment. Anything stored at all
    /// shows as a visible dot.
    private func fillWidth(allotmentWidth: CGFloat) -> CGFloat {
        guard usedBytes > 0 else { return 0 }
        return max(allotmentWidth * usedFraction, trackHeight)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let minWidth = trackHeight
                let position = (value.location.x - minWidth) / max(width - minWidth, 1)
                limitGB = scale.gb(forPosition: position)
            }
            .onEnded { _ in
                isDragging = false
                onEditingEnded()
            }
    }
}

#Preview {
    StorageBarPreviewHost()
}

private struct StorageBarPreviewHost: View {
    @State private var limitGB = 7.0

    var body: some View {
        StorageBarView(limitGB: $limitGB, usedBytes: 2_470_000_000)
            .frame(width: 360)
            .padding()
    }
}
