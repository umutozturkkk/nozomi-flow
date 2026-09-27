import SwiftUI

// The floating "flow bar" pill -- Nozomi Flow's signature UI. One Liquid Glass
// capsule whose content, width and tint morph with the dictation phase.
// The hosting NSPanel stays a fixed 420x76; every size/position animation
// happens in here so AppKit never has to animate the window frame.

// MARK: - Root

struct HUDView: View {
    var appState: AppState
    var settings: SettingsStore

    var body: some View {
        ZStack {
            if appState.phase != .idle {
                HUDPill(
                    appState: appState,
                    settings: settings,
                    phase: appState.phase,
                    mode: appState.sessionMode
                )
                .transition(.asymmetric(
                    insertion: AnyTransition.offset(y: 14)
                        .combined(with: .scale(scale: 0.9, anchor: .bottom))
                        .combined(with: .opacity),
                    removal: AnyTransition.offset(y: 12)
                        .combined(with: .scale(scale: 0.94, anchor: .bottom))
                        .combined(with: .opacity)
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.phase == .idle)
    }
}

// MARK: - Pill

/// `phase`/`mode` are passed as plain values (not re-read from AppState) so
/// that while the exit transition plays after the coordinator flips to
/// `.idle`, the departing pill keeps rendering its last real content
/// instead of collapsing into an empty capsule.
private struct HUDPill: View {
    var appState: AppState
    var settings: SettingsStore
    var phase: DictationPhase
    var mode: SessionMode

    private var isCommand: Bool { mode == .command }

    var body: some View {
        ZStack { stateContent }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .frame(minWidth: 118)
            .glassEffect(glass, in: .capsule)
            .overlay {
                // Top rim light -- same craft detail as the onboarding keycap.
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .background {
                // Hand-rolled soft shadow (panel hasShadow = false). Kept as a
                // separate blurred capsule so text glyphs never grow shadows.
                Capsule()
                    .fill(Color.black.opacity(0.22))
                    .blur(radius: 12)
                    .offset(y: 5)
            }
            .geometryGroup()
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: animKey)
    }

    // MARK: State -> content

    @ViewBuilder
    private var stateContent: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .recording(_, let handsFree):
            RecordingRow(
                appState: appState,
                settings: settings,
                handsFree: handsFree,
                isCommand: isCommand
            )
            .transition(Self.swapTransition)
        case .processing:
            ThinkingRow(label: L10n.string(isCommand ? "hud.workingOnIt" : "hud.polishing"))
                .transition(Self.swapTransition)
        case .inserting:
            InsertingRow()
                .transition(Self.swapTransition)
        case .success(let wordCount):
            SuccessRow(wordCount: wordCount)
                .transition(Self.swapTransition)
        case .failure(let error):
            FailureRow(error: error)
                .transition(Self.swapTransition)
        }
    }

    /// Insertion pops in with a snappy spring; removal is a quick fade.
    private static let swapTransition: AnyTransition = .asymmetric(
        insertion: AnyTransition.scale(scale: 0.9)
            .combined(with: .opacity)
            .animation(.spring(response: 0.25, dampingFraction: 0.8)),
        removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12))
    )

    // MARK: State -> glass

    private var glass: Glass {
        switch phase {
        case .recording, .processing, .inserting:
            // Command sessions read violet; plain dictation stays neutral
            // (the red belongs to the recording dot, not the glass).
            return isCommand ? .regular.tint(Color.purple.opacity(0.18)) : .regular
        case .success:
            return .regular.tint(Color.green.opacity(0.14))
        case .failure(let error):
            return error == .cancelled
                ? .regular
                : .regular.tint(Color.red.opacity(0.16))
        case .idle:
            return .regular
        }
    }

    // MARK: Layout animation key

    /// Everything that changes the pill's footprint. One spring drives all
    /// width/content moves so fast phase flips stay interruptible.
    private var animKey: AnimKey {
        AnimKey(
            kind: PhaseKind(phase),
            command: isCommand,
            handsFree: {
                if case .recording(_, let hf) = phase { return hf }
                return false
            }(),
            transcriptShown: {
                guard case .recording = phase else { return false }
                return settings.showLiveTranscript && !appState.liveTranscript.isEmpty
            }()
        )
    }

    private struct AnimKey: Equatable {
        var kind: PhaseKind
        var command: Bool
        var handsFree: Bool
        var transcriptShown: Bool
    }

    private enum PhaseKind: Equatable {
        case idle, recording, processing, inserting, success, failure

        init(_ phase: DictationPhase) {
            switch phase {
            case .idle: self = .idle
            case .recording: self = .recording
            case .processing: self = .processing
            case .inserting: self = .inserting
            case .success: self = .success
            case .failure: self = .failure
            }
        }
    }
}

// MARK: - Recording

private struct RecordingRow: View {
    var appState: AppState
    var settings: SettingsStore
    var handsFree: Bool
    var isCommand: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isCommand {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom)
                    )
            } else {
                RecordingDot()
            }

            WaveformView(appState: appState)

            if handsFree {
                LockBadge()
                    .transition(AnyTransition.scale(scale: 0.5).combined(with: .opacity))
            }

            if settings.showLiveTranscript && !appState.liveTranscript.isEmpty {
                TranscriptTail(text: appState.liveTranscript)
                    .transition(AnyTransition.opacity.combined(with: .offset(x: 10)))
            }
        }
    }
}

/// Pulsing red-hot dot: soft glow halo + core, breathing on a ~1.6s loop.
private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.35))
                .frame(width: 16, height: 16)
                .blur(radius: 3)
                .scaleEffect(pulsing ? 1.3 : 0.75)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.36, blue: 0.30), .red],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 10, height: 10)
                .scaleEffect(pulsing ? 1.0 : 0.86)
                .opacity(pulsing ? 1.0 : 0.78)
        }
        .frame(width: 16, height: 16)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { pulsing = true }
    }
}

/// Hands-free lock that bounces in when the double-tap lock engages.
private struct LockBadge: View {
    @State private var appeared = false

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
            .onAppear { appeared = true }
    }
}

/// Last ~42 chars of the live transcript, single line, faded out at its
/// leading edge so new words appear to push old ones off to the left.
private struct TranscriptTail: View {
    var text: String

    var body: some View {
        Text(String(text.suffix(42)))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 168, alignment: .trailing)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.22),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
    }
}

// MARK: - Processing / inserting

/// Custom phased-scale dot row: a wave travels left-to-right through four
/// dots, each scaling and brightening as the crest passes.
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    let wave = sin((t * 2 * .pi / 1.1) - Double(i) * 0.9)
                    let n = (wave + 1) / 2
                    Circle()
                        .fill(.primary.opacity(0.3 + 0.55 * n))
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.7 + 0.5 * n)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ThinkingRow: View {
    var label: String

    var body: some View {
        HStack(spacing: 9) {
            ThinkingDots()
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct InsertingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(L10n.string("hud.inserting"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Success

private struct SuccessRow: View {
    var wordCount: Int
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
            Text(L10n.format(wordCount == 1 ? "hud.words.one" : "hud.words.other", wordCount))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Failure

private struct FailureRow: View {
    var error: DictationError
    @State private var shakes = 0

    private struct ShakeValue {
        var x: CGFloat = 0
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: error == .cancelled ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    error == .cancelled
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color.red.opacity(0.85))
                )
            Text(error.userMessage)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280)
        }
        // Gentle horizontal shake on appear; keyframes stay interruptible.
        .keyframeAnimator(initialValue: ShakeValue(), trigger: shakes) { content, value in
            content.offset(x: value.x)
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                CubicKeyframe(0, duration: 0.02)
                CubicKeyframe(-7, duration: 0.08)
                CubicKeyframe(6, duration: 0.09)
                CubicKeyframe(-3, duration: 0.09)
                CubicKeyframe(0, duration: 0.07)
            }
        }
        .onAppear { shakes += 1 }
    }
}

// MARK: - Previews

#Preview("Recording + transcript") {
    let state = AppState()
    state.phase = .recording(startedAt: Date(), handsFree: true)
    state.audioLevel = 0.5
    state.liveTranscript = "so the pill should widen once the live transcript arrives"
    return HUDView(appState: state, settings: SettingsStore())
        .frame(width: 420, height: 76)
}

#Preview("Success") {
    let state = AppState()
    state.phase = .success(wordCount: 42)
    return HUDView(appState: state, settings: SettingsStore())
        .frame(width: 420, height: 76)
}

#Preview("Failure") {
    let state = AppState()
    state.phase = .failure(.noSpeechDetected)
    return HUDView(appState: state, settings: SettingsStore())
        .frame(width: 420, height: 76)
}
