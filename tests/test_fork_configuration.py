import json
import plistlib
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "DynamicIsland.xcodeproj" / "project.pbxproj"
INFO_PLIST = ROOT / "DynamicIsland" / "Info.plist"
ENTITLEMENTS = ROOT / "DynamicIsland" / "DynamicIsland.entitlements"
NOTICE = ROOT / "NOTICE"
THIRD_PARTY = ROOT / "THIRD-PARTY-LICENSES.md"
RESOLVED = ROOT / "DynamicIsland.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"

ATOLL_TEAM = "9Y64TRM77N"
BASE_COMMIT = "868c25d4a1128eda9c556eb08f09468d9766219f"


def app_target_configs(project):
    """Build settings blocks of the app target (the ones that set CODE_SIGN_ENTITLEMENTS)."""
    blocks = re.findall(r"buildSettings = \{(.*?)\n\t\t\t\};", project, re.S)
    return [b for b in blocks if "CODE_SIGN_ENTITLEMENTS = DynamicIsland/DynamicIsland.entitlements;" in b]


def public_text_files():
    """Name and text of every file the public copy is exported with."""
    private = ("docs/", ".claude/", "REPORT.md", "CHANGES.md", "README_RU.md")
    listed = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True).stdout
    for name in filter(None, listed.split("\0")):
        path = ROOT / name
        if name.startswith(private) or not path.is_file():
            continue
        try:
            yield name, path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue


def swift_comments(source):
    """The comments of a Swift file. Strings and what is interpolated into them
    are followed, so the // of a URL is no comment."""
    token = re.compile(r'//|/\*|#*"(?:"")?|[()]')
    comments, stack, at = [], [], 0  # stack: an open string (a tuple), or an interpolation's depth (a list)
    while True:
        if stack and isinstance(stack[-1], tuple):
            closer, escape = stack[-1]
            ends = [escape, closer] + ([] if closer.startswith('"""') else ["\n"])
            found = re.compile("|".join(map(re.escape, ends))).search(source, at)
            if not found:
                return comments
            at = found.end()
            if found.group() != escape:
                stack.pop()
            elif source.startswith("(", at):
                stack.append([1])
                at += 1
            else:
                at += 1
            continue
        found = token.search(source, at)
        if not found:
            return comments
        at = found.end()
        if found.group() == "//":
            end = source.find("\n", at)
            at = len(source) if end < 0 else end
            comments.append(source[found.start():at])
        elif found.group() == "/*":
            depth = 1
            while depth:
                inner = re.compile(r"/\*|\*/").search(source, at)
                if not inner:
                    return comments + [source[found.start():]]
                depth += 1 if inner.group() == "/*" else -1
                at = inner.end()
            comments.append(source[found.start():at])
        elif found.group() in "()":
            if stack:
                stack[-1][0] += 1 if found.group() == "(" else -1
                if stack[-1][0] == 0:
                    stack.pop()
        else:
            hashes = found.group()[:found.group().index('"')]
            stack.append((found.group()[len(hashes):] + hashes, "\\" + hashes))


class ForkConfigurationTests(unittest.TestCase):
    def test_bundle_identifiers(self):
        project = PROJECT.read_text()

        self.assertEqual(1, project.count("PRODUCT_BUNDLE_IDENTIFIER = io.github.amidamaru940.luoto;"))
        self.assertEqual(1, project.count("PRODUCT_BUNDLE_IDENTIFIER = io.github.amidamaru940.luoto.dev;"))
        self.assertEqual(2, project.count("PRODUCT_BUNDLE_IDENTIFIER = io.github.amidamaru940.luoto.tests;"))
        self.assertEqual(2, project.count("PRODUCT_BUNDLE_IDENTIFIER = io.github.amidamaru940.luoto.uitests;"))
        self.assertNotIn("com.Ebullioscopic.Atoll", project)

    def test_product_and_display_name(self):
        project = PROJECT.read_text()

        self.assertEqual(2, project.count('PRODUCT_NAME = "Luoto";'))
        self.assertEqual(2, project.count('INFOPLIST_KEY_CFBundleDisplayName = "Luoto";'))
        # The Swift module keeps its upstream name so `@testable import Atoll` and upstream merges keep working.
        self.assertEqual(2, project.count("PRODUCT_MODULE_NAME = Atoll;"))

    def test_signing_comes_from_the_xcconfig(self):
        """No team in the project: ad-hoc for anyone, an own team only in the untracked Local.xcconfig."""
        project = PROJECT.read_text()
        configs = app_target_configs(project)
        signing = (ROOT / "Config" / "Signing.xcconfig").read_text()

        self.assertEqual(2, len(configs))  # Debug and Release
        self.assertEqual(2, project.count("baseConfigurationReference = 5CE2A1F0B7C94E3DA0F11A01 /* Signing.xcconfig */;"))
        for config in configs:
            self.assertIn("CODE_SIGN_STYLE = Automatic;", config)
            self.assertIn("ENABLE_HARDENED_RUNTIME = YES;", config)
        self.assertIsNone(re.search(r"^\s*DEVELOPMENT_TEAM = ", project, re.M), "the team belongs in Config/Local.xcconfig")
        self.assertIsNone(re.search(r'^\s*"?CODE_SIGN_IDENTITY(\[[^\]]*\])?"? = ', project, re.M), "the identity too")
        self.assertNotIn(ATOLL_TEAM, project)
        self.assertIn("CODE_SIGN_IDENTITY = -", signing)
        self.assertIn('#include? "Local.xcconfig"', signing)
        ignored = subprocess.run(["git", "check-ignore", "-q", "Config/Local.xcconfig"], cwd=ROOT)
        self.assertEqual(0, ignored.returncode, "Config/Local.xcconfig must never be committed")

    def test_release_is_not_debuggable(self):
        """Apple Development signing injects get-task-allow; Release must not carry it."""
        project = PROJECT.read_text()
        release = [c for c in app_target_configs(project) if "PRODUCT_BUNDLE_IDENTIFIER = io.github.amidamaru940.luoto;" in c]

        self.assertEqual(1, len(release))
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;", release[0])
        # Coverage counters name every source file (with its full path) and slow the app down.
        self.assertIn("ENABLE_CODE_COVERAGE = NO;", release[0])
        self.assertIn("CLANG_COVERAGE_MAPPING = NO;", release[0])
        self.assertNotIn("Developer ID Application", project)

    def test_updates_stay_off_until_the_person_agrees(self):
        info = plistlib.loads(INFO_PLIST.read_bytes())

        self.assertEqual(info["SUFeedURL"], "https://github.com/amidamaru940/luoto/releases/latest/download/appcast.xml")
        self.assertIs(info["SUEnableAutomaticChecks"], False)
        self.assertIs(info["SUAutomaticallyUpdate"], False)
        self.assertIs(info["SUAllowsAutomaticUpdates"], False)
        self.assertIs(info["SUEnableSystemProfiling"], False)
        self.assertEqual(info["SUScheduledCheckInterval"], 86400)
        self.assertEqual(len(info["SUPublicEDKey"]), 44, "the update key is what makes updates safe")
        for key in ("SUEnableDownloaderService", "SUEnableInstallerLauncherService"):
            self.assertNotIn(key, info)

    def test_usage_descriptions_do_not_say_atoll(self):
        project = PROJECT.read_text()
        info = plistlib.loads(INFO_PLIST.read_bytes())

        for line in re.findall(r"INFOPLIST_KEY_NS\w+UsageDescription = .*", project):
            self.assertNotIn("Atoll", line)
        for key, value in info.items():
            if key.endswith("UsageDescription"):
                self.assertNotIn("Atoll", value, key)

    def test_camera_entitlement_removed(self):
        entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())

        self.assertNotIn("com.apple.security.device.camera", entitlements)
        # Hardened Runtime "Resource Access: Camera" would add the entitlement back at signing time.
        project = PROJECT.read_text()
        self.assertEqual(2, project.count("ENABLE_RESOURCE_ACCESS_CAMERA = NO;"))
        self.assertNotIn("ENABLE_RESOURCE_ACCESS_CAMERA = YES;", project)

    def test_notice_records_the_fork(self):
        notice = NOTICE.read_text()

        self.assertIn("Atoll (DynamicIsland) - NOTICE", notice)
        self.assertIn("Luoto is a fork of Atoll (Ebullioscopic/Atoll", notice)
        self.assertIn(BASE_COMMIT, notice)
        self.assertIn("modified in 2026", notice)
        self.assertIn("GNU\nGeneral Public License v3.0", notice)
        self.assertIn("not\naffiliated with", notice)

    def test_test_files_are_not_git_ignored(self):
        """The upstream .gitignore ignores *.py and *.txt; every file in tests/ must be exempt."""
        files = [str(path.relative_to(ROOT)) for path in sorted((ROOT / "tests").iterdir())
                 if path.is_file() and not path.name.startswith(".")]
        # The project's own scripts and config too (the upstream rules ignore *.sh as well).
        files += ["scripts/make-release.sh", "scripts/make_luoto_icon.swift", "Config/Signing.xcconfig",
                  "THIRD-PARTY-LICENSES.md",
                  "DynamicIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
        result = subprocess.run(["git", "check-ignore", *files], cwd=ROOT, capture_output=True, text=True)

        self.assertEqual("", result.stdout.strip(), "ignored by git; add a !rule to .gitignore")


    def test_each_setting_lives_on_one_page(self):
        # The audit found the same switch on two to four pages (lock screen
        # widgets on Media, Timer and Calendar too; the display style on
        # General and Appearance). Each now has one place, and the other pages
        # point there. The HUD has one copy per HUD style, and only the chosen
        # style's settings are on screen.
        settings = ROOT / "DynamicIsland" / "components" / "Settings"
        one_per_hud_style = {"useColorCodedVolumeDisplay", "useSmoothColorGradient"}
        counts = {}
        for path in sorted(settings.glob("*.swift")):
            for key in re.findall(r"Defaults\.Toggle\(key: \.(\w+)\)", path.read_text(encoding="utf-8")):
                counts[key] = counts.get(key, 0) + 1
        repeated = sorted(key for key, count in counts.items() if count > 1 and key not in one_per_hud_style)
        self.assertEqual(repeated, [])

        view = (settings / "SettingsView.swift").read_text(encoding="utf-8")
        self.assertEqual(view.count("selection: $externalDisplayStyle"), 1, "one display style picker")
        self.assertNotIn("Lock Screen Integration", view, "the copied lock screen sections are gone")

        # Different settings under one title («Temperature unit» for the
        # weather and the CPU, «Cursor» for an AI editor and a colour).
        titles = {}
        for path in sorted(settings.glob("*.swift")):
            source = path.read_text(encoding="utf-8")
            found = re.findall(r'(?:Toggle|Picker|SettingsSegmentedPicker|ColorPicker)\(\s*"([^"]+)"', source)
            found += re.findall(r'Defaults\.Toggle\(key: \.\w+\) \{\s*Text\("([^"]+)"\)', source)
            for title in found:
                titles[title] = titles.get(title, 0) + 1
        hud_styles = {"Volume HUD", "Brightness HUD", "Keyboard Backlight HUD", "Show Percentage", "Use Accent Color",
                      "Material", "Glass mode", "Color-coded Volume", "Smooth color transitions"}
        shared = sorted(title for title, count in titles.items() if count > 1 and title not in hud_styles)
        self.assertEqual(shared, [])

    def test_every_release_gets_a_higher_build_number(self):
        script = (ROOT / "scripts" / "make-release.sh").read_text()
        self.assertIn("BUILD_NUMBER=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))", script)
        self.assertIn('CURRENT_PROJECT_VERSION="$BUILD_NUMBER"', script)
        major, minor, patch = (int(part) for part in (ROOT / "VERSION").read_text().strip().split("."))
        numbers = set(re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", PROJECT.read_text()))
        self.assertEqual(numbers, {str(major * 10000 + minor * 100 + patch)})

    def test_release_script_builds_ad_hoc_and_offline_friendly(self):
        # No paid Apple account: the app is signed with the project's own
        # certificate, or ad-hoc without it, whatever team this Mac uses, and
        # nothing in the script talks to Apple.
        script = (ROOT / "scripts" / "make-release.sh").read_text()
        self.assertIn("CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=", script)
        self.assertIn('EXPECTED_SIGNATURE="Signature=adhoc"', script)
        self.assertIn('EXPECTED_SIGNATURE="Authority=$IDENTITY_NAME"', script)
        self.assertIn("LUOTO_RELEASE: the certificate", script)
        self.assertIn("LUOTO_RELEASE: the EdDSA key", script)
        self.assertIn("LUOTO_RELEASE: test settings are not for a real release", script)
        self.assertIn("--timestamp=none", script)
        self.assertIn("hdiutil create", script)
        for tool in ("notarytool", "altool", "curl ", "wget "):
            self.assertNotIn(tool, script)
        self.assertIn('shasum -a 256 "${DMG:t}"', script, "the published checksum names the file, not a local path")
        self.assertIn('-file-prefix-map \\"$HOME=~\\"', script, "source paths in the binary must not name the builder's home")
        self.assertIn('-file-prefix-map \\"$ROOT_ABS=.\\"', script, "quoted, or xcodebuild splits a path with a space")
        self.assertIn('grep -rlaF "$HOME/" "$APP"', script)
        self.assertIn("STRIP_STYLE=debugging", script, "the debug map names the build folder")
        self.assertIn("ENABLE_CODE_COVERAGE=NO", script)

    def test_the_version_is_the_same_everywhere(self):
        # make-release.sh names the DMG after VERSION; the app reports the
        # project's MARKETING_VERSION; the changelog's top entry is the release.
        version = (ROOT / "VERSION").read_text().strip()
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        project = (ROOT / "DynamicIsland.xcodeproj" / "project.pbxproj").read_text()
        self.assertEqual(set(re.findall(r"MARKETING_VERSION = ([^;]+);", project)), {version})
        changelog = (ROOT / "CHANGELOG.md").read_text()
        self.assertEqual(re.search(r"^## \[([^\]]+)\]", changelog, re.M).group(1), version)


    def test_sources_do_not_compile_their_paths_into_the_app(self):
        # In Swift 5 mode #file is the full source path, and every use puts
        # the builder's home folder into the released binary; #fileID does not.
        offenders = []
        for path in sorted((ROOT / "DynamicIsland").rglob("*.swift")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                code = line.split("//", 1)[0]
                if re.search(r"#file(?!ID)\b|#filePath", code):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(offenders, [])

    def test_every_resolved_package_has_a_licence_row(self):
        # A new package must not ship without its licence being read. The row
        # names the pinned revision, so an update means looking at it again.
        section = THIRD_PARTY.read_text(encoding="utf-8").split("## Swift packages", 1)[1].split("\n## ", 1)[0]
        rows = {}
        for line in section.splitlines():
            if line.startswith("|") and not line.startswith("|---"):
                rows[line.split("|")[1].strip().lower()] = line
        rows.pop("name")

        pins = {pin["identity"]: pin["state"]["revision"] for pin in json.loads(RESOLVED.read_text())["pins"]}
        self.assertEqual(sorted(rows), sorted(pins), "THIRD-PARTY-LICENSES.md and Package.resolved list different packages")
        for identity, revision in pins.items():
            self.assertIn(revision[:7], rows[identity], f"{identity} moved: read its licence again")

    def test_release_ships_the_licences(self):
        script = (ROOT / "scripts" / "make-release.sh").read_text()
        self.assertIn('cp LICENSE "$STAGE/LICENSE.txt"', script)
        self.assertIn('cp NOTICE "$STAGE/NOTICE.txt"', script)
        self.assertIn('cp THIRD-PARTY-LICENSES.md "$STAGE/THIRD-PARTY-LICENSES.txt"', script)

    def test_nothing_without_a_known_source_ships(self):
        licences = (ROOT / "THIRD-PARTY-LICENSES.md").read_text()
        self.assertNotIn("no licence on record", licences.lower())
        self.assertNotIn("cannot confirm", licences.lower())
        app = ROOT / "DynamicIsland"
        kinds = ("*.mov", "*.mp4", "*.m4v", "*.gif", "*.mp3", "*.m4a", "*.aac", "*.wav", "*.aiff", "*.caf", "*.ogg", "*.flac")
        kinds += ("*.png", "*.jpg", "*.jpeg", "*.svg", "*.pdf", "*.lottie")
        media = [p for pattern in kinds for p in app.rglob(pattern) if "Assets.xcassets" not in p.parts]
        self.assertEqual(media, [], "a media file needs a row in THIRD-PARTY-LICENSES.md and a known source")
        self.assertEqual([p.name for p in (ROOT / "LottieAnimations").glob("*.json")], ["FingerprintScan.json"])
        data = sorted(p.name for p in app.rglob("*.json") if p.name != "Contents.json")
        self.assertEqual(data, ["pricing.json"], "a bundled animation needs a row in THIRD-PARTY-LICENSES.md")
        catalog = sorted(p.stem for p in (app / "Assets.xcassets").glob("*.imageset"))
        self.assertEqual(catalog, sorted([
            "AmazonMusicLogo", "CiderLogo", "LocalSend", "logo2", "TidalLogo", "YouTubeMusicLogo",
        ]), "a new picture needs a row in THIRD-PARTY-LICENSES.md")

    def test_the_idle_animation_stays_hidden_until_it_has_free_assets(self):
        app = ROOT / "DynamicIsland"
        view = (app / "components" / "IdleAnimationView.swift").read_text()
        self.assertIn("static let isAvailable = false", view)
        content = (app / "ContentView.swift").read_text()
        self.assertIn("IdleAnimationFeature.isAvailable && Defaults[.showNotHumanFace]", content)
        self.assertEqual(content.count("Defaults[.showNotHumanFace]"), 1)
        settings = (app / "components" / "Settings" / "SettingsView.swift").read_text()
        self.assertNotIn('title: "Idle Animation"', settings)
        self.assertGreaterEqual(settings.count("IdleAnimationFeature.isAvailable"), 2)
        launch = (app / "DynamicIslandApp.swift").read_text()
        self.assertIn("IdleAnimationFeature.isAvailable", launch)

    def test_the_old_name_stays_out_of_the_public_files(self):
        old = "am" + "g"
        pattern = re.compile(rf"(?<![a-z]){old}(?![a-z])|{old}island|mer" + "cedes|sk" + "erry", re.IGNORECASE)
        private = ("docs/", ".claude/", "REPORT.md", "CHANGES.md", "README_RU.md")
        listed = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True).stdout
        found = []
        for name in filter(None, listed.split("\0")):
            path = ROOT / name
            if name.startswith(private) or not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            found += [f"{name}: {match.group()}" for match in pattern.finditer(text)]
        self.assertEqual(found, [])

    def test_the_public_files_hold_no_project_notes(self):
        # Comments give the reason. Who asked, when, on which machine and in
        # which private document stay out of what is exported.
        person = "own" + "er"
        # In code the word is an argument: a label, or the object an association hangs on.
        about_the_person = re.compile(rf"(?<!AssociatedObject)\({person}\b(?!:| \w+:)|{person}.s Mac", re.IGNORECASE)
        cyrillic = re.compile("[Ѐ-ӿ]")
        private_folder = "do" + "cs/"
        private_document = re.compile(rf"(?<![\w/.-]){private_folder}[A-Za-z][\w./-]*")
        measurements = private_folder + "perf/"
        found = []
        for name, text in public_text_files():
            for number, line in enumerate(text.splitlines(), 1):
                if about_the_person.search(line):
                    found.append(f"{name}:{number}: {line.strip()}")
                if name == ".gitignore":
                    continue
                for match in private_document.finditer(line):
                    kept = name.startswith("scripts/perf/") and match.group().startswith(measurements)
                    if not kept or "REPORT" in match.group():
                        found.append(f"{name}:{number}: {match.group()}")
            if name.endswith(".swift"):
                found += [f"{name}: {comment}" for comment in swift_comments(text) if cyrillic.search(comment)]
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
