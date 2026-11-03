/*
 * Luoto — a fork of Atoll (DynamicIsland)
 * Copyright (C) 2026 amidamaru940 and Luoto contributors
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

import Foundation

/// What the island does when a drag that opened it seems to have left.
///
/// As the island opens its window grows under the pointer, and the system
/// reports the drag as gone for a moment before it comes straight back.
/// Closing on that moment opened and closed the island over and over, so
/// nothing could be dropped on it (owner, 02.11.2026). So it waits, and
/// closes only once the drag has really gone.
enum DragLeavePolicy {
    /// Long enough for the island to finish growing.
    static let grace: TimeInterval = 0.5

    enum Next: Equatable {
        /// The drag is back, or something else holds the island open.
        case keepOpen
        /// Still dragging over the island's window: look again later.
        case wait
        /// Let go over the island's window, not on a drop zone: the hover
        /// logic decides, as after any other drag.
        case recheckHover
        case close
    }

    static func decide(targeted: Bool, buttonHeld: Bool, pointerInsideWindow: Bool, holdOpen: Bool) -> Next {
        if targeted || holdOpen { return .keepOpen }
        guard pointerInsideWindow else { return .close }
        return buttonHeld ? .wait : .recheckHover
    }
}
