import SwiftUI

/// A small System Settings-style icon chip: an SF Symbol centered on a
/// rounded gradient tile. Used for the settings sidebar rows.
struct SettingsIconChip: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint, tint.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

/// A small colored status dot for permission/availability rows -- green when
/// good, otherwise `badColor` (defaults to orange; callers needing a strict
/// red/green reading, like permission grants, pass `.red`).
struct StatusDot: View {
    let isGood: Bool
    var goodColor: Color = .green
    var badColor: Color = .orange

    var body: some View {
        Circle()
            .fill(isGood ? goodColor : badColor)
            .frame(width: 7, height: 7)
    }
}
