"""Compile the actual CLI entry point with inert backends and bounded child processes."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


# The entry point also references GUI and recording paths. These types satisfy
# compilation without loading models, reading saved defaults, or touching audio.
STUBS = r"""
import AppKit

enum HarnessError: Error, LocalizedError {
    case requested
    var errorDescription: String? { "stub failure" }
}
struct AppIdentity {
    static let current = AppIdentity()
    static let localID = "test.localflow.local"
    static let productionID = "test.localflow"
    var isLocal: Bool { true }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() { fatalError("GUI launch is unavailable in this harness") }
}
actor PersonalVoiceStore {
    static let shared = PersonalVoiceStore()
    func importDiagnostics() async throws -> Int { 0 }
}
enum DictationReplay {
    @MainActor static func run(arguments: [String]) async throws {}
}
enum Settings {
    static let effectiveVocabulary = [String]()
    static let whisperModel = "stub-whisper"
    static let corrections = [String: String]()
    static var cleanupEnabled: Bool { ProcessInfo.processInfo.environment["HARNESS_CASE"] != "disabled" }
    static let ollamaModel = "stub-cleanup"
    static let inputDeviceUID: String? = nil
    static let keepMicWarm = false
}
actor Transcriber {
    func setVocabulary(_ vocabulary: [String]) {}
    func load(model: String) async throws {
        try await Task.sleep(for: .milliseconds(10))
        if ProcessInfo.processInfo.environment["HARNESS_CASE"] == "load-failure" { throw HarnessError.requested }
    }
    func transcribe(file: String) async throws -> String {
        if ProcessInfo.processInfo.environment["HARNESS_CASE"] == "transcribe-failure" { throw HarnessError.requested }
        return "raw transcript"
    }
}
enum TranscriptCorrections {
    static func apply(_ text: String, corrections: [String: String]) -> String { text }
}
enum VoiceFormatter {
    static func apply(_ text: String) -> String { text }
}
enum AppStyleProfile { case general }
struct TranscriptCleanupResult { let text: String; let succeeded: Bool }
@MainActor final class LocalTextModelPolicy {
    static let shared = LocalTextModelPolicy()
    func cleanup(_ text: String, model: String, profile: AppStyleProfile) async throws -> TranscriptCleanupResult {
        precondition(Thread.isMainThread)
        await Task.yield()
        if ProcessInfo.processInfo.environment["HARNESS_CASE"] == "raw-fallback" {
            return TranscriptCleanupResult(text: text, succeeded: false)
        }
        return TranscriptCleanupResult(text: "Cleaned transcript.", succeeded: true)
    }
}
struct Recording { let samples: [Float] }
final class AudioRecorder {
    static let sampleRate = 16_000.0
    var deviceUID: String?
    var keepWarm = false
    func start(_ completion: @escaping (Error?) -> Void) { completion(HarnessError.requested) }
    func stop(_ completion: @escaping (Recording) -> Void) { completion(Recording(samples: [])) }
}
"""


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"),
                     "Requires macOS and the Swift compiler")
class TranscribeCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="localflow-cli-tests.")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        root = Path(__file__).resolve().parents[1]
        source = root / "Sources/LocalFlow/LocalFlowMain.swift"
        stubs = cls.directory / "Stubs.swift"
        stubs.write_text(STUBS)
        cls.binary = cls.compile(source, stubs, "current")

    @classmethod
    def compile(cls, source, stubs, name):
        binary = cls.directory / name
        result = subprocess.run(
            ["swiftc", "-parse-as-library", str(source), str(stubs), "-o", str(binary)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode:
            raise AssertionError(result.stderr)
        return binary

    def run_cli(self, scenario, *arguments):
        environment = dict(os.environ, HARNESS_CASE=scenario)
        return subprocess.run(
            [str(self.binary), "--transcribe", "unused.wav", *arguments],
            env=environment, capture_output=True, text=True, timeout=5,
        )

    def test_successful_modes_preserve_text_timings_and_exit_status(self):
        cases = [
            ("cleanup", [], "Cleaned transcript.\n", "complete"),
            ("no-cleanup", ["--no-cleanup"], "raw transcript\n", None),
            ("disabled", [], "raw transcript\n", None),
            ("raw-fallback", [], "raw transcript\n", "raw fallback"),
        ]
        for scenario, arguments, output, cleanup in cases:
            with self.subTest(scenario=scenario):
                result = self.run_cli(scenario, *arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, output)
                self.assertRegex(result.stderr, r"model load: \d+ms \(stub-whisper\)")
                self.assertRegex(result.stderr, r"transcribe: \d+ms")
                if cleanup:
                    self.assertIn("local cleanup:", result.stderr)
                    self.assertIn(cleanup, result.stderr)
                else:
                    self.assertNotIn("local cleanup:", result.stderr)
                self.assertNotIn("error:", result.stderr)

    def test_failures_write_stderr_and_exit_one(self):
        for scenario in ("load-failure", "transcribe-failure"):
            with self.subTest(scenario=scenario):
                result = self.run_cli(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("error: stub failure\n", result.stderr)
                self.assertNotIn("local cleanup:", result.stderr)



if __name__ == "__main__":
    unittest.main()
