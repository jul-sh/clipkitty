import SwiftUI

struct RadioDot: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 14, height: 14)
            if isSelected {
                // The system's text-on-selection color stays legible against
                // a light accent, where a hard-coded white dot disappears.
                Circle()
                    .fill(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: 5, height: 5)
            }
        }
    }
}
