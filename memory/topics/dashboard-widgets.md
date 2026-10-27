# Custom dashboard widgets

Updated: 2026-10-27 (archived session).

EdgeCompanion has no plugin system; custom widgets were added to the local source and the app rebuilt/reinstalled. Its built-in web page widget can display a web dashboard, but the session reported only one such widget supported.

## Arthur's layout and design preference

Arthur requested the two new widgets on the main screen and no launcher/shortcuts. The installed layout is one page: account quotas on top, call recorder below, each taking half the dashboard height. Layout controls are in Settings → Dashboard → Widget layout. Earlier instructions to swipe to separate second/third pages are superseded.

Arthur found the first UI too small and the recorder too empty. The redesign uses larger type, account tiles, compact bars, a large round recording control, a large timer and a transcription progress ring. Final dashboard height was reduced to preserve the menu bar; see [split mode](split-mode.md).

## Account quotas

- Reads the same local quota feed and usable/blocked rules as Devboard, covering eight accounts: six Claude, then two Codex. This is broader than the app's original Claude Code/Codex usage widget.
- Shows 5-hour, weekly and Fable-weekly usage/reset information, plan and active-account indication. Usage thresholds are amber at 75% and red at 90%.
- The redesigned account tiles emphasize whichever usage limit is closest to exhaustion, with three small bars underneath. Blocked tiles turn red; Fable-blocked tiles turn amber. Both show the release time; the header counts ready/blocked accounts. A reset-time formatting fix preserves minutes for dates beyond today.
- Polls every minute while visible. If the feed fails, keeps the last values greyed out with a feed-status indication.
- Classification tests passed and small/large/wide layouts were rendered and refined. The redesigned preview used sample data with blocked-account examples while the Edge was asleep.

## Call recorder

- Integrates the existing Poly speakerphone recording script and pipeline. Record uses the same Poly device and recording name as the speakerphone button.
- Stop requires two taps within three seconds. During recording the widget shows a pulsing red indicator and elapsed time; the redesign uses a large round Record/Stop control and big timer.
- After stopping, shows Transcribing with percentage and recording duration, then Sending to Discord. The redesigned transcription state has a progress ring.
- Idle state reports the last call's date, duration and result: sent to Discord, transcript saved but Discord handoff failed, no audio captured, or recording did not start.
- Supporting recorder pipeline status writes were added for recording, transcribing, sending and done. A stale previous-call 100% transcription display and small-size truncation were fixed.
- State tests passed and layouts were rendered across states. Start/Stop invocation and error handling were exercised with a stand-in recorder script; pipeline status was exercised using fake input and an unreachable Discord endpoint to avoid posting. A real 9:46 test recording later completed the pipeline and was reported sent to Discord.

Verification boundaries: rendered previews often used sample data while the panel slept; the final installed layouts were not all observed directly on the panel.
