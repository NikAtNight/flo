# Changelog

## [1.8.0](https://github.com/NikAtNight/walkie/compare/v1.7.0...v1.8.0) (2026-10-06)


### Features

* rename LocalFlow to Walkie ([ad726e1](https://github.com/NikAtNight/walkie/commit/ad726e1ab78e1fc591a6a357a246f0769c05af31))
* walkie-talkie menubar icon that animates while you talk ([56f5ac7](https://github.com/NikAtNight/walkie/commit/56f5ac731a26275c0f0eda5c05e9b6335df18e12))

## [1.7.0](https://github.com/NikAtNight/localflow/compare/v1.6.2...v1.7.0) (2026-10-02)


### Features

* add Parakeet TDT 0.6B v3 engine through FluidAudio ([86b65ac](https://github.com/NikAtNight/localflow/commit/86b65acd590fad17c1da775bbaa94d49aa187d3c))
* add Show live transcript in the HUD setting ([219efb5](https://github.com/NikAtNight/localflow/commit/219efb53ebe225c3eb2c74d971a11cdce5105b00))
* draw a live transcript strip under the HUD capsule ([d88b012](https://github.com/NikAtNight/localflow/commit/d88b012bd5cd90918e8b5a23978b7fede3b9acac))
* Escape cancels an in-progress dictation ([33c1c9c](https://github.com/NikAtNight/localflow/commit/33c1c9c57e9e2c78379cd3b8a6d689c5c54ff70d))
* offer Parakeet in the Model menu and Settings ([63a743a](https://github.com/NikAtNight/localflow/commit/63a743a94b161f12d9c78a357542485bd0c23118))
* pick the live-text chunk cadence from the speech engine ([48d5c81](https://github.com/NikAtNight/localflow/commit/48d5c8149546ccf973d1d6264cf5f815efc6ecd9))
* report raw partial transcripts from the dictation pipeline ([dcf12e2](https://github.com/NikAtNight/localflow/commit/dcf12e2cc03998c3d36e30d22783d3b7dcf78baf))
* restore clipboard after the paste is read, not on a fixed timer ([bb9ffae](https://github.com/NikAtNight/localflow/commit/bb9ffaeab7a4afd9ccbac77f083d12f76d0e5b55))
* show live transcript text in the HUD while dictating ([3bdb301](https://github.com/NikAtNight/localflow/commit/3bdb301f6db0a89d47ffe2cb701ae87e3cad8d6c))
* show Parakeet preview text in the HUD every second ([d104f5c](https://github.com/NikAtNight/localflow/commit/d104f5c7b77cfda55a57b5834494f7eba3db78f3))
* show the live transcript in a Handy-style panel above the HUD ([fd81fb6](https://github.com/NikAtNight/localflow/commit/fd81fb64ad7312a5d5b90180483301a230975d37))


### Fixes

* keep each Parakeet segment's start at or before its end ([e56e1d1](https://github.com/NikAtNight/localflow/commit/e56e1d1123a36f9ac9be5b67fbacccdd6efc6ea3))
* keep the speech model loaded when Escape cancels a dictation ([bfad00d](https://github.com/NikAtNight/localflow/commit/bfad00df2c2d7a2337c8438234c8a8ce007b7071))
* let Escape cancel while Right Command is the held hotkey ([16d8cbf](https://github.com/NikAtNight/localflow/commit/16d8cbf31f781a9d1979b37a4dbf8f2f95bb0387))
* log a disabled Escape tap only while it should be on ([ce99886](https://github.com/NikAtNight/localflow/commit/ce998863b419a417c7dbc31cb8806b19b147e8b2))
* measure Parakeet pauses the way FluidAudio reports them ([1f71feb](https://github.com/NikAtNight/localflow/commit/1f71feb968f995519447778b19cc50dc9807e860))
* name the speech model, not Whisper, in errors and drop em dashes ([24ba624](https://github.com/NikAtNight/localflow/commit/24ba624b2689f4907609187b4d7b79145c12ea54))
* recreate the Escape tap after macOS invalidates it ([eb5cf4d](https://github.com/NikAtNight/localflow/commit/eb5cf4d32f9bdd9b75b7e7a5fdb6e14557bfeac3))
* restore a pending clipboard at quit instead of refusing for up to 10 s ([b8ead55](https://github.com/NikAtNight/localflow/commit/b8ead5506c2a7bf7c19f04e94febf45d5de81ef8))
* skip the command-mode AX warmup while a paste awaits its read ([af978d0](https://github.com/NikAtNight/localflow/commit/af978d08d0be3c6e3038d023b14f0781d0029078))
* stop restoring the clipboard early at quit ([4b5e4cb](https://github.com/NikAtNight/localflow/commit/4b5e4cbc7121f2f3359ac7f19f8a9651e90f51c1))

## [1.6.2](https://github.com/NikAtNight/localflow/compare/v1.6.1...v1.6.2) (2026-10-01)


### Fixes

* resolve dictation stalls and command, CLI, and history bugs ([396b8ff](https://github.com/NikAtNight/localflow/commit/396b8ff149a32d28de9e1a23e97e02c78af943d2))

## [1.6.1](https://github.com/NikAtNight/localflow/compare/v1.6.0...v1.6.1) (2026-09-13)


### Fixes

* reduce repeated decoding of near-silent dictations ([5ddcfba](https://github.com/NikAtNight/localflow/commit/5ddcfba8922499201eb8fc8306ca0b9f338e5bee))

## [1.6.0](https://github.com/NikAtNight/localflow/compare/v1.5.0...v1.6.0) (2026-09-11)


### Features

* add production diagnostics with 30-day retention and export ([2201626](https://github.com/NikAtNight/localflow/commit/2201626466629327c0849554ee2dafaddd79d899))


### Fixes

* retain local diagnostics across app updates ([d08765d](https://github.com/NikAtNight/localflow/commit/d08765dd94b863c5b37b964f94eed1f9cd1c5bf3))

## [1.5.0](https://github.com/NikAtNight/localflow/compare/v1.4.1...v1.5.0) (2026-09-10)


### Features

* retain and review local personal voice recordings ([f635daf](https://github.com/NikAtNight/localflow/commit/f635daf109ef096cae3a55cd509a54e66fb2c81d))
* retain local audio and transcript stages for diagnostics ([7c12e64](https://github.com/NikAtNight/localflow/commit/7c12e64355a739cc3a16100c3a8c51e09a676f5f))


### Fixes

* preserve Developer ID identity when updating theme icons ([84f6ce9](https://github.com/NikAtNight/localflow/commit/84f6ce94787859c87dc9e93159d2aca992abda3c))

## [1.4.1](https://github.com/NikAtNight/localflow/compare/v1.4.0...v1.4.1) (2026-09-10)


### Fixes

* match Liquid Glass icon to the listening waveform ([ab1848d](https://github.com/NikAtNight/localflow/commit/ab1848d15e1e99863ddb91521b19f7f52c00aa02))
* use compact native toolbar in settings ([601fee5](https://github.com/NikAtNight/localflow/commit/601fee53a3d9f5de87c7e7e2d74d300546ffd112))

## [1.4.0](https://github.com/NikAtNight/localflow/compare/v1.3.0...v1.4.0) (2026-09-09)


### Features

* recover empty dictations and protect active recordings ([0d91b1b](https://github.com/NikAtNight/localflow/commit/0d91b1bd102ed5af42e53e0e70cef56215087429))

## [1.3.0](https://github.com/NikAtNight/localflow/compare/v1.2.0...v1.3.0) (2026-09-09)


### Features

* add native settings and local diagnostics ([3966f32](https://github.com/NikAtNight/localflow/commit/3966f321422b1ec92d36825ad4316daf4f2d26e7))

## [1.2.0](https://github.com/NikAtNight/localflow/compare/v1.1.4...v1.2.0) (2026-09-09)


### Features

* add local dictation and Whisper startup timing diagnostics ([4d3ca41](https://github.com/NikAtNight/localflow/commit/4d3ca410d949cfcba8d74f4dc8cfd4e68353f092))
* give Liquid Glass its own app icon ([cd22291](https://github.com/NikAtNight/localflow/commit/cd2229179e00c9fc6bdb184e2813c767d6200fe7))


### Fixes

* scale HUD loudness by log-ratio over the room floor ([8f69581](https://github.com/NikAtNight/localflow/commit/8f695817726143f11a26e1c82611fa1dedf80a92))

## [1.1.4](https://github.com/NikAtNight/localflow/compare/v1.1.3...v1.1.4) (2026-09-01)


### Fixes

* keep launch updater sessions from wedging ([4ecf7f5](https://github.com/NikAtNight/localflow/commit/4ecf7f5721980dddf6031bc3e27a8e91c245c5ec))
* run the app from a synchronous main entry ([d4eec7b](https://github.com/NikAtNight/localflow/commit/d4eec7b904a3d9cbffeacdd608c3382413003d4a))

## [1.1.3](https://github.com/NikAtNight/localflow/compare/v1.1.2...v1.1.3) (2026-09-01)


### Fixes

* fall back to an installed cleanup model ([46ba035](https://github.com/NikAtNight/localflow/commit/46ba0353f15655673764800ae7e2d94e36da0a0c))
* keep menu error summaries compact ([4417b35](https://github.com/NikAtNight/localflow/commit/4417b35081a8fdc6c0538e3923b574ce31e0b693))
* share release gate logic across workflows ([518899b](https://github.com/NikAtNight/localflow/commit/518899b86f12a384b89375208f6b215c8ce1e99b))

## [1.1.2](https://github.com/NikAtNight/localflow/compare/v1.1.1...v1.1.2) (2026-09-01)


### Fixes

* compact status and serialize model startup ([7838b5e](https://github.com/NikAtNight/localflow/commit/7838b5e78caf8846d6d18d818710ad52fd51d95f))

## [1.1.1](https://github.com/NikAtNight/localflow/compare/v1.1.0...v1.1.1) (2026-08-31)


### Fixes

* finalize published release labels ([f89a3bb](https://github.com/NikAtNight/localflow/commit/f89a3bbdac3b116948c1af14014d0b8e2b62ced2))
* finalize published release labels ([0bdac60](https://github.com/NikAtNight/localflow/commit/0bdac60e10efa35b378c53c0ab364d73ce38298f))
* sign release disk images ([febfdbe](https://github.com/NikAtNight/localflow/commit/febfdbefcbf8ae69c8ce8e2dc2e9a909bea26bb2))
* sign release disk images ([0c68f85](https://github.com/NikAtNight/localflow/commit/0c68f854aac9a5efe6266f5ae5f41cdae61b9cde))

## [1.1.0](https://github.com/NikAtNight/localflow/compare/v1.0.0...v1.1.0) (2026-08-31)


### Features

* speed up dictation and compact status feedback ([9c7be1d](https://github.com/NikAtNight/localflow/commit/9c7be1d8c5e2f5892a2741766da3e24c54fb2e32))
* speed up local dictation and compact feedback ([df8822f](https://github.com/NikAtNight/localflow/commit/df8822fc8aec45fefd17f44d1a535edbc78b34c4))


### Fixes

* apply correction replacements atomically ([161e6b5](https://github.com/NikAtNight/localflow/commit/161e6b5ba6cd73031eba44be93a7bfb88e83dba7))
* arm stalled dictation timeout ([1f50eda](https://github.com/NikAtNight/localflow/commit/1f50edab989eeeadbe9800968d1dbe5b1b9974e8))
* bind releases to trusted state ([f95603f](https://github.com/NikAtNight/localflow/commit/f95603f44d58d33f38d1b11b9893b7cff3389513))
* block stale release publication ([524b1d0](https://github.com/NikAtNight/localflow/commit/524b1d059dbe182e21b6bf5c808514aeaa365e9b))
* cancel stalled mixed-mode injections ([c59a458](https://github.com/NikAtNight/localflow/commit/c59a4582111228b3b4542d871eb4f90155c5e6cb))
* compare release assets portably ([5e1d62f](https://github.com/NikAtNight/localflow/commit/5e1d62f516ac411880f4c1dda9519e0b67712e65))
* dispatch releases from default branch ([2c6c390](https://github.com/NikAtNight/localflow/commit/2c6c390d94656e8e6d777fa129df9b6e8a80ed7c))
* fail closed before publishing releases ([87ac6cc](https://github.com/NikAtNight/localflow/commit/87ac6cc2f80e60c7810006b7d358ae52e0304d7e))
* fail closed before publishing releases ([a9dc716](https://github.com/NikAtNight/localflow/commit/a9dc716f63544ccef5d29cbd44bd55a721d77e40))
* finish local text model integration ([c5a4acd](https://github.com/NikAtNight/localflow/commit/c5a4acdcc4b5b748764e9f80c24280685db65983))
* integrate local text model policy ([89fe898](https://github.com/NikAtNight/localflow/commit/89fe898aa3159b52dc3cbbb4ac4ba71c595aecdf))
* keep liquid glass compatible with the CI SDK ([2fd63e1](https://github.com/NikAtNight/localflow/commit/2fd63e153370760811766a3426d6fd0fa4be810e))
* keep settings compatible with the CI SDK ([40325c5](https://github.com/NikAtNight/localflow/commit/40325c5f2c34142115341ea77e5b9cce5613c21a))
* key prewarm cooldowns by backend ([57c2fe5](https://github.com/NikAtNight/localflow/commit/57c2fe50bb910107d8f1d3dc29d3aae0d88bac91))
* make release invocation non-replayable ([84fe882](https://github.com/NikAtNight/localflow/commit/84fe882e6df7f9abaecd7e00af19dbabad3b7023))
* make the non-ASCII lint work on BSD grep, and add release-please ([73ed875](https://github.com/NikAtNight/localflow/commit/73ed8759f9fee8b30f42d02a17f5acb9c630e682))
* preserve injection stall deadline ([22ce84d](https://github.com/NikAtNight/localflow/commit/22ce84d3c6d76d5d353d23e8e52dfcee5464020b))
* preserve stalled dictation deadline ([d23afda](https://github.com/NikAtNight/localflow/commit/d23afda227002b919f66ae1e7fbbab4d89223489))
* restrict release please to main pushes ([3676efc](https://github.com/NikAtNight/localflow/commit/3676efc7042b50ddf9c5d11530327fd5ffdc8bf4))
* verify release source and destination ([b736066](https://github.com/NikAtNight/localflow/commit/b736066a976e79b8343a8ab51b1cfa996c9f3db7))
