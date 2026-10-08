"""Exercise app-name compatibility and idle checks without touching installed apps."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class LocalAppIdleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = (Path(__file__).resolve().parents[1] / "scripts/local-app.sh").read_text()
        cls.script = script
        source = script.split("python3 - <<'PY_CHECK_IDLE'\n", 1)[1].split("\nPY_CHECK_IDLE", 1)[0]
        cls.code = compile(source, "local-app-idle-preflight", "exec")

    @staticmethod
    def event(name, status=None):
        value = {"source": "dictation", "traceID": "fixture", "name": name}
        if status:
            value["status"] = status
        return "time timing " + json.dumps(value)

    def check(self, events, prefix="", running=True):
        log = prefix + "time === LocalFlow session start (pid 123) ===\n" + "\n".join(events)
        process = SimpleNamespace(returncode=0 if running else 1, stdout="123\n")
        with patch("subprocess.run", return_value=process), patch("pathlib.Path.read_text", return_value=log):
            exec(self.code, {})

    def test_recording_and_processing_prevent_restart(self):
        for events in ([self.event("hotkeyPressed")],
                       [self.event("hotkeyPressed"), self.event("hotkeyReleased"), self.event("resultReady", "success")]):
            with self.subTest(events=events), self.assertRaises(SystemExit):
                self.check(events)

    def test_paste_waits_for_clipboard_resolution(self):
        events = [self.event("hotkeyPressed"), self.event("pasteDispatched", "success")]
        with self.assertRaises(SystemExit):
            self.check(events)
        self.check(events + [self.event("clipboardWindowResolved", "changedClipboard")])

    def test_empty_failed_and_silent_results_allow_restart(self):
        for status in ("empty", "failed", "insufficientVoice", "cancelled"):
            with self.subTest(status=status):
                self.check([self.event("hotkeyPressed"), self.event("resultReady", status)])

    def test_cancelled_skipped_and_typed_results_allow_restart(self):
        for name in ("cancellationRequested", "injectionSkipped", "typingDispatched"):
            with self.subTest(name=name):
                self.check([self.event("hotkeyPressed"), self.event(name)])

    def test_stale_previous_launch_does_not_block_restart(self):
        old = "time === LocalFlow session start (pid 99) ===\n" + self.event("hotkeyPressed") + "\n"
        self.check([], prefix=old)

    def test_stopped_app_does_not_require_a_log(self):
        self.check([], running=False)

    def test_each_current_and_legacy_app_name_blocks_restart_while_recording(self):
        for name in ("Flo", "Walkie", "LocalFlow", "Flo Local", "Walkie Local", "LocalFlow Local"):
            with self.subTest(name=name):
                def running_app(arguments, **kwargs):
                    pattern = arguments[-1]
                    return SimpleNamespace(returncode=0 if f"/{name}\\.app/" in pattern else 1,
                                           stdout="123\n")

                log = "time === LocalFlow session start (pid 123) ===\n" + self.event("hotkeyPressed")
                with patch("subprocess.run", side_effect=running_app), \
                     patch("pathlib.Path.read_text", return_value=log), \
                     self.assertRaisesRegex(SystemExit, f"{name} has an active dictation"):
                    exec(self.code, {})

    def test_channel_switch_prefers_current_name_and_accepts_legacy_installs(self):
        source = self.script.split('LOCAL_APP=', 1)[1].split('# Older installed builds', 1)[0]
        source = 'LOCAL_APP=' + source
        cases = [
            ("local", ["Flo Local", "Walkie Local", "LocalFlow Local"], "Flo Local"),
            ("local", ["Walkie Local", "LocalFlow Local"], "Walkie Local"),
            ("local", ["LocalFlow Local"], "LocalFlow Local"),
            ("production", ["Flo", "Walkie", "LocalFlow"], "Flo"),
            ("production", ["Walkie", "LocalFlow"], "Walkie"),
            ("production", ["LocalFlow"], "LocalFlow"),
        ]
        for action, installed, expected in cases:
            with self.subTest(action=action, installed=installed), tempfile.TemporaryDirectory() as directory:
                for name in installed:
                    (Path(directory) / f"{name}.app").mkdir()
                fixture = source.replace('/Applications/', directory + '/')
                result = subprocess.run(
                    ["bash", "-c", f"set -eu\nACTION={action}\n" + fixture + '\nprintf "%s" "$TARGET_APP"'],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, str(Path(directory) / f"{expected}.app"))

    def test_production_installer_stops_current_and_legacy_production_processes(self):
        script = (Path(__file__).resolve().parents[1] / "scripts/make-app.sh").read_text()
        start = script.index('    # Belt for instances')
        source = script[start:script.index('    rm -rf', start)]
        stubs = """
pkill() { printf 'pattern=%s\\n' "${!#}"; }
pgrep() { printf 'pattern=%s\\n' "${!#}" >&2; return 1; }
"""
        result = subprocess.run(["bash", "-c", "set -eu\n" + stubs + source],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        patterns = [line.removeprefix("pattern=") for line in (result.stdout + result.stderr).splitlines()]
        self.assertEqual(len(patterns), 3)
        for pattern in patterns:
            for name in ("Flo", "Walkie", "LocalFlow"):
                self.assertRegex(f"/Applications/{name}.app/Contents/MacOS/LocalFlow", pattern)
            for name in ("Flo Local", "Walkie Local", "LocalFlow Local", "Other"):
                self.assertIsNone(re.search(pattern, f"/Applications/{name}.app/Contents/MacOS/LocalFlow"))


if __name__ == "__main__":
    unittest.main()
