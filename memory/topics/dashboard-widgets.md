# Custom dashboard widgets

Updated: 2026-10-27 (archived session).

EdgeCompanion has no plugin system; custom widgets were added to the local source and the app rebuilt/reinstalled. Its built-in web page widget can display a web dashboard, but the session reported only one such widget supported.

## Arthur's layout and design preference

Arthur requested the two new widgets on the main screen and no launcher/shortcuts. The installed layout is one page. Since 2026-11-04 the quotas take a large (2×2) slot and the recorder a tall (1×2) slot beside it; before that they were stacked, each half the height. Layout controls are in Settings → Dashboard → Widget layout. Earlier instructions to swipe to separate second/third pages are superseded.

Arthur found the first UI too small and the recorder too empty. The redesign uses larger type, account tiles, compact bars, a large round recording control, a large timer and a transcription progress ring. Final dashboard height was reduced to preserve the menu bar; see [split mode](split-mode.md).

## Account quotas

- Reads the same local quota feed and usable/blocked rules as Devboard, covering eight accounts: six Claude, then two Codex. This is broader than the app's original Claude Code/Codex usage widget.
- Shows 5-hour, weekly and Fable-weekly usage/reset information, plan and active-account indication. Usage thresholds are amber at 75% and red at 90%.
- The redesigned account tiles emphasize whichever usage limit is closest to exhaustion, with three small bars underneath. Blocked tiles turn red; Fable-blocked tiles turn amber. Both show the release time; the header counts ready/blocked accounts. A reset-time formatting fix preserves minutes for dates beyond today.
- Tiers (2026-11-03, Arthur): Claude Ultra plans (feed `plan` containing "Ultra"; currently gmail and arthur) are the top tier. They sort first among Claude accounts even when blocked and sit in a left column of larger tiles with a plan tag, a big number and labeled horizontal bars with percentages. The Team 5x seats, cascade and the Codex accounts form the second tier in a 3×2 grid of smaller tiles on the right. With only one tier present the original grid is used.
- Groups (2026-11-04, Arthur): the widget shows three labeled groups top to bottom: Claude Ultra as full-width rows (number left, labeled bars right), Claude Team as a tile grid, then Codex as a tile grid. Each group label carries its ready and blocked counts; the header keeps only the feed-offline pill. Grouping lives in EdgeCore `QuotaBucket`, with a test. This replaces the left-column tier split.
- Polls every minute while visible. If the feed fails, keeps the last values greyed out with a feed-status indication.
- Classification tests passed and small/large/wide layouts were rendered and refined. The redesigned preview used sample data with blocked-account examples while the Edge was asleep.

## Call recorder

- Integrates the existing Poly speakerphone recording script and pipeline. Record uses the same Poly device and recording name as the speakerphone button.
- Stop requires two taps within three seconds. During recording the widget shows a pulsing red indicator and elapsed time; the redesign uses a large round Record/Stop control and big timer.
- After stopping, shows Transcribing with percentage and recording duration, then Sending to Discord. The redesigned transcription state has a progress ring.
- Idle state reports the last call's date, duration and result: sent to Discord, transcript saved but Discord handoff failed, no audio captured, or recording did not start.
- Supporting recorder pipeline status writes were added for recording, transcribing, sending and done. A stale previous-call 100% transcription display and small-size truncation were fixed.
- State tests passed and layouts were rendered across states. Start/Stop invocation and error handling were exercised with a stand-in recorder script; pipeline status was exercised using fake input and an unreachable Discord endpoint to avoid posting. A real 9:46 test recording later completed the pipeline and was reported sent to Discord.
- Mic mute (added 2026-11-03): a round mic button the same size as Record, side by side under the header with captions beneath each, mutes every physical microphone at the device level (CoreAudio input mute), so Teams, Zoom, Meet, phone calls and the recorder's mic channel all go silent, whichever mic the app picked. Virtual and aggregate inputs (such as Microsoft Teams Audio) are skipped. It reads "Muted" (amber) only when every physical mic is muted; one tap mutes all unless all are already muted. State is re-read every second, so mutes made elsewhere show up. The caption names the mic an app has open (joined with "+" if several, e.g. the recorder on the Poly plus Teams on the MV7), falling back to the system default. On 2026-11-03 Teams was capturing from the Shure MV7 while the Poly was the system default, which is why it mutes every mic rather than only the default.
- Mute verification: rule tests pass; the panel showed equal Record and mic circles with the mic captioned "Mic on · Shure MV7" while Teams held the MV7; a Poly-only device mute was read back and correctly left the state at "Mic on". The muted look and a real tap were not exercised because Teams held the MV7 open.
- Stacked layout (2026-11-04): in a card taller than it is wide (Arthur's layout: quotas large, recorder tall), Record and the mic each sit in their own rounded panel, stacked, with a Last call strip at the bottom while idle. The record panel tints red while recording and blue while transcribing or sending; the mic panel tints amber when muted. Wider cards keep the side-by-side layout. Checked on the panel at the 480-point split width in the idle state.

Verification boundaries: rendered previews often used sample data while the panel slept; the final installed layouts were not all observed directly on the panel.
