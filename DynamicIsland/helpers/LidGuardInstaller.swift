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

import CryptoKit
import Defaults
import Foundation
import Security

/// Puts the root helper in place, the one time Luoto ever asks for the Mac's
/// password, and only when the user turns on "with the lid closed".
///
/// macOS's own dialog takes the password; Luoto never sees it. The helper runs
/// from a root-owned copy: root must never run a file in the app bundle, which
/// the user (and so any process of the user's) can change.
enum LidGuardInstaller {
    enum State: Equatable {
        case missing
        /// Set up for this app, with this version of the helper.
        case current
        /// An older helper, or one set up for a copy of the app elsewhere.
        case outdated
        /// Another user of this Mac set it up.
        case otherUser
    }

    enum Outcome: Equatable { case done, cancelled, failed, damaged }

    /// Exit codes of the setup script, as the dialog's error reports them.
    static let signatureExitCode = 10
    static let launchdExitCode = 11
    static let refusedExitCode = 12

    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(LidGuardConfig.label)")
    }

    #if DEBUG
    /// Tests keep everything in a folder of their own, with the app's path made up.
    nonisolated(unsafe) static var testRoot: String?
    #endif

    /// A path as the app looks at it. A test host never reaches the real helper:
    /// a test once told the helper of the Mac it ran on to remove itself.
    private static func onDisk(_ path: String) -> String {
        #if DEBUG
        if let testRoot { return testRoot + path }
        if AppRuntimeEnvironment.isHostingUnitTests { return "/nonexistent-luoto-test-root" + path }
        #endif
        return path
    }

    private static var appPath: String {
        #if DEBUG
        if testRoot != nil { return "/Applications/Luoto.app" }
        #endif
        return Bundle.main.bundleURL.path
    }

    private static var sessionDirectory: URL { URL(fileURLWithPath: onDisk(LidGuardConfig.sessionDirectory)) }
    static var leaseURL: URL { sessionDirectory.appendingPathComponent(LidGuardConfig.leaseName) }
    static var uninstallURL: URL { sessionDirectory.appendingPathComponent(LidGuardConfig.uninstallName) }
    static var wakeURL: URL { sessionDirectory.appendingPathComponent(LidGuardConfig.wakeName) }

    private static func supportFile(_ name: String) -> String { "\(LidGuardConfig.supportDirectory)/\(name)" }
    private static var statusFile: String { onDisk(supportFile(LidGuardConfig.statusName)) }

    static var state: State {
        let files = FileManager.default
        guard files.fileExists(atPath: onDisk(LidGuardConfig.plistPath)), files.fileExists(atPath: onDisk(LidGuardConfig.helperPath)) else {
            return .missing
        }
        let version = try? String(contentsOfFile: onDisk(supportFile(LidGuardConfig.versionName)), encoding: .utf8)
        return resolve(version: version, installedAppPath: installedAppPath, appPath: appPath,
                       sessionWritable: files.isWritableFile(atPath: onDisk(LidGuardConfig.sessionDirectory)))
    }

    nonisolated static func resolve(version: String?, installedAppPath: String?, appPath: String, sessionWritable: Bool) -> State {
        guard version == String(LidGuardConfig.version), installedAppPath == appPath else { return .outdated }
        return sessionWritable ? .current : .otherUser
    }

    private static var installedAppPath: String? {
        guard let data = FileManager.default.contents(atPath: onDisk(LidGuardConfig.plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String], arguments.count > 1 else { return nil }
        return arguments[1]
    }

    static var status: LidGuardStatus {
        (try? String(contentsOfFile: statusFile, encoding: .utf8))
            .flatMap(LidGuardStatus.init(rawValue:)) ?? .off
    }

    /// The helper rewrites its status at each check, so an old date means it is
    /// not running, whatever the status says.
    static var statusIsFresh: Bool {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: statusFile))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) <= LidGuardConfig.statusLifetime
    }

    /// The helper turned the flag on and has not turned it off.
    static var hasMarker: Bool { FileManager.default.fileExists(atPath: onDisk(supportFile(LidGuardConfig.markerName))) }

    /// A copy run from a disk image or translocated by Gatekeeper will be gone
    /// soon, and the helper would remove itself with it.
    nonisolated static func canInstall(fromAppPath path: String) -> Bool {
        !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
    }

    static func install() async -> Outcome {
        guard AppRuntimeEnvironment.mayAskForPermissions,
              FileManager.default.isExecutableFile(atPath: bundledHelper.path) else { return .failed }
        let requirement: String?
        switch signature() {
        case .certificate(let leaf): requirement = leaf
        case .adHoc: requirement = nil
        case .unreadable:
            NSLog("[LidGuard] this app's signature does not hold up; not setting up the helper")
            return .failed
        }
        let script = shellScript(
            bundledHelper: bundledHelper.path,
            user: getuid(),
            group: getgid(),
            plist: launchdPlist(appPath: Bundle.main.bundleURL.path),
            requirement: requirement
        )
        let prompt = String(localized: "Luoto is installing a helper so the Mac can stay awake with the lid closed. This is needed once.")
        return await runAsAdministrator(script, prompt: prompt)
    }

    /// The last resort, when the helper cannot be reached and the Mac cannot
    /// sleep: it was switched off in Login Items while the flag was on.
    static func resetSleepFlag() async -> Outcome {
        guard AppRuntimeEnvironment.mayAskForPermissions else { return .failed }
        let prompt = String(localized: "Luoto needs this to let the Mac sleep again.")
        return await runAsAdministrator(
            resetScript,
            prompt: prompt
        )
    }

    private static func runAsAdministrator(_ script: String, prompt: String) async -> Outcome {
        let source = "do shell script \"\(AppleScriptText.literal(script))\" with prompt \"\(AppleScriptText.literal(prompt))\" with administrator privileges"
        do {
            try await AppleScriptHelper.executeVoid(source)
            return .done
        } catch {
            let number = (error as NSError).userInfo[NSAppleScript.errorNumber] as? Int
            NSLog("[LidGuard] the privileged step ended with \(number ?? 0)")
            switch number {
            case -128: return .cancelled
            case signatureExitCode: return .damaged
            default: return .failed
            }
        }
    }

    /// The stored choice, if it is one the helper knows. Everything that shows or
    /// sends the level reads it here, so that they cannot disagree.
    static var chosenBatteryFloor: Int {
        let stored = Defaults[.lidClosedBatteryFloor]
        return LidGuardConfig.batteryFloors.contains(stored) ? stored : LidGuardConfig.batteryFloor
    }

    /// Tells the helper the level the user chose, by which fixed name exists. The
    /// new one first: when several exist the highest counts.
    static func writeBatteryFloor(_ floor: Int) {
        let folder = sessionDirectory
        if floor != LidGuardConfig.batteryFloor, LidGuardConfig.batteryFloors.contains(floor) {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(LidGuardConfig.floorName(floor)).path, contents: Data())
        }
        for other in LidGuardConfig.batteryFloors where other != floor {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(LidGuardConfig.floorName(other)))
        }
    }

    /// Asks the helper to remove itself. No password: it only takes the feature
    /// away, which any process of the user's may do.
    static func requestRemoval() {
        FileManager.default.createFile(atPath: uninstallURL.path, contents: Data())
    }

    // MARK: - Pure

    static func launchdPlist(appPath: String) -> Data {
        let plist: [String: Any] = [
            "Label": LidGuardConfig.label,
            "ProgramArguments": [LidGuardConfig.helperPath, appPath],
            "RunAtLoad": true,
            "WatchPaths": [LidGuardConfig.sessionDirectory],
            // Every deliberate exit is 0, so anything else brings it back.
            "KeepAlive": ["Crashed": true, "SuccessfulExit": false],
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "io.github.amidamaru940.luoto"],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    /// The commands run as root. Only absolute paths. The bundled file is the
    /// user's to change, so it must be a plain file, its copy stays unreadable to
    /// others until its signature is checked, and only then becomes the helper.
    /// The plist travels in the command itself, so there is no file to swap. Links
    /// planted where the helper's folders go are refused, and none is followed.
    static func shellScript(bundledHelper: String, user: uid_t, group: gid_t, plist: Data, requirement: String?) -> String {
        let label = LidGuardConfig.label
        let source = quoted(bundledHelper)
        let helper = quoted(LidGuardConfig.helperPath)
        let newHelper = quoted(LidGuardConfig.helperPath + ".new")
        let plistPath = quoted(LidGuardConfig.plistPath)
        let newPlist = quoted(LidGuardConfig.plistPath + ".new")
        let support = quoted(LidGuardConfig.supportDirectory)
        let session = quoted(LidGuardConfig.sessionDirectory)
        let version = quoted(supportFile(LidGuardConfig.versionName))
        let check = requirement.map { "-R=\(quoted($0)) " } ?? ""
        return [
            "set -e",
            "umask 022",
            "trap '/bin/rm -f \(LidGuardConfig.helperPath).new \(LidGuardConfig.plistPath).new' EXIT",
            "if [ ! -f \(source) ] || [ -L \(source) ]; then exit \(refusedExitCode); fi",
            "if [ -L \(support) ] || [ -L \(session) ]; then exit \(refusedExitCode); fi",
            "/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons",
            "/usr/bin/install -o root -g wheel -m 700 \(source) \(newHelper)",
            "/usr/bin/xattr -c \(newHelper) || true",
            "/usr/bin/codesign --verify --strict \(check)\(newHelper) || exit \(signatureExitCode)",
            "/bin/chmod 755 \(newHelper)",
            "/bin/echo \(plist.base64EncodedString()) | /usr/bin/base64 -D > \(newPlist)",
            "/usr/bin/plutil -lint -s \(newPlist)",
            "/usr/sbin/chown root:wheel \(newPlist)",
            "/bin/chmod 644 \(newPlist)",
            "/bin/mkdir -p \(support)",
            "/usr/sbin/chown -h root:wheel \(support)",
            "/bin/chmod -h 755 \(support)",
            "/bin/mkdir -p \(session)",
            "/usr/sbin/chown -h \(user):\(group) \(session)",
            "/bin/chmod -h 700 \(session)",
            "/bin/launchctl bootout system/\(label) 2>/dev/null || true",
            "/bin/mv -f \(newHelper) \(helper)",
            "/bin/mv -f \(newPlist) \(plistPath)",
            "/bin/rm -f \(quoted(LidGuardConfig.sessionDirectory + "/" + LidGuardConfig.leaseName)) \(quoted(LidGuardConfig.sessionDirectory + "/" + LidGuardConfig.uninstallName)) 2>/dev/null || true",
            "/bin/rm -f \(version)",
            "/usr/bin/printf %s \(LidGuardConfig.version) > \(version)",
            "/bin/chmod 644 \(version)",
            // launchd may still be letting go of the old job.
            "loaded=0",
            "for attempt in 1 2 3 4 5; do if /bin/launchctl bootstrap system \(plistPath) 2>/dev/null; then loaded=1; break; fi; /bin/sleep 1; done",
            "if [ \"$loaded\" != 1 ]; then /bin/rm -f \(plistPath) \(helper); exit \(launchdExitCode); fi",
        ].joined(separator: "\n")
    }

    /// If the helper is gone too, what it left behind goes with the marker.
    static var resetScript: String {
        let session = LidGuardConfig.sessionDirectory
        let support = LidGuardConfig.supportDirectory
        let floorFiles = LidGuardConfig.batteryFloors.map { quoted("\(session)/\(LidGuardConfig.floorName($0))") }.joined(separator: " ")
        return """
        /usr/bin/pmset -a disablesleep 0 && /bin/rm -f \(quoted(supportFile(LidGuardConfig.markerName)))
        if [ ! -e \(quoted(LidGuardConfig.plistPath)) ]; then /bin/rm -f \(quoted(supportFile(LidGuardConfig.statusName))) \(quoted(supportFile(LidGuardConfig.versionName))) \(floorFiles); /bin/rmdir \(quoted(session)) \(quoted(support)) 2>/dev/null; fi
        /usr/bin/true
        """
    }

    /// One argument to `/bin/sh`, whatever is in it.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum Signature: Equatable {
        /// This app's certificate, as a code requirement for the helper.
        case certificate(String)
        /// Anyone's own build: there is no certificate to hold the helper to.
        case adHoc
        /// A signed build whose signature cannot be read must not go unchecked.
        case unreadable
    }

    static func signature() -> Signature {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              // What is on disk must be what is running: otherwise someone re-signed
              // the app on disk ad-hoc under the running one, to get out of the check.
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let details = information as? [String: Any],
              let flags = details[kSecCodeInfoFlags as String] as? UInt32 else { return .unreadable }
        // kSecCodeSignatureAdhoc, which Swift does not import under this name.
        if flags & 0x0002 != 0 { return .adHoc }
        guard let chain = details[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = chain.first else {
            return .unreadable
        }
        return .certificate(requirement(leafCertificate: SecCertificateCopyData(leaf) as Data))
    }

    static func requirement(leafCertificate: Data) -> String {
        let hash = Insecure.SHA1.hash(data: leafCertificate).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(LidGuardConfig.label)\" and certificate leaf = H\"\(hash)\""
    }
}
