import AppKit

/// Subtle audio cues for record start/stop. Kept quiet on purpose.
@MainActor
final class SoundPlayer {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func playStart() { play(named: "Pop", volume: 0.25) }
    func playStop() { play(named: "Tink", volume: 0.2) }
    func playError() { play(named: "Basso", volume: 0.2) }

    private func play(named name: String, volume: Float) {
        guard settings.playSounds else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
