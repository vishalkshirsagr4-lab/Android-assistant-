# Lucy device regression checklist

This checklist is the final manual gate before calling a build release-ready. CI can verify formatting, static analysis, unit tests and APK compilation; it cannot prove Android accessibility, MediaProjection, speech engines, notification access, battery reporting or third-party app behavior on a physical device.

Use a test phone and synthetic/test accounts. Do not test message sending, calls, payments or destructive actions against real people or real accounts.

## 1. Install and first launch

- [ ] Install the APK on a clean Android 13+ device.
- [ ] Launch Lucy; confirm the app opens without a crash.
- [ ] Select English, Hindi and Kannada in turn; confirm the selection persists after force-stop and relaunch.
- [ ] Open the first-run setup guide; confirm the spoken and visible explanations match the selected language.
- [ ] Deny optional permissions; confirm Lucy remains usable for features that do not need them.
- [ ] Grant Accessibility only from Android Settings; confirm Lucy detects the change after returning to the app.
- [ ] Grant screen capture only through Android's system consent dialog; confirm the system prompt is visible and user-controlled.
- [ ] Confirm notification access and Usage access remain optional and are not enabled automatically.

## 2. Stop and safety controls

- [ ] Start a harmless screen-reading task and stop it with the in-app Stop control.
- [ ] Repeat using the persistent notification Stop action while Lucy is in another app.
- [ ] Stop during a deep scroll and during `open_each`; confirm no next item is opened after Stop.
- [ ] Confirm Stop releases the wake lock and stops speech.
- [ ] Turn Autopilot off during an active task; confirm the task stops and no later phone action is executed.
- [ ] With Autopilot off, verify read-only time/battery queries still work but app taps, typing, navigation, direct phone actions and skill replay are blocked.
- [ ] Verify Safety Stop cannot be disabled or bypassed.
- [ ] Verify messages, calls, payments, purchases, permanent deletion, account-security changes and app installation/uninstallation require the appropriate user review.
- [ ] Verify Android permission dialogs remain manual; Lucy must not tap Allow or Deny for camera, microphone, location, contacts or other runtime permissions.

## 3. ScreenWatcher

- [ ] In a supported video app, verify an exposed, explicit Skip Ad control is clicked when auto-skip is enabled.
- [ ] Verify a generic Skip/Close control on a normal non-popup screen is not clicked as a popup dismissal.
- [ ] Verify Not now, Maybe later, No thanks and Got it are handled only inside a recognized popup/banner container.
- [ ] Verify Close/X is handled only inside a dialog, modal, banner, promo or popup container.
- [ ] Verify cookie consent uses Reject all only; it must not choose Accept all.
- [ ] Verify system permission dialogs, banking/payment apps, password/2FA screens and excluded packages are never auto-clicked.
- [ ] Disable ScreenWatcher globally and per app; confirm no automatic clicks occur.
- [ ] Re-enable it and confirm the user's app exclusions remain saved.

## 4. Deep reading and screen automation

Use test accounts populated with synthetic content.

- [ ] WhatsApp test account: populate at least 150 test chats; say “scroll to the bottom”; confirm the final item is reached and the result reports whether the end was verified.
- [ ] Gmail test account: populate inbox threads with known read/unread states, dates and synthetic urgent/non-urgent subjects; ask Lucy to check all mail; compare reported thread and unread counts with the test inbox.
- [ ] Confirm `read_all` returns a de-duplicated ordered result and reports `reachedEnd` honestly.
- [ ] Confirm `open_each` returns to the list between items and does not skip or repeat items.
- [ ] Stop during `open_each`; confirm no further row is opened.
- [ ] Confirm password fields and hidden sensitive fields are not included in spoken summaries.
- [ ] Confirm an infinite feed stops at its configured limit and does not claim the end was reached.
- [ ] Confirm a locked phone is not unlocked or bypassed by Lucy; the task should pause and ask the user to unlock it.
- [ ] Confirm FLAG_SECURE screens are not captured and Lucy explains the limitation.

## 5. Memory and approved skills

- [ ] Save facts/preferences in English, Hindi and Kannada; restart Lucy and verify they persist.
- [ ] Save more than 50 test memories; verify none are silently truncated.
- [ ] Search for a saved Japanese phrase using a shorter substring; verify it is retrieved.
- [ ] Forget one memory and then all memories; verify deletion persists after restart.
- [ ] Run the same harmless navigation/reading workflow successfully once; confirm it appears as a suggestion but cannot replay.
- [ ] Repeat the exact same workflow successfully a second time; confirm approval becomes available.
- [ ] Approve it in Lucy tools; verify it replays only on the matching app version and screen signature.
- [ ] Revoke approval; verify replay stops immediately.
- [ ] Change the workflow sequence or update the target app; verify the previous approval is invalidated.

## 6. Voice and multilingual behavior

- [ ] Install/enable Hindi and Kannada speech recognition language packs in the Android speech service.
- [ ] Test short commands, questions and longer sentences in Hindi and Kannada.
- [ ] Test switching languages while idle and while listening.
- [ ] Verify TTS speaks in the selected language when the device has that voice installed.
- [ ] Temporarily select a language unavailable in the Android speech engine; confirm Lucy stops retrying and gives a clear explanation rather than looping.
- [ ] Verify a missing TTS voice does not disable STT or crash the app.
- [ ] Verify barge-in and Stop cancel queued speech without later sentences starting.

## 7. Performance, battery and long sessions

- [ ] Set Android screen timeout to 30 seconds; run a task longer than 30 seconds; confirm the display stays awake during the task and returns to normal after completion/Stop.
- [ ] Run 10 ordinary commands; inspect last/p50/p95 tree, screenshot, model, execution and TTS timings.
- [ ] Run a deep task; verify the 150-step / 6-minute budget is enforced and Stop remains responsive.
- [ ] Open Lucy tools; verify RAM, Lucy-process CPU and battery level are shown.
- [ ] Check whether the device exposes the Android charge counter. If available, compare the reported net task charge change with the before/after charge counter; otherwise confirm the UI says unavailable.
- [ ] Keep voice mode active for at least 30 minutes with intermittent commands; verify no duplicate recognizers, repeated notifications, unbounded memory growth or crash.
- [ ] Repeatedly start and stop voice mode 20 times; verify microphone/foreground service and Stop notification are released each time.
- [ ] Test network loss during a task; confirm Lucy fails safely without reading raw exception text or claiming success.

## 8. Release and update

- [ ] Confirm CI passes formatting, `flutter analyze`, all Flutter tests, JVM tests and debug APK build on the final commit.
- [ ] Confirm release signing secrets are configured: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.
- [ ] Build universal and per-ABI release APKs using the permanent release keystore.
- [ ] Verify SHA-256 checksums.
- [ ] Install the signed APK cleanly and record the signing certificate fingerprint.
- [ ] Install a subsequent APK signed with the same key over the previous version; confirm Android accepts the update without uninstalling.
- [ ] Verify the in-app update prompt opens Android's installer only after the user chooses to install.

## Known Android and OEM limitations

- Android permission dialogs and the lock screen remain user-controlled.
- FLAG_SECURE apps may return a black screenshot; this is an Android restriction.
- Some apps expose incomplete or unstable accessibility nodes, so deep reading and ad skipping cannot be guaranteed in every app.
- Ads can be skipped only when a usable skip control is exposed.
- Battery charge-counter telemetry is OEM-dependent and is an estimate, not a laboratory power measurement.
- Hindi/Kannada STT and TTS depend on language packs and the speech engine installed on the phone.
