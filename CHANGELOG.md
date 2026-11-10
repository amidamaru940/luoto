# Changelog

All notable changes to Luoto are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). For the history
before the fork, see [Atoll's changelog](https://github.com/Ebullioscopic/Atoll/blob/dev/CHANGELOG.md).

## [1.3.8] — 2026-11-10

### Fixed
- **The Keep Awake cup shows up promptly again.** Since 1.3.7 the cup and ∞ come out only after two checks in a row find room beside the menus. The second check came only half a second later, and after a window opened or closed it did not come at all, so the cup could stay hidden until you switched apps. Now the second check follows within 0.2 seconds while Keep Awake is on.

## [1.3.7] — 2026-11-10

### Fixed
- **Keep Awake no longer flashes over the menus right after you turn it on.** While none of its windows has focus, Thunderbird shows only its name in the menu bar, and its full menus come back as soon as a window does. Luoto saw room for the cup and ∞ in that moment and let them out over the menus that came back. A menu bar with only the Apple menu and the app's own now counts as no room, the cup and ∞ fold at once whenever they would touch a menu, and they come out only after two checks in a row find room (about half a second after you switch apps).
- Keep Awake also folds at once when the island moves to another screen or gets wider, instead of waiting for the next app switch.

## [1.3.6] — 2026-11-10

### Fixed
- **Large copies no longer freeze the island.** Copying a long web page, code with syntax highlighting or a large document used to stop the island for about a second per megabyte while Luoto read its formatting, which it then dropped anyway. Formatting too large to keep (RTF over 100 KB, HTML over 150 KB) is no longer read when the copy also has plain text: the entry is saved and pasted as that text, as before. A copy that comes only as HTML is still read, so it is never lost from the history.
- Search in the Clipboard tab looks at the first 100,000 characters of each entry (about fifty pages), so typing a search no longer slows down with very long entries in the history.
- A copied picture is read from the clipboard once, not two to four times, and checks for codes and colours no longer go through long texts.

## [1.3.5] — 2026-11-09

### Fixed
- **Keep Awake folds in Thunderbird too.** Thunderbird shows its full menus only once a window is open. If you switched to it before the window opened, Luoto kept the menus it saw at the switch, and the Keep Awake cup and ∞ stayed over Tools and Window. While Keep Awake is on, Luoto now measures the menus again when the app in front opens a window, at most once every 2 seconds. Nothing more runs while Keep Awake is off.
- A menu measurement that finished after you had already switched to another app could be shown for the new app. It is now dropped, and the app in front is measured instead.

## [1.3.4] — 2026-11-09

### Changed
- **Keep Awake no longer covers the menus of the app you are using.** When an app's menus reach the notch (Xcode, Thunderbird), the Keep Awake cup and ∞ fold into the notch, and every menu stays visible and clickable. In apps with short menus they stay where they were. Before, the island stayed over the notch and hid menus on both sides of it.
- Keep Awake on the closed island is now calm grey instead of yellow. Yellow is kept for the warning that the lid must not be closed, which stays visible until you open the island.
- A timed session shows minutes, «45 мин» or «1 ч 20» ("45 min", "1h 20"), instead of a countdown in seconds, and the island keeps one width for the whole session. The closed island no longer redraws every second while it counts down.
- Turning Keep Awake on with its shortcut while the island is closed shows the cup for 2 seconds, even over long menus, as a confirmation.

## [1.3.3] — 2026-11-09

### Changed
- **Luoto no longer touches copies from your other devices.** Anything copied on an iPhone, iPad or another Mac and passed on through Universal Clipboard is no longer read by Luoto or added to its clipboard history: not text, links, rich text, files or pictures. You paste it with ⌘V as before. Until 1.3.2, text copied on the iPhone still entered the history; now nothing does.
- The screen snipping tool ignores pictures copied on another device too.
- The camera indicator no longer watches an iPhone used as a Continuity Camera. Built-in and USB cameras work as before.
- Luoto no longer searches for cameras while the hidden mirror feature is off.
- When you unlock the Mac or wake it from sleep, Luoto no longer checks what changed on the clipboard while you were away: nobody copies on a locked or sleeping Mac, so that copy came from another device. Checking it while macOS was still fetching it from the phone could freeze the island for several seconds. A copy you make right before locking is still kept: Luoto looks once more as you leave.
- For a copy from another device Luoto asks the clipboard only for its list of types, and no longer for each of its items.
- While clipboard history is paused, Luoto no longer asks the clipboard what it holds; it only notices that something changed.
- The camera indicator now relies only on the system's camera status. Luoto no longer uses the camera framework for it, which used to wake up whenever an iPhone came near.

### Added
- A log line when a clipboard check takes longer than half a second. It records only how long the check took, never what was copied.

## [1.3.2] — 2026-11-07

### Changed
- **A picture copied on the iPhone stays there until you paste it.** Luoto used to fetch every picture copied on another device through Universal Clipboard within a second, for the clipboard history. Now it leaves it alone: you paste it with ⌘V as before, but it no longer enters Luoto's history by itself. Text copied on the iPhone still does.

### Fixed
- A debug log line looked at the copied picture on every clipboard change, even while the history was paused or the copy came from a password manager. It now looks only at what kind of copy it is.
- Pasting into the island's Notes no longer reads the copied picture when only the text is pasted. A picture that is listed but never arrives pastes its text instead of nothing, and a JPEG-only copy now pastes as a picture.

## [1.3.1] — 2026-11-03

### Fixed
- Dragging a file or picture onto the island made it open and close over and over, so it could not be dropped there, on AirDrop or the shelf. The island now stays open until the drag has really left.

## [1.3.0] — 2026-11-02

### Added
- **Keep Awake with the lid closed.** Turn on *With the lid closed* in the Keep Awake panel or in Settings, and the Mac goes on working under a closed lid, on battery and with no display: builds, downloads, AI agents. It is off until you turn it on. The first time asks for your password once, and macOS reports a new background item: a small helper that acts only during a session. Luoto says you can close the lid only after reading back from the system that it will hold. It stops by itself at the battery level you choose (10, 20, 30 or 50%; 20% unless you change it) or if the Mac overheats, and the Mac sleeps as usual if Luoto crashes or quits. See [SECURITY.md](SECURITY.md).

### Fixed
- Luoto could crash if it started, or a display setting changed, with no screen online.
- The Now Playing helper could stay behind after Luoto quit. Quitting now stops it, and the next launch clears one left by a crash.

## [1.2.0] — 2026-10-31

### Changed
- **New name: Luoto.** A fresh start with a new app identity, so settings from earlier versions do not carry over.
- **Nothing asks for a permission at launch.** Each one is asked when you turn on the feature that needs it, or the first time you use it.
- **Updates, if you want them.** Onboarding asks once. Say yes and Luoto asks GitHub once a day; say no and nothing goes to the network. Nothing installs without you, and you can check by hand at any time.
- **Accessibility should stay on after an update**, because every release is signed with the same certificate. Replacing the app with a newer copy kept it in testing; the first real in-app update comes with the next release. If macOS loses it anyway, Settings offers to restore it.
- **Sounds are macOS system sounds** instead of bundled files.
- The switches for download detection, the Bluetooth battery on the lock screen, reminders and the calendar event on the lock screen start off, because they need a permission.

### Removed
- Everything bundled without a known source or licence: the AirPods and Beats videos (the HUD uses system symbols), the idle animations (hidden until freely licensed ones exist), six sounds and two wallpaper pictures.
- The mirror, which could not work without camera access.
- The shelf's requests for folder and Full Disk Access, which it never needed.
- The animation downloaded from LottieFiles when the visualizer is off; the app's own wave takes its place.

## [1.1.12] — 2026-10-30

### Security
A security review of the whole app; nothing a user sees changes.
- **Another program on the Mac can no longer run code inside Luoto.** The Now Playing reader (perl) and zip start without the environment variables that make them load outside code (PERL5OPT and the like), so a program could not borrow Luoto's Accessibility permission that way.
- **AirPlay device names are escaped properly** when Luoto switches devices in Apple Music, so a crafted name cannot run a script.
- **Rich text copied from a web page is read with a policy that forbids loading anything** from the network (pictures, style sheets, fonts) — the mechanism browsers use; the copied text and its formatting are kept exactly as they were.
- **Third-party extensions (off by default):** web pages can no longer connect to the extensions port (native clients still can); a client you revoked is not let back in by itself; file access is no longer granted automatically; a client can only show its own content; a file a client sends stays in its folder.
- **The Spotify Canvas session (sp_dc cookie) is kept in the Keychain** instead of the preferences file; an existing one moves there by itself. After an update macOS may ask once to let Luoto use it.
- The terminal tab runs only a shell listed in /etc/shells (add a Homebrew shell there, as `chsh` also needs); file names from drag and drop cannot leave the temporary folder; a calendar event's title is no longer written to the system log in the clear.
- **Sparkle 2.9.6** (updates stay off) instead of 2.7.0, which had published vulnerabilities, and the release no longer carries Sparkle's XPC services.

## [1.1.11] — 2026-10-29

### Fixed
- **An empty black card stayed under the menu bar after the island closed.** The island's close animation and the animations inside the card kept the card on screen for a second or more. Now it disappears the moment the island closes.
- macOS no longer logs an exception at the first launch: Luoto no longer reads its own menu bar from a background thread.

## [1.1.10] — 2026-10-29

### Changed
- **The island opens only when you mean it.** A pointer passing over the notch no longer opens it, and the closed island no longer grows under it. Stop the pointer on the notch and the island opens at once, in about a tenth of a second. Only the notch itself opens it this way; a click on the island still opens it too. The "Hover delay" setting now adds to that stop and is 0 by default.
- **The open island is a card under the menu bar.** It no longer drops out of the notch with a neck. A black card fades in under the menu bar, the notch stays a plain notch, and the menus beside it stay the app's. On close the card goes at once. Screens without a notch open as before.
- **The thumbnail size line in "Shots" is smooth.** Its light follows the pointer while you drag and settles on the size when you let go, and the screenshots reflow to the new size instead of jumping.

## [1.1.9] — 2026-10-24

### Fixed
- **Dictation (F5) switched on and straight off after a click on the closed island.** The island took the keyboard and kept it for half a minute, so macOS had no text field to dictate into. A click on the closed island no longer takes the keyboard; the open island takes it only for its own controls, the shortcut, or a text field.
- **Bluetooth connections left open.** Reading AirPods' and other devices' battery opened Bluetooth LE connections and never closed them; they are now closed when each read ends or times out (Handoff and Universal Clipboard share Bluetooth LE).
- **Copies from the iPhone were downloaded in every format at once.** On each copy Luoto read the picture, the text and the rich text to learn which one it was; it now reads only the one it keeps.
- Fewer CoreAudio log errors when an app that played sound quits.

## [1.1.8] — 2026-10-24

### Changed
- **"Do Not Disturb" is the moon alone.** The Focus name beside it made the closed island as wide as the name on both sides and covered the menus of the app in front. The name can still be turned on in Settings.

## [1.1.7] — 2026-10-23

### Added
- **A trash in "Buffer".** A small trash beside pause clears what the filter shows: on "All" the copies and the screenshots, on "Shots" the screenshots, on "Text", "Links" and "Files" those copies. Pinned copies stay, and "Cleared · N — Undo" puts everything back for 5 seconds. Clipboard screenshots are then deleted; saved screenshots only leave "Buffer", their files are not touched. "Clear" in the "…" menu does the same.

### Fixed
- **"Clear History" seemed to do nothing** when "Buffer" held only screenshots: it cleared the copies alone.

## [1.1.6] — 2026-10-23

### Fixed
- **Videos on any site, not only YouTube.** A video that reports no artist (an episode on a series site, a film) was treated like an Instagram Reel: hidden, with the music kept on screen and the controls on hold. Only short clips (under 5 minutes) are held now; longer videos show on the island and its buttons control them.
- **"Resume" no longer looks live when it can't work.** While a video in the browser holds the system's controls, the paused-track strip on "Now" dims "Resume" and says "Controls are with a video in …", as the player already did; before, the button silently did nothing.

## [1.1.5] — 2026-10-23

### Fixed
- **A crash while screenshots came into the open "Buffer".** SwiftUI resized the island's window on its own while Luoto set its size too, and the two re-entered AppKit's layout until it threw. 1.1.2 had removed only part of this. The island and the picture preview are now sized by Luoto alone.
- **The picture preview was empty since 1.1.2.** Resting the pointer on a picture in "Buffer" opened a preview with no size; it shows the picture again.

## [1.1.4] — 2026-10-23

### Fixed
- **"Paste into Claude · N" closed the island and pasted nothing.** The closed island kept the keyboard, so the paste stopped before its first ⌘V (it never pastes into the island). The island now hands the keyboard back to the app in front as it closes.
- **The "where to" list held a macOS prompt.** The window asking for Accessibility after a reinstall came forward and became a paste target; its ⌘V only beeped. Only apps with a Dock icon are remembered now.
- **"Buffer" cut off on the first open, whole on the second.** With copies in the history, the island measured only the copies and not the film above them, so it grew too little and stayed cut until reopened. It now grows to the film and the copies at once.

## [1.1.3] — 2026-10-23

### Fixed
- **"Buffer" cut off with the paste key missing.** After the island had shrunk to "No copies yet", a new screenshot batch appeared above it but the island did not grow back, so the film was cut and "Paste into … · N" sat below the edge. The Buffer now grows when its content runs past the island.

## [1.1.2] — 2026-10-23

### Fixed
- A rare crash while the island or a picture preview resized itself (AppKit's layout loop in a SwiftUI window); the island and the preview panel are now sized only by Luoto.

## [1.1.1]

### Fixed
- **Pasting a batch into Claude, Chrome or Telegram.** "Paste into … · 3" did not always paste every shot there. Each shot now goes in as a picture, one after another, so all three arrive. If another app comes forward or the island opens mid-way, pasting stops and the rest are copied for your own ⌘V; copying something else stops it too.
- **Clipboard screenshots from the first launch.** Screenshots taken to the clipboard (⌃⇧⌘4) were collected only after the screenshot folder had been asked for, so with "Skip" on the first launch they were lost. They are now collected from launch, need no folder, and expire within a day even if the folder was never asked for.
- **"Do Not Disturb" no longer hides under the camera.** The closed island gives the moon and the Focus name equal wings, so the name starts after the camera; a long name fades at 150 pt. Battery, AirPods, timer, reminder, recording and extension indicators got equal wings too.

### Changed
- **Clipboard screenshots are now collected by default**, also after updating from 1.1.0. Screenshots taken to the clipboard (⌃⇧⌘4) are kept only as files in a local temporary folder, so they can be pasted or dragged as a batch, and are deleted within a day. Turn this off in Settings → Screenshots → "Also collect clipboard screenshots".
- **Pictures you can tell apart.** A picture in "All" shows a larger thumbnail with its size, and the pointer resting on it opens a preview beside the island that never takes the keyboard. VoiceOver reads where the picture came from and when.
- Without access to the screenshot folder, "Screenshots" still shows the clipboard screenshots.
- Turning on only the clipboard screenshots no longer asks for the Desktop folder.
- "Nothing to paste: the shots are gone" when a batch's files are gone.

## [1.1.0]

### Changed
- **A new look for the island** (concept E, "edge of light"): the closed island, "Now" and "Buffer" are a black body without grey plates; colour comes only as light from what is shown.
- **"Buffer" v3:** filters as words, a film of screenshots with one "Paste into … · N" key, the history in two columns, deleting with "Undo". Every function of the previous tab is kept.
- **The menu bar stays free.** The open island leaves the other apps' menus uncovered: only a neck over the camera, the panel below. It opens on hover at once.
- **A full-screen film leaves the island empty.**

### Security
- Recovery after a crash, no permission prompts at launch, and the Screen Assistant's API keys in the Keychain.

### Fixed
- The Russian interface was checked in full (454 corrections).

## [1.0.3]

### Changed
- **Sliders are easy to catch.** Seeking and the volume needed a click right on a thin line. The volume now takes clicks within 24 points (it was 6), the player's seek bar within 20 (14) and the compact one within 18 (11), and each thickens as soon as the pointer is over it, not only while dragged. The player is no taller than before.

## [1.0.2]

### Fixed
- **Reminders in "Next".** Reminders are a macOS permission of their own, and Luoto never asked for it, so they were missing from "Next" with nothing to say why. While that permission is unanswered, "Next" now offers "Reminders too · Allow Access", and a click asks macOS. Reminders whose due date comes without a calendar are no longer dropped.
- **Fewer permission prompts.** Luoto asks for the Downloads folder only when the download listener is on, not on every launch.

### Changed
- **Running the tests leaves your Mac alone.** The unit-test host is a second Luoto to macOS. It no longer asks for any permission, never shows its island, and never takes the keyboard. A source scan keeps new prompting calls behind the guard.
- The README shows a screenshot batch and the shelf.

## [1.0.1]

### Fixed
- **Seeking in the compact player.** The progress line under the title was only drawn, so music could not be wound in the one-row player. A click or a drag now seeks, and the time shows while you drag.
- **Videos no longer take the player over.** A browser hands macOS one tab at a time, so a video without track details, such as Instagram Reels, replaced the music playing in another tab, and the controls reached the video. The music now stays on screen. Its controls rest, with "Controls are with a video in Chrome", until the browser hands them back when the video is closed.
- **Idle animations after moving the app.** The built-in animations were stored with the app's path and disappeared once the app was moved or renamed.
- **Track changes without a gap.** A browser reports a track change in steps: about a second of nothing, then the title, then the rest, then the artwork. The player disappeared and redrew itself for each. The previous track now stays until the next one has arrived, and that one appears complete.
- **Tracks no longer switch by themselves.** The swipe that changes tracks added up scrolling that was never a swipe: sideways drift while scrolling a page near the top of the screen, gestures that ended off the island, and mouse-wheel nudges minutes apart.

### Changed
- **The Clipboard tab is as tall as what it shows.** An empty clipboard is a thin strip with one line instead of a large square, and the island grows with the copies up to the full grid.

### Added
- Issue and pull request templates, and a security policy.

## [1.0.0]

First release of Luoto, forked from Atoll at `868c25d`.

### Added
- **Screenshot batches.** New screenshots gather into batches at the notch, and "Paste into … · N" pastes a whole batch, or the shots picked from it, into the app you were working in. You can drag a batch by its title, select all, open Quick Look, use AirDrop, show it in Finder, and mark up several shots one after another. Optionally, screenshots taken to the clipboard join the batch from a temporary folder that clears itself within a day.
- **Clipboard tab.**
  - Cards with source app and time, and filters (All, Screenshots, Text, Links, Files).
  - Search that understands Russian, a folded "Pinned" row, and ⌘1–⌘9 to paste.
  - Pause recording, with an indicator on the closed island.
- **Now tab.**
  - A calm player: the extras appear on hover, a volume popover, "Nothing playing" with Resume.
  - "Next" with your upcoming events, the Auto music source with a priority order, and track changes by swiping the closed island.
- **Compact layout:** fewer tabs, the player in one row with volume and the next two events.
- **Closed island:** hover "ears" beside the notch, wings centred on the camera, a priority order for live indicators, flashes for a new screenshot, a picked colour and shelf drops, and Keep Awake with its time left.
- **Presenting mode:** while the screen is shared or recorded, clipboard and screenshots show only their titles and notifications stay quiet.
- **Design system and a new header:** tabs with an "unseen" dot, a status capsule, and one "…" menu.
- **Settings and languages:** settings in eight sections, each setting on one page, with "Configure ›" links where pages meet. Onboarding in three steps. Full Russian translation with an in-app language switch.
- **Tooling:** `scripts/make-release.sh` builds an ad-hoc signed DMG. Signing comes from `Config/Signing.xcconfig`, with an optional local team.

### Changed
- **Privacy by default.**
  - Every networked feature is off until you turn it on, and nothing listens on a port.
  - Clipboard history stays in memory, and passwords are never recorded.
  - A test lists every network address in the code.
- **Updates and permissions:** Sparkle updates are switched off, and the camera entitlement is removed.
- **Data:** app data lives in `~/Library/Application Support/<bundle id>`, not in iCloud Documents.

### Removed
- The minimalistic mode (replaced by Compact), the separate Screenshots tab (merged into Clipboard), the timer popover and the old onboarding.
- About forty files of code nothing used any more.
