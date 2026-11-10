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
import Defaults
import KeyboardShortcuts
import XCTest

// MARK: - Clipboard capture

/// Uses a private, uniquely named pasteboard: the user's clipboard is never
/// read or written by these tests.
@MainActor
final class ClipboardPrivacyTests: XCTestCase {
    private let manager = ClipboardManager.shared
    private var pasteboard: NSPasteboard!
    private var directory: URL!
    private var savedHistory: [ClipboardItem] = []
    private var savedPinned: [ClipboardItem] = []
    private var savedPersist = false
    private var savedPaused = false
    private var savedIgnored: [String] = []
    private var savedAutoClear = 0
    private var savedStoredHistory: Data?

    override func setUp() {
        super.setUp()
        savedHistory = manager.clipboardHistory
        savedPinned = manager.pinnedItems
        savedPersist = Defaults[.persistClipboardHistory]
        savedPaused = Defaults[.clipboardHistoryPaused]
        savedIgnored = Defaults[.clipboardIgnoredApps]
        savedAutoClear = Defaults[.clipboardAutoClearHours]
        savedStoredHistory = UserDefaults.standard.data(forKey: "ClipboardHistory")

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LuotoClipboardPrivacy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ClipboardManager.directoryOverride = directory

        pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.amidamaru940.luoto.tests.\(UUID().uuidString)"))
        manager.clipboardHistory = []
        Defaults[.clipboardHistoryPaused] = false
        Defaults[.clipboardIgnoredApps] = ClipboardCapturePolicy.defaultIgnoredApps
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        manager.clipboardHistory = savedHistory
        manager.pinnedItems = savedPinned
        Defaults[.persistClipboardHistory] = savedPersist
        Defaults[.clipboardHistoryPaused] = savedPaused
        Defaults[.clipboardIgnoredApps] = savedIgnored
        Defaults[.clipboardAutoClearHours] = savedAutoClear
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let savedStoredHistory {
            UserDefaults.standard.set(savedStoredHistory, forKey: "ClipboardHistory")
        } else {
            UserDefaults.standard.removeObject(forKey: "ClipboardHistory")
        }
        ClipboardManager.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func copy(_ text: String, markers: [NSPasteboard.PasteboardType] = []) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + markers, owner: nil)
        pasteboard.setString(text, forType: .string)
        for marker in markers {
            pasteboard.setData(Data(), forType: marker)
        }
    }

    /// `addToHistory` lands on the main queue.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func recorded(_ text: String) -> Bool {
        manager.clipboardHistory.contains { $0.stringData == text }
    }

    // MARK: Large copies do not stall the island

    private func copyRich(_ pairs: [(NSPasteboard.PasteboardType, Data)]) {
        pasteboard.clearContents()
        pasteboard.declareTypes(pairs.map(\.0), owner: nil)
        for (type, data) in pairs { pasteboard.setData(data, forType: type) }
    }

    /// A web page's HTML of about `bytes`, with the markup a browser puts there.
    private func pageHTML(bytes: Int) -> (html: Data, plain: String) {
        let paragraph = "<p style=\"color:#333\"><b>Строка</b> текста <span class=\"k\">с разметкой</span> и <a href=\"#\">ссылкой</a>.</p>\n"
        let count = bytes / paragraph.utf8.count + 1
        let html = "<html><body>" + String(repeating: paragraph, count: count) + "</body></html>"
        return (Data(html.utf8), String(repeating: "Строка текста с разметкой и ссылкой.\n", count: count))
    }

    /// The fastest of three captures of the same copy: one slow run on a
    /// busy Mac is not the code's cost.
    private func timeCapture() -> TimeInterval {
        (0..<3).map { _ in
            let start = Date()
            XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "com.google.Chrome"), .record)
            return Date().timeIntervalSince(start)
        }.min()!
    }

    func testALargeWebPageCopyIsTakenAsPlainTextWithoutParsingIt() {
        for megabytes in [1, 3] {
            let page = pageHTML(bytes: megabytes * 1_000_000)
            copyRich([(.html, page.html), (.string, Data(page.plain.utf8))])
            let took = timeCapture()
            XCTAssertLessThan(took, 0.1, "\(megabytes) MB of HTML: \(took) s")
            settle()
            XCTAssertEqual(manager.clipboardHistory.first?.type, .text)
            XCTAssertEqual(manager.clipboardHistory.first?.stringData, page.plain)
        }
    }

    func testALargeRTFCopyIsTakenAsPlainTextWithoutParsingIt() {
        let plain = String(repeating: "Абзац текста из документа Word с форматированием. ", count: 100_000)
        let rtf = NSAttributedString(string: plain, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            .rtf(from: NSRange(location: 0, length: (plain as NSString).length), documentAttributes: [:])!
        XCTAssertGreaterThan(rtf.count, ClipboardItem.maxRTFBytes)
        copyRich([(.rtf, rtf), (.string, Data(plain.utf8))])
        let took = timeCapture()
        XCTAssertLessThan(took, 0.1, "RTF of \(rtf.count) bytes: \(took) s")
        settle()
        XCTAssertEqual(manager.clipboardHistory.first?.type, .text)
        XCTAssertEqual(manager.clipboardHistory.first?.stringData, plain)
    }

    func testASmallRichCopyKeepsItsFormatting() {
        let page = pageHTML(bytes: 2_000)
        copyRich([(.html, page.html), (.string, Data(page.plain.utf8))])
        _ = timeCapture()
        settle()
        XCTAssertEqual(manager.clipboardHistory.first?.type, .rtf)
        XCTAssertNotNil(manager.clipboardHistory.first?.rtfData)
    }

    func testALargeCopyWithOnlyHTMLIsStillKept() {
        // A web app may put only HTML on the clipboard: parsed as before, so
        // the copy is not lost.
        let page = pageHTML(bytes: 200_000)
        copyRich([(.html, page.html)])
        XCTAssertFalse(pasteboard.richTextTooLargeToParse())
        XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "com.google.Chrome"), .record)
        settle()
        XCTAssertFalse(manager.clipboardHistory.first?.stringData?.isEmpty ?? true)
    }

    func testHTMLUpTo150KBWithPlainTextIsStillParsed() {
        let near = pageHTML(bytes: 140_000)
        copyRich([(.html, near.html), (.string, Data(near.plain.utf8))])
        XCTAssertFalse(pasteboard.richTextTooLargeToParse())
        let over = pageHTML(bytes: 160_000)
        copyRich([(.html, over.html), (.string, Data(over.plain.utf8))])
        XCTAssertTrue(pasteboard.richTextTooLargeToParse())
    }

    func testALargeFormattedDocumentStartingWithALinkStaysText() {
        let page = pageHTML(bytes: 1_000_000)
        let plain = "https://example.com/sources\n" + page.plain
        copyRich([(.html, page.html), (.string, Data(plain.utf8))])
        XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "notion.id"), .record)
        settle()
        XCTAssertEqual(manager.clipboardHistory.first?.type, .text)
        // A plain copied address is still a link.
        copy("https://example.com/page")
        XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "com.google.Chrome"), .record)
        settle()
        XCTAssertEqual(manager.clipboardHistory.first?.type, .url)
    }

    func testAPictureIsReadFromThePasteboardOncePerChange() {
        let first = Data([1, 2, 3])
        copyRich([(.png, first)])
        ClipboardChangeBytes.during(pasteboard) {
            let before = ClipboardChangeBytes.pasteboardReads
            XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), first)
            XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), first)
            XCTAssertEqual(ClipboardChangeBytes.pasteboardReads, before + 1, "one read for two asks")
            XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), first, "served again")
            // A new change while handling one is read afresh, never served stale.
            let second = Data([4, 5])
            copyRich([(.png, second)])
            XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), second)
        }
        // Outside a change the pasteboard is read directly.
        XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), Data([4, 5]))
    }

    func testTheSameChangeSharesItsBytesAndAnotherKeepsItsOwn() {
        copyRich([(.png, Data([1]))])
        ClipboardChangeBytes.during(pasteboard) {
            _ = ClipboardChangeBytes.data(pasteboard, forType: .png)
            let reads = ClipboardChangeBytes.pasteboardReads
            // The same change asked again inside: shared, no new read.
            ClipboardChangeBytes.during(pasteboard) {
                XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), Data([1]))
            }
            XCTAssertEqual(ClipboardChangeBytes.pasteboardReads, reads)
            // Another pasteboard inside: its own bytes, the outer kept after.
            let other = NSPasteboard(name: NSPasteboard.Name("io.github.amidamaru940.luoto.tests.\(UUID().uuidString)"))
            other.clearContents()
            other.setData(Data([9]), forType: .png)
            ClipboardChangeBytes.during(other) {
                XCTAssertEqual(ClipboardChangeBytes.data(other, forType: .png), Data([9]))
            }
            other.releaseGlobally()
            let afterInner = ClipboardChangeBytes.pasteboardReads
            XCTAssertEqual(ClipboardChangeBytes.data(pasteboard, forType: .png), Data([1]))
            XCTAssertEqual(ClipboardChangeBytes.pasteboardReads, afterInner, "the outer bytes came back")
        }
    }

    func testEveryChangeIsHandledInsideOneReadOfItsBytes() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manager = try! String(contentsOf: root.appendingPathComponent("DynamicIsland/managers/ClipboardManager.swift"), encoding: .utf8)
        XCTAssertTrue(manager.contains("return ClipboardChangeBytes.during(pasteboard) {\n            recordChange("))
        let collector = try! String(contentsOf: root.appendingPathComponent("DynamicIsland/components/Screenshots/ClipboardScreenshotCollector.swift"), encoding: .utf8)
        XCTAssertTrue(collector.contains("ClipboardChangeBytes.during(pasteboard) { () -> Shot? in"))
        let watcher = try! String(contentsOf: root.appendingPathComponent("DynamicIsland/managers/ClipboardChangeWatcher.swift"), encoding: .utf8)
        XCTAssertTrue(watcher.contains("ClipboardChangeBytes.during(pasteboard) {\n            for listener in"))
    }

    func testSearchLooksAtTheFirstHundredThousandCharactersQuickly() {
        let big = "начало " + String(repeating: "текст без совпадений ", count: 500_000) + "хвост"
        XCTAssertGreaterThan(big.utf8.count, 10_000_000)
        let items = [ClipboardItem(stringData: big, type: .text)]
            + (0..<49).map { ClipboardItem(stringData: "запись \($0)", type: .text) }
        let took = (0..<3).map { _ -> TimeInterval in
            let start = Date()
            XCTAssertTrue(ClipboardFiltering.apply(items, filter: .all, query: "нет такого слова").isEmpty)
            return Date().timeIntervalSince(start)
        }.min()!
        XCTAssertLessThan(took, 0.05, "\(took) s")
        XCTAssertEqual(ClipboardFiltering.apply(items, filter: .all, query: "НАЧАЛО").count, 1, "found near the start")
        XCTAssertTrue(ClipboardFiltering.apply(items, filter: .all, query: "хвост").isEmpty, "past the first 100 000 characters")
        XCTAssertEqual(ClipboardFiltering.apply(items, filter: .all, query: "запись 7").count, 1)
    }

    func testShortValueChecksDoNotWalkALongText() {
        let huge = String(repeating: "1", count: 30_000_000)
        let item = ClipboardItem(stringData: huge, type: .text)
        let native = (0..<3).map { _ -> TimeInterval in
            let start = Date()
            XCTAssertFalse(item.isOneTimeCode)
            XCTAssertNil(ClipboardRowText.swatch(huge))
            return Date().timeIntervalSince(start)
        }.min()!
        XCTAssertLessThan(native, 0.001)
        // Text as the clipboard hands it over (often bridged from NSString,
        // whose UTF-8 length is not known without walking it).
        copy(String(repeating: "код ", count: 7_500_000))
        let bridged = pasteboard.string(forType: .string)!
        let bridgedTook = (0..<3).map { _ -> TimeInterval in
            let start = Date()
            XCTAssertFalse(ClipboardItem(stringData: bridged, type: .text).isOneTimeCode)
            XCTAssertNil(ClipboardRowText.swatch(bridged))
            return Date().timeIntervalSince(start)
        }.min()!
        XCTAssertLessThan(bridgedTook, 0.001)
        // Short values still work, with spaces around them.
        XCTAssertTrue(ClipboardItem(stringData: " 123456\n", type: .text).isOneTimeCode)
        XCTAssertEqual(ClipboardRowText.swatch(" #5BBEEB "), 0x5BBEEB)
    }

    func testPlainCopyIsRecorded() {
        copy("ordinary text")
        XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "com.apple.TextEdit"), .record)
        settle()
        XCTAssertTrue(recorded("ordinary text"))
    }

    func testConcealedAndTransientCopiesAreNotRecorded() {
        XCTAssertEqual(ClipboardCapturePolicy.concealedTypes.count, 7)
        for (index, marker) in ClipboardCapturePolicy.concealedTypes.enumerated() {
            let secret = "secret-\(index)"
            copy(secret, markers: [marker])
            XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "com.apple.TextEdit"), .concealed, marker.rawValue)
            settle()
            XCTAssertFalse(recorded(secret), "\(marker.rawValue) copy was recorded")
        }
    }

    func testCopiesFromIgnoredAppsAreNotRecorded() {
        for (index, app) in ClipboardCapturePolicy.defaultIgnoredApps.enumerated() {
            let secret = "password-\(index)"
            copy(secret)
            XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: app), .ignoredApp, app)
            settle()
            XCTAssertFalse(recorded(secret), "copy from \(app) was recorded")
        }
    }

    func testIgnoredAppListIsEditable() {
        Defaults[.clipboardIgnoredApps] = ["com.example.vault"]

        copy("from vault")
        manager.captureChange(from: pasteboard, sourceBundleID: "com.example.vault")
        copy("from passwords")
        manager.captureChange(from: pasteboard, sourceBundleID: "com.apple.Passwords")
        settle()

        XCTAssertFalse(recorded("from vault"))
        XCTAssertTrue(recorded("from passwords"))
    }

    func testPausedHistoryRecordsNothing() {
        Defaults[.clipboardHistoryPaused] = true
        copy("while paused")
        XCTAssertEqual(manager.captureChange(from: pasteboard, sourceBundleID: "com.apple.TextEdit"), .paused)
        settle()
        XCTAssertFalse(recorded("while paused"))
    }

    func testNothingReachesDiskWhilePersistenceIsOff() throws {
        Defaults[.persistClipboardHistory] = false
        settle()
        UserDefaults.standard.removeObject(forKey: "ClipboardHistory")

        copy("text kept in memory")
        manager.captureChange(from: pasteboard, sourceBundleID: "com.apple.TextEdit")
        pasteboard.clearContents()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Self.pngData(), forType: .png)
        manager.captureChange(from: pasteboard, sourceBundleID: "com.apple.Preview")
        settle()

        XCTAssertTrue(recorded("text kept in memory"))
        XCTAssertTrue(manager.clipboardHistory.contains { $0.type == .image })
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [], "files written to the clipboard data folder")
        XCTAssertNil(UserDefaults.standard.data(forKey: "ClipboardHistory"))
    }

    func testClipboardDataLivesInTheBundleIDFolder() {
        let root = AppDataDirectory.root
        XCTAssertEqual(root.lastPathComponent, Bundle.main.bundleIdentifier)
        XCTAssertTrue(root.path.hasSuffix("/Library/Application Support/\(Bundle.main.bundleIdentifier!)"))
        XCTAssertTrue(ClipboardManager.defaultDataDirectory.path.hasPrefix(root.path))
        for folder in [CustomAppIcon.iconDirectory, NoteItem.noteImageDataDirectory,
                       ScreenAssistantManager.screenshotDataDirectory] {
            XCTAssertTrue(folder.path.hasPrefix(root.path), folder.path)
            XCTAssertFalse(folder.path.contains("/Documents/"), folder.path)
        }
    }

    func testAutoClearRemovesOldItemsButKeepsRecentOnes() {
        Defaults[.clipboardAutoClearHours] = 24
        manager.clipboardHistory = [ClipboardItem(stringData: "copied now", type: .text)]

        manager.purgeExpiredItems(now: Date().addingTimeInterval(23 * 3600))
        XCTAssertTrue(recorded("copied now"), "an item younger than 24 h was removed")

        manager.purgeExpiredItems(now: Date().addingTimeInterval(25 * 3600))
        XCTAssertFalse(recorded("copied now"), "an item older than 24 h was kept")
    }

    func testAutoClearZeroKeepsEverything() {
        Defaults[.clipboardAutoClearHours] = 0
        manager.clipboardHistory = [ClipboardItem(stringData: "old copy", type: .text)]

        manager.purgeExpiredItems(now: Date().addingTimeInterval(1000 * 3600))
        XCTAssertTrue(recorded("old copy"))
    }

    func testClipboardDefaults() {
        XCTAssertFalse(Defaults.Keys.persistClipboardHistory.defaultValue)
        XCTAssertEqual(Defaults.Keys.clipboardHistorySize.defaultValue, 50)
        XCTAssertEqual(Defaults.Keys.clipboardDisplayMode.defaultValue, .notchTab)
        XCTAssertFalse(Defaults.Keys.clipboardHistoryPaused.defaultValue)
        XCTAssertEqual(Defaults.Keys.clipboardAutoClearHours.defaultValue, 24)
        XCTAssertEqual(Defaults.Keys.clipboardIgnoredApps.defaultValue, [
            "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
            "com.bitwarden.desktop", "com.lastpass.LastPass",
        ])
        XCTAssertNil(KeyboardShortcuts.Name.toggleClipboardPause.defaultShortcut)
    }

    private static func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}

// MARK: - Network features

/// Records requests to the given hosts and fails them, so a regression shows
/// up as a recorded host instead of a real request leaving the Mac.
private final class RecordingURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var watchedHosts: Set<String> = []
    static var recordedHosts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock(); defer { lock.unlock() }
        guard watchedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        recordedHosts.append(host)
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

@MainActor
final class NetworkDefaultsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecordingURLProtocol.recordedHosts = []
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        RecordingURLProtocol.watchedHosts = []
        super.tearDown()
    }

    func testNetworkFeaturesAreOffByDefault() {
        let keys: [Defaults.Key<Bool>] = [
            .enableLockScreenWeatherWidget, .enableScreenAssistant, .enableLLMUsageFeature,
            .enableThirdPartyExtensions, .enableExtensionLiveActivities, .enableExtensionLockScreenWidgets,
            .enableExtensionNotchExperiences, .enableExtensionNotchTabs, .enableExtensionNotchMinimalisticOverrides,
            .enableExtensionNotchInteractiveWebViews, .enableExtensionFileSharing, .extensionDiagnosticsLoggingEnabled,
            .enableLyrics, .enableLocalSend, .showMirror, .enableOnlineTrackLookups,
            .lockScreenMusicFullscreenVideoArtwork,
        ]
        for key in keys {
            XCTAssertFalse(key.defaultValue, "\(key.name) must default to off")
        }
    }

    func testExtensionServerRunsOnlyWhileExtensionsAreEnabled() {
        XCTAssertEqual(ExtensionRPCServer.shared.isRunning, Defaults[.enableThirdPartyExtensions])
    }

    func testLocalSendDoesNotStartWhileDisabled() {
        let saved = Defaults[.enableLocalSend]
        defer { Defaults[.enableLocalSend] = saved }
        Defaults[.enableLocalSend] = false

        LocalSendService.shared.startDiscovery()
        LocalSendService.shared.refreshDeviceScan()

        XCTAssertFalse(LocalSendService.shared.isDiscoveryActive)
        XCTAssertFalse(QuickShareService.shared.availableProviders.contains { $0.id == "LocalSend" })
    }

    func testPricingIsNotFetchedWhileLLMMonitorIsOff() {
        let saved = Defaults[.enableLLMUsageFeature]
        defer { Defaults[.enableLLMUsageFeature] = saved }
        Defaults[.enableLLMUsageFeature] = false

        XCTAssertFalse(ModelPricingManager.shouldFetchRemotePricing)
    }

    /// Known upstream bug #694: lyrics requests with lyrics turned off.
    func testLyricsMakeNoRequestsWhileDisabled() {
        let saved = Defaults[.enableLyrics]
        defer { Defaults[.enableLyrics] = saved }
        Defaults[.enableLyrics] = false
        RecordingURLProtocol.watchedHosts = ["lrclib.net", "music.163.com"]

        MusicManager.shared.fetchLyrics()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertEqual(RecordingURLProtocol.recordedHosts, [])
    }

    func testWeatherMakesNoRequestsWhileDisabled() async {
        let saved = Defaults[.enableLockScreenWeatherWidget]
        defer { Defaults[.enableLockScreenWeatherWidget] = saved }
        Defaults[.enableLockScreenWeatherWidget] = false
        RecordingURLProtocol.watchedHosts = ["wttr.in", "open-meteo.com"]

        let snapshot = await LockScreenWeatherManager.shared.refresh(force: true)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(snapshot)
        XCTAssertEqual(RecordingURLProtocol.recordedHosts, [])
    }

    func testScreenAssistantIgnoresMessagesWhileDisabled() {
        let saved = Defaults[.enableScreenAssistant]
        defer { Defaults[.enableScreenAssistant] = saved }
        Defaults[.enableScreenAssistant] = false
        let assistant = ScreenAssistantManager.shared
        let before = assistant.chatMessages.count

        assistant.sendMessage("hello")

        XCTAssertEqual(assistant.chatMessages.count, before)
    }

    func testLLMUsageDoesNotRefreshWhileDisabled() {
        let saved = Defaults[.enableLLMUsageFeature]
        defer { Defaults[.enableLLMUsageFeature] = saved }
        Defaults[.enableLLMUsageFeature] = false

        LLMUsageManager.shared.refreshAll(force: true)

        XCTAssertFalse(LLMUsageManager.shared.isRefreshing)
    }
}

// MARK: - System safety

/// Luoto freezes system processes and rewrites the wallpaper for some features;
/// a crash must not leave them that way.
final class SystemSafetyTests: XCTestCase {
    func testFullScreenLockScreenArtworkIsOffByDefault() {
        XCTAssertFalse(Defaults.Keys.lockScreenMusicFullscreenArtworkEnabled.defaultValue)
    }

    func testProcessSignalsFindsAProcessByName() {
        let pids = ProcessSignals.pids(named: [ProcessInfo.processInfo.processName])
        XCTAssertTrue(pids.contains(getpid()))
    }

    func testContinuingAProcessThatDoesNotExistSignalsNothing() {
        XCTAssertEqual(ProcessSignals.continueProcesses(named: ["LuotoNoSuchProcess"]), 0)
    }

    func testWallpaperBackupSurvivesARestart() {
        let backup = FullScreenArtworkWindowManager.backupFolder.standardizedFileURL.path
        XCTAssertTrue(backup.hasPrefix(AppDataDirectory.root.standardizedFileURL.path))
        XCTAssertFalse(backup.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
    }
}
