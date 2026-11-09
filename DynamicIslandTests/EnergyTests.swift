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
import CoreAudio
import XCTest

/// The overheating fix: nothing runs on its own clock while the Mac sleeps,
/// its screen sleeps or locks, and idle means idle.
final class EnergyTests: XCTestCase {
    private var workspace: NotificationCenter!
    private var distributed: NotificationCenter!
    private var gate: ActivityGate!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        workspace = NotificationCenter()
        distributed = NotificationCenter()
        gate = ActivityGate(initial: ActivityGate.State(), workspaceCenter: workspace, distributedCenter: distributed)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.amidamaru940.luoto.tests.energy.\(UUID().uuidString)"))
    }

    override func tearDown() {
        gate.invalidate()
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func post(_ event: ActivityGate.Event, on center: NotificationCenter? = nil) {
        let source = ActivityGate.notificationName(for: event)
        (center ?? (source.distributed ? distributed : workspace)).post(name: source.name, object: nil)
        // Observers are on the main queue; let any queued delivery run.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - The gate

    func testTheGateFollowsSleepScreenLockAndSession() {
        var state = ActivityGate.State()
        XCTAssertTrue(state.userPresent)

        state = ActivityGate.apply(.screenLocked, to: state)
        XCTAssertTrue(state.screenInUse, "the lock screen is on screen")
        XCTAssertFalse(state.userPresent)

        state = ActivityGate.apply(.screensDidSleep, to: state)
        XCTAssertFalse(state.screenInUse, "closing the lid sleeps the displays")

        state = ActivityGate.apply(.willSleep, to: state)
        state = ActivityGate.apply(.didWake, to: state)
        XCTAssertFalse(state.screenInUse, "a dark wake leaves the displays asleep")

        state = ActivityGate.apply(.screensDidWake, to: state)
        state = ActivityGate.apply(.screenUnlocked, to: state)
        XCTAssertTrue(state.userPresent)

        state = ActivityGate.apply(.sessionDidResignActive, to: state)
        XCTAssertFalse(state.screenInUse, "another user's session")
        state = ActivityGate.apply(.sessionDidBecomeActive, to: state)
        XCTAssertTrue(state.userPresent)
    }

    func testTheGateHearsTheSystemNotices() {
        post(.willSleep)
        XCTAssertFalse(gate.state.systemAwake)
        post(.didWake)
        XCTAssertTrue(gate.state.systemAwake)
        post(.screenLocked)
        XCTAssertFalse(gate.state.unlocked)
        post(.screenUnlocked)
        XCTAssertTrue(gate.state.userPresent)
    }

    // MARK: - On willSleep everything is stopped

    func testOnWillSleepEverythingIsStopped() {
        // A poll, a lock-screen task, the clipboard look in a burst, and the
        // clipboard-screenshot collector on top of it.
        let poll = GatedTimer(name: "test poll", interval: 1, tolerance: 0.5, gate: gate) {}
        let lockScreen = GatedTimer(name: "test lock screen", interval: 1, tolerance: 0.5, requirement: .screenInUse, gate: gate) {}
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        let token = watcher.add { _ in }
        watcher.burst()
        let collector = ClipboardScreenshotCollector(pasteboard: pasteboard, folder: FileManager.default.temporaryDirectory,
                                                     watcher: watcher) { _, _ in }
        collector.start()
        poll.start()
        lockScreen.start()
        XCTAssertTrue(poll.isScheduled)
        XCTAssertTrue(lockScreen.isScheduled)
        XCTAssertTrue(watcher.isLooking)
        XCTAssertTrue(watcher.isBursting)

        post(.willSleep)

        XCTAssertFalse(poll.isScheduled, "no poll while the Mac sleeps")
        XCTAssertFalse(lockScreen.isScheduled, "nor work for the lock screen")
        XCTAssertFalse(watcher.isLooking, "nor the clipboard look")
        XCTAssertFalse(watcher.isBursting)
        XCTAssertFalse(GatedTimer.scheduledNames.contains("test poll"))
        XCTAssertFalse(GatedTimer.scheduledNames.contains("test lock screen"))

        // Wake with the display on: back, without catching up.
        post(.didWake)
        XCTAssertTrue(poll.isScheduled)
        XCTAssertTrue(lockScreen.isScheduled)
        XCTAssertTrue(watcher.isLooking)

        collector.stop()
        watcher.remove(token)
        poll.stop()
        lockScreen.stop()
        XCTAssertFalse(watcher.isLooking)
    }

    func testOnWillSleepTheAppsOwnTimersStop() throws {
        try XCTSkipUnless(ActivityGate.shared.allows(.userPresent), "the screen is locked or asleep")
        // The app's gate hears NSWorkspace itself: post to the real center.
        let poll = GatedTimer(name: "test shared poll", interval: 1, tolerance: 0.5) {}
        poll.start()
        XCTAssertTrue(GatedTimer.scheduledNames.contains("test shared poll"))

        post(.willSleep, on: NSWorkspace.shared.notificationCenter)
        XCTAssertTrue(GatedTimer.scheduledNames.isEmpty,
                      "scheduled while asleep: \(GatedTimer.scheduledNames)")

        post(.didWake, on: NSWorkspace.shared.notificationCenter)
        XCTAssertTrue(poll.isScheduled)
        poll.stop()
    }

    func testTheScreenSleepingOrLockingStopsThePolls() {
        let poll = GatedTimer(name: "test poll", interval: 1, tolerance: 0.5, gate: gate) {}
        poll.start()
        post(.screensDidSleep)
        XCTAssertFalse(poll.isScheduled, "lid closed")
        post(.screensDidWake)
        XCTAssertTrue(poll.isScheduled)
        post(.screenLocked)
        XCTAssertFalse(poll.isScheduled, "locked")
        post(.screenUnlocked)
        XCTAssertTrue(poll.isScheduled)
        poll.stop()
        XCTAssertFalse(poll.isScheduled)
    }

    // MARK: - The clipboard look

    func testTheClipboardIsLookedAtOnceASecondWithHalfASecondOfTolerance() {
        XCTAssertGreaterThanOrEqual(ClipboardChangeWatcher.interval, 1)
        XCTAssertGreaterThanOrEqual(ClipboardChangeWatcher.tolerance, 0.5)
        XCTAssertLessThanOrEqual(ClipboardChangeWatcher.burstDuration, 10, "a burst is bounded")
    }

    func testTheClipboardLookSeesAChangeOnce() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        pasteboard.clearContents()
        pasteboard.setString("copied", forType: .string)
        watcher.look()
        watcher.look()
        XCTAssertEqual(seen.count, 1)
        watcher.remove(token)
    }

    /// A look that held the main thread over half a second leaves one public
    /// line with its duration and whether the copy came from another device.
    /// The clock and the log are fakes: nothing waits for real.
    private func withFakeClockAndLog(_ body: (_ advance: @escaping (Double) -> Void, _ lines: () -> [String]) -> Void) {
        let savedNow = ClipboardChangeWatcher.now
        let savedLog = ClipboardChangeWatcher.logSlowLook
        defer {
            ClipboardChangeWatcher.now = savedNow
            ClipboardChangeWatcher.logSlowLook = savedLog
        }
        var clock: UInt64 = 1_000_000_000
        var lines: [String] = []
        ClipboardChangeWatcher.now = { clock }
        ClipboardChangeWatcher.logSlowLook = { lines.append($0) }
        body({ clock += UInt64($0 * 1_000_000_000) }, { lines })
    }

    /// What the history and the screenshot collector do on a change: read
    /// the types once and decide. The watcher's slow-look line takes its
    /// remote yes/no from this.
    private func decide(_ count: Int) {
        _ = ClipboardCapturePolicy.decide(on: pasteboard, changeCount: count, sourceBundleID: nil,
                                          isPaused: false, ignoredApps: [])
    }

    func testASlowClipboardLookLeavesExactlyOneLogLine() {
        withFakeClockAndLog { advance, lines in
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            let token = watcher.add { [unowned self] count in
                self.decide(count)
                advance(0.8)
            }
            pasteboard.clearContents()
            pasteboard.setString("copied", forType: .string)
            watcher.look()
            XCTAssertEqual(lines(), ["clipboard look took 0.8 s (remote=no)"])
            XCTAssertTrue(lines().allSatisfy { !$0.contains("copied") && !$0.contains("public.") }, "no content, no types")

            // Nothing changed since: the next look is quick and says nothing.
            watcher.look()
            XCTAssertEqual(lines().count, 1)
            watcher.remove(token)
        }
    }

    func testASlowLookAtACopyFromThePhoneSaysRemote() {
        withFakeClockAndLog { advance, lines in
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            let token = watcher.add { [unowned self] count in
                self.decide(count)
                advance(1.26)
            }
            pasteboard.clearContents()
            pasteboard.setString("1", forType: ClipboardCapturePolicy.remoteMarker)
            watcher.look()
            XCTAssertEqual(lines(), ["clipboard look took 1.3 s (remote=yes)"])
            XCTAssertTrue(lines()[0].hasPrefix("clipboard look took"), "log readers match this start")
            watcher.remove(token)
        }
    }

    /// No listener decided on the change: the line says it does not know
    /// rather than asking the pasteboard.
    func testASlowLookNobodyDecidedOnSaysUnknown() {
        withFakeClockAndLog { advance, lines in
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            let token = watcher.add { _ in advance(0.9) }
            pasteboard.clearContents()
            pasteboard.setString("1", forType: ClipboardCapturePolicy.remoteMarker)
            watcher.look()
            XCTAssertEqual(lines(), ["clipboard look took 0.9 s (remote=?)"])
            watcher.remove(token)
        }
    }

    func testAQuickClipboardLookLeavesNoLogLine() {
        withFakeClockAndLog { advance, lines in
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            let token = watcher.add { [unowned self] count in
                self.decide(count)
                advance(0.5)
            }
            pasteboard.clearContents()
            pasteboard.setString("copied", forType: .string)
            watcher.look()
            watcher.look()
            XCTAssertEqual(lines(), [], "half a second is not slow")
            watcher.remove(token)
        }
    }

    /// WebKit's nested run loop (HTML to RTF) can fire a nudge or a tick
    /// inside a listener. The inner look belongs to the outer one: one line,
    /// with the outer look's whole time.
    func testANestedLookWritesOnlyTheOuterLine() {
        withFakeClockAndLog { advance, lines in
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            var calls = 0
            let token = watcher.add { [unowned self] count in
                calls += 1
                if calls == 1 {
                    self.decide(count)
                    // A new copy arrives while this listener still runs, and
                    // the nested run loop looks again.
                    self.pasteboard.clearContents()
                    self.pasteboard.setString("second", forType: .string)
                    watcher.look()
                    advance(0.1)
                } else {
                    self.decide(count)
                    advance(0.7)
                }
            }
            pasteboard.clearContents()
            pasteboard.setString("first", forType: .string)
            watcher.look()
            XCTAssertEqual(calls, 2, "the nested look saw the second copy")
            XCTAssertEqual(lines(), ["clipboard look took 0.8 s (remote=no)"])
            watcher.remove(token)
        }
    }

    /// The outer look's change came from the phone; a nested look then saw a
    /// local copy. The line belongs to the outer look: remote=yes.
    func testANestedLookKeepsTheOuterChangesRemoteFlag() {
        withFakeClockAndLog { advance, lines in
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            var seen: [Int] = []
            let token = watcher.add { [unowned self] count in
                seen.append(count)
                self.decide(count)
                if seen.count == 1 {
                    self.pasteboard.clearContents()
                    self.pasteboard.setString("local", forType: .string)
                    watcher.look()
                    advance(0.3)
                } else {
                    advance(0.6)
                }
            }
            pasteboard.clearContents()
            pasteboard.setString("1", forType: ClipboardCapturePolicy.remoteMarker)
            watcher.look()
            XCTAssertEqual(seen.count, 2, "the nested look saw the local copy")
            XCTAssertEqual(ClipboardCapturePolicy.seenRemote(changeCount: seen[1], pasteboardName: pasteboard.name.rawValue),
                           false, "the inner change was noted as local")
            XCTAssertEqual(lines(), ["clipboard look took 0.9 s (remote=yes)"])
            watcher.remove(token)
        }
    }

    /// Slowness inside `changeCount` or the type reads themselves: one line,
    /// and writing it reads nothing more from the pasteboard than a quick
    /// look at the same change does.
    func testASlowPasteboardReadLeavesOneLineAndReadsNothingMore() {
        withFakeClockAndLog { advance, lines in
            let originalClass: AnyClass = object_getClass(pasteboard!) ?? NSPasteboard.self
            object_setClass(pasteboard, CountingPasteboard.self)
            defer {
                object_setClass(pasteboard, originalClass)
                CountingPasteboard.reset()
            }
            let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
            let token = watcher.add { [unowned self] count in self.decide(count) }

            // A quick look at a change: what deciding on it reads.
            pasteboard.clearContents()
            pasteboard.setString("quick", forType: .string)
            CountingPasteboard.reset()
            watcher.look()
            XCTAssertEqual(lines(), [])
            let quickTypeReads = CountingPasteboard.typeReads
            let quickItemReads = CountingPasteboard.itemReads
            XCTAssertGreaterThan(quickTypeReads, 0)

            // The same kind of change, with the type read hanging.
            pasteboard.clearContents()
            pasteboard.setString("slow", forType: .string)
            CountingPasteboard.reset()
            CountingPasteboard.onTypes = { advance(1.4) }
            watcher.look()
            XCTAssertEqual(lines(), ["clipboard look took 1.4 s (remote=no)"])
            XCTAssertEqual(CountingPasteboard.typeReads, quickTypeReads, "no type read on the slow path")
            XCTAssertEqual(CountingPasteboard.itemReads, quickItemReads, "no item read on the slow path")

            // Nothing changed, but `changeCount` itself hangs before any
            // listener: one line, and no types or items are read at all.
            CountingPasteboard.reset()
            CountingPasteboard.onChangeCount = { advance(0.7) }
            watcher.look()
            XCTAssertEqual(lines().count, 2)
            XCTAssertEqual(lines().last, "clipboard look took 0.7 s (remote=no)", "the change already decided on")
            XCTAssertEqual(CountingPasteboard.typeReads, 0)
            XCTAssertEqual(CountingPasteboard.itemReads, 0)
            CountingPasteboard.reset()
            watcher.remove(token)
        }
    }

    func testAMouseReleaseLooksAFewTimesSoAQuickShotIsNotMissed() {
        // ⌃⇧⌘4 ends with a mouse release; the picture reaches the clipboard
        // a moment later. Two shots inside one once-a-second look kept only
        // the second, so a release brings a few extra looks.
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        watcher.nudge()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        pasteboard.clearContents()
        pasteboard.setString("the first shot", forType: .string)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(seen.count, 1, "seen by a nudge look, before any scheduled one")
        XCTAssertLessThanOrEqual(ClipboardChangeWatcher.nudgeDelays.count, 3, "a few looks, not a poll")
        XCTAssertLessThan(ClipboardChangeWatcher.nudgeDelays.max() ?? 0, ClipboardChangeWatcher.interval)

        // Nobody at the Mac: a release asks for nothing.
        post(.screenLocked)
        pasteboard.clearContents()
        pasteboard.setString("while locked", forType: .string)
        watcher.nudge()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(seen.count, 1)
        watcher.remove(token)
    }

    func testAfterAMinuteWithoutInputTheClipboardLookWaitsForInput() {
        var idle: TimeInterval = 0
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { idle })
        let token = watcher.add { _ in }
        watcher.tick()
        XCTAssertTrue(watcher.isLooking)

        idle = ClipboardChangeWatcher.idleAfter
        watcher.tick()
        XCTAssertFalse(watcher.isLooking, "no look while nobody is at the Mac")
        XCTAssertTrue(watcher.isWaitingForInput)

        // Locking and unlocking counts as coming back.
        post(.screenLocked)
        post(.screenUnlocked)
        XCTAssertFalse(watcher.isWaitingForInput)
        XCTAssertTrue(watcher.isLooking)
        watcher.remove(token)
    }

    /// Nobody copies on a locked Mac: a change made while away came from
    /// another device. Coming back takes its count as seen, without asking
    /// the pasteboard about it, and the next change is looked at as usual.
    func testComingBackFromALockDoesNotLookAtWhatChangedWhileAway() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        post(.screenLocked)
        pasteboard.clearContents()
        pasteboard.setString("arrived while locked", forType: .string)
        post(.screenUnlocked)
        XCTAssertTrue(watcher.isLooking)
        XCTAssertEqual(seen, [], "no look at the unlock")
        watcher.tick()
        XCTAssertEqual(seen, [], "the change from while away is taken as seen")

        pasteboard.clearContents()
        pasteboard.setString("copied after", forType: .string)
        watcher.tick()
        XCTAssertEqual(seen, [pasteboard.changeCount])
        watcher.remove(token)
    }

    /// The same after a sleep: wake takes the count as seen.
    func testComingBackFromASleepDoesNotLookAtWhatChangedWhileAway() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        post(.willSleep)
        pasteboard.clearContents()
        pasteboard.setString("arrived while asleep", forType: .string)
        post(.didWake)
        watcher.tick()
        XCTAssertEqual(seen, [])
        watcher.remove(token)
    }

    /// macOS by default locks as the screen sleeps: that counts as a lock.
    func testAScreenSleepThatLocksSkipsTheTimeAway() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        post(.screensDidSleep)
        post(.screenLocked)
        pasteboard.clearContents()
        pasteboard.setString("arrived while locked", forType: .string)
        post(.screensDidWake)
        post(.screenUnlocked)
        watcher.tick()
        XCTAssertEqual(seen, [])
        watcher.remove(token)
    }

    /// Another user took the screen: nobody copied in this session.
    func testComingBackFromAnotherSessionSkipsTheTimeAway() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        post(.sessionDidResignActive)
        pasteboard.clearContents()
        pasteboard.setString("arrived while switched away", forType: .string)
        post(.sessionDidBecomeActive)
        watcher.tick()
        XCTAssertEqual(seen, [])
        watcher.remove(token)
    }

    /// Launched on a locked Mac: the first unlock skips what came before.
    func testLaunchedWhileLockedSkipsTheTimeAwayAtTheUnlock() {
        let locked = ActivityGate(initial: ActivityGate.State(unlocked: false),
                                  workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter())
        defer { locked.invalidate() }
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: locked, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        pasteboard.clearContents()
        pasteboard.setString("arrived while locked", forType: .string)
        locked.handle(.screenUnlocked)
        watcher.tick()
        XCTAssertEqual(seen, [])
        watcher.remove(token)
    }

    /// A copy made a moment before the lock, before the next tick, is the
    /// user's own: leaving looks once more and keeps it.
    func testACopyJustBeforeTheLockIsStillSeen() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        pasteboard.clearContents()
        pasteboard.setString("copied, then locked", forType: .string)
        let copied = pasteboard.changeCount
        post(.screenLocked)
        XCTAssertEqual(seen, [copied])
        post(.screenUnlocked)
        watcher.tick()
        XCTAssertEqual(seen, [copied], "seen once")
        watcher.remove(token)
    }

    /// A dark screen without a lock: scripts and remote desktop apps may
    /// write meanwhile, so waking the screen looks at once, as before.
    func testWakingTheScreenWithoutALockLooksAtOnce() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        var seen: [Int] = []
        let token = watcher.add { seen.append($0) }
        post(.screenLocked)
        post(.screenUnlocked)   // an earlier lock must not carry over
        post(.screensDidSleep)
        pasteboard.clearContents()
        pasteboard.setString("written by a script", forType: .string)
        post(.screensDidWake)
        XCTAssertEqual(seen, [pasteboard.changeCount])
        watcher.remove(token)
    }

    func testNoListenerNoLook() {
        let watcher = ClipboardChangeWatcher(pasteboard: pasteboard, gate: gate, idleSeconds: { 0 })
        XCTAssertFalse(watcher.isLooking)
        watcher.burst()
        XCTAssertFalse(watcher.isBursting, "a burst needs someone to tell")
    }

    // MARK: - Pure rules

    func testExpiryIsTheEarliestDueItemNotAMinuteTick() {
        let now = Date()
        let code = ClipboardItem(stringData: "482913", type: .text)
        let text = ClipboardItem(stringData: "meeting at 10", type: .text)
        XCTAssertNil(ClipboardManager.nextExpiry(of: [text], autoClearHours: 0, removeCodes: true),
                     "nothing ever expires: no timer at all")
        let due = try? XCTUnwrap(ClipboardManager.nextExpiry(of: [text, code], autoClearHours: 24, removeCodes: true))
        XCTAssertEqual(due?.timeIntervalSince(now) ?? 0, ClipboardManager.oneTimeCodeLifetime, accuracy: 2)
        let noCodes = ClipboardManager.nextExpiry(of: [code], autoClearHours: 24, removeCodes: false)
        XCTAssertEqual(noCodes?.timeIntervalSince(now) ?? 0, 24 * 3600, accuracy: 2)
    }

    func testTheIdleAnimationPlaysOnEventsAndHoldsOtherwise() {
        XCTAssertTrue(IdleAnimationPlayback.plays(present: true, hovering: false, firstLook: true), "going idle")
        XCTAssertFalse(IdleAnimationPlayback.plays(present: true, hovering: false, firstLook: false), "then it holds")
        XCTAssertTrue(IdleAnimationPlayback.plays(present: true, hovering: true, firstLook: false), "the pointer on it")
        XCTAssertFalse(IdleAnimationPlayback.plays(present: false, hovering: true, firstLook: true), "nobody there")
        XCTAssertLessThanOrEqual(IdleAnimationPlayback.performance, 10)
    }

    func testTheNowPlayingAdapterRunsOnlyWhileSomethingPlays() {
        XCTAssertTrue(NowPlayingController.AdapterDemand.reportCountsAsPlaying(isPlaying: true, title: "Song"))
        XCTAssertFalse(NowPlayingController.AdapterDemand.reportCountsAsPlaying(isPlaying: false, title: "Song"))
        XCTAssertFalse(NowPlayingController.AdapterDemand.reportCountsAsPlaying(isPlaying: true, title: ""))
        XCTAssertGreaterThan(NowPlayingController.AdapterDemand.idleGrace, 10, "longer than a paused track stays shown")
        // Restarts back off and stop growing at a minute.
        var delay = NowPlayingController.AdapterDemand.firstRestartDelay
        for _ in 0..<10 { delay = NowPlayingController.AdapterDemand.nextRestartDelay(after: delay) }
        XCTAssertEqual(delay, NowPlayingController.AdapterDemand.maximumRestartDelay)
    }

    func testOutputStartingIsANewProcessOutputting() {
        XCTAssertTrue(AudioOutputActivity.outputBegan(previous: [], current: [7]))
        XCTAssertTrue(AudioOutputActivity.outputBegan(previous: [7], current: [7, 9]))
        XCTAssertFalse(AudioOutputActivity.outputBegan(previous: [7, 9], current: [7]))
        XCTAssertFalse(AudioOutputActivity.outputBegan(previous: [7], current: [7]))
    }

    func testOutputStartIsHeardFromIsRunning() {
        // macOS 26 posts no IsRunningOutput change; IsRunning is what arrives
        // when a player starts or resumes (measured).
        XCTAssertTrue(AudioOutputActivity.listenedProcessProperties.contains(kAudioProcessPropertyIsRunning))
    }

    func testAStalledDownloadStopsSampling() {
        XCTAssertLessThanOrEqual(DownloadManager.stallAfter, 120)
    }
}

/// Put on a private test pasteboard with `object_setClass` (no stored
/// properties, so the instance fits): counts type and item reads, and lets a
/// test make `changeCount` or `types` hang on a fake clock.
final class CountingPasteboard: NSPasteboard {
    static var typeReads = 0
    static var itemReads = 0
    /// Run once, on the next read.
    static var onChangeCount: (() -> Void)?
    static var onTypes: (() -> Void)?

    static func reset() {
        typeReads = 0
        itemReads = 0
        onChangeCount = nil
        onTypes = nil
    }

    override var changeCount: Int {
        if let hang = Self.onChangeCount {
            Self.onChangeCount = nil
            hang()
        }
        return super.changeCount
    }

    override var types: [NSPasteboard.PasteboardType]? {
        Self.typeReads += 1
        if let hang = Self.onTypes {
            Self.onTypes = nil
            hang()
        }
        return super.types
    }

    override var pasteboardItems: [NSPasteboardItem]? {
        Self.itemReads += 1
        return super.pasteboardItems
    }
}
