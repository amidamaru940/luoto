"""Promises of the lid-closed feature that the code can be held to without running it."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "DynamicIsland"
HELPER = ROOT / "LidGuard"
MAIN = (HELPER / "main.swift").read_text()
POLICY = (HELPER / "LidGuardPolicy.swift").read_text()
CONTROLLER = (APP / "managers" / "LidAwakeController.swift").read_text()
INSTALLER = (APP / "helpers" / "LidGuardInstaller.swift").read_text()


def code(text):
    return re.sub(r"/\*.*?\*/", "", re.sub(r"//[^\n]*", "", text), flags=re.S)


def app_files_with(needle):
    return sorted(p.relative_to(APP).as_posix() for p in APP.rglob("*.swift")
                  if needle in code(p.read_text(errors="ignore")))


class HelperTests(unittest.TestCase):
    def test_the_helper_has_no_way_to_be_talked_to(self):
        for banned in ("URLSession", "NWConnection", "NWListener", "NSXPC", "xpc_", "socket(", "bind(", "listen(",
                       "CFMessagePort", "DistributedNotificationCenter"):
            self.assertNotIn(banned, code(MAIN) + code(POLICY), banned)

    def test_it_only_runs_pmset_and_launchctl_at_fixed_paths(self):
        self.assertIn('var pmset = "/usr/bin/pmset"', MAIN)
        self.assertIn('var launchctl: String? = "/bin/launchctl"', MAIN)
        arguments = re.findall(r"run\(([^,]+), (\[[^\]]*\])\)", code(MAIN))
        self.assertEqual(sorted(a for a, _ in arguments), ["launchctl", "world.pmset", "world.pmset"])
        self.assertEqual(MAIN.count("posix_spawn("), 1, "one place starts programs")
        self.assertNotIn("posix_spawnp", MAIN)

    def test_children_get_an_empty_environment(self):
        self.assertIn("let environment: [UnsafeMutablePointer<CChar>?] = [nil]", MAIN)

    def test_it_never_opens_anything_in_the_users_folder(self):
        # The session folder belongs to the user: names in it are only looked at
        # with lstat, or removed one by one.
        for line in code(MAIN).splitlines():
            if "sessionDirectory" in line and "world.sessionDirectory =" not in line and "var sessionDirectory" not in line:
                self.assertRegex(line, r'lstat|let path = |exists\(|unlink\(|rmdir\(', line)
        self.assertNotIn("removeItem", code(MAIN), "no recursive delete as root")
        self.assertNotIn("contentsOfDirectory", code(MAIN))
        self.assertIn("lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG", MAIN)

    def test_a_link_is_not_a_lease(self):
        self.assertIsNone(re.search(r"(?<![l.])\bstat\(\w*[pP]ath", code(MAIN)))
        self.assertNotIn("attributesOfItem", code(MAIN))

    def test_the_test_hook_exists_only_in_debug_builds(self):
        before, _, rest = MAIN.partition("#if DEBUG")
        hook, _, after = rest.partition("#endif")
        self.assertIn("--test-root", hook)
        self.assertIn("running from a test root", hook, "what the release script looks for")
        self.assertNotIn("--test-root", before + after)
        self.assertNotIn("fake-pmset", before + after)

    def test_no_flag_without_a_marker_and_no_marker_gone_without_the_flag_off(self):
        apply_body = MAIN.split("private func apply(", 1)[1].split("/// One check.", 1)[0]
        self.assertLess(apply_body.index("createFile(atPath: markerPath"), apply_body.index('"disablesleep"'))
        self.assertLess(apply_body.index("flagIsConfirmedOff("), apply_body.index("unlink(markerPath)"))
        self.assertLess(apply_body.index("guard flagIsOff"), apply_body.index("unlink(markerPath)"))
        self.assertLess(apply_body.index("guard flagIsOff"), apply_body.index('["sleepnow"]'))

    def test_every_deliberate_exit_is_zero(self):
        # launchd brings back any other exit (KeepAlive: SuccessfulExit false).
        self.assertEqual(set(re.findall(r"\bexit\((\d+)\)", code(MAIN))), {"0"})

    def test_it_handles_being_asked_to_stop(self):
        self.assertIn("DispatchSource.makeSignalSource(signal: SIGTERM", MAIN)
        self.assertIn("signal(SIGTERM, SIG_IGN)", MAIN)

    def test_the_helper_is_compiled_for_itself_alone(self):
        project = (ROOT / "DynamicIsland.xcodeproj" / "project.pbxproj").read_text()
        self.assertIn('"com.apple.product-type.tool"', project)
        self.assertRegex(project, r'membershipExceptions = \(\s*main\.swift,\s*\);')


class AppTests(unittest.TestCase):
    def test_the_password_is_asked_in_one_place(self):
        self.assertEqual(app_files_with("with administrator privileges"), ["helpers/LidGuardInstaller.swift"])

    def test_the_password_is_never_asked_under_tests(self):
        for function in ("static func install()", "static func resetSleepFlag()"):
            body = INSTALLER.split(function, 1)[1][:400]
            self.assertIn("AppRuntimeEnvironment.mayAskForPermissions", body, function)

    def test_a_session_alone_never_asks_for_the_password(self):
        # Only a click: the switch, or a button of the row. Starting a session,
        # including from a shortcut, must not put up a dialog.
        session = CONTROLLER.split("func sessionDidStart()", 1)[1].split("func sessionDidEnd()", 1)[0]
        self.assertNotIn("install()", session)
        self.assertEqual(app_files_with("LidGuardInstaller.install()"), ["managers/LidAwakeController.swift"])
        callers = app_files_with("lid.install()")
        self.assertEqual(callers, ["components/Caffeinate/LidAwakeRow.swift"])

    def test_no_sudo_and_no_setting_written_from_the_app(self):
        for path in [*APP.rglob("*.swift"), *HELPER.rglob("*.swift")]:
            text = code(path.read_text(errors="ignore"))
            if path.name == "LidGuardInstaller.swift":
                continue
            self.assertNotRegex(text, r'"\s*sudo\b', path.name)
            if path.parent != HELPER:
                self.assertNotIn("disablesleep", text, path.name)

    def test_the_watch_and_the_lease_exist_only_in_the_controller(self):
        self.assertEqual(app_files_with("IOServiceAddInterestNotification(port, root, kIOGeneralInterest"),
                         ["managers/LidAwakeController.swift"])
        self.assertEqual(app_files_with("LidGuardInstaller.leaseURL"), ["managers/LidAwakeController.swift"])

    def test_nothing_runs_until_a_session_wants_it(self):
        init = CONTROLLER.split("private init()", 1)[1].split("\n", 1)[0]
        self.assertIn("{}", init)
        arm = CONTROLLER.split("private func arm()", 1)[1].split("private func ", 1)[0]
        self.assertIn("startLidWatch()", arm)
        self.assertIn("startHeartbeat()", arm)
        for starter in ("startLidWatch()", "startHeartbeat()"):
            self.assertEqual(code(CONTROLLER).count(starter) - code(arm).count(starter), 1, f"{starter}: only arm() starts it")
        launch = CONTROLLER.split("func appDidLaunch()", 1)[1].split("func appWillTerminate()", 1)[0]
        self.assertNotIn("arm()", launch)

    def test_the_lease_is_renewed_on_the_main_thread(self):
        self.assertIn("DispatchSource.makeTimerSource(queue: .main)", CONTROLLER)
        self.assertNotIn("makeTimerSource(queue: .global", CONTROLLER)

    def test_the_option_starts_off(self):
        constants = (APP / "models" / "Constants.swift").read_text()
        self.assertIn('Key<Bool>("caffeinateWithLidClosed", default: false)', constants)

    def test_the_app_says_close_the_lid_only_after_reading_back(self):
        self.assertIn('bool("SleepDisabled")', CONTROLLER)
        self.assertRegex(CONTROLLER, r"flagOn: PowerRootDomain\.sleepDisabled")


class ReleaseTests(unittest.TestCase):
    def test_the_release_script_checks_the_helper(self):
        script = (ROOT / "scripts" / "make-release.sh").read_text()
        for needle in ("Identifier=io.github.amidamaru940.luoto.lidguard", "running from a test root", "otool -L", "[^)]*runtime",
                       'certificate leaf = H'):
            self.assertIn(needle, script)

    def test_the_texts_describe_the_helper(self):
        for name in ("README.md", "README.ru.md"):
            text = (ROOT / name).read_text()
            self.assertIn("io.github.amidamaru940.luoto.lidguard", text, name)
            self.assertIn("20 %" if name.endswith("ru.md") else "20%", text, name)
        security = (ROOT / "SECURITY.md").read_text()
        for needle in ("lstat", "disablesleep", "Remove Helper"):
            self.assertIn(needle, security)


if __name__ == "__main__":
    unittest.main()
