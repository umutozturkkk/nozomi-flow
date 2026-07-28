import SwiftUI

/// Step 6: the playground. A real, focusable text view the hotkey flow can
/// insert into, so this is a genuine end-to-end test, not a simulation.
/// "Finish" lights up once a success phase has fired at least once while
/// this step has been on screen.
struct OnboardingTryItStep: View {
    let appState: AppState
    @Bindable var settings: SettingsStore
    let coordinator: DictationCoordinator
    var onBack: () -> Void
    var onFinish: () -> Void

    @State private var playgroundText = ""
    @State private var hasSucceededOnce = false
    @FocusState private var isFocused: Bool

    var body: some View {
        OnboardingStepScaffold(showBack: true, onBack: onBack, primary: primarySpec) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingStepIcon(systemName: "mic.and.signal.meter.fill")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Try it out")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("One quick test before you go.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                playgroundCard
                    .frame(maxHeight: .infinity)

                statusRow

                Button(action: runDebugSimulate) {
                    Text("Or run a 2-second test")
                        .font(.callout)
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

                Toggle("Launch Nozomi Flow at login", isOn: $settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .font(.callout)
            }
        }
        .onChange(of: appState.phase) { _, phase in
            if case .success = phase { hasSucceededOnce = true }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isFocused = true
        }
    }

    private var playgroundCard: some View {
        ZStack(alignment: .topLeading) {
            if playgroundText.isEmpty {
                Text("Click here, then hold \(settings.dictationKey.displayName) and say something…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 9)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $playgroundText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
        }
        .padding(10)
        .frame(minHeight: 100)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            switch appState.phase {
            case .idle:
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                Text("Ready when you are.").foregroundStyle(.tertiary)
            case .recording:
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("Listening…").foregroundStyle(.primary)
                LevelMeterView(level: appState.audioLevel).frame(width: 64)
            case .processing:
                Image(systemName: "wand.and.stars").foregroundStyle(Color.indigo)
                Text("Polishing…").foregroundStyle(.primary)
            case .inserting:
                Image(systemName: "arrow.right.circle").foregroundStyle(Color.indigo)
                Text("Inserting…").foregroundStyle(.primary)
            case .success(let words):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                Text("Inserted \(words) word\(words == 1 ? "" : "s")").foregroundStyle(.primary)
            case .failure(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red)
                Text(error.userMessage).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .frame(height: 16)
        .animation(.easeOut(duration: 0.2), value: appState.phase)
    }

    private func runDebugSimulate() {
        isFocused = true
        coordinator.debugSimulate()
    }

    private var primarySpec: OnboardingButtonSpec {
        OnboardingButtonSpec(
            title: "Finish",
            systemImage: "sparkles",
            isEnabled: hasSucceededOnce,
            celebrate: hasSucceededOnce,
            action: finish
        )
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }
}
