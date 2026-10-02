# LocalFlow

Push-to-talk dictation for Apple Silicon Macs that runs entirely on your
machine. Hold a key, speak, let go, and the text is pasted into whatever app
has focus. Speech is transcribed on-device with
[WhisperKit](https://github.com/argmaxinc/WhisperKit) or Parakeet
([FluidAudio](https://github.com/FluidInference/FluidAudio)), and can
optionally be cleaned up by a local LLM. No audio leaves the Mac.

## Requirements

- Apple Silicon Mac (M1 or later). Intel isn't supported.
- macOS 14 or later. Apple Intelligence cleanup and command mode need macOS 26.
- About 2 GB of disk for the model cache. The default Large v3 Turbo model is
  about 1.5 GB.
- Internet on first launch only, to download the model.

## Install

Download `LocalFlow-<version>.dmg` from the [releases page](../../releases)
and drag LocalFlow to Applications. Builds are signed and notarized.

On first launch, grant two permissions:

1. **Microphone**, to record while you hold the key.
2. **Accessibility**, for the global hotkey and the synthesized paste. The
   menubar icon shows a warning until it's granted. No relaunch needed.

The first launch downloads the model and lets Core ML prepare it, which can
take a few minutes. The menubar shows Ready when it's done.

LocalFlow lives in the menubar and starts at login. It updates itself through
[Sparkle](https://sparkle-project.org) once a day (you can turn that off in
Settings). To uninstall, quit it, delete the app, and delete
`~/Library/Application Support/LocalFlow/`.

To check a download came from this repo's release workflow:

```bash
gh attestation verify LocalFlow-<version>.dmg --repo NikAtNight/localflow
shasum -a 256 -c SHA256SUMS.txt   # attached to each release
```

## Using it

Hold **Right Option**, speak, release. Press **Escape** to cancel before the
text is ready. The hotkey, speech model, microphone, and HUD theme are all in
Settings.

- **Live transcript.** While you talk, finished chunks show up in a panel above
  the HUD. That text is raw. The pasted text comes after release.
- **Formatting.** Long pauses start new paragraphs, and spoken ordinals
  ("first... second...") become numbered lists. Commands like "new line",
  "new paragraph", "bullet point", "numbered list", and "thumbs up emoji" work
  too. They're always interpreted, so saying "bullet point" mid-sentence
  starts a list item.
- **Vocabulary and corrections.** Add names and jargon in Settings to bias
  recognition (Whisper only). Teach fixes like "talex" to "Talix", or edit a
  pasted dictation, copy it, and pick **Fix Last Dictation...** to learn the
  swaps.
- **Snippets.** Say a trigger phrase and it's replaced with saved text.
- **History.** Every dictation is appended to a daily Markdown file in
  `~/Library/Application Support/LocalFlow/History/`. The last 5 are in the
  menu for copying back if a paste goes astray.
- **Retry.** If transcription fails, the audio stays in memory so you can
  retry from the menu. It's gone when you quit.

### Cleanup (optional)

Cleanup strips filler words, fixes false starts, and adapts style to the app
you're in (casual in Slack, identifier-safe in editors). It's off by default
because it adds latency. It runs on Apple Intelligence when that's available,
otherwise on [Ollama](https://ollama.com) with Superwhisper's
[s1-mini](https://huggingface.co/superwhisper/s1-mini):

```bash
brew install ollama
brew services start ollama
./scripts/setup-s1-mini.sh   # also attached to each release
```

If the cleanup backend is down, LocalFlow pastes the raw transcript.

### Command mode

Hold the command key and say what you want. With text selected, it rewrites
it ("make this shorter", "translate to Spanish"). With nothing selected, it
writes at the cursor. It uses Apple Intelligence or a local Ollama instruct
model (`gemma3:4b` by default).

## Privacy

There's no account, server, or telemetry. The only network request LocalFlow
makes on its own is the model download (plus the update check, if enabled).
The hotkey monitor sees modifier keys only, never characters. Optional
diagnostic recordings are off by default and stay local. See
[SECURITY.md](SECURITY.md) for details and how to report a vulnerability.

## Limitations

- Whisper models are English-only by default.
- In password fields, LocalFlow types instead of pasting, and some apps
  ignore synthesized keystrokes. Escape doesn't work there either.
- Recordings stop at 5 minutes.

## Development

See [docs/development.md](docs/development.md) for building, the local test
channel, diagnostics, and benchmarks. Feature notes live in
[docs/flows](docs/flows).

## Cutting a release

Release Please maintains the version PR. Merging it updates the release
manifest, and that main push automatically calls
`.github/workflows/release.yml`. The workflow tests, signs, notarizes, and
packages the app, validates the DMG, Sparkle feed, and checksums, then
publishes the tag and GitHub Release. A failed run can leave a private draft,
never a partial public release. It also fails if `FoundationModels` didn't
link, since that build would ship without command mode or on-device cleanup.

Required repository secrets:

| Secret | What it is |
|---|---|
| `MAC_CERT_P12_BASE64` | Developer ID Application certificate + key, as base64 .p12 |
| `MAC_CERT_PASSWORD` | Password for that .p12 |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Developer team ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA key matching the public key in `Info.plist` |

## License

MIT. See [LICENSE](LICENSE).
