"""The windows Luoto sizes itself never have a SwiftUI hosting view as
their contentView. There SwiftUI attaches its own window-sizing helper,
whatever the view's sizingOptions, and resizes the window from
windowDidLayout while Luoto sets the frame too: the island re-entered
Update Constraints until AppKit threw.
They go in through NSWindow.setSelfSizedContent, inside a plain container."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "DynamicIsland"


def function_body(source, name):
    """The text between the braces of `func name(` or `func name<`."""
    start = source.index("{", re.search(rf"func {name}[(<]", source).start())
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(name)


class SelfSizedWindowTests(unittest.TestCase):
    def assert_self_sized(self, path, function, host):
        body = function_body((SOURCES / path).read_text(), function)
        self.assertIn(f"setSelfSizedContent({host})", body)
        self.assertNotRegex(body, rf"\.contentView = {host}\b")

    def test_the_island_window(self):
        self.assert_self_sized("DynamicIslandApp.swift", "createDynamicIslandWindow", "host")

    def test_the_picture_preview_panel(self):
        self.assert_self_sized("components/Notch/NotchClipboardView.swift", "show", "hosting")



class OpenCardTests(unittest.TestCase):
    """The open island as a card under the menu bar: it fades in
    where it stands, goes at once, and never slides between the closed
    island's place beside the menus and the centre."""

    def setUp(self):
        self.content = (SOURCES / "ContentView.swift").read_text()
        self.card = (SOURCES / "components/Notch/OpenIslandNeck.swift").read_text()

    def test_opening_and_closing_do_not_slide_the_surface(self):
        # The slide is keyed to the closed island's place, which opening and
        # closing leave alone; the offset itself jumps between it and 0.
        # (A modifier keyed to `showsOpenCard` here broke the Release build:
        # "opaque type defined in terms of itself".)
        self.assertRegex(
            self.content,
            r"\.offset\([^)]*menuBarClearanceOffset[\s\S]{0,400}?\)\n(\s*//[^\n]*\n)*"
            r"\s*\.animation\(\.smooth\(duration: 0\.25\), value: closedMenuBarClearanceOffset\)")
        self.assertNotIn("value: menuBarClearanceOffset)", self.content)
        self.assertNotIn("value: showsOpenCard)", self.content)

    def test_the_card_goes_at_once(self):
        body = function_body(self.card, "cardTransition")
        self.assertIn("removal: .identity", body)
        self.assertNotIn("move(", body)

    def test_the_root_frame_makes_room_for_the_gap(self):
        self.assertIn("(showsOpenCard ? IslandCard.top(bandHeight: neckBandHeight) : openNeckBand)", self.content)

    def test_the_gap_above_the_card_stays_transparent(self):
        layout = self.content[self.content.index("private var openCardLayout"):self.content.index("private var islandLayout")]
        self.assertNotIn("-IslandCard.gap", layout, "the shadow would take the clicks in the gap")


if __name__ == "__main__":
    unittest.main()
