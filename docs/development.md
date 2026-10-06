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
