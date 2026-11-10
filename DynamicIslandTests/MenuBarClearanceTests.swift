import XCTest
@testable import Atoll
import SwiftUI

/// The screen these use is a 14" MacBook Pro: 1710pt wide, notch 185pt wide and
/// centred, so the menu bar's left strip runs 0...762.5. Menu titles that do
/// not fit there are laid out by macOS to the right of the notch.
final class MenuBarClearanceTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    private let gap: CGFloat = 8

    /// A menu-bar item's frame: menu bar height, from `start` to `end`, at `y`
    /// in top-left global coordinates (0 is the main display's menu bar).
    private func menu(_ start: CGFloat, _ end: CGFloat, y: CGFloat = 0) -> CGRect {
        CGRect(x: start, y: y, width: end - start, height: 24)
    }

    private func offset(
        contentWidth: CGFloat,
        menus: [CGRect],
        statusItems: [CGRect] = [],
        maxRightEdge: CGFloat? = nil,
        hasNotch: Bool = true,
        menuBarBand: ClosedRange<CGFloat> = 0...40,
        screen: CGRect? = nil
    ) -> CGFloat {
        let screen = screen ?? self.screen
        return MenuBarLayout.clearanceOffset(
            contentWidth: contentWidth,
            screenFrame: screen,
            measurement: MenuBarLayout.Measurement(menuItemFrames: menus, statusItemFrames: statusItems),
            menuBarBand: menuBarBand,
            hasNotch: hasNotch,
            maxRightEdge: maxRightEdge ?? screen.maxX,
            gap: gap
        )
    }

    func testLuotosOwnMenuBarIsNotScanned() throws {
        XCTAssertFalse(MenuBarLayout.canMeasure(pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(MenuBarLayout.canMeasure(pid: 1))
        // The Clock timer's menu-bar poll reads the front app's menu bar on a
        // background queue as well.
        let bridge = try! String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/managers/SystemTimerBridge.swift"), encoding: .utf8)
        let poll = try XCTUnwrap(bridge.range(of: "private func pollMenuExtra()"))
        let locate = try XCTUnwrap(bridge.range(of: "menuExtra = locateTimerMenuExtra()", range: poll.upperBound..<bridge.endIndex))
        XCTAssertTrue(bridge[poll.upperBound..<locate.lowerBound].contains("MenuBarLayout.canMeasure(pid: front)"))
    }

    func testShortMenusLeaveTheNotchCentred() {
        // 300pt of content is centred at 855, so it begins at 705. Menus that
        // end at 606 -- Zen's, measured -- are nowhere near it.
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 606)]), 0)
    }

    func testMenusReachingTheContentPushItRight() {
        // Content begins at 705; menus ending at 720 overlap it by 15, plus the
        // 8pt gap.
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 650), menu(655, 720)]), 23)
    }

    func testTheGapAloneIsEnoughToMove() {
        // Menus end exactly where the content begins: no overlap, but they would
        // be flush, so the content still steps aside by the gap.
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 705)]), 8)
    }

    func testMenusEndingJustShortOfTheGapDoNotMove() {
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 697)]), 0)
    }

    func testTheBlackSurfaceClearsTheMenusNotJustTheContent() {
        // The surface is the content plus the closed padding on both sides:
        // 300 + 2 x 14 = 328, centred at 855, so it begins at 691.
        let surface = MenuBarLayout.surfaceWidth(contentWidth: 300, padding: 14)
        XCTAssertEqual(surface, 328)
        let shift = offset(contentWidth: surface, menus: [menu(10, 700)])
        XCTAssertEqual(shift, 17)
        XCTAssertGreaterThanOrEqual(screen.midX - surface / 2 + shift, 700 + gap, "the black edge, not just the content, is off the menus")
        // Measured on the content alone, the black edge would still lie over the last menu.
        let contentOnly = offset(contentWidth: 300, menus: [menu(10, 700)])
        XCTAssertLessThan(screen.midX - surface / 2 + contentOnly, 700)
        XCTAssertEqual(MenuBarLayout.surfaceWidth(contentWidth: 0, padding: 14), 0, "nothing measured yet: no surface to move")
    }

    func testAWiderActivityIsCoveredSooner() {
        // 500pt of content begins at 605, so the same menus that cleared a
        // 300pt activity now overlap it.
        XCTAssertEqual(offset(contentWidth: 500, menus: [menu(10, 606)]), 9)
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 606)]), 0)
    }

    func testMenusLaidOutPastTheNotchDoNotTeleportTheIsland() {
        // Chrome with Russian menus: the titles did not fit in the left
        // strip, so macOS put the last ones right of the notch. The old code
        // took their right edge (1480) for "where the menus end" and jumped the
        // island onto the status items. A wrapped title under the surface means
        // both sides are taken: the island stays on the notch.
        let wrapped = [menu(10, 740), menu(950, 1030), menu(1040, 1130), menu(1400, 1480)]
        XCTAssertEqual(offset(contentWidth: 300, menus: wrapped), 0)
    }

    func testNoJumpingOverAWrappedMenuTitle() {
        // A wide activity is covered by the left strip's last title, but a
        // wrapped title starts under its body: it stays put.
        XCTAssertEqual(offset(contentWidth: 500, menus: [menu(10, 740), menu(950, 1030)]), 0)
        // The same activity moves once the wrapped titles are far enough away.
        XCTAssertEqual(offset(contentWidth: 500, menus: [menu(10, 740), menu(1420, 1500)]), 143)
        // A wrapped title just past the surface limits the move instead of
        // cancelling it: 1250 - 8 - 1105 = 137.
        XCTAssertEqual(offset(contentWidth: 500, menus: [menu(10, 740), menu(1250, 1300)]), 137)
    }

    func testSeveralLeftStripTitlesUnderAWideSurfaceStillMoveIt() {
        // The surface (605...1105) reaches over two left-strip titles. Neither
        // is a wrapped one -- both end before the notch -- so the island steps
        // aside past the last of them. (A first version of this change took any
        // covered title starting under the surface for a wrapped one.)
        XCTAssertEqual(offset(contentWidth: 500, menus: [menu(10, 680), menu(690, 740), menu(1420, 1500)]), 143)
    }

    func testTheMoveStopsShortOfTheStatusItems() {
        // The move wanted is 143pt; a weather item at 1200 leaves room for
        // 1200 - 8 - 1105 = 87 (the island half-covered the weather).
        let menus = [menu(10, 740)]
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, statusItems: [menu(1200, 1260)]), 87)
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, statusItems: [menu(1500, 1560)]), 143)
        // Status items on another display do not constrain this screen.
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, statusItems: [menu(2000, 2060)]), 143)
    }

    func testOnlyThisScreensMenuBarCounts() {
        let menus = [menu(10, 740)]
        // A status-level window elsewhere on screen is not a menu bar item.
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, statusItems: [menu(1200, 1260, y: 500)]), 143)
        // A display stacked above the laptop (negative y, overlapping x): its
        // titles and status items are not on this menu bar.
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 740, y: -1100)]), 0)
        XCTAssertEqual(offset(contentWidth: 500, menus: menus + [menu(950, 1030, y: -1100)],
                              statusItems: [menu(1150, 1200, y: -1100)]), 143)
    }

    func testTheMoveStopsAtTheIslandsOwnWindow() {
        // Content past the window's right edge is clipped to a hard black edge,
        // so the window bounds the move.
        let menus = [menu(10, 740)]
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, maxRightEdge: 1240), 135)
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, maxRightEdge: 1248), 143)
        XCTAssertEqual(offset(contentWidth: 500, menus: menus, maxRightEdge: 1100), 0, "already past it: no move")
    }

    func testTheShiftStopsAtTheScreenEdge() {
        // Content this wide has only 105pt of room on the right, so a demand for
        // more than that is capped rather than pushing it off screen.
        XCTAssertEqual(offset(contentWidth: 1500, menus: [menu(10, 1000)], hasNotch: false), 105)
    }

    func testContentFillingTheScreenNeverMoves() {
        XCTAssertEqual(offset(contentWidth: 1710, menus: [menu(10, 900)]), 0)
    }

    func testNoContentMeansNoShift() {
        XCTAssertEqual(offset(contentWidth: 0, menus: [menu(10, 900)]), 0)
    }

    func testAScreenWithoutANotchHasNoWrappedTitles() {
        // On a plain display the menus simply run on past the centre.
        // 1440 wide: 300pt of content begins at 570; the last title ends at 760.
        let plain = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 600), menu(610, 700), menu(710, 760)],
                              hasNotch: false, screen: plain), 198)
    }

    func testAnExternalDisplayIsMeasuredOnItsOwnGeometry() {
        // A screen that does not start at x=0 -- the arithmetic is in global
        // coordinates, so a second display must not be treated as if it did.
        // Menus of the laptop's own screen do not constrain it either.
        let external = CGRect(x: 1710, y: 0, width: 2560, height: 1440)
        // Centre is 2990, so 300pt of content begins at 2840.
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(1720, 2850)], hasNotch: false, screen: external), 18)
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(1720, 2000)], hasNotch: false, screen: external), 0)
        XCTAssertEqual(offset(contentWidth: 300, menus: [menu(10, 740)], hasNotch: false, screen: external), 0)
    }

    func testHoveringCannotChangeThePosition() {
        // The closed island keeps its size under the pointer, so the
        // clearance is worked out for the resting size and hovering cannot
        // move it.
        let source = try! String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/ContentView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("isHovering ? 8"), "nothing in the closed island grows under the pointer")
    }

    // MARK: Keep Awake folds instead of stepping aside

    /// Keep Awake's ∞ surface on this screen: 189 + 2 × 38 = 265, centred at
    /// 855, so it spans 722.5...987.5.
    private func collides(_ menus: [CGRect], surface: CGFloat = 265, screen: CGRect? = nil, band: ClosedRange<CGFloat> = 0...40) -> Bool {
        MenuBarLayout.wingsCollide(
            surfaceWidth: surface,
            screenFrame: screen ?? self.screen,
            measurement: MenuBarLayout.Measurement(menuItemFrames: menus, statusItemFrames: []),
            menuBarBand: band,
            gap: gap
        )
    }

    func testKeepAwakeFoldsWhenMenusReachEitherSide() {
        XCTAssertFalse(collides([menu(10, 600)]), "short menus")
        XCTAssertTrue(collides([menu(10, 720)]), "left only")
        XCTAssertTrue(collides([menu(10, 600), menu(990, 1030)]), "right only")
        // Thunderbird: Tools up to the notch, Window and Help past it.
        XCTAssertTrue(collides([menu(10, 700), menu(705, 760), menu(960, 1000), menu(1005, 1060)]), "both sides")
        XCTAssertFalse(collides([]))
    }

    func testKeepAwakeGapIsEightOnBothSides() {
        XCTAssertFalse(collides([menu(10, 714.5)]), "8 pt left: clear")
        XCTAssertTrue(collides([menu(10, 715.5)]), "7 pt left: touches")
        XCTAssertFalse(collides([menu(995.5, 1040)]), "8 pt right: clear")
        XCTAssertTrue(collides([menu(994.5, 1040)]), "7 pt right: touches")
    }

    func testKeepAwakeIgnoresOtherScreensMenus() {
        // A display stacked above: its menu bar is outside this one's band.
        XCTAssertFalse(collides([menu(700, 1000, y: -1000)]))
        // A display to the right: outside this screen's x range.
        XCTAssertFalse(collides([menu(1800, 2000)]))
    }

    func testKeepAwakeOnAScreenWithoutANotch() {
        // The rule does not depend on a notch: same answer on a plain screen.
        let plain = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(collides([menu(10, 830)], screen: plain))
        XCTAssertFalse(collides([menu(10, 700)], screen: plain))
    }

    func testKeepAwakeNeverStepsAside() {
        let source = try! String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DynamicIsland/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("guard !vm.hideOnClosed,\n              !keepAwakeOnIsland,"), "F5")
    }
}

/// The open island on the 14" MacBook Pro keeps the menu bar to the app in
/// front: in the band only a neck as wide as the closed island, the panel
/// from the bottom of the menu bar.
final class OpenIslandNeckTests: XCTestCase {
    /// `vm.closedNotchSize.width` on the 14": the 185 pt camera plus 4.
    private let closedNotchWidth: CGFloat = 189
    /// The open island: 640 wide, the 200 standard height plus its bottom
    /// padding, below a 33 pt menu bar.
    private let openRect = CGRect(x: 0, y: 0, width: 640, height: 33 + 212)

    private var openNeck: NotchShape.Neck {
        OpenIslandNeck.neck(closedNotchWidth: closedNotchWidth, bandHeight: 33, isOpen: true)!
    }

    func testTheBandIsTheMenuBarOnAScreenWithANotch() {
        // safe-area top 32, menu bar 33 (measured on the 14").
        XCTAssertEqual(OpenIslandNeck.bandHeight(safeAreaTop: 32, menuBarHeight: 33), 33)
        // A hidden menu bar leaves the notch's height.
        XCTAssertEqual(OpenIslandNeck.bandHeight(safeAreaTop: 32, menuBarHeight: 0), 32)
        // Never more than a little past the notch.
        XCTAssertEqual(OpenIslandNeck.bandHeight(safeAreaTop: 32, menuBarHeight: 100), 32 + OpenIslandNeck.maxMenuBarExcess)
        // No notch: no band, the island as before.
        XCTAssertEqual(OpenIslandNeck.bandHeight(safeAreaTop: 0, menuBarHeight: 24), 0)
        XCTAssertNil(OpenIslandNeck.neck(closedNotchWidth: closedNotchWidth, bandHeight: 0, isOpen: true))
    }

    func testTheNeckIsTheClosedIslandAndThePanelStartsBelowTheMenuBar() {
        let layout = NotchShape.neckLayout(
            in: openRect,
            topCornerRadius: cornerRadiusInsets.opened.top,
            bottomCornerRadius: cornerRadiusInsets.opened.bottom,
            neck: openNeck
        )
        // The neck's body is the camera, as the closed island's at rest.
        XCTAssertEqual(layout.neckRight - layout.neckLeft, ClosedWingE.cameraWidth(closedNotchWidth: closedNotchWidth), accuracy: 0.001)
        XCTAssertEqual(layout.neckLeft + layout.neckRight, openRect.width, accuracy: 0.001)
        // At the screen edge, flares included: the camera plus the closed
        // flare either side, as `OpenIslandNeck.outerWidth` has it.
        let outer = (layout.neckRight + layout.neckFlare) - (layout.neckLeft - layout.neckFlare)
        XCTAssertEqual(layout.neckFlare, cornerRadiusInsets.closed.top, accuracy: 0.001)
        XCTAssertEqual(
            outer,
            ClosedWingE.cameraWidth(closedNotchWidth: closedNotchWidth) + 2 * cornerRadiusInsets.closed.top,
            accuracy: 0.001
        )
        XCTAssertEqual(outer, OpenIslandNeck.outerWidth(closedNotchWidth: closedNotchWidth), accuracy: 0.001)
        // The panel hangs from the bottom of the menu bar, with the open
        // island's sides, flowing out of the neck with the open flare.
        XCTAssertEqual(layout.panelTop, 33, accuracy: 0.001)
        XCTAssertEqual(layout.panelLeft, cornerRadiusInsets.opened.top, accuracy: 0.001)
        XCTAssertEqual(layout.panelRight, openRect.width - cornerRadiusInsets.opened.top, accuracy: 0.001)
        XCTAssertEqual(layout.junctionFlare, cornerRadiusInsets.opened.top, accuracy: 0.001)
        XCTAssertEqual(layout.panelCornerRadius, cornerRadiusInsets.opened.bottom, accuracy: 0.001)
        XCTAssertEqual(layout.bottomCornerRadius, cornerRadiusInsets.opened.bottom, accuracy: 0.001)
    }

    func testTheShapeLeavesTheMenuBarBesideTheNeck() {
        let path = NotchShape(
            topCornerRadius: cornerRadiusInsets.opened.top,
            bottomCornerRadius: cornerRadiusInsets.opened.bottom,
            neck: openNeck
        ).path(in: openRect)
        let midX = openRect.midX
        // The camera stays black.
        XCTAssertTrue(path.contains(CGPoint(x: midX, y: 16)))
        XCTAssertTrue(path.contains(CGPoint(x: midX - 90, y: 30)))
        // Beside it the menu titles: nothing of the island.
        XCTAssertFalse(path.contains(CGPoint(x: midX - 150, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: midX + 250, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: midX - 150, y: 32.5)))
        // Below the menu bar the panel, across its width.
        XCTAssertTrue(path.contains(CGPoint(x: midX - 250, y: 40)))
        XCTAssertTrue(path.contains(CGPoint(x: midX + 250, y: 200)))
        // The flare where the neck flows into the panel is filled.
        XCTAssertTrue(path.contains(CGPoint(x: midX - 92.5 - 5, y: 32.5)))
    }

    func testTheClosedIslandIsUnchanged() {
        let rect = CGRect(x: 0, y: 0, width: closedNotchWidth + 8, height: 32)
        let classic = NotchShape(topCornerRadius: 6, bottomCornerRadius: 14).path(in: rect)
        let closed = NotchShape(
            topCornerRadius: 6,
            bottomCornerRadius: 14,
            neck: OpenIslandNeck.neck(closedNotchWidth: closedNotchWidth, bandHeight: 33, isOpen: false)
        ).path(in: rect)
        XCTAssertEqual(classic, closed)
    }

    func testMidMorphTheShapeStaysInsideItsRect() {
        // The open neck in a rect still the closed size, and a little larger.
        for rect in [CGRect(x: 0, y: 0, width: 197, height: 32), CGRect(x: 0, y: 0, width: 300, height: 50)] {
            let layout = NotchShape.neckLayout(in: rect, topCornerRadius: 19, bottomCornerRadius: 24, neck: openNeck)
            XCTAssertGreaterThanOrEqual(layout.panelTop, layout.neckFlare + layout.junctionFlare - 0.001)
            XCTAssertLessThanOrEqual(layout.panelTop + layout.panelCornerRadius + layout.bottomCornerRadius, rect.maxY + 0.001)
            XCTAssertLessThanOrEqual(layout.neckRight - layout.neckLeft, layout.panelRight - layout.panelLeft + 0.001)
            let path = NotchShape(topCornerRadius: 19, bottomCornerRadius: 24, neck: openNeck).path(in: rect)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
        }
    }

    func testAPointerBesideTheNeckIsTheMenuBars() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let outer = OpenIslandNeck.outerWidth(closedNotchWidth: closedNotchWidth)
        func beside(_ x: CGFloat, _ y: CGFloat, band: CGFloat = 33) -> Bool {
            OpenIslandNeck.isBesideNeck(CGPoint(x: x, y: y), screenFrame: screen, bandHeight: band, neckOuterWidth: outer)
        }
        XCTAssertFalse(beside(864, 1110))            // on the neck
        XCTAssertFalse(beside(864 + 98, 1117))       // its flare, top pixel
        XCTAssertTrue(beside(864 - 120, 1110))       // a menu title beside it
        XCTAssertTrue(beside(864 + 200, 1085))       // the band's last row
        XCTAssertFalse(beside(864 - 120, 1083))      // below the menu bar: the panel
        XCTAssertFalse(beside(864 - 120, 1110, band: 0)) // no notch: the window as before
    }

    /// `islandWindowContainsPoint`: the open island's window (640 + 24 wide,
    /// 4 pt of it above the screen edge) as the hover poll and the outside
    /// click see it.
    func testTheWindowLeavesTheBandBesideTheNeckToTheMenus() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let window = CGRect(x: 864 - 332, y: 1117 + 4 - 33 - 212 - 12, width: 664, height: 33 + 212 + 12)
        let outer = OpenIslandNeck.outerWidth(closedNotchWidth: closedNotchWidth)
        func inside(_ x: CGFloat, _ y: CGFloat, band: CGFloat = 33, footprint: CGRect? = nil) -> Bool {
            OpenIslandNeck.windowContains(
                CGPoint(x: x, y: y), windowFrame: window, screenFrame: screen,
                bandHeight: band, neckOuterWidth: outer, footprint: footprint
            )
        }
        XCTAssertTrue(inside(864, 1117))              // the neck, top pixel
        XCTAssertTrue(inside(864 + 98, 1100))         // its flare
        XCTAssertFalse(inside(864 - 120, 1100))       // a menu title beside it
        XCTAssertFalse(inside(864 + 300, 1085))       // the band's last row
        XCTAssertTrue(inside(864 - 120, 1083))        // just below the menu bar: the panel
        XCTAssertTrue(inside(864 + 300, 1000))        // the panel's side
        XCTAssertFalse(inside(864 + 340, 1000))       // past the window
        XCTAssertTrue(inside(864 - 120, 1100, band: 0)) // no notch: the whole window
        // The closed island it opened from (wings with music, shifted right
        // off the menus) is the island's while the pointer rests there, on
        // its side only.
        let footprint = CGRect(x: 864 - 150 + 40, y: 1117 - 40 - 6, width: 300, height: 46)
        XCTAssertTrue(inside(864 + 170, 1100, footprint: footprint))
        XCTAssertFalse(inside(864 - 170, 1100, footprint: footprint)) // not mirrored onto the menus
        XCTAssertFalse(inside(864 + 200, 1100, footprint: footprint))
    }

    /// `adjustedSizeForScreen`: the band and the card's gap are added only
    /// in the notch style.
    func testTheWindowGrowsByTheBandOnlyOnScreensWithANotch() {
        let base = CGSize(width: 664, height: 224)
        // The 14": top bleed, the 33 pt band and the 6 pt gap above the card.
        XCTAssertEqual(
            OpenIslandNeck.windowSize(
                for: base, dynamicIslandMode: false, topBleed: notchTopScreenBleedAmount,
                bandHeight: OpenIslandNeck.bandHeight(safeAreaTop: 32, menuBarHeight: 33)
            ),
            CGSize(width: 664, height: 224 + notchTopScreenBleedAmount + 33 + IslandCard.gap)
        )
        // A screen without a notch in the notch style: the bleed as before.
        XCTAssertEqual(
            OpenIslandNeck.windowSize(
                for: base, dynamicIslandMode: false, topBleed: notchTopScreenBleedAmount,
                bandHeight: OpenIslandNeck.bandHeight(safeAreaTop: 0, menuBarHeight: 24)
            ),
            CGSize(width: 664, height: 224 + notchTopScreenBleedAmount)
        )
        // The Dynamic Island pill: its insets, no band.
        XCTAssertEqual(
            OpenIslandNeck.windowSize(for: base, dynamicIslandMode: true, topBleed: 0, bandHeight: 0),
            CGSize(width: 664 + 2 * dynamicIslandShadowInset, height: 224 + dynamicIslandTopOffset)
        )
    }
}

/// The open island as a card under the menu bar.
final class IslandCardTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testTheCardHangsBelowTheMenuBarWithAGap() {
        XCTAssertEqual(IslandCard.gap, 6)
        XCTAssertEqual(IslandCard.top(bandHeight: 33), 39)
        XCTAssertEqual(IslandCard.top(bandHeight: 0), 0, "without a notch the island opens as before")
        XCTAssertEqual(IslandCard.cornerRadius, cornerRadiusInsets.opened.bottom)
    }

    func testAbovetheCardIsTheIslandsOnlyOnAScreenWithANotch() {
        XCTAssertTrue(IslandCard.isAboveCard(CGPoint(x: 864, y: 1117), screenFrame: screen, bandHeight: 33))
        XCTAssertTrue(IslandCard.isAboveCard(CGPoint(x: 700, y: 1117 - 36), screenFrame: screen, bandHeight: 33), "the gap")
        XCTAssertFalse(IslandCard.isAboveCard(CGPoint(x: 864, y: 1117 - 40), screenFrame: screen, bandHeight: 33), "the card")
        XCTAssertFalse(IslandCard.isAboveCard(CGPoint(x: 864, y: 1117), screenFrame: screen, bandHeight: 0))
    }

    func testTheCardKeepsThePanelsSidesAndRoundsEveryCorner() {
        let rect = CGRect(x: 0, y: 0, width: 664, height: 300)
        let card = IslandCardShape(sideInset: 19, cornerRadius: 24).path(in: rect)
        XCTAssertEqual(card.boundingRect, rect.insetBy(dx: 19, dy: 0))
        XCTAssertFalse(card.contains(CGPoint(x: 20, y: 1)), "the top corner is round")
        XCTAssertFalse(card.contains(CGPoint(x: 20, y: 299)), "the bottom corner too")
        XCTAssertTrue(card.contains(CGPoint(x: 332, y: 1)))
    }

    func testTheCardTakesThePointerOnTheNotchAndTheCardOnly() {
        // The window's rect: the top bleed (say 1), the band and the gap, then the card.
        let rect = CGRect(x: 0, y: 0, width: 664, height: 340)
        let notch = OpenIslandNeck.outerWidth(closedNotchWidth: 189)
        let hit = IslandCardHitShape(notchWidth: notch, cardTop: 40, sideInset: 19).path(in: rect)
        XCTAssertTrue(hit.contains(CGPoint(x: 332, y: 10)), "the notch")
        XCTAssertTrue(hit.contains(CGPoint(x: 332, y: 37)), "the notch's column down to the card")
        XCTAssertFalse(hit.contains(CGPoint(x: 100, y: 10)), "the menus beside the notch")
        XCTAssertFalse(hit.contains(CGPoint(x: 100, y: 37)), "the gap beside the column")
        XCTAssertTrue(hit.contains(CGPoint(x: 100, y: 120)), "the card")
        // Its corners are the drawn card's, also with the smaller radius.
        let small = IslandCardHitShape(notchWidth: notch, cardTop: 40, sideInset: 6, cornerRadius: 14).path(in: rect)
        let drawn = IslandCardShape(sideInset: 6, cornerRadius: 14).path(in: CGRect(x: 0, y: 40, width: 664, height: 300))
        for point in [CGPoint(x: 9, y: 43), CGPoint(x: 11, y: 45), CGPoint(x: 655, y: 337)] {
            XCTAssertEqual(small.contains(point), drawn.contains(point), "\(point)")
        }
    }
}
