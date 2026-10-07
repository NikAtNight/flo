# Development

## Build

Requires macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
./scripts/make-app.sh            # release build, packaged as build/Walkie.app
open build/Walkie.app
./scripts/make-dmg.sh            # wrap the built app in dist/Walkie-<version>.dmg
```

`make-app.sh` signs with the stable `Talix Dev Signing` identity when it's
present, otherwise with a pinned ad-hoc requirement. `swift run` works for quick
iteration, but then Microphone and Accessibility attach to your terminal app
instead of Walkie. Use the app bundle for real testing.

If the hotkey stops working after a rebuild, macOS is holding a stale
Accessibility grant. Remove Walkie in System Settings > Accessibility and
add the new build back (or toggle it off and on).

## Local test channel

`scripts/local-app.sh` installs a second copy next to production so you can
test without touching the release build:

```bash
./scripts/local-app.sh install     # build, install Walkie Local, wait until the model is ready
./scripts/local-app.sh production  # quit local and open production
./scripts/local-app.sh local       # switch back without rebuilding
```

- Production stays at `/Applications/Walkie.app`. The local copy is
  `/Applications/Walkie Local.app` with bundle ID `app.talix.localflow.local`.
  Grant it Microphone and Accessibility on first launch.
- Run one app at a time. The switch commands quit both before opening the
  target, and refuse to switch while a dictation is active.
- The local copy builds from the working tree, uncommitted changes included.
  It has no auto-update and no login item. The previous local bundle is kept in
  a hidden `/Applications/.localflow-local.*` directory.
- Settings are copied from production on first install, then drift apart.
  History, diagnostics, and the personal voice archive live under
  `~/Library/Application Support/LocalFlow Local/`. Downloaded models and Ollama
  are shared.
- `install` waits up to 330 seconds for Core ML to prepare the model and prints
  the load time. If preparation fails or times out, it exits non-zero and
  leaves the app open so you can look.

## Diagnostics

Settings > Diagnostics shows retained dictation and model-load timings, with
an event timeline per entry. It reads structured metrics only, never
transcripts or raw log lines. **Export diagnostics** writes a text report with
the same scope. Production keeps 30 days of traces in
`~/Library/Application Support/LocalFlow/Diagnostics`. Local builds keep them
indefinitely. The debug log at `~/Library/Logs/LocalFlow-diag.log` rotates at
5 MB on launch.

For missing-word investigations, turn on **Settings > History > Save audio and
transcript stages for diagnostics**. It keeps audio and every transcript stage
for 7 days, capped at 1 GB. See
[diagnostic recording and replay](flows/diagnostic-recordings.md).

## Benchmarking

`--replay` feeds a recording through the real session pipeline (incremental
transcription, formatting, snippets, cleanup) without the mic, paste, or
history:

```bash
build/Walkie.app/Contents/MacOS/LocalFlow --replay /path/to/test.wav --runs 5 --no-cleanup
build/Walkie.app/Contents/MacOS/LocalFlow --replay /path/to/test.wav --runs 5 --cleanup
```

Text goes to stdout, timing events to stderr. `--transcribe <file>` does a
single full-file pass with coarse timings. Record hardware, build, model, and
warm state with every run. See [measuring dictation latency](dictation-timings.md)
for the protocol.

## Tests

```bash
swift test
bash Tests/ReleaseContractTests.sh
python3 Tests/LocalAppIdleTests.py
python3 Tests/TranscribeCLITests.py
python3 -B Tests/StartupReadinessTests.py   # no mic or model download needed
```

CI runs all of these except the startup readiness check.

## CodeQL scans

[The CodeQL workflow](../.github/workflows/codeql.yml) scans main pushes,
pull requests targeting main, and the weekly schedule. A newer run cancels
an older run for the same Git ref, so separate PRs do not cancel each other.

SwiftPM resolves packages and builds the WhisperKit and FluidAudio dependency
targets before CodeQL tracing starts. Sparkle arrives as a binary dependency.
The workflow saves the dependency cache at this point, before compiling
LocalFlow. This lets a restored cache reuse dependencies while all app sources
still compile between CodeQL initialization and analysis, even on an unchanged
rerun. Keep the dependency target list in sync with `Package.swift`.

Cache keys include the OS, architecture, macOS version, Xcode and Swift versions,
and the package manifest and lockfile. A dependency update may restore an older cache for
the same toolchain; SwiftPM then resolves and rebuilds what changed. Toolchain
changes start a fresh cache. The separate `codeql-deps-v1` namespace excludes
older caches containing compiled app code. Do not move the save step after the
app build or replace it with an action that saves at job completion.

With `actionlint` installed, validate workflow edits with
`actionlint .github/workflows/codeql.yml`.
Local SwiftPM checks can verify that the dependency cache excludes app objects,
but runtime savings and extracted-file coverage need a GitHub CodeQL run.
Compare a cold run and an unchanged warm run, including their dependency-build,
app-build, and analysis timings. The workflow maintainer owns that check when
these changes reach GitHub.
