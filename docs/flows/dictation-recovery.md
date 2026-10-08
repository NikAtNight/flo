# Dictation recovery

## Requirement and owner

Owner: Flo maintainers. Requested September 9, 2026 after the user confirmed
speaking during a recording whose final recognition result was empty. Recover
empty dictations before discarding audio. Command mode, decoder settings, voice
gates, model selection, and audio persistence are outside this change.

## Behavior and path

`AppDelegate.beginDictationSession` snapshots settings and optional recording
retention into `DictationDelivery.Configuration`. `DictationDelivery` allocates
the dictation generation and owns its pipeline session. At release, AppDelegate
passes the recorder's paired audio result to `DictationDelivery.release`.

`DictationSessionPipeline.release` retains original audio before applying
`DictationAudioPreparation`. Captures with less than 0.3 seconds of detected
voice produce `insufficientVoice` without recognition or retry. That outcome
returns immediately even while an earlier dictation is waiting. The UI reports
heard-nothing, and archives keep the existing cancelled status. Command mode and
CLI replay use the same preparation rules; replay rejects silence before model
loading. Voiced time uses the existing analysis windows, not total clip duration.

The pipeline retries an empty full result once when the supplied audio has at
least 0.3 seconds of detected voice. Chunk/tail fallback consumes the same recovery
attempt. Requests contain prepared samples and the low-energy decision, so live
and replay callers do not repeat trimming or energy checks. Recovered text goes
through formatting and cleanup once. A second empty result emits `emptyTranscript`;
a thrown error emits `failed`. An unchanged decode can return empty again.

`DictationDelivery` correlates pipeline generations with mixed-mode injection
sequences. Success records transcript history and recent text before dispatch.
Empty and failed results skip injection and retain the latest three originals
in memory. `retryFailedDictations` drains them oldest first through the same
pipeline with current settings. Failed manual attempts are retained again;
manual retries never create personal voice clips. Quitting loses retry audio.
Optional [diagnostic recordings](diagnostic-recordings.md) keep independent disk
copies and do not restore the retry queue.

## Near-silent recording latency

On September 13, 2026, the user reported slow results after release, especially
when holding the trigger without speaking. The local timing log showed two
near-silent captures taking 3.54 and 5.66 seconds, each with two Whisper calls.
Microphone handoff took milliseconds. Separately, one spoken dictation spent
1.31 seconds in recognition and 2.72 seconds in Ollama cleanup. Across that day's
95 completed sessions, median release-to-result time was 1.29 seconds.

Low-energy sample decoding now uses temperature zero without WhisperKit's five
temperature fallback attempts. Normal-energy decoding keeps its previous options.
An unexplained empty result still gets the pipeline's existing full-audio retry.
A canonical hallucination already filtered from low-energy audio instead returns
`TranscriberError.noSpeech`, which completes full dictation or command handling
as heard-nothing without another full attempt. Chunk/tail failures still allow
full-recording recovery so a partial decision cannot reject the entire utterance.

After a committed speech chunk, only an empty or all-zero tail skips recognition.
Nonzero quiet tails remain eligible even when their energy falls below the
full-recording admission threshold. This protects softly spoken final words.
Original recordings remain retained before these decisions. Replay reports
runtime no-speech outcomes per run, while its initial energy gate still rejects
unadmitted input before loading the model.

Verification used base `082025a` plus the latency fix on macOS 26.6.2, arm64,
Swift 6.3.3. Diff evidence: `/tmp/localflow-silence-fix.diff`.

- PASS: `swift test -c release --disable-automatic-resolution`, 293 tests.
  Evidence: `/tmp/localflow-silence-release-tests.log`.
- PASS: `DictationAudioPreparationTests` covers digital silence after committed
  speech, nonzero final words below -50 dBFS, filtered non-speech without retry
  or cleanup, and the existing quiet-empty recovery path. The new silent-tail
  test failed on the old behavior in `/tmp/localflow-silence-tail-red.log`.
- PASS: independent read-only review and follow-up review of the quiet-tail fix,
  cancellation, gate release, command handling, and diagnostic outcomes.
- PASS: two saved ambient candidates replayed through the cached 626 MB Whisper
  model improved from 4.27-5.00 seconds and 4.44 seconds to 1.36-1.39 seconds.
  They still used two pipeline calls, each with no temperature fallback.
  One baseline run of the second candidate produced variable text instead.
- PASS: a quiet speech candidate reproduced its 62-character baseline exactly
  in both runs, at 0.86-0.90 seconds. A separate recording known to need recovery
  still produced text after an initially empty result.
- LIMIT: another ambiguous low-energy clip changed from variable short outputs
  to empty. Its archived output matched the vocabulary prompt prefix, but it
  has no human-verified transcript. These checks do not prove accuracy for all
  quiet speech. Reducing temperature fallback is an accuracy/latency tradeoff.
- Replay evidence is private under `/tmp/localflow-silence-baseline-<traceID>`
  and `/tmp/localflow-silence-candidate-<traceID>`, with `.out` and `.log` suffixes.
  Each command used the app bundle's `--replay <original.wav> --runs 2
  --no-cleanup --whisper-model openai_whisper-large-v3-v20240930_626MB`.

The fixed energy floor can still admit background noise and prevent incremental
pause detection. This change does not add a speech classifier or change those
thresholds. Cleanup remains enabled and can add variable latency. Live microphone
behavior and human-verified quiet-speech accuracy still need user validation.

The pipeline and injection coordinator retain their distinct stall rules.
Injection-side cancellation removes the correlated dictation and cancels its
pipeline work; late outcomes cannot write history, refill retry audio, or inject
text. Pipeline timeout remains a recoverable failure. Commands share injection
ordering and their completion is accepted once.

Delivery remains busy until the text injector's completion callback, including
clipboard restoration. AppDelegate also refuses Quit during recording and queued
audio handoff. A dispatch callback alone does not make delivery idle and does
not establish visible insertion in the target app.

## Architecture implementation verification

The user requested implementation of all four architecture-review candidates on
September 10, 2026. Owner: Flo maintainers. Base: `4f4526a`, with uncommitted
changes. This refactor preserves recognition settings, retry limits, ordering,
retention policies, login/update policy, and microphone implementation.

- `DictationDeliveryTests` covers delayed delivery completion, duplicate callbacks,
  bounded FIFO retry with current corrections, failed manual retry, immediate
  silence rejection, both stall paths, and late results after cancellation.
- `DictationAudioPreparationTests` exercises admission and low-energy decisions,
  exact original retention, prepared retry audio, incremental requests, and an
  empty tail through the pipeline's transcription interface.
- `AudioCaptureLifecycleTests` exercises queued samples and native audio through
  the recorder's real start/stop path using a synthetic input adapter.
- Settings routing checks cover window/menu effects, no-op suppression, rollback,
  login failure/retry, and correction identity. See [settings](settings.md).

Verified on macOS 26.6.2, arm64, Apple Swift 6.3.3:

- PASS: `swift test --disable-automatic-resolution --filter
  'DictationDeliveryTests|DictationAudioPreparationTests|AudioCaptureLifecycleTests|DictationSession|DictationDiagnosticPipelineTests|DictationTraceTests|SettingsApplication|RemainingSettings|SettingsModelCorrection|UpdateController|AppTerminationTests'`,
  70 tests before the additional runtime-error capture test.
- PASS: `swift test -c release --disable-automatic-resolution`, 282 tests with
  zero failures, including the added runtime-error recovery/stale-input test.
  This command also built the changed application in release mode.
- PASS: `python3 -B Tests/LocalAppIdleTests.py`, six tests;
  `python3 -B Tests/StartupReadinessTests.py`, four tests; `git diff --check`.
- PASS: fresh independent source review found no blocking regression. Its
  runtime-error test gap was covered by the added capture test and release run.
- NOT RUN: live microphone capture, actual model inference, target-app insertion,
  installed settings interactions, packaging, or installation. Tests use
  synthetic input and isolated recording folders. No commit or push was made.

Logs are `localflow-architecture-implementation-focused.log` and
`localflow-architecture-release-tests.log` in the OS temporary directory.
The final source and documentation diff is
`/tmp/localflow-architecture-implementation-20260910.diff`.
Two existing compiler warnings remain in StartupModelSequenceTests and
InjectionCoordinatorTests.

The domain names are recorded in [CONTEXT.md](../../CONTEXT.md). Audio admission
uses trimmed analysis windows; empty-result retry and tail fallback retain their
original-window rules. A regression test covers the half-frame alignment case.

## Review fixes, September 30, 2026

Owner: Flo maintainers. The user requested fixes for six reproduced
review findings on base `a353f358d5c540c66575f7193dedd1176dec78d9`.

Each released dictation starts its own 90-second processing deadline. It does
not need a completed follower to time out, and recording time is excluded.
Timeout emits a recoverable failure, retains original retry audio, and removes
the delivery busy state. Commands have independent 90-second deadlines from
processing start. Late results cannot inject text, record history, or restore
retry entries. Metadata traces can still report when cancelled work returns.

`TranscriptionGate` removes cancelled waiters without releasing the active
engine's permit. If active inference ignores cancellation, Transcriber isolates
its engine and keeps its original gate held until inference actually returns.
Manual Retry loads a fresh engine before draining retained recordings, using
the existing model-load deadline. Reload failure preserves the recordings.
At most two abandoned engine generations may remain outstanding; further reload
attempts report a retry-later error until one returns. A normal model switch
continues to serve queued requests through the replacement engine and gate.

Command selection reads Accessibility selected text, removing the competing
clipboard save/restore path. Unsupported selection access reports a failure;
empty selection in a supported field permits generation. Marker filtering now
removes known Whisper and non-speech labels while preserving `Array<String>`,
HTML tags, `[API]`, and other ordinary bracketed text.

The `--transcribe` CLI keeps the main run loop available for MainActor cleanup.
`Tests/TranscribeCLITests.py` compiles the actual entry point with inert backends
and checks cleanup, no-cleanup, saved cleanup disabled, raw fallback, and error
exit statuses in bounded child processes. CI runs this check alongside Swift
tests. The original semaphore version reproduced the cleanup deadlock with
the same backends before the fix.

Verification uses synthetic recognition, isolated settings, temporary disk
folders, and injected selection attributes. Live microphone capture, real model
inference, and insertion into target apps remain separate runtime checks.

Final verification passed:

- `swift test --disable-automatic-resolution`: 317 tests, zero failures.
- `swift test -c release --disable-automatic-resolution`: 317 tests, zero
  failures, including compilation of the changed application.
- `python3 -B Tests/TranscribeCLITests.py`: two tests covering six CLI cases;
  idle and startup-readiness checks: ten tests.
- `bash Tests/ReleaseContractTests.sh`: 63 checks; `git diff --check`.

An initial full run caught missing cancellation-return metadata; the repair
preserves the existing trace contract and passed both final suites. Logs are
`final-debug-tests.log`, `final-release-tests.log`, and `release-contract.log`
under `/tmp/localflow-fixes.N7UJy9`. No app installation or personal data
modification was performed.

### Live selection follow-up

The user confirmed ordinary dictation preserved their clipboard and command
editing worked in iMessage. T3 Code initially reported unreadable selection.
Read-only inspection found its `AXManualAccessibility` flag disabled and the
system-wide focused-application query failing. Enabling the documented Electron
flag made its focused `AXTextArea` and selected-text attribute readable through
the application-specific interface. No text contents were exported.

`TextInjector.prepareSelectionAccess` now requests this tree at command-key
press, allowing Electron to construct it while the instruction is recorded.
Selection reading obtains the frontmost application from NSWorkspace, then
reads its focused element directly. Native apps without the Electron attribute
and trees already enabled are left alone. Neither path uses the clipboard.
See [Electron's Accessibility documentation](https://www.electronjs.org/docs/latest/tutorial/accessibility).

The focused 11-test TextInjector suite passed. Tests cover disabled and enabled
trees, unsupported attributes, preparation failure, missing focus, and the
existing clipboard-free selection behavior. Direct inspection read T3's focused
field successfully. A standalone extracted-source harness could not read it
after focus moved to another app; first-command behavior remains a user check.

PASS: the complete release suite, 320 tests; `git diff --check`; local installation,
signature verification, and model readiness in 0.89 seconds. Evidence is
`t3-selection-full-release.log` and `t3-selection-install.log` under
`/tmp/localflow-fixes.N7UJy9`. The running local build was replaced after a clean
quit and its previous bundle was retained. T3's tree flag was reset to its
original disabled state for the user's first-command retest. That retest remains
NOT RUN until the user confirms the selected text is edited successfully.


## Acceptance and verification

Base commit: `2102c80b9644b1dc1509d4068994bdd762446d4e`, with the uncommitted
recovery diff in `/tmp/localflow-empty-recovery.diff`. macOS 26.6.2, Apple M5 Pro,
Swift 6.3.3. Evidence paths are local temporary files.

Tests in `Tests/LocalFlowTests/DictationSessionPipelineTests.swift` cover:

- `testEmptyFullUtteranceRetriesOnceAndCleansOnlyRecoveredText`: same audio retried,
  recovered text delivered, cleanup receives only recovered text.
- `testRepeatedEmptyFullUtteranceStopsAndUnblocksLaterDictation`: two attempts,
  one empty outcome, subsequent dictation delivered in order.
- `testFailedAutomaticRetryEmitsFailureWithoutFurtherAttempts`: a thrown retry
  emits failure after two calls, without cleanup.
- `testEmptySilentFullUtteranceDoesNotRetry`: silence adds no retry.
- `testEmptyChunkRecoveryDoesNotRetryFullUtteranceAgain`: chunk fallback uses
  the recovery budget.
- `testCancelledEmptyResultRetryCannotDeliverLateText`: cancelled retry output
  cannot reach cleanup or delivery; the next dictation proceeds.

Results on September 9, 2026:

- PASS: new regression tests failed against the prior implementation, with five
  assertions exposing the missing full-result retry. Evidence:
  `/tmp/localflow-empty-recovery-red.log`.
- PASS: `swift test --disable-automatic-resolution --filter
  'DictationSessionPipelineTests|DictationSessionStallTests|DictationTraceTests'`,
  20 tests before the additional thrown-retry test. Evidence:
  `/tmp/localflow-empty-recovery-focused.log`.
- PASS: `swift test --disable-automatic-resolution`, 213 tests, zero failures.
  Evidence: `/tmp/localflow-empty-recovery-tests.log`. This command also built
  the changed application source and tests.
- PASS: independent source review and `git diff --check`.
- NOT RUN: installed-app menu retry, microphone capture, target-app insertion,
  and real Whisper recovery. The tests substitute recognition results and do
  not establish decoder accuracy or actual menu behavior. Maintainers should
  verify the installed retry flow in a designated test document when the app
  can be replaced. The running app was not rebuilt or relaunched by this task.

## Installed follow-up

The user subsequently requested all usage-review follow-ups, including local
installation and a live microphone check. The recovery change is now installed
in LocalFlow Local 1.3.0. `scripts/local-app.sh install` observed model readiness
in 0.98 seconds; code-signature verification passed. The installed executable
matches the packaged executable before its embedded signature. The existing
runtime theme-icon rebake changes the signature after launch.

PASS: final follow-up release suite, 215 tests, zero failures, in
`/tmp/localflow-usage-release-tests.log`. This supersedes the earlier note that
the running app had not been updated. The application retains the same source
base plus uncommitted changes. See the [usage review](../usage-review-2026-09-09.md)
for controlled replay results, new diagnostic context, paste warning semantics,
and remaining real-device checks. No test forces the installed app to produce
an empty decoder result; manual retry UI remains a separate verification gap.

The later install-safety fix refuses Quit across recording, audio handoff,
processing, and injection completion. It was prompted by an interrupted recording
during the first rebuild. The final release suite contains 217 passing tests;
the installer preflight has six passing Python tests. Details and limitations
are recorded in the usage review.

## Architecture local installation

The user subsequently requested rebuilding the local app, then committing and
pushing these changes. On September 10, 2026, `./scripts/local-app.sh install`
built and installed LocalFlow Local 1.5.0. The installer passed its idle check,
preserved the previous local bundle, and observed speech recognition ready in
0.97 seconds. Post-launch `codesign --verify --deep --strict` passed, and the
installed local executable was running.

The app was built before the commit, as requested. Its metadata reports base
revision `4f4526a` with a modified tree and build time
`2026-09-11T02:49:36Z`. The source matched the reviewed implementation diff and
the 282-test release run. Installation evidence is
`localflow-architecture-install-20260910.log` in the OS temporary directory.
No live microphone dictation or target-app insertion was performed during
installation. This installation supersedes the earlier not-installed status.
