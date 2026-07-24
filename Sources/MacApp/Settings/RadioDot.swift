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
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
            }
        }
    }
}
