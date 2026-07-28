import SwiftUI

// Shared visual language for the onboarding flow: every step is built from
// these pieces so the six screens read as one crafted object, not six
// separately-designed wizard pages.

// MARK: - Shared accent

extension ShapeStyle where Self == LinearGradient {
    /// The onboarding flow's signature indigo -> violet accent.
    static var murmurAccent: LinearGradient {
        LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Bottom bar chrome

/// Declarative description of a bottom-bar action button. Steps hand these to
/// `OnboardingStepScaffold` so button placement/styling never has to be
/// re-implemented per step, only the label/action/enabled state changes.
struct OnboardingButtonSpec {
    var title: String
    var systemImage: String? = nil
    var isEnabled: Bool = true
    /// Flips true to play a one-shot `.bounce` on the icon (e.g. the Finish sparkle).
    var celebrate: Bool = false
    var action: () -> Void
}

/// Pinned footer shared by every step: optional Back on the leading edge,
/// optional secondary + primary action on the trailing edge. A step that
/// wants no primary button (e.g. mid-auto-advance) just passes `nil`.
struct OnboardingBottomBar: View {
    var showBack: Bool
    var onBack: () -> Void
    var secondary: OnboardingButtonSpec?
    var primary: OnboardingButtonSpec?

    var body: some View {
        HStack(spacing: 12) {
            if showBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
            Spacer(minLength: 12)
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!secondary.isEnabled)
            }
            if let primary {
                Button(action: primary.action) {
                    HStack(spacing: 6) {
                        Text(primary.title)
                        if let systemImage = primary.systemImage {
                            Image(systemName: systemImage)
                                .symbolEffect(.bounce, value: primary.celebrate)
                        }
                    }
                    .frame(minWidth: 40)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.indigo)
                .disabled(!primary.isEnabled)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: primary?.title)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: primary?.isEnabled)
    }
}

// MARK: - Step scaffold

/// Consistent 24pt content padding + pinned bottom bar for every step, so
/// only the middle content differs between screens.
struct OnboardingStepScaffold<Content: View>: View {
    var showBack: Bool
    var onBack: () -> Void
    var secondary: OnboardingButtonSpec? = nil
    var primary: OnboardingButtonSpec?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            content()
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardingBottomBar(showBack: showBack, onBack: onBack, secondary: secondary, primary: primary)
        }
    }
}

// MARK: - Step icon

/// Large hierarchical step icon (56pt, indigo -> violet gradient) with a
/// one-time bounce when the step appears.
struct OnboardingStepIcon: View {
    var systemName: String
    @State private var bounced = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 56, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.murmurAccent)
            .symbolEffect(.bounce, value: bounced)
            .task { bounced = true }
    }
}

// MARK: - Status chip

/// Small state card used by the permission and model steps: neutral while
/// waiting, green on success, red/amber on trouble.
struct OnboardingStatusChip: View {
    enum Style { case neutral, success, warning }

    var icon: String
    var title: String
    var subtitle: String? = nil
    var style: Style
    var bounce: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iconStyle)
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(glass, in: .rect(cornerRadius: 14))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: title)
    }

    private var iconStyle: AnyShapeStyle {
        switch style {
        case .neutral: return AnyShapeStyle(.secondary)
        case .success: return AnyShapeStyle(Color.green)
        case .warning: return AnyShapeStyle(Color.red)
        }
    }

    private var glass: Glass {
        switch style {
        case .neutral: return .regular
        case .success: return .regular.tint(Color.green.opacity(0.16))
        case .warning: return .regular.tint(Color.red.opacity(0.14))
        }
    }
}

// MARK: - Keycap

/// Big glass "keycap" showing the current dictation hotkey.
struct KeycapView: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(.murmurAccent)
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .glassEffect(.regular.tint(Color.indigo.opacity(0.12)), in: .rect(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .contentTransition(.opacity)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: label)
    }
}

// MARK: - Level meter

/// Compact horizontal mic-level bar, 0...1, used in the "Try it" playground.
struct LevelMeterView: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(.murmurAccent)
                    .frame(width: max(4, geo.size.width * CGFloat(min(max(level, 0), 1))))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

// MARK: - Progress dots

/// 6-segment progress indicator at the top of the window. The current step's
/// dot elongates into a pill; passed steps stay filled; upcoming steps are dim.
struct OnboardingProgressDots: View {
    var total: Int
    var current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(style(for: index))
                    .frame(width: index == current ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: current)
    }

    private func style(for index: Int) -> AnyShapeStyle {
        index <= current ? AnyShapeStyle(.murmurAccent) : AnyShapeStyle(Color.secondary.opacity(0.25))
    }
}
