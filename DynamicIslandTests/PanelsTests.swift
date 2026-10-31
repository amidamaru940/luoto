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
import SwiftUI
import Network
import XCTest

/// Keep Awake, the one timer, popovers of one width.
@MainActor
final class PanelsTests: XCTestCase {
    // MARK: Keep Awake

    func testKeepAwakeSaysWhatIsGoingOn() {
        let off = KeepAwakeStatus.title(isActive: false, remaining: nil)
        let forever = KeepAwakeStatus.title(isActive: true, remaining: nil)
        let timed = KeepAwakeStatus.title(isActive: true, remaining: 895)
        XCTAssertNotEqual(off, forever)
        XCTAssertTrue(timed.contains("14:55"), timed)
        XCTAssertFalse(forever.contains("14:55"))
    }

    func testChoosingTheRunningDurationDoesNotRestartIt() {
        XCTAssertFalse(KeepAwakeStatus.shouldStart(.oneHour, isActive: true, active: .oneHour))
        XCTAssertTrue(KeepAwakeStatus.shouldStart(.twoHours, isActive: true, active: .oneHour))
        XCTAssertTrue(KeepAwakeStatus.shouldStart(.oneHour, isActive: false, active: nil))
    }

    func testDurationsFitOneRowShortestFirst() {
        let order = CaffeinateDuration.panelOrder
        XCTAssertEqual(order.count, 5, "one row that fits 280 pt")
        XCTAssertEqual(Set(order).union([.fourHours]), Set(CaffeinateDuration.allCases), "four hours stays in Settings")
        XCTAssertEqual(order.first, .fifteenMinutes)
        XCTAssertEqual(order.last, .indefinite)
        XCTAssertEqual(CaffeinateDuration.indefinite.shortName, "∞")
        for duration in order {
            XCTAssertLessThanOrEqual(duration.shortName.count, 7, duration.shortName)
        }
    }

    func testEveryPopoverHasOneWidth() {
        XCTAssertEqual(DS.panelWidth, 280)
    }

    // MARK: Timer

    func testTheTimerShowsThreePresetsWithShortLabels() {
        XCTAssertEqual(TimerTabLayout.presetCount, 3)
        XCTAssertTrue(TimerTabLayout.presetLabel(300).contains("5"))
        XCTAssertTrue(TimerTabLayout.presetLabel(5400).contains("1"))
        XCTAssertTrue(TimerTabLayout.presetLabel(5400).contains("30"))
        XCTAssertTrue(TimerTabLayout.presetLabel(45).contains("45"))
    }

    func testTheTimerPopoverBecomesTheTab() {
        let saved = Defaults[.timerDisplayMode]
        defer { Defaults[.timerDisplayMode] = saved }
        Defaults[.timerDisplayMode] = .popover
        Defaults.Keys.migrateTimerPopoverToTab()
        XCTAssertEqual(Defaults[.timerDisplayMode], .tab)
        Defaults.Keys.migrateTimerPopoverToTab()
        XCTAssertEqual(Defaults[.timerDisplayMode], .tab)
    }

    // MARK: Drawing

    func testTheKeepAwakePanelDraws() throws {
        let renderer = ImageRenderer(content: CaffeinatePopover().background(DS.Palette.surface).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, DS.panelWidth, accuracy: 1)
        if let folder = ProcessInfo.processInfo.environment["LUOTO_SNAPSHOT_DIR"].map({ URL(fileURLWithPath: $0) }),
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: folder.appendingPathComponent("keep-awake.png"))
        }
    }
}

/// The island and the picture preview are sized by Luoto alone. With the
/// hosting view as the window's contentView, SwiftUI resized the window too
/// when its content grew, and the two re-entered Update Constraints until
/// AppKit threw.
final class SelfSizedWindowTests: XCTestCase {
    private final class Height: ObservableObject {
        @Published var value: CGFloat = 50
    }

    private struct Root: View {
        @ObservedObject var height: Height
        var body: some View { Color.clear.frame(width: 200, height: height.value) }
    }

    /// The control needs the SwiftUI App lifecycle, which the test host
    /// (Luoto itself) has; without a host app it would fail.
    @MainActor
    func testSwiftUIDoesNotResizeASelfSizedWindow() {
        XCTAssertNotEqual(windowHeightAfterTheContentGrows(selfSized: false), 100,
                          "as contentView the hosting view resizes the window: the test sees it")
        XCTAssertEqual(windowHeightAfterTheContentGrows(selfSized: true), 100)
    }

    @MainActor
    func testTheHostFillsTheWindowAndFollowsItsSize() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: Color.clear)
        window.setSelfSizedContent(host)
        XCTAssertFalse(window.contentView is NSHostingView<Color>)
        XCTAssertTrue(host.superview === window.contentView)
        XCTAssertEqual(host.frame.size, NSSize(width: 200, height: 100))
        window.setContentSize(NSSize(width: 300, height: 150))
        XCTAssertEqual(host.frame.size, NSSize(width: 300, height: 150))

        // The picture preview starts at .zero and is sized from its content.
        // Its own hosting view, with sizingOptions = [], measures 0 × 0: the
        // preview was an empty panel from 1.1.2 to 1.1.4.
        let content = Color.clear.frame(width: 120, height: 80)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        let preview = NSHostingView(rootView: content)
        preview.sizingOptions = []
        panel.setSelfSizedContent(preview)
        panel.setFrame(NSRect(origin: .zero, size: ClipboardPreviewPanel.measuredSize(of: content)), display: false)
        XCTAssertEqual(preview.frame.size, NSSize(width: 120, height: 80))
    }

    /// Shows a 200 × 100 window (out of sight), grows its content to 300 pt
    /// in an animation, and returns the window's height after it.
    @MainActor
    private func windowHeightAfterTheContentGrows(selfSized: Bool) -> CGFloat {
        let height = Height()
        let window = NSPanel(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let host = NSHostingView(rootView: Root(height: height))
        host.sizingOptions = []
        if selfSized {
            window.setSelfSizedContent(host)
        } else {
            window.contentView = host
        }
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        withAnimation(.linear(duration: 0.1)) { height.value = 300 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if selfSized {
            XCTAssertEqual(host.frame.size, window.contentView?.bounds.size, "the shown window's content fills it")
        }
        return window.frame.height
    }
}

/// The real island's view in a window like the island's: open it, close it,
/// and look at the window where the card was: an empty black card stayed
/// under the menu bar after the pointer left; it stayed opaque 0.75–1.75 s
/// here, held by the animations inside it.
final class RealCardRemovalTests: XCTestCase {
    @MainActor
    private func alpha(in view: NSView, atDistanceFromTop top: CGFloat) throws -> CGFloat {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        return rep.colorAt(x: rep.pixelsWide / 2, y: Int(top * scale))?.alphaComponent ?? -1
    }

    @MainActor
    func testTheRealCardIsGoneAfterClosing() throws {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        try XCTSkipUnless(notched != nil, "needs a screen with a notch")
        let screen = notched!
        let coordinator = DynamicIslandViewCoordinator.shared
        let firstLaunch = coordinator.firstLaunch
        coordinator.firstLaunch = false
        defer { coordinator.firstLaunch = firstLaunch }
        let band = OpenIslandNeck.bandHeight(for: screen)
        let vm = DynamicIslandViewModel(screen: screen.localizedName)
        let size = OpenIslandNeck.windowSize(
            for: CGSize(width: openNotchSize.width + 60, height: openNotchSize.height + 60),
            dynamicIslandMode: false, topBleed: notchTopScreenBleedAmount, bandHeight: band)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let host = NSHostingView(rootView: ContentView()
            .environmentObject(vm)
            .environmentObject(WebcamManager.shared))
        host.sizingOptions = []
        window.setSelfSizedContent(host)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        let card = notchTopScreenBleedAmount + IslandCard.top(bandHeight: band) + 50
        let notch = notchTopScreenBleedAmount + vm.effectiveClosedNotchHeight / 2
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertLessThan(try alpha(in: host, atDistanceFromTop: card), 0.05, "closed: no card")

        vm.open()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let fading = try alpha(in: host, atDistanceFromTop: card)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let open = try alpha(in: host, atDistanceFromTop: card)
        XCTAssertLessThan(fading, 0.99, "the card fades in, it does not pop")
        XCTAssertGreaterThan(open, 0.9, "the card is drawn while open")

        vm.close()
        var after: [(TimeInterval, CGFloat)] = []
        for wait in [0.05, 0.2, 0.5, 1.0] {
            RunLoop.main.run(until: Date().addingTimeInterval(wait))
            after.append((wait, try alpha(in: host, atDistanceFromTop: card)))
        }
        let notchAfter = try alpha(in: host, atDistanceFromTop: notch)
        print("CARD-PROBE band=\(band) fading=\(fading) open=\(open) after=\(after) notch=\(notchAfter)")
        // Before the fix: opaque for 0.75 s or more after closing.
        for (wait, alpha) in after {
            XCTAssertLessThan(alpha, 0.05, "the card is gone \(wait) s after closing")
        }
        XCTAssertGreaterThan(notchAfter, 0.9, "the closed island is back in the notch")
    }
}

/// Security hardening of 1.1.12 (audit 30.10.2026).
final class SecurityHardeningTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    func testChildProcessesDoNotInheritInjectionVariables() {
        let env = ChildProcessEnvironment.sanitized([
            "PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "LANG": "ru_RU.UTF-8",
            "PERL5OPT": "-Mevil", "PERL5LIB": "/tmp/evil", "PERLLIB": "/tmp", "PERL5DB": "x",
            "ZIPOPT": "-T -TT evil", "UNZIP": "x", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
            "BASH_ENV": "/tmp/x", "NODE_OPTIONS": "--require x", "PYTHONPATH": "/tmp",
        ])
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "LANG"], "only the injection variables go")
        XCTAssertTrue(ChildProcessEnvironment.isInjection("NOWPLAYING_CLIENT"))
        XCTAssertTrue(ChildProcessEnvironment.isInjection("MEDIAREMOTEADAPTER_PARAM_x"))
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
    }

    func testEveryPerlAndZipStartsWithTheCleanEnvironment() throws {
        for path in ["DynamicIsland/helpers/MediaChecker.swift",
                     "DynamicIsland/MediaControllers/NowPlayingController.swift",
                     "DynamicIsland/MediaControllers/AmazonMusicController.swift",
                     "DynamicIsland/DynamicIslandApp.swift",
                     "DynamicIsland/components/Shelf/Services/TemporaryFileStorageService.swift"] {
            let text = try source(path)
            let launches = text.components(separatedBy: #"URL(fileURLWithPath: "/usr/bin/perl")"#).count - 1
                + text.components(separatedBy: #"URL(fileURLWithPath: "/usr/bin/zip")"#).count - 1
            let cleaned = text.components(separatedBy: "ChildProcessEnvironment.sanitized()").count - 1
            XCTAssertGreaterThan(launches, 0, path)
            XCTAssertEqual(cleaned, launches, "\(path): every perl/zip gets the clean environment")
        }
    }

    func testAppleScriptLiteralsCannotBeBrokenOutOf() {
        let name = #"Speaker\" & (do shell script "touch /tmp/x") & "#
        let literal = AppleScriptText.literal(name)
        XCTAssertEqual(literal, #"Speaker\\\" & (do shell script \"touch /tmp/x\") & "#)
        // The literal, read back by AppleScript, is the name again.
        let script = NSAppleScript(source: "return \"\(literal)\"")
        var error: NSDictionary?
        XCTAssertEqual(script?.executeAndReturnError(&error).stringValue, name, "\(String(describing: error))")
        XCTAssertEqual(AppleScriptText.literal("a\nb\r\nc"), #"a\nb\nc"#)
    }

    func testAirPlayNamesGoThroughTheLiteral() throws {
        let text = try source("DynamicIsland/managers/AppleMusicAirPlayManager.swift")
        XCTAssertFalse(text.contains(#"replacingOccurrences(of: "\"", with: "\\\"")"#))
        XCTAssertEqual(text.components(separatedBy: "AppleScriptText.literal(").count - 1, 2)
    }

    // MARK: Extensions RPC

    func testTheRPCHandshakeRefusesWebPagesAndForeignHosts() {
        typealias H = [(name: String, value: String)]
        XCTAssertTrue(ExtensionRPCServer.acceptsHandshake(headers: [] as H), "a native client sends no Origin")
        XCTAssertTrue(ExtensionRPCServer.acceptsHandshake(headers: [("Host", "127.0.0.1:9020")]))
        XCTAssertTrue(ExtensionRPCServer.acceptsHandshake(headers: [("host", "localhost:9020")]))
        XCTAssertTrue(ExtensionRPCServer.acceptsHandshake(headers: [("Host", "[::1]:9020")]))
        XCTAssertFalse(ExtensionRPCServer.acceptsHandshake(headers: [("Origin", "https://evil.example")]))
        XCTAssertFalse(ExtensionRPCServer.acceptsHandshake(headers: [("origin", "null")]))
        XCTAssertFalse(ExtensionRPCServer.acceptsHandshake(headers: [("Host", "evil.example:9020")]), "DNS rebinding")
        // Some native WebSocket libraries send the server's own address as Origin.
        XCTAssertTrue(ExtensionRPCServer.acceptsHandshake(headers: [("Origin", "http://127.0.0.1:9020")]))
        XCTAssertTrue(ExtensionRPCServer.acceptsHandshake(headers: [("Origin", "ws://localhost:9020")]))
        XCTAssertFalse(ExtensionRPCServer.acceptsHandshake(headers: [("Origin", "http://localhost:3000")]), "a local web page")
        XCTAssertFalse(ExtensionRPCServer.acceptsHandshake(headers: [("Origin", "http://127.0.0.1")]))
    }

    /// The real handshake through Network.framework: a request with `Origin`
    /// gets no 101, the same request without it does.
    func testTheRealListenerRefusesABrowserHandshake() throws {
        let parameters = NWParameters(tls: nil)
        parameters.defaultProtocolStack.applicationProtocols.insert(ExtensionRPCServer.webSocketOptions(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receiveMessage { _, _, _, _ in }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        defer { listener.cancel() }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        let port = try XCTUnwrap(listener.port?.rawValue)

        XCTAssertTrue(try statusLine(port: port, origin: nil).contains(" 101"), "a native client connects")
        XCTAssertFalse(try statusLine(port: port, origin: "https://evil.example").contains(" 101"), "a web page does not")
        XCTAssertTrue(try statusLine(port: port, origin: "http://127.0.0.1:9020").contains(" 101"),
                      "a native library naming this server connects")
    }

    /// Sends a WebSocket upgrade request and returns the response's first line.
    private func statusLine(port: UInt16, origin: String?) throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        var line = ""
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            var request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString())\r\nSec-WebSocket-Version: 13\r\n"
            if let origin { request += "Origin: \(origin)\r\n" }
            request += "\r\n"
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    line = data.flatMap { String(data: $0, encoding: .utf8) }?
                        .components(separatedBy: "\r\n").first ?? ""
                    done.signal()
                }
            })
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        _ = done.wait(timeout: .now() + 5)
        return line
    }

    func testSharedFilesStayInTheirFolder() {
        let folder = URL(fileURLWithPath: "/tmp/AtollExtensionFiles", isDirectory: true)
        XCTAssertEqual(ExtensionRPCService.sharedFileURL(named: "report.pdf", in: folder)?.path, "/tmp/AtollExtensionFiles/report.pdf")
        XCTAssertEqual(ExtensionRPCService.sharedFileURL(named: "../../Library/LaunchAgents/x.plist", in: folder)?.path,
                       "/tmp/AtollExtensionFiles/x.plist", "only the last component is used")
        XCTAssertNil(ExtensionRPCService.sharedFileURL(named: "..", in: folder))
        XCTAssertNil(ExtensionRPCService.sharedFileURL(named: "", in: folder))
        XCTAssertNil(ExtensionRPCService.sharedFileURL(named: "/", in: folder))
    }

    func testFileSharingIsNotADefaultScope() {
        let scopes = ExtensionAuthorizationManager.defaultScopes()
        XCTAssertFalse(scopes.contains(.fileSharing))
        XCTAssertEqual(scopes.count, ExtensionPermissionScope.allCases.count - 1)
    }

    func testRevokedClientsAreNotAuthorisedAgainAndDescriptorsMustBeTheirOwn() throws {
        let text = try source("DynamicIsland/services/Extensions/ExtensionRPCService.swift")
        XCTAssertTrue(text.contains("if entry.status == .denied || entry.status == .revoked {"))
        XCTAssertEqual(text.components(separatedBy: "if let refusal = refusal(forDescriptorOf: descriptor.bundleIdentifier, id: id) { return refusal }").count - 1, 6,
                       "every present and update checks the descriptor's owner")
    }

    // MARK: Spotify session

    private final class MemoryStore: SpotifyTokenStoring, @unchecked Sendable {
        var values: [SpotifyTokenAccount: String] = [:]
        var failWrites = false
        func read(_ account: SpotifyTokenAccount) -> String? { values[account] }
        func write(_ value: String, account: SpotifyTokenAccount) -> OSStatus {
            guard !failWrites else { return errSecIO }
            values[account] = value
            return errSecSuccess
        }
        func delete(_ account: SpotifyTokenAccount) -> OSStatus { values[account] = nil; return errSecSuccess }
    }

    @MainActor
    func testTheSpotifySessionMovesFromThePlistToTheKeychain() {
        let savedStore = SpotifyWebSession.store
        let savedCookie = Defaults[.spotifySPDCCookie], savedToken = Defaults[.spotifyAuthAccessToken]
        defer {
            SpotifyWebSession.store = savedStore
            Defaults[.spotifySPDCCookie] = savedCookie
            Defaults[.spotifyAuthAccessToken] = savedToken
        }
        let store = MemoryStore()
        SpotifyWebSession.store = store

        // A failed Keychain write keeps the only copy, and the session reads it.
        store.failWrites = true
        Defaults[.spotifySPDCCookie] = "legacy-cookie"
        Defaults[.spotifyAuthAccessToken] = "legacy-token"
        XCTAssertEqual(SpotifyWebSession.cookie, "legacy-cookie")
        XCTAssertEqual(Defaults[.spotifySPDCCookie], "legacy-cookie")

        // The next launch (a fresh store) moves it.
        store.failWrites = false
        SpotifyWebSession.store = store
        XCTAssertEqual(SpotifyWebSession.cookie, "legacy-cookie")
        XCTAssertEqual(SpotifyWebSession.accessToken, "legacy-token")
        XCTAssertEqual(Defaults[.spotifySPDCCookie], "", "the plist no longer holds the session")
        XCTAssertEqual(Defaults[.spotifyAuthAccessToken], "")

        SpotifyWebSession.cookie = "new-cookie"
        XCTAssertEqual(store.values[.webCookie], "new-cookie")
        XCTAssertEqual(Defaults[.spotifySPDCCookie], "")
        SpotifyWebSession.cookie = ""
        XCTAssertNil(store.values[.webCookie], "clearing deletes it")
    }

    // MARK: Terminal and dropped files

    func testTheTerminalRunsOnlyAListedShell() {
        let listed = "# List of acceptable shells\n/bin/bash\n/bin/zsh\n/opt/homebrew/bin/fish\n"
        XCTAssertEqual(TerminalManager.allowedShell("/opt/homebrew/bin/fish", listed: listed), "/opt/homebrew/bin/fish")
        XCTAssertEqual(TerminalManager.allowedShell("/tmp/evil", listed: listed), "/bin/zsh")
        XCTAssertEqual(TerminalManager.allowedShell("/bin/bash", listed: nil), "/bin/zsh")
        XCTAssertEqual(TerminalManager.allowedShell("/bin/zsh"), "/bin/zsh", "the real /etc/shells lists zsh")
    }

    /// The shelf's zip with the real /usr/bin/zip: `--` keeps a name like
    /// "-x.txt" a file, and the archive holds it.
    func testTheShelfZipsAFileNamedLikeAnOption() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("-x.txt")
        try Data("hi".utf8).write(to: file)
        let made = await TemporaryFileStorageService.shared.createZip(from: [file])
        let archive = try XCTUnwrap(made)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-l", archive.path]
        let out = Pipe()
        list.standardOutput = out
        try list.run()
        list.waitUntilExit()
        let listing = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(list.terminationStatus, 0)
        XCTAssertTrue(listing.contains("-x.txt"), listing)
    }

    func testDroppedFileNamesStayInTheTemporaryFolder() {
        XCTAssertEqual(TemporaryFileStorageService.safeFileName("photo.png"), "photo.png")
        XCTAssertEqual(TemporaryFileStorageService.safeFileName("../../.ssh/authorized_keys"), "authorized_keys")
        XCTAssertNil(TemporaryFileStorageService.safeFileName(".."))
        XCTAssertNil(TemporaryFileStorageService.safeFileName(nil))
        XCTAssertNil(TemporaryFileStorageService.safeFileName(""))
    }

    // MARK: Sparkle and the release script

    func testSparkleIsPatchedAndItsXPCServicesStayOutOfReleases() throws {
        let resolved = try source("DynamicIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        XCTAssertTrue(resolved.contains("\"version\" : \"2.9.6\""), "Sparkle 2.9.6 fixes the published advisories")
        let script = try source("scripts/make-release.sh")
        XCTAssertTrue(script.contains(#"find "$SPARKLE" -name XPCServices -maxdepth 3 -exec rm -rf {} +"#))
        XCTAssertTrue(script.contains("Re-signing changed the entitlements"))
        XCTAssertTrue(script.contains("Sparkle XPC services must not ship"))
        XCTAssertTrue(script.contains("-onlyUsePackageVersionsFromResolvedFile"))
        XCTAssertTrue(script.contains("BUILD_STATUS=${pipestatus[1]}"))
        XCTAssertFalse(script.contains(#"| grep -E "error:|\*\* BUILD" || true"#), "a failed build is not hidden")
    }
}

/// The app plays macOS system sounds by name; no sound file ships with it.
final class AppSoundTests: XCTestCase {
    func testEverySoundExistsOnTheSystem() {
        for sound in AppSound.allCases {
            XCTAssertNotNil(NSSound(named: sound.rawValue), sound.rawValue)
        }
    }

    func testNoSoundFileShipsWithTheApp() {
        for (name, kind) in [("lock", "mp3"), ("unlock", "mp3"), ("timer", "mp3"), ("lowbattery", "mp3"), ("dynamic", "m4a"), ("audio-feedback", "m4a")] {
            XCTAssertNil(Bundle.main.url(forResource: name, withExtension: kind), name)
        }
    }

    func testEverySoundPlays() throws {
        for sound in AppSound.allCases {
            let silent = try XCTUnwrap(NSSound(named: sound.rawValue)?.copy() as? NSSound)
            silent.volume = 0
            XCTAssertTrue(silent.play(), sound.rawValue)
            silent.stop()
        }
    }

    func testTheRingStartsAndStops() {
        let ring = TimerRing(volume: 0)
        XCTAssertFalse(ring.isRinging)
        ring.start(customPath: nil)
        XCTAssertTrue(ring.isRinging)
        ring.stop()
        XCTAssertFalse(ring.isRinging)
    }

    func testARingForAFileThatIsGoneUsesTheSystemSound() {
        let ring = TimerRing(volume: 0)
        ring.start(customPath: "/nonexistent/ring.mp3")
        XCTAssertTrue(ring.isRinging)
        ring.stop()
    }

    func testARingPlaysTheChosenFile() throws {
        // One second of 8 kHz, 8-bit mono silence.
        let samples = Data(repeating: 0x80, count: 8000)
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wave = Data("RIFF".utf8) + le(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        wave += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(8000)) + le(UInt32(8000)) + le(UInt16(1)) + le(UInt16(8))
        wave += Data("data".utf8) + le(UInt32(samples.count)) + samples
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("island-ring-\(UUID().uuidString).wav")
        try wave.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let ring = TimerRing(volume: 0)
        ring.start(customPath: file.path)
        XCTAssertTrue(ring.isRinging)
        ring.stop()
        XCTAssertFalse(ring.isRinging)
    }

    func testStartingAgainLeavesOneRing() {
        let ring = TimerRing(volume: 0)
        ring.start(customPath: nil)
        ring.start(customPath: nil)
        XCTAssertTrue(ring.isRinging)
        ring.stop()
        XCTAssertFalse(ring.isRinging)
    }

    func testEveryBluetoothDeviceDrawsASymbol() {
        for type in BluetoothAudioDeviceType.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: type.sfSymbol, accessibilityDescription: nil), "\(type)")
        }
        // The check above would pass on the fallback alone.
        XCTAssertEqual(BluetoothAudioDeviceType.generic.sfSymbol, "dot.radiowaves.left.and.right")
        XCTAssertEqual(BluetoothAudioDeviceType.speaker.sfSymbol, "hifispeaker.fill")
    }

    /// The timer rings until it is stopped, and that leaves the shared sound alone.
    func testTheTimerLoopsOnACopyOfItsOwn() throws {
        let looping = try XCTUnwrap(AppSound.timer.looping())
        XCTAssertTrue(looping.loops)
        XCTAssertFalse(try XCTUnwrap(NSSound(named: AppSound.timer.rawValue)).loops)
    }
}

/// A picture copied in Finder is not a request for the folder it sits in.
final class FolderFirstTouchReadTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func mayRead(
        _ path: String,
        touched: Bool = false,
        touchedPath: String? = nil,
        documents: Bool = false,
        downloads: Bool = false
    ) -> Bool {
        FolderFirstTouch.mayRead(
            URL(fileURLWithPath: path), home: home,
            screenshotFolderTouched: touched, screenshotFolderTouchedPath: touchedPath,
            documentsAllowed: documents, downloadsAllowed: downloads
        )
    }

    func testAProtectedFolderWaitsUntilItIsAllowed() {
        XCTAssertFalse(mayRead("/Users/someone/Desktop/a.png"))
        XCTAssertFalse(mayRead("/Users/someone/Documents/deep/a.png"))
        XCTAssertFalse(mayRead("/Users/someone/Downloads/a.png"))
        XCTAssertTrue(mayRead("/Users/someone/Desktop/a.png", touched: true, touchedPath: "/Users/someone/Desktop"))
        XCTAssertTrue(mayRead("/Users/someone/Desktop/a.png", touched: true, touchedPath: FolderFirstTouch.anyScreenshotFolder))
        XCTAssertTrue(mayRead("/Users/someone/Documents/a.png", documents: true))
        XCTAssertTrue(mayRead("/Users/someone/Downloads/a.png", downloads: true))
    }

    func testAnAnswerForAnotherScreenshotFolderSaysNothingAboutTheDesktop() {
        XCTAssertFalse(mayRead("/Users/someone/Desktop/a.png", touched: true, touchedPath: "/Users/someone/Screenshots"))
    }

    func testOtherGuardedPlacesWait() {
        XCTAssertFalse(mayRead("/Volumes/Disk/a.png"))
        XCTAssertFalse(mayRead("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/a.png"))
    }

    func testOtherFoldersAreReadAsBefore() {
        XCTAssertTrue(mayRead("/Users/someone/Pictures/a.png"))
        XCTAssertTrue(mayRead("/Users/someone/DesktopBackup/a.png"))
    }
}

/// The tap follows Accessibility both ways, or the native HUD stays frozen with
/// nothing drawing in its place.
final class MediaKeyTapActionTests: XCTestCase {
    func testTheTapFollowsAccessibility() {
        XCTAssertEqual(MediaKeyTapAction.after(trusted: true, hasTap: false), .install)
        XCTAssertEqual(MediaKeyTapAction.after(trusted: false, hasTap: true), .remove)
        XCTAssertEqual(MediaKeyTapAction.after(trusted: true, hasTap: true), .none)
        XCTAssertEqual(MediaKeyTapAction.after(trusted: false, hasTap: false), .none)
    }
}

final class AccessibilityRestoreTests: XCTestCase {
    func testTheCardShowsOnlyWhenAccessWasGivenAndIsGone() {
        XCTAssertTrue(AccessibilityPermissionStore.needsRestore(isAuthorized: false, wasGranted: true))
        XCTAssertFalse(AccessibilityPermissionStore.needsRestore(isAuthorized: true, wasGranted: true))
        XCTAssertFalse(AccessibilityPermissionStore.needsRestore(isAuthorized: false, wasGranted: false))
    }
}
