import AppKit

/// Short feedback sounds, like Wispr's record ping. Uses built-in system sounds.
@MainActor
enum SoundPlayer {
    static func playStart() { play("Tink") }
    static func playStop() { play("Pop") }
    static func playError() { play("Basso") }

    private static func play(_ name: String) {
        guard Settings.shared.soundsEnabled else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
