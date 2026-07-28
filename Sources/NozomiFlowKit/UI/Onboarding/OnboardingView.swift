import SwiftUI
import AppKit

/// The six stops of first-run setup, in order. Raw values double as the
/// progress-dot index, so `OnboardingProgressDots` and Back/Continue math
/// stay trivial.
enum OnboardingStep: Int, CaseIterable, Hashable {
    case welcome
    case microphone
    case accessibility
    case hotkey
    case speechModel
    case tryIt
}

/// Which way we're navigating, so the asymmetric slide transition points
/// the right direction (forward = new content slides in from the right;
/// back = it slides in from the left).
enum OnboardingDirection {
    case forward
    case backward
}

/// Root view: owns the step state machine, the top progress dots, and the
/// springy slide/fade transition between steps. Each step is a self-contained
/// view that renders its own content + bottom bar via `OnboardingStepScaffold`.
struct OnboardingRootView: View {
    let appState: AppState
    let settings: SettingsStore
    let permissions: PermissionsService
    let transcriber: TranscriptionServiceProtocol
    let coordinator: DictationCoordinator
    var onAccessibilityGranted: () -> Void
    var onFinish: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var direction: OnboardingDirection = .forward

    var body: some View {
        ZStack(alignment: .top) {
            background
            VStack(spacing: 0) {
                OnboardingProgressDots(total: OnboardingStep.allCases.count, current: step.rawValue)
                    .padding(.top, 22)
                    .padding(.bottom, 2)
                stepContainer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var stepContainer: some View {
        ZStack {
            switch step {
            case .welcome:
                OnboardingWelcomeStep(onNext: advance)
            case .microphone:
                OnboardingMicrophoneStep(appState: appState, permissions: permissions, onBack: retreat, onNext: advance)
            case .accessibility:
                OnboardingAccessibilityStep(
                    appState: appState,
                    permissions: permissions,
                    onAccessibilityGranted: onAccessibilityGranted,
                    onBack: retreat,
                    onNext: advance
                )
            case .hotkey:
                OnboardingHotkeyStep(settings: settings, onBack: retreat, onNext: advance)
            case .speechModel:
                OnboardingSpeechModelStep(appState: appState, settings: settings, transcriber: transcriber, onBack: retreat, onNext: advance)
            case .tryIt:
                OnboardingTryItStep(appState: appState, settings: settings, coordinator: coordinator, onBack: retreat, onFinish: onFinish)
            }
        }
        .id(step)
        .transition(
            .asymmetric(
                insertion: .move(edge: direction == .forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: direction == .forward ? .leading : .trailing).combined(with: .opacity)
            )
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.indigo.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        direction = .forward
        step = next
    }

    private func retreat() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        direction = .backward
        step = previous
    }
}
