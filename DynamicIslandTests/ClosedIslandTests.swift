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

@testable import Atoll
import AppKit
import CoreGraphics
import Defaults
import XCTest

/// The click area (the hover ears were removed for energy),
/// symmetric wings, the shelf flash, Keep Awake in the closed island,
/// Compact instead of the minimalistic mode.
final class ClosedIslandTests: XCTestCase {
    // A 1512 × 982 screen with a 200 × 32 notch in the middle.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var notch: CGRect { IslandHoverZone.notchRect(screenFrame: screen, width: 200, height: 32) }

    // MARK: Hover and click area

    func testTheNotchHangsFromTheTopEdgeInTheMiddle() {
        XCTAssertEqual(notch, CGRect(x: 656, y: 950, width: 200, height: 32))
        let shifted = IslandHoverZone.notchRect(screenFrame: screen, width: 200, height: 32, xOffset: 40)
        XCTAssertEqual(shifted.minX, 696)
    }

    func testTheClickAreaReachesSixPointsBelowTheNotch() {
        let click = IslandHoverZone.clickArea(around: notch)
        XCTAssertTrue(IslandHoverZone.contains(click, CGPoint(x: notch.midX, y: notch.minY - 5)))
        XCTAssertFalse(IslandHoverZone.contains(click, CGPoint(x: notch.midX, y: notch.minY - 7)))
    }

    func testAClickOpensOnlyOnTheIslandNotBesideIt() {
        let click = IslandHoverZone.clickArea(around: notch)
        XCTAssertTrue(IslandHoverZone.contains(click, CGPoint(x: notch.minX, y: 975)), "the island's edge")
        XCTAssertTrue(IslandHoverZone.contains(click, CGPoint(x: notch.maxX, y: 975)), "the island's edge")
        // A menu title flush against the camera is the menu bar's: upstream's
        // 12 pt margin beside the notch is gone.
        XCTAssertFalse(IslandHoverZone.contains(click, CGPoint(x: notch.minX - 1, y: 975)), "the menu bar's")
        XCTAssertFalse(IslandHoverZone.contains(click, CGPoint(x: notch.minX - 11, y: 975)), "the menu bar's")
        XCTAssertFalse(IslandHoverZone.contains(click, CGPoint(x: notch.maxX + 11, y: 975)), "the menu bar's")
        // Below the notch, where there is no menu, the strip stays.
        XCTAssertEqual(click, CGRect(x: notch.minX, y: notch.minY - IslandHoverZone.below, width: notch.width, height: notch.height + IslandHoverZone.below))
        XCTAssertFalse(IslandHoverZone.clickOpens(onNotch: false, overIsland: false))
        XCTAssertTrue(IslandHoverZone.clickOpens(onNotch: true, overIsland: false))
        XCTAssertTrue(IslandHoverZone.clickOpens(onNotch: false, overIsland: true))
    }

    // MARK: Symmetric wings

    func testTheLeftWingMatchesAWiderRightWing() {
        // Scrolling title: artwork wing ~20 pt, title wing ~151 pt.
        XCTAssertEqual(IslandWings.symmetricWidth(left: 20, right: 151), 151)
        XCTAssertEqual(IslandWings.symmetricWidth(left: 20, right: 20), 20)
        // The island's centre then sits on the camera.
        let left = IslandWings.symmetricWidth(left: 20, right: 151)
        let total = left + 200 + 151
        XCTAssertEqual(left + 100, total / 2)
    }

    // MARK: Nothing behind the camera

    /// Every closed state with text, at the longest strings it shows, on a
    /// 185 pt notch (14" MacBook Pro) and a 200 pt one: the trailing content
    /// starts at or past the camera's right edge, and the leading content
    /// ends at or before its left edge.
    func testNoClosedTextSitsBehindTheCamera() {
        for notch: CGFloat in [185, 200] {
            var states: [(String, ClosedWingGeometry)] = []

            // Focus: «Do Not Disturb», a custom name past the cap, the toast.
            for label in ["Не беспокоить", "Do Not Disturb", "Фокус выключен", "Работа над очень длинным проектом", "On"] {
                states.append(("Focus «\(label)»", DoNotDisturbLiveActivity.closedGeometry(closedNotchWidth: notch, showsGlyph: true, label: label)))
            }
            states.append(("Focus, glyph only", DoNotDisturbLiveActivity.closedGeometry(closedNotchWidth: notch, showsGlyph: true, label: nil)))

            // Caps Lock, AirPods and the other text HUDs.
            func hud(
                _ type: SneakContentType,
                listening: String? = nil,
                battery: Bool = false,
                deviceName: Bool = false,
                percentage: Bool = false,
                capsLabel: Bool = true
            ) -> ClosedWingGeometry {
                let wings = InlineHUD.textWings(
                    type: type,
                    listeningModeLabel: listening,
                    hasBatteryLevel: battery,
                    showsDeviceName: deviceName,
                    circularBattery: false,
                    showsBatteryPercentage: percentage,
                    showsCapsLockLabel: capsLabel,
                    gestureProgress: 0
                )
                return .equalWings(closedNotchWidth: notch, leading: wings.info, trailing: wings.trailing)
            }
            states.append(("Caps Lock", hud(.capsLock)))
            states.append(("Caps Lock, glyph only", hud(.capsLock, capsLabel: false)))
            for mode in ["Распознавание разговора", "Conversation Awareness", "Шумоподавление"] {
                states.append(("AirPods «\(mode)»", hud(.bluetoothAudio, listening: mode)))
            }
            states.append(("AirPods name and battery", hud(.bluetoothAudio, battery: true, deviceName: true, percentage: true)))
            states.append(("AirPods battery", hud(.bluetoothAudio, battery: true, percentage: true)))

            // Battery.
            for title in ["Полный заряд", "Низкий заряд", "Полностью заряжена", "Fully charged"] {
                states.append(("Battery «\(title)»", BatteryTemporaryActivityView.compactGeometry(title: title, closedNotchWidth: notch)))
            }

            // Keep Awake, colour copied, screenshot flash.
            states.append(("Keep Awake ∞", KeepAwakeLiveActivity.closedGeometry(closedNotchWidth: notch, timed: false, value: nil)))
            // One width per session, in the language the value is shown in.
            let ruWidest = CaffeinateManager.widestClosedLabels(minutesFormat: "%lld мин", hoursFormat: "%lld ч %02lld")
            let enWidest = CaffeinateManager.widestClosedLabels(minutesFormat: "%lld min", hoursFormat: "%lldh %02lld")
            for value in ["1 мин", "45 мин", "59 мин", "1 ч 00", "3 ч 59"] {
                states.append(("Keep Awake «\(value)»", KeepAwakeLiveActivity.closedGeometry(closedNotchWidth: notch, timed: true, value: value, widestLabels: ruWidest)))
            }
            for value in ["1 min", "45 min", "59 min", "1h 00", "3h 59"] {
                states.append(("Keep Awake «\(value)»", KeepAwakeLiveActivity.closedGeometry(closedNotchWidth: notch, timed: true, value: value, widestLabels: enWidest)))
            }
            states.append(("Colour copied", ColorPickedLiveActivityContent.closedGeometry(closedNotchWidth: notch, hex: "#5BBEEB")))
            for count in [1, 3, 25, 99] {
                states.append(("Screenshot flash \(count)", ClosedScreenshotFlash.closedGeometry(closedNotchWidth: notch, count: count)))
            }

            // Timer: a long name in the leading wing, an hour on the clock.
            let name = min(max(ClosedWingE.measure("Очень длинное название таймера", font: .systemFont(ofSize: 12, weight: .medium)), 44), 220)
            let countdown = ClosedWingE.measure("1:00:00", font: .monospacedSystemFont(ofSize: 13, weight: .semibold))
            states.append(("Timer", TimerLiveActivity.closedGeometry(
                closedNotchWidth: notch,
                middle: notch,
                leftWing: 28 + 11 + 8 + name + 18,
                rightWing: 22 + max(countdown + 16, 72)
            )))

            // Reminder: «in 120 min» beside the 26 pt glyph.
            let minutes = ClosedWingE.measure("in 120 min", font: .systemFont(ofSize: 13, weight: .semibold))
            states.append(("Reminder", ReminderLiveActivity.closedGeometry(closedNotchWidth: notch, leftWing: 16 + 26, rightWing: 16 + max(minutes + 18, 88))))

            // Recording: an hour, and «Error», scaled into their wing.
            for text in ["1:02:03", "Ошибка"] {
                let width = ClosedWingE.measure(text, font: .monospacedDigitSystemFont(ofSize: 14, weight: .semibold))
                states.append(("Recording «\(text)»", RecordingLiveActivity.closedGeometry(
                    closedNotchWidth: notch,
                    hudWidth: notch + RecordingHUDPresentation.compact.extraWidth,
                    centerWidth: notch,
                    textWidth: width
                )))
            }

            // Download with its rate, and an extension's widest value.
            states.append(("Download", DownloadLiveActivity.closedGeometry(
                closedNotchWidth: notch,
                notchHeight: 32,
                isHovering: false,
                gestureProgress: 0,
                isDownloading: true,
                speedText: "1023.5 MB/s"
            )))
            let extensionValue = 44 + notch * 0.6
            let layout = ExtensionStandaloneLayout.equalWings(
                outerHeight: 32,
                contentHeight: 20,
                leadingContentWidth: 44,
                centerWidth: notch,
                trailingContentWidth: extensionValue
            )
            states.append(("Extension", layout.closedGeometry(closedNotchWidth: notch, trailingContent: extensionValue)))

            for (state, geometry) in states {
                if geometry.trailingContent > 0 {
                    XCTAssertGreaterThanOrEqual(
                        geometry.trailingContentMinX, geometry.cameraMaxX,
                        "\(state), notch \(notch): the trailing content starts under the camera"
                    )
                }
                XCTAssertTrue(geometry.clearsCamera, "\(state), notch \(notch)")
            }
        }

        // The row that went wrong: a 20 pt glyph wing beside a 164 pt
        // name wing slid «Do Not Disturb» in to 26 pt right of the camera's centre.
        let before = ClosedWingGeometry(leadingWing: 20, middle: 185, trailingWing: 164, leadingContent: 20, trailingContent: 160, camera: 181)
        XCTAssertLessThan(before.trailingContentMinX, before.cameraMaxX)
        XCTAssertFalse(before.clearsCamera)
        // Now: both wings 98, the name from 92.5, past the camera's 90.5.
        let focus = DoNotDisturbLiveActivity.closedGeometry(closedNotchWidth: 185, showsGlyph: true, label: "Не беспокоить")
        XCTAssertEqual(focus.leadingWing, focus.trailingWing)
        XCTAssertGreaterThanOrEqual(focus.trailingContentMinX, 92.5)
        XCTAssertLessThanOrEqual(DoNotDisturbLiveActivity.labelWidth("Работа над очень длинным проектом и ещё немного"), ClosedWingE.textCap)
    }

    /// «Do Not Disturb» is the moon alone by default: the name made both wings
    /// as wide as itself and covered the app's menus. The name stays
    /// a setting.
    func testFocusIsTheMoonAloneByDefault() {
        XCTAssertFalse(Defaults.Keys.showDoNotDisturbLabel.defaultValue)
        let moon = DoNotDisturbLiveActivity.closedGeometry(closedNotchWidth: 185, showsGlyph: true, label: nil)
        let named = DoNotDisturbLiveActivity.closedGeometry(closedNotchWidth: 185, showsGlyph: true, label: "Не беспокоить")
        XCTAssertEqual(moon.leadingWing, moon.trailingWing)
        XCTAssertLessThan(moon.width, named.width - 100, "far narrower than with the name")
    }

    // MARK: Shelf flash

    func testOnlyFilesNewSinceTheLastLookCount() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(ShelfFlashModel.added(previous: nil, current: [a, b]), 0, "the saved shelf at launch")
        XCTAssertEqual(ShelfFlashModel.added(previous: [a], current: [a, b, c]), 2)
        XCTAssertEqual(ShelfFlashModel.added(previous: [a, b], current: [a]), 0, "removing never flashes")
    }

    @MainActor
    func testAddingFilesFlashesForAMoment() {
        let model = ShelfFlashModel()
        let a = UUID(), b = UUID()
        model.itemsChanged([a])
        XCTAssertNil(model.flash, "loading the shelf does not flash")
        model.itemsChanged([a, b])
        XCTAssertEqual(model.flash?.added, 1)
        model.clear()
        XCTAssertNil(model.flash)
        model.itemsChanged([a])
        XCTAssertNil(model.flash)
        XCTAssertEqual(ShelfFlashModel.duration, 2.5)
    }

    // MARK: Keep Awake

    func testKeepAwakeIsVisibleInTheClosedIsland() {
        XCTAssertEqual(ClosedIndicator.defaultOrder.last, .keepAwake, "can stay on for hours: below the rest")
        XCTAssertTrue(ClosedIndicator.keepAwake.pairsWithMusic, "a cup on the artwork while music plays")
        XCTAssertEqual(ClosedIndicatorResolver.winner(active: [.keepAwake], order: ClosedIndicator.defaultOrder), .keepAwake)
        XCTAssertEqual(ClosedIndicatorResolver.winner(active: [.keepAwake, .shelf], order: ClosedIndicator.defaultOrder), .shelf)
        XCTAssertEqual(ClosedIndicatorResolver.musicBadge(active: [.music, .keepAwake], order: ClosedIndicator.defaultOrder), .keepAwake)
    }

    // MARK: Keep Awake folds beside long menus

    private let ruMinutes = "%lld мин"
    private let ruHours = "%lld ч %02lld"

    func testKeepAwakeValueIsMinutesRoundedUpWithoutSeconds() {
        func label(_ seconds: TimeInterval) -> String {
            CaffeinateManager.closedLabel(remaining: seconds, minutesFormat: ruMinutes, hoursFormat: ruHours)
        }
        XCTAssertEqual(label(0), "1 мин")
        XCTAssertEqual(label(1), "1 мин")
        XCTAssertEqual(label(60), "1 мин")
        XCTAssertEqual(label(61), "2 мин")
        XCTAssertEqual(label(45 * 60), "45 мин")
        XCTAssertEqual(label(59 * 60), "59 мин")
        XCTAssertEqual(label(59 * 60 + 1), "1 ч 00")
        XCTAssertEqual(label(65 * 60), "1 ч 05")
        XCTAssertEqual(label(80 * 60), "1 ч 20")
        XCTAssertEqual(label(4 * 3600), "4 ч 00")
        XCTAssertEqual(CaffeinateManager.closedLabel(remaining: 80 * 60, minutesFormat: "%lld min", hoursFormat: "%lldh %02lld"), "1h 20")
    }

    func testKeepAwakeValueChangesOncePerMinuteAndKeepsOneWidth() {
        // A four-hour session, second by second: the value changes exactly
        // at each minute boundary, and the wing never changes width.
        let widest = CaffeinateManager.widestClosedLabels(minutesFormat: ruMinutes, hoursFormat: ruHours)
        let wing = KeepAwakeLiveActivity.sessionWing(timed: true, widestLabels: widest)
        var previous: String?
        var changes = 0
        for second in stride(from: 14_400, through: 0, by: -1) {
            let value = CaffeinateManager.closedLabel(remaining: TimeInterval(second), minutesFormat: ruMinutes, hoursFormat: ruHours)
            if let previous, previous != value { changes += 1 }
            previous = value
            XCTAssertLessThanOrEqual(ClosedWingE.measure(value), wing, value)
        }
        // 240 minutes down to one: 239 changes.
        XCTAssertEqual(changes, 239)
        XCTAssertEqual(wing, ClosedWingE.measure("59 мин"), "«59 мин» is the widest")
    }

    func testKeepAwakeWingsMatchTheDetailSheet() {
        // W = wing + the island's 14 of padding: 38 indefinite (glyphs 24).
        XCTAssertEqual(KeepAwakeLiveActivity.sessionWing(timed: false), 24)
        XCTAssertEqual(KeepAwakeLiveActivity.sessionWing(timed: false) + ClosedWingE.islandPadding, 38)
        let ru = KeepAwakeLiveActivity.sessionWing(timed: true, widestLabels: CaffeinateManager.widestClosedLabels(minutesFormat: ruMinutes, hoursFormat: ruHours))
        XCTAssertEqual(ru + ClosedWingE.islandPadding, 61, accuracy: 1)
        let en = KeepAwakeLiveActivity.sessionWing(timed: true, widestLabels: CaffeinateManager.widestClosedLabels(minutesFormat: "%lld min", hoursFormat: "%lldh %02lld"))
        XCTAssertEqual(en + ClosedWingE.islandPadding, 58, accuracy: 1)
        XCTAssertEqual(
            KeepAwakeLiveActivity.surfaceWidth(closedNotchWidth: 189, timed: false, padding: 14),
            189 + 2 * 38
        )
        // The app's own formats, through the string catalog: the test host
        // runs in English.
        XCTAssertEqual(CaffeinateManager.closedLabel(remaining: 45 * 60), String(format: String(localized: "%lld min"), Int64(45)))
        XCTAssertEqual(CaffeinateManager.closedLabel(remaining: 80 * 60), String(format: String(localized: "%lldh %02lld"), Int64(1), Int64(20)))
        XCTAssertGreaterThanOrEqual(KeepAwakeLiveActivity.sessionWing(timed: true), KeepAwakeLiveActivity.glyphBox)
    }

    func testFoldedKeepAwakeGivesTheIslandAway() {
        // F2: folded, Keep Awake is not active, so the next one wins.
        let order = ClosedIndicatorResolver.normalizedOrder([.keepAwake, .download])
        XCTAssertEqual(ClosedIndicatorResolver.winner(active: [.keepAwake, .download], order: order), .keepAwake)
        XCTAssertEqual(ClosedIndicatorResolver.winner(active: [.download], order: order), .download)
        XCTAssertNil(ClosedIndicatorResolver.winner(active: [], order: order))
        // The view inserts Keep Awake only with its wings out.
        let source = try! String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("enableCaffeinate && keepAwakeActive && keepAwakeWingsShown { active.insert(.keepAwake) }"))
    }

    func testKeepAwakeFoldRemembersTheLastAnswer() {
        // F3.
        XCTAssertTrue(KeepAwakeFold.wingsFit(lastCollides: nil, trusted: false), "no Accessibility: as before")
        XCTAssertTrue(KeepAwakeFold.wingsFit(lastCollides: true, trusted: false))
        XCTAssertFalse(KeepAwakeFold.wingsFit(lastCollides: nil, trusted: true), "before the first answer: folded")
        XCTAssertFalse(KeepAwakeFold.wingsFit(lastCollides: true, trusted: true), "just closed over Thunderbird")
        XCTAssertTrue(KeepAwakeFold.wingsFit(lastCollides: false, trusted: true))
    }

    func testKeepAwakeFoldsAtOnceButUnfoldsOnlyAfterTwoRoomyScans() {
        typealias E = KeepAwakeFold.FitEvidence
        // Thunderbird, folded; the island closes and the first scan catches
        // its partial menu bar: the wings stay folded.
        var state: (lastCollides: Bool?, evidence: E) = (true, E(pid: 7, roomyScans: 0))
        state = KeepAwakeFold.afterScan(lastCollides: state.lastCollides, evidence: state.evidence, pid: 7, collides: false)
        XCTAssertEqual(state.lastCollides, true)
        // The follow-up sees the full menus: still folded, the count restarts.
        state = KeepAwakeFold.afterScan(lastCollides: state.lastCollides, evidence: state.evidence, pid: 7, collides: true)
        XCTAssertEqual(state.lastCollides, true)
        XCTAssertEqual(state.evidence.roomyScans, 0)
        // Finder comes forward: one roomy scan is not enough...
        state = KeepAwakeFold.afterScan(lastCollides: state.lastCollides, evidence: state.evidence, pid: 9, collides: false)
        XCTAssertEqual(state.lastCollides, true)
        // ...the second of the same app is.
        state = KeepAwakeFold.afterScan(lastCollides: state.lastCollides, evidence: state.evidence, pid: 9, collides: false)
        XCTAssertEqual(state.lastCollides, false)
        // One scan that finds no room folds at once.
        state = KeepAwakeFold.afterScan(lastCollides: state.lastCollides, evidence: state.evidence, pid: 9, collides: true)
        XCTAssertEqual(state.lastCollides, true)
        // Roomy scans of two different apps do not add up.
        state = KeepAwakeFold.afterScan(lastCollides: true, evidence: E(pid: 9, roomyScans: 1), pid: 10, collides: false)
        XCTAssertEqual(state.lastCollides, true)
        XCTAssertEqual(KeepAwakeFold.roomyScansToUnfold, 2)
        // A first roomy scan is checked again at once, while Keep Awake is on.
        XCTAssertTrue(KeepAwakeFold.wantsConfirmation(keepAwakeOn: true, collides: false, evidence: E(pid: 9, roomyScans: 1)))
        XCTAssertFalse(KeepAwakeFold.wantsConfirmation(keepAwakeOn: true, collides: false, evidence: E(pid: 9, roomyScans: 2)), "already out")
        XCTAssertFalse(KeepAwakeFold.wantsConfirmation(keepAwakeOn: true, collides: true, evidence: E(pid: 9, roomyScans: 0)), "no room: nothing to confirm")
        XCTAssertFalse(KeepAwakeFold.wantsConfirmation(keepAwakeOn: false, collides: false, evidence: E(pid: 9, roomyScans: 1)), "Keep Awake off: no extra scans")
        XCTAssertLessThanOrEqual(MenuBarLayout.confirmDelay, 0.25)
        // Thunderbird with no window in focus: only the Apple menu and its
        // own. Its full menus may come back at any moment: no room.
        XCTAssertTrue(KeepAwakeFold.menuMayExpand(itemCount: 2))
        XCTAssertTrue(KeepAwakeFold.menuMayExpand(itemCount: 1))
        XCTAssertFalse(KeepAwakeFold.menuMayExpand(itemCount: 7), "Finder's short menus are room")
        let source = try! String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let noRoom = collides || KeepAwakeFold.menuMayExpand(itemCount: measurement.menuItemFrames.count)"))
        XCTAssertTrue(source.contains("collides: noRoom"))
    }

    func testKeepAwakePeeksAndHeldWarning() {
        // F6, F7.
        XCTAssertTrue(KeepAwakeFold.wingsShown(fit: false, peeking: true, warningHeld: false))
        XCTAssertTrue(KeepAwakeFold.wingsShown(fit: false, peeking: false, warningHeld: true))
        XCTAssertFalse(KeepAwakeFold.wingsShown(fit: false, peeking: false, warningHeld: false))
        XCTAssertTrue(KeepAwakeFold.peeksOnStart(wasActive: false, isActive: true, seen: true), "its shortcut")
        XCTAssertFalse(KeepAwakeFold.peeksOnStart(wasActive: false, isActive: true, seen: false), "from the open panel, locked or asleep")
        XCTAssertFalse(KeepAwakeFold.peeksOnStart(wasActive: false, isActive: true, seen: true, replacedSession: true), "a new duration")
        XCTAssertFalse(KeepAwakeFold.peeksOnStart(wasActive: true, isActive: true, seen: true))
        XCTAssertFalse(KeepAwakeFold.peeksOnStart(wasActive: true, isActive: false, seen: true))
        XCTAssertEqual(KeepAwakeFold.peekDuration, .seconds(2))
        XCTAssertTrue(KeepAwakeFold.holdsWarning(from: .ready, to: .failed))
        XCTAssertTrue(KeepAwakeFold.holdsWarning(from: .idle, to: .helperSilent))
        XCTAssertFalse(KeepAwakeFold.holdsWarning(from: .failed, to: .helperSilent), "a move inside the group")
        XCTAssertFalse(KeepAwakeFold.holdsWarning(from: .idle, to: .ready))
    }

    func testKeepAwakeIsGreyUnlessItNeedsAttention() {
        for phase: LidAwakePhase in [.idle, .arming, .ready, .foreign] {
            XCTAssertFalse(KeepAwakeLiveActivity.needsAttention(phase))
        }
        for phase: LidAwakePhase in [.stopped(.battery), .stopped(.thermal), .helperOff, .failed, .helperSilent] {
            XCTAssertTrue(KeepAwakeLiveActivity.needsAttention(phase))
        }
        let source = try! String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/components/Caffeinate/KeepAwakeLiveActivity.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Self.needsAttention(phase) ? DS.Palette.attention : calm"))
        XCTAssertFalse(source.contains("@ObservedObject private var caffeinate"), "no redraw on every second's tick")
    }

    // MARK: Compact instead of minimalistic

    func testCompactKeepsTheMainTabsAndTheirOrder() {
        let all = NotchTabLayout.visibleTabs(order: NotchTab.defaultOrder, hidden: [], layout: .compact) { _ in true }
        XCTAssertEqual(all, [.nowPlaying, .screenshots, .clipboard, .shelf])
        let reordered = NotchTabLayout.visibleTabs(order: [.terminal, .shelf, .nowPlaying], hidden: [.screenshots], layout: .compact) { _ in true }
        XCTAssertEqual(reordered, [.shelf, .nowPlaying, .clipboard])
        XCTAssertEqual(NotchTabLayout.visibleTabs(order: NotchTab.defaultOrder, hidden: [], layout: .standard) { _ in true },
                       NotchTab.defaultOrder)
    }

    func testCompactMakesNowPlayingOneLowerRow() {
        XCTAssertEqual(compactHomeHeight(for: .home, layout: .compact), 140)
        XCTAssertNil(compactHomeHeight(for: .home, layout: .standard))
        XCTAssertNil(compactHomeHeight(for: .clipboard, layout: .compact), "other tabs keep their height")
        XCTAssertEqual(CompactPlayerRowContent.progress(elapsed: 30, duration: 120), 0.25)
        XCTAssertEqual(CompactPlayerRowContent.progress(elapsed: 200, duration: 120), 1)
        XCTAssertNil(CompactPlayerRowContent.progress(elapsed: 10, duration: 0), "a live stream has no length")
    }

    func testTheMinimalisticModeBecomesCompactAndNeverHidesTheTabs() {
        XCTAssertEqual(IslandLayout.migratedFromMinimalistic(minimalistic: true, current: .standard), .compact)
        XCTAssertEqual(IslandLayout.migratedFromMinimalistic(minimalistic: false, current: .standard), .standard)
        XCTAssertEqual(IslandLayout.migratedFromMinimalistic(minimalistic: false, current: .compact), .compact)
        XCTAssertEqual(Defaults.Keys.islandLayout.defaultValue, .standard)
        XCTAssertTrue(IslandLayout.compact.keeps(.nowPlaying), "never an island without a tab")
    }
}

/// A drag that opened the island was reported as gone for a moment while the
/// island grew, and the island closed and opened over and over (02.11.2026).
final class DragLeavePolicyTests: XCTestCase {
    func testAMomentaryLeaveThatComesBackKeepsTheIslandOpen() {
        XCTAssertEqual(DragLeavePolicy.decide(targeted: true, buttonHeld: true, pointerInsideWindow: true, holdOpen: false), .keepOpen)
    }

    func testStillDraggingOverTheIslandWaits() {
        XCTAssertEqual(DragLeavePolicy.decide(targeted: false, buttonHeld: true, pointerInsideWindow: true, holdOpen: false), .wait)
    }

    func testLetGoOverTheIslandHandsItToTheHoverLogic() {
        XCTAssertEqual(DragLeavePolicy.decide(targeted: false, buttonHeld: false, pointerInsideWindow: true, holdOpen: false), .recheckHover)
    }

    func testADragThatReallyLeftClosesIt() {
        XCTAssertEqual(DragLeavePolicy.decide(targeted: false, buttonHeld: true, pointerInsideWindow: false, holdOpen: false), .close)
        XCTAssertEqual(DragLeavePolicy.decide(targeted: false, buttonHeld: false, pointerInsideWindow: false, holdOpen: false), .close)
    }

    func testSomethingHoldingItOpenWins() {
        XCTAssertEqual(DragLeavePolicy.decide(targeted: false, buttonHeld: false, pointerInsideWindow: false, holdOpen: true), .keepOpen)
    }

    func testTheGraceOutlastsTheIslandGrowing() {
        XCTAssertGreaterThanOrEqual(DragLeavePolicy.grace, 0.3)
        XCTAssertLessThanOrEqual(DragLeavePolicy.grace, 1)
    }

    /// The close on a drag leaving goes only through the policy.
    func testTheDragDetectorNoLongerClosesOnTheSpot() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/ContentView.swift"), encoding: .utf8)
        let detector = try XCTUnwrap(source.range(of: "var dragDetector: some View"))
        let end = try XCTUnwrap(source.range(of: "private func scheduleDragLeaveCheck()"))
        let body = source[detector.upperBound..<end.lowerBound]
        XCTAssertFalse(body.contains("vm.close()"))
        XCTAssertTrue(body.contains("scheduleDragLeaveCheck()"))
        // A drag coming back cancels the pending check.
        XCTAssertTrue(body.contains("dragLeaveWork?.cancel()"))
        // And a view torn down mid-drag, moving to another screen, takes it with it.
        let teardown = try XCTUnwrap(source.range(of: "private func performViewTeardown()"))
        XCTAssertTrue(source[teardown.upperBound...].prefix(400).contains("dragLeaveWork?.cancel()"))
    }
}
