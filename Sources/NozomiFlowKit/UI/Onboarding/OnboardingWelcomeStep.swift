import SwiftUI
import AppKit

/// Step 1: the hero screen. App icon, name, tagline, three staggered value
/// bullets. No Back button (nothing to go back to).
struct OnboardingWelcomeStep: View {
    var onNext: () -> Void

    var body: some View {
        OnboardingStepScaffold(
            showBack: false,
            onBack: {},
            primary: OnboardingButtonSpec(title: "Get Started", systemImage: "arrow.right", action: onNext)
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 4)

                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)

                VStack(spacing: 8) {
                    Text("Nozomi Flow")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Don't type. Just murmur.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Takes about a minute to set up.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    WelcomeBullet(icon: "waveform", text: "Speak into any app", delay: 0.22)
                    WelcomeBullet(icon: "sparkles", text: "AI cleans it up", delay: 0.36)
                    WelcomeBullet(icon: "lock.shield", text: "Everything stays on this Mac", delay: 0.50)
                }
                .padding(.horizontal, 36)

                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One value-prop row that fades/slides in and bounces its icon after `delay`.
private struct WelcomeBullet: View {
    var icon: String
    var text: String
    var delay: Double

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.murmurAccent)
                .symbolEffect(.bounce, value: appeared)
                .frame(width: 26)
            Text(text)
                .font(.body)
            Spacer(minLength: 0)
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -14)
        .task {
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                appeared = true
            }
        }
    }
}
