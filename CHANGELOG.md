# Changelog

All notable changes to Lucy are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> [!NOTE]
> **Version numbers restart at `0.1.0`.** Earlier `1.0.x` builds were private test
> builds distributed outside this repository — no tag, no release and no APK for
> them ever existed here. `0.1.0` is the first version anyone can actually
> download, so it is where the public history begins. The `0.x` line is also the
> honest label: Lucy is experimental, and anything may change before `1.0.0`.

---

## [Unreleased]

### Added

- 📲 In-app update checks against GitHub Releases, with an update prompt, APK download and Android package-installer handoff
- 🔐 Stable release signing is required so future APKs can update the installed app without uninstalling

---

## [0.3.0] - 2026-11-17

### Added

- 🛑 Executor-level Autopilot enforcement across local shortcuts, model actions, learned-skill replay and ScreenWatcher automation; turning Autopilot off stops an active task.
- 🧭 Safer ScreenWatcher matching for separate text/content descriptions, localized popup choices and context-aware dialog close controls.
- 🧠 User-controlled routine learning: the same safe workflow must succeed twice and be explicitly approved before replay; approval can be revoked.
- 🗣️ Localized Hindi and Kannada first-run permission guidance, spoken setup explanations and clearer handling when Android speech-language packs are unavailable. TTS setup remains independent of microphone permission.
- 📊 Bounded performance diagnostics for model/tree/screenshot/execution/TTS timings, p50/p95 latency, task counts, task duration and optional charge-counter deltas.
- 🧪 Expanded regression tests for safety policy, localized watcher labels, approved skills, concurrent memory writes, Japanese retrieval, voice locales and performance metrics.
- 📋 Physical-device regression checklist covering permissions, Stop, WhatsApp/Gmail deep reading, YouTube ad skip, multilingual voice, battery and release updates.

### Changed

- Ordinary tasks use a 50-step / 3-minute budget; explicit deep-list tasks can use up to 150 steps / 6 minutes.
- Memory persistence writes are serialized; Japanese phrase retrieval uses overlapping Kana/Kanji bigrams.
- Release documentation and README now describe the current five-language, safety, notification and learning behavior.

### Fixed

- Fixed a ScreenWatcher Kotlin compile failure caused by a stale deduplication variable after label extraction changed.
- Fixed localized setup wizard constant-expression and recursive-translation-map errors found by CI.
- Prevented unavailable speech-language packs from triggering endless recognizer retries.
- Prevented TTS language setup failures from escaping the speech error boundary or disabling otherwise working STT.
- Added task exception containment and best-effort release of wake locks, screen operations and voice resources on Stop.

### Validation notes

- CI validation is required on the final release-candidate commit. A passing CI run does not replace the physical-device checklist in [docs/DEVICE_REGRESSION.md](docs/DEVICE_REGRESSION.md).
- Battery charge-counter data and Hindi/Kannada voice availability depend on the Android device and installed services.

## [0.2.0] - 2026-11-12

### Added

- 📲 In-app update prompt, download and Android installer flow for newer stable GitHub releases
- 🔐 Release workflow now requires a persistent signing keystore to protect seamless upgrades

### Changed

- 🎬 The README demo is now an **inline video player** instead of a GIF. The clip is hosted on GitHub's asset CDN rather than committed to the repo, so a clone no longer carries it — and viewers get the full 68 seconds with sound and controls instead of a silent 13-second excerpt

---

## [0.1.0] - 2026-08-26

**The first public release** — and the first downloadable APK. If you are arriving
from GitHub, everything below is new to you.

### Added

**The agent**

- 🗣️ **Voice-driven agent loop** — speech in, screenshot and accessibility tree to Gemini, real taps and keystrokes out, spoken answer back
- 👁️ **Dual-input perception** — a downscaled JPEG screenshot plus a structured JSON accessibility tree with exact pixel bounds for every element
- 🎯 **Tap-by-element** — the model references elements by integer ID; coordinates are resolved on the Dart side, making hallucinated taps structurally impossible
- ⚡ **Seven actions** — `open_app`, `tap`, `type`, `swipe`, `back`, `home`, `wait`
- 🌍 **Trilingual support** — English, Japanese and Arabic, with language detection from the model's response, matching TTS/STT locales, and a persisted language preference
- 🛑 **Persistent "Stop Lucy" notification** — cancels the agent from anywhere, including from inside another app
- 🔑 **Bring-your-own Gemini API key**, stored locally via `shared_preferences`
- ♿ **Accessibility gate** — the app requires its accessibility service before it will run, and re-checks on resume
- 💬 **Conversation view** with inline screenshots, action summaries and timestamps
- 🔁 **Step ceiling** — Lucy stops herself after 50 steps on a single command, so she can never loop forever

**Speed and reliability**

- Screenshots are encoded to JPEG in memory on a dedicated background thread, never written to disk
- Screen capture and UI-tree collection run concurrently within each agent step
- Post-action waits are readiness-based, not fixed sleeps — the loop waits for an observed package change, UI-tree change, or newly focused input, with per-action timeouts
- Screen capture recovers from a lost or expired `MediaProjection` token, including the single-use token behaviour on Android 14+
- Capture is retried after app switches, when the `VirtualDisplay` has not yet rendered a frame
- Speech recognition retries on empty results, with a 3-attempt ceiling before returning to idle

**Getting it, and working on it**

- 📦 **Downloadable APKs**, published automatically by GitHub Actions whenever a new semantic version lands in `pubspec.yaml` on `main` — universal plus per-ABI builds, with SHA-256 checksums. `lucy-latest.apk` is a permanent link to the newest stable build. See [docs/RELEASING.md](docs/RELEASING.md)
- 🎬 **Demo video** in the README, showing Lucy composing and sending an email by voice
- 📖 Open source documentation set: `README`, `CONTRIBUTING`, `CODE_OF_CONDUCT`, `SECURITY`, `docs/ARCHITECTURE.md` and `docs/RELEASING.md`
- 📄 MIT `LICENSE`
- 🔧 GitHub Actions CI — format check, analyze, tests, and a debug APK build on every push and pull request
- 📋 Issue templates for bug reports and feature requests, plus a pull request template
- 🧪 Widget tests covering the accessibility gate and the main screen, with the platform channel mocked
- 🔐 Release builds fall back to the debug signing key when no keystore is configured, so a fresh clone can still produce an installable APK

### Fixed

- 🧪 `flutter test` no longer fails on a clean checkout — the previous test asserted against the main screen without mocking the accessibility method channel, so it always rendered the "Accessibility Required" gate instead
- 🔐 `key.properties`, `*.jks` and `*.keystore` are now actually in `.gitignore`. The README claimed they were; they were not

### Known limitations

- 🔏 Release APKs are signed with a **debug key** until a release keystore is configured, so the signature changes between builds. Uninstall an older Lucy before installing a newer one
- 🤖 **Android only.** Screen capture and the action layer are Android APIs; there is no iOS target
- 🚫 Apps that set `FLAG_SECURE` (banking apps, Netflix) return black screenshots. This is enforced by Android and cannot be worked around
- 📉 Apps with weak accessibility semantics expose little of their UI tree, and Lucy is less reliable there

---

[Unreleased]: https://github.com/vishalkshirsagr4-lab/Android-assistant-/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/vishalkshirsagr4-lab/Android-assistant-/releases/tag/v0.3.0
[0.2.0]: https://github.com/vishalkshirsagr4-lab/Android-assistant-/releases/tag/v0.2.0
[0.1.0]: https://github.com/alzin/lucy-screen-agent/releases/tag/v0.1.0
