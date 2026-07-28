import SwiftUI
import Foundation

// MARK: - Ring buffer

/// Fixed-capacity ring of recent mic-level samples, oldest at index 0 and
/// newest at `capacity - 1`. A plain value type so it's trivial to unit test
/// in isolation from SwiftUI/Canvas.
struct WaveformRingBuffer: Equatable {
    private var storage: [Float]
    private var head = 0
    let capacity: Int

    init(capacity: Int = 28) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: 0, count: self.capacity)
    }

    /// Pushes a new sample, overwriting the oldest one. O(1), no allocation.
    mutating func push(_ value: Float) {
        storage[head] = value
        head = (head + 1) % capacity
    }

    /// index 0 = oldest sample, index (capacity - 1) = newest.
    subscript(index: Int) -> Float {
        storage[(head + index) % capacity]
    }
}

// MARK: - Model

/// Drives the waveform: raw ring-buffer samples plus an eased "displayed"
/// copy so every bar glides toward its target height instead of snapping.
/// A class held in `@State` so one instance persists for the view's
/// lifetime; mutated in place from the draw loop, never reallocates.
final class WaveformModel {
    let capacity: Int
    private var ring: WaveformRingBuffer
    private(set) var displayed: [Float]
    private(set) var isSilent = false

    private var lastLevel: Float = 0
    private var lastPushAt: TimeInterval = 0
    private var lastLoudAt: TimeInterval = 0

    private let easing: Float = 0.35
    private let loudThreshold: Float = 0.05
    /// Seconds of near-silence before the flat dotted baseline look kicks in.
    private let silenceAfter: TimeInterval = 0.8
    /// If no fresh sample arrived for ~2 frames, re-push the last one so the
    /// scope keeps scrolling (onChange stops firing on identical values).
    private let repushAfter: TimeInterval = 1.0 / 15.0

    init(capacity: Int = 28) {
        self.capacity = capacity
        self.ring = WaveformRingBuffer(capacity: capacity)
        self.displayed = Array(repeating: 0, count: capacity)
    }

    /// Call whenever a fresh mic level arrives (~30 Hz while recording).
    func push(level: Float) {
        let clamped = min(max(level, 0), 1)
        ring.push(clamped)
        lastLevel = clamped
        let now = Date.timeIntervalSinceReferenceDate
        lastPushAt = now
        if clamped >= loudThreshold { lastLoudAt = now }
    }

    /// Call every animation frame. Keeps the scroll alive during silence and
    /// eases displayed heights toward targets. O(capacity), allocation-free.
    func tick(now: TimeInterval) {
        if now - lastPushAt > repushAfter {
            ring.push(lastLevel)
            lastPushAt = now
        }
        for i in 0..<capacity {
            displayed[i] += (ring[i] - displayed[i]) * easing
        }
        isSilent = now - lastLoudAt > silenceAfter
    }

    func barHeight(at index: Int) -> CGFloat {
        4 + CGFloat(displayed[index]) * 32
    }
}

// MARK: - View

/// Live mic-level scope: newest sample on the right, scrolling left like an
/// oscilloscope. Driven by the real `appState.audioLevel` stream, not a
/// canned sine -- sustained silence settles into a softly breathing dotted
/// baseline (the "still listening, just quiet" Wispr detail) instead of
/// going dead. Reads audioLevel inside its own body so the ~30 Hz updates
/// only invalidate this small view, not the whole pill.
struct WaveformView: View {
    var appState: AppState

    @State private var model = WaveformModel()

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2.5
    private let barMaxHeight: CGFloat = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            Canvas { context, size in
                model.tick(now: timeline.date.timeIntervalSinceReferenceDate)
                draw(into: &context, size: size, now: timeline.date)
            }
            .frame(width: canvasWidth, height: barMaxHeight)
        }
        .onChange(of: appState.audioLevel) { _, newValue in
            model.push(level: newValue)
        }
        .onAppear { model.push(level: appState.audioLevel) }
        .accessibilityHidden(true)
    }

    private var canvasWidth: CGFloat {
        CGFloat(model.capacity) * barWidth + CGFloat(model.capacity - 1) * barSpacing
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, now: Date) {
        let step = barWidth + barSpacing
        let midY = size.height / 2
        let lastIndex = max(model.capacity - 1, 1)
        // Slow shared breathing applied only while silent, so the baseline
        // reads as "idle but alive" rather than frozen.
        let breathe = model.isSilent
            ? sin(now.timeIntervalSinceReferenceDate * 2.4) * 0.5 + 0.5
            : 1.0

        for i in 0..<model.capacity {
            let height = model.barHeight(at: i)
            let x = CGFloat(i) * step
            let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)

            // Newest (right) bars are brightest; older ones fall off.
            let newness = Double(i) / Double(lastIndex)
            var opacity = 0.28 + 0.72 * newness
            if model.isSilent { opacity *= 0.45 + 0.4 * breathe }

            context.fill(path, with: .color(.primary.opacity(opacity)))
        }
    }
}

#Preview("Waveform") {
    let state = AppState()
    state.audioLevel = 0.5
    return WaveformView(appState: state)
        .padding(24)
        .background(.black)
}
