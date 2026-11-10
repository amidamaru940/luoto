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

import AppKit
import Combine
import os
import SwiftUI

/// Closed-island indicator while Keep Awake is on, so it is visible without
/// opening the island: [cup] ─── [ notch ] ─── [∞ or "45 min"].
///
/// A state that can last hours, so it rests in grey below tasks; only
/// the warning triangle is yellow. Both wings are one width for the whole
/// session, so the island stays centred on the notch and never twitches
/// as the minutes go by. Where the frontmost app's menus reach the notch the
/// wings fold away instead (`KeepAwakeFold`).
struct KeepAwakeLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @Environment(\.colorSchemeContrast) private var contrast
    // Taken through `onReceive` with duplicates removed, not by observing the
    // managers: `CaffeinateManager` republishes `remainingTime` every second.
    @State private var value = CaffeinateManager.shared.closedLabel
    @State private var timed = CaffeinateManager.shared.expiresAt != nil
    @State private var phase = LidAwakeController.shared.phase

    /// The glyphs' box: the cup, laptop, triangle and ∞ are all this wide.
    static let glyphBox: CGFloat = 24

    /// The cup, a laptop once it is safe to close the lid, a warning when that
    /// has stopped being true: visible without opening the island.
    static func symbol(phase: LidAwakePhase) -> String {
        needsAttention(phase) ? "exclamationmark.triangle.fill" : {
            switch phase {
            case .ready, .foreign: return "laptopcomputer"
            default: return "cup.and.saucer.fill"
            }
        }()
    }

    /// The phases shown with the yellow triangle.
    static func needsAttention(_ phase: LidAwakePhase) -> Bool {
        switch phase {
        case .idle, .arming, .ready, .foreign: return false
        case .stopped, .helperOff, .failed, .helperSilent: return true
        }
    }

    /// Said after the time left, when the symbol says more than the cup.
    static func spokenPhase(_ phase: LidAwakePhase) -> String? {
        switch phase {
        case .idle, .arming: return nil
        case .ready, .foreign: return LidAwakeCopy.canClose
        case .stopped, .helperOff, .failed, .helperSilent: return LidAwakeCopy.needsAttention
        }
    }

    /// One wing's content width for the whole session: the glyph box when
    /// indefinite, the widest value a timed session can show otherwise
    /// ("59 min" in English, its Russian form a little wider: wing 47, W 61 with
    /// the island's 14 of padding).
    static func sessionWing(timed: Bool, widestLabels: [String]? = nil) -> CGFloat {
        guard timed else { return glyphBox }
        guard let widestLabels else { return timedWing }
        return max(glyphBox, widestLabels.map { ClosedWingE.measure($0) }.max() ?? 0)
    }

    /// The timed wing in the app's own language, measured once: the island
    /// asks for it on every pass.
    private static let timedWing = sessionWing(timed: true, widestLabels: CaffeinateManager.widestClosedLabels())

    /// The whole black surface: the notch frame, both wings and the island's
    /// padding on each side. What `KeepAwakeFold` holds against the menus.
    static func surfaceWidth(closedNotchWidth: CGFloat, timed: Bool, padding: CGFloat = ClosedWingE.islandPadding) -> CGFloat {
        closedNotchWidth + 2 * (sessionWing(timed: timed) + padding)
    }

    /// The glyph flush left, ∞ or the value flush right, in equal wings.
    static func closedGeometry(
        closedNotchWidth: CGFloat,
        timed: Bool,
        value: String?,
        widestLabels: [String]? = nil
    ) -> ClosedWingGeometry {
        let wing = sessionWing(timed: timed, widestLabels: widestLabels)
        return ClosedWingGeometry(
            leadingWing: wing,
            middle: closedNotchWidth,
            trailingWing: wing,
            leadingContent: glyphBox,
            trailingContent: value.map { ClosedWingE.measure($0) } ?? glyphBox,
            camera: ClosedWingE.cameraWidth(closedNotchWidth: closedNotchWidth)
        )
    }

    #if DEBUG
    /// One event per redraw, for the energy check: at rest at most one a minute.
    private static let signposter = OSSignposter(subsystem: "io.github.amidamaru940.luoto", category: "KeepAwake")
    #endif

    /// "Keep Awake: until turned off" / "Keep Awake: 1 hour, 20 minutes left".
    static func spokenValue(remaining: TimeInterval?) -> String {
        guard let remaining else { return String(localized: "Keep Awake: until turned off") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute]
        let minutes = max(1, ceil(max(0, remaining) / 60))
        let spoken = formatter.string(from: minutes * 60) ?? CaffeinateManager.closedLabel(remaining: remaining)
        return String(format: String(localized: "Keep Awake: %@ left"), spoken)
    }

    var body: some View {
        #if DEBUG
        let _ = Self.signposter.emitEvent("KeepAwake.body")
        #endif
        let wing = Self.sessionWing(timed: timed)
        let calm = DSE.Palette.secondary(contrast)
        HStack(spacing: 0) {
            Image(systemName: Self.symbol(phase: phase))
                .font(DSE.Typeface.glyphClosed)
                .foregroundStyle(Self.needsAttention(phase) ? DS.Palette.attention : calm)
                .frame(width: wing, alignment: .leading)

            Rectangle()
                .fill(Color.black)
                .frame(width: vm.closedNotchSize.width)

            Group {
                if let value {
                    Text(verbatim: value)
                        .font(DSE.Typeface.value)
                        .fixedSize()
                        .contentTransition(.numericText(countsDown: true))
                } else {
                    Image(systemName: "infinity")
                        .font(DSE.Typeface.glyphClosed)
                }
            }
            .foregroundStyle(calm)
            .lineLimit(1)
            .frame(width: wing, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .animation(DS.spring, value: value)
        .onReceive(CaffeinateManager.shared.$closedLabel.removeDuplicates()) { value = $0 }
        .onReceive(CaffeinateManager.shared.$expiresAt.map { $0 != nil }.removeDuplicates()) { timed = $0 }
        .onReceive(LidAwakeController.shared.$phase.removeDuplicates()) { phase = $0 }
        // One phrase: "Keep Awake: 45 minutes left, lid can be closed".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: {
            let spoken = Self.spokenValue(remaining: value == nil ? nil : CaffeinateManager.shared.remainingTime)
            return Self.spokenPhase(phase).map { "\(spoken), \($0)" } ?? spoken
        }()))
    }
}

/// Whether Keep Awake's wings are out on the closed island. Pure, so the
/// rules can be held by tests.
enum KeepAwakeFold {
    /// F1/F3: out when they would touch no menu title. Without Accessibility
    /// nothing can be known, and the wings show as they always did. With it,
    /// the last answer stands while nothing is measured (right after the
    /// island closes, an app without a menu bar, a scan that ran out of time);
    /// before the first answer the wings stay folded, so they never flash
    /// over a long menu.
    static func wingsFit(lastCollides: Bool?, trusted: Bool) -> Bool {
        guard trusted else { return true }
        return lastCollides == false
    }

    /// Room for the wings found by scans of one app in a row.
    struct FitEvidence: Equatable {
        var pid: pid_t = 0
        var roomyScans = 0
    }

    /// A menu bar of no more than the Apple menu and the app's own: an app
    /// between windows. Thunderbird shows exactly that while none of its
    /// windows has focus, and its full menus come back the moment one does,
    /// often with nothing to tell Luoto. Such a bar counts as no room, so the
    /// wings are never out when the menus come back under them.
    static func menuMayExpand(itemCount: Int) -> Bool {
        itemCount <= 2
    }

    /// How many scans in a row of the same app must find room before the
    /// wings come out. An app can show a partial menu bar for a moment as it
    /// comes forward (a mail app did, right after the island closed), and one
    /// such scan let the wings out over its full menus until the next one.
    static let roomyScansToUnfold = 2

    /// Whether a scan that left the wings folded should be confirmed at once:
    /// it found room, but not yet enough scans in a row did. Only while Keep
    /// Awake is on, so nothing more is scanned the rest of the day.
    static func wantsConfirmation(keepAwakeOn: Bool, collides: Bool, evidence: FitEvidence) -> Bool {
        keepAwakeOn && !collides && evidence.roomyScans < roomyScansToUnfold
    }

    /// The answer after a scan of `pid`: no room folds at once; room unfolds
    /// only once `roomyScansToUnfold` scans of that app in a row found it.
    static func afterScan(lastCollides: Bool?, evidence: FitEvidence, pid: pid_t, collides: Bool) -> (lastCollides: Bool?, evidence: FitEvidence) {
        if collides { return (true, FitEvidence(pid: pid, roomyScans: 0)) }
        let roomy = evidence.pid == pid ? evidence.roomyScans + 1 : 1
        return (roomy >= roomyScansToUnfold ? false : lastCollides, FitEvidence(pid: pid, roomyScans: roomy))
    }

    /// F6/F7: a peek after turning it on, or a held warning, shows the wings
    /// over the menus.
    static func wingsShown(fit: Bool, peeking: Bool, warningHeld: Bool) -> Bool {
        fit || peeking || warningHeld
    }

    /// F6: a peek only when it was turned on while the island was closed
    /// (its shortcut). From the open panel the user has just seen it.
    /// `seen`: the island is closed and someone can see it (not locked,
    /// display awake). A new duration replacing a running session is no start.
    static func peeksOnStart(wasActive: Bool, isActive: Bool, seen: Bool, replacedSession: Bool = false) -> Bool {
        !wasActive && isActive && seen && !replacedSession
    }

    /// F7: held on entering the triangle's phases, not on moves inside them.
    static func holdsWarning(from old: LidAwakePhase, to new: LidAwakePhase) -> Bool {
        !KeepAwakeLiveActivity.needsAttention(old) && KeepAwakeLiveActivity.needsAttention(new)
    }

    /// How long the start peek lasts.
    static let peekDuration: Duration = .seconds(2)
}
