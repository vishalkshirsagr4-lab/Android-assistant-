# Lucy physical-device validation

These checks must be run on a real Android phone. CI cannot validate microphone hardware,
OEM battery management, lock-screen behavior, or the notification shade.

## Before testing
- Install the debug APK produced by the latest successful CI run.
- Grant microphone permission when Lucy requests it.
- Grant notification permission on Android 13+.
- Enable Lucy Accessibility only if you intend to test screen actions.
- Keep the phone unlocked for the first start of microphone listening.

## Native foreground speech
- [ ] Tap Lucy's microphone button while the app is visible; confirm Android shows the persistent "Lucy is listening" notification.
- [ ] Speak a short phrase; confirm partial text appears and the final phrase is handled once.
- [ ] Leave Lucy in listening mode, turn the screen off, wait 2 minutes, and speak; record whether the OEM permits continued recognition.
- [ ] Repeat with Battery Saver enabled; record interruptions and recovery behavior.
- [ ] Switch between apps while listening; confirm the notification remains visible and recognition behavior is expected.
- [ ] Tap "Stop Lucy" in the notification; confirm the notification disappears and Lucy returns to idle.
- [ ] Deny microphone permission, then start Lucy; confirm it reports the permission problem and does not keep retrying.
- [ ] Force-stop the app from Android Settings, reopen it; confirm microphone listening does not silently resume.
- [ ] Revoke microphone permission while Lucy is stopped; confirm a new start is rejected until permission is restored.

## WorkManager routines
- [ ] Schedule a one-time reminder for 2 minutes; confirm the notification appears.
- [ ] Schedule a recurring reminder every 15 minutes; confirm it repeats at an OS-permitted time.
- [ ] Cancel a recurring reminder; confirm later notifications stop.
- [ ] Reboot the phone with a recurring reminder scheduled; confirm WorkManager restores it after boot.
- [ ] Deny notification permission; confirm Lucy asks you to grant it and does not claim a reminder notification will be visible.
- [ ] Enable Battery Saver / Doze; confirm reminder timing may be delayed by Android's battery policy.

## Approval-gated actions
- [ ] Ask Lucy to open an app; confirm the approval dialog appears before the app opens.
- [ ] Ask Lucy to tap an on-screen control; confirm the dialog appears before the tap.
- [ ] Ask Lucy to type text; confirm the dialog appears before typing and the displayed parameters are correct.
- [ ] Deny each action; confirm no corresponding action executes.
- [ ] Approve each action; confirm only the displayed action executes.
- [ ] Start an action while the app is backgrounded or approval UI is unavailable; confirm the action is denied.

## Recovery and evidence
Record device model, Android version, app commit SHA, exact steps, expected result, actual result,
and a redacted logcat excerpt for every failure. Do not include API keys, personal messages,
screenshots containing private data, or other secrets in bug reports.

## Phase 4 — proactive suggestions and decision policy

- [ ] In Lucy tools, open **Proactive suggestions** and verify it is disabled by default.
- [ ] Grant Android notification permission, enable suggestions, and save.
- [ ] Set quiet hours spanning midnight (for example 22:00–08:00); verify no suggestion notification is posted during that window.
- [ ] Verify the daily limit and cooldown prevent repeated suggestion notifications.
- [ ] With notification context disabled, verify no notification-based suggestion is generated.
- [ ] With notification context explicitly enabled, post a test notification and use **Check now**; the suggestion should be generic and must not expose notification text.
- [ ] If calendar permission is granted, create a test event within 30 minutes and use **Check now**; verify the notification identifies the event without launching an action.
- [ ] Verify low-battery advice appears only below 20% while not charging (this may require a controlled test device).
- [ ] Open **Why this suggestion?** and confirm it shows the stored reason, confidence and risk.
- [ ] Disable proactive suggestions and verify the periodic WorkManager task is cancelled.
- [ ] Verify medium/high-risk agent actions ask for spoken approval; cancelling or timing out must not execute them.
- [ ] Verify normal navigation remains hands-free and an unlabeled tap in a sensitive app requests approval.

**Platform timing note:** WorkManager periodic work is not an exact timer. Android enforces a 15-minute minimum interval and may delay execution further due to Doze, battery saver, OEM background limits or network constraints. Proactive checks run locally and do not call an AI provider. Notifications require Android notification permission. The worker never sends messages, places calls, changes settings or performs other phone actions.
