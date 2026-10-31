/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import AVFoundation

/// What the app plays. All of these are macOS system sounds, asked for by name,
/// so no sound file ships with the app: the bundled ones came with Atoll with no
/// known source or licence.
enum AppSound: String, CaseIterable {
    case welcome = "Hero"
    case lock = "Bottle"
    case unlock = "Pop"
    case lowBattery = "Funk"
    case timer = "Glass"
    case volumeFeedback = "Tink"

    /// Plays from the start, also while the sound is still playing.
    func play() {
        guard let sound = NSSound(named: rawValue) else { return }
        sound.stop()
        sound.play()
    }

    /// A copy of its own that repeats until it is stopped.
    func looping() -> NSSound? {
        guard let sound = NSSound(named: rawValue)?.copy() as? NSSound else { return nil }
        sound.loops = true
        return sound
    }
}

/// The timer's ring: the file the person chose if it still plays, otherwise a
/// system sound. It repeats until it is stopped.
final class TimerRing {
    private let volume: Float
    private var player: AVAudioPlayer?
    private var systemSound: NSSound?

    init(volume: Float = 1) {
        self.volume = volume
    }

    var isRinging: Bool {
        player?.isPlaying == true || systemSound?.isPlaying == true
    }

    func start(customPath: String?) {
        stop()
        if let customPath, !customPath.isEmpty,
           let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: customPath)) {
            player.numberOfLoops = -1 // Loop indefinitely
            player.volume = volume
            if player.play() {
                self.player = player
                return
            }
        }
        systemSound = AppSound.timer.looping()
        systemSound?.volume = volume
        if systemSound?.play() != true {
            NSSound.beep()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        systemSound?.stop()
        systemSound = nil
    }
}
