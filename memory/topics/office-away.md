# Office away and back (screen blanking)

Updated: 2026-11-27.

Since 2026-11-27 EdgeCompanion is the only owner of "Arthur is away / back" for the office. It replaced the assistant repo's standalone `office-display-blanker` LaunchAgent, which was retired the same day. Code: `Sources/EdgeCompanion/Away/`; pure rules and tests: EdgeCore `OfficeAway.swift`.

## Why it moved here

On 2026-11-27 the old blanker held Arthur's screens dark for 48 hours and then, with this app, overloaded WindowServer:

- His real mouse woke the displays at 09:31:55, but the Dock had landed on the Edge. The blanker ignored pointer moves while the Dock was off the main display, guessing they were this app's Dock pushes, so it kept re-darkening until 09:38:31.
- It then spent 73 s restoring brightness through `m1ddc` retries.
- Meanwhile this app re-acquired the Edge and pushed the Dock for about 50 s. Its PointerGuard tap was disabled by timeout six times, because the tap called `CGWarpMouseCursorPosition` synchronously while WindowServer was busy.
- While blanked, the old blanker also rewrote gamma and spawned `m1ddc display list` every 5 s, and listed windows 5 times a second.

## Trigger contract (Home Assistant)

- HA's office auto-off SSHes in with a forced command, `~/Dev/assistant/tools/office-away`. That script mutes the LG, then runs `/Applications/EdgeCompanion.app/Contents/MacOS/EdgeCompanion --away blank`.
- `--away blank|unblank|status` (`AwayCommand`) talks to the running app through files in `~/Library/Application Support/EdgeCompanion/OfficeAway/`: `request`, `response`, `heartbeat` (rewritten every 5 s with a status line) and `state.json`.
- Exit status: 0 handled, including "ignored: input Ns ago"; 3 no heartbeat in 20 s (app not running); 4 no answer in 5 s; 5 refused because the input watch is off; 64 usage. HA retries every minute until a call succeeds.
- `--away unblank` restores the screens without anyone's input; use it for tests and recovery. `--away status` prints the heartbeat line and the state.

## Who counts as a person

- `HumanInputWatch` is a listen-only session event tap on its own thread over every input kind (moves, clicks, keys, scrolls, gestures, tablet).
- Hardware input has source process id 0 and counts. Two posters count as Arthur too: this app's Edge touch replays (tag `InputTag.touch`, from this process only) and `logioptionsplus_agent`, which re-posts his real scrolls, buttons and gestures.
- Everything else posted never counts: Computer Use, the Dock relocator (its own tag `InputTag.dock`) and any other automation.
- A pointer move with zero delta does not count (measured: about 15% of his real move events have zero delta; real movement always includes non-zero ones). Mouse entered/exited and system-defined events, which a display waking on its own posts, are not in the mask.
- A finger on the Edge counts directly from its HID reports (`TouchController.onFingerDown`). While dark, that first touch only wakes; it is not delivered.
- A key or click that wakes dark screens is delivered to the front app as usual (system default). Arthur often wakes with Space and chose to keep that behaviour (2026-11-27); do not swallow it.

## Away

- A blank request is ignored if a person used the Mac in the last 60 s; the app assumes input at its own launch. It is refused (exit 5) if the input watch is not running, because nothing could wake the screens.
- Darkening: zero gamma on every display (instant; screen capture is unaffected, so Computer Use keeps working), then DDC brightness 0 on awake external monitors (the LG and the Edge). Asleep monitors are dimmed when they wake, since DDC can wake them.
- DDC goes through `DDCController(.located(path))`, matched to each display by CoreDisplay's `IODisplayLocation`. Transactions on one display share a lock across controllers, so dimming never interleaves frames with the LG volume strip or the Edge colour code. Replies are checked for the right VCP code; a garbled readback trusts the write.
- Brightness to restore is kept in `state.json` with a remembered ordinary level per monitor (`lastGood`), so a dark reading is never restored. Readings below 10 restore the last ordinary level, else 100. With no reading and no known level the monitor is not dimmed.
- While away the app is quiet: the dashboard's widgets leave the screen (so none polls DDC, the network or files), telemetry is suspended, and the window evictor and Dock relocator pause.
- Darkness is re-applied only when a display reconfigures, the screens or system wake, or the session becomes active. A 5 s check reads only each display's gamma and sleep state.

## Back

- Gamma is restored at once on the away queue, never on the main thread or an input path.
- Brightness is then restored on the DDC queues, with up to three write-and-check rounds per monitor and up to three retries 30 s apart. The quiet lifts when brightness is back, or after 8 s at most.
- Lifting the quiet un-pauses the Dock relocator, which makes one fresh check.
- Startup restores anything left dark by an earlier run. Quitting from the menu restores first; a killed app gets gamma back from macOS and brightness at its next start.
- Log lines are `[away]` in `~/Library/Logs/EdgeCompanion/EdgeCompanion.log`. That log is now capped at 1 MB while running, not only at launch.

## Input paths

- PointerGuard's tap no longer calls WindowServer. It rewrites the event location and hands the cursor warp to its own queue, where the newest target wins.
- Verified 2026-11-27 with CGGetEventTapList: both taps enabled, none disabled by timeout since the install. The list's latency fields are not a live measure: they stayed frozen at one value for 10 s while the pointer moved through the tap.

## Verification

Verified 2026-11-27 on the installed app with Arthur at the desk:

- Accessibility and Input Monitoring kept working after the install: the input watch, touch seizing and PointerGuard all started.
- A blank request while he was active answered `ignored-active` (exit 0).
- Posted moves, button presses, keys and scrolls, at both the HID and session levels, were classified synthetic. The app's last-person-input time did not move across them; his own mouse and Logi scrolls counted.
- The app's own DDC path read the LG (99) and the Edge (100) in 0.08 s each.
- Exit codes through a copy of `office-away` with a stub mute: 0 with the app running, 4 just after it stopped, 3 after 20 s down.
- A 7-second live blank, run after 5 minutes of HID idle:
  - Gamma read dark on both displays, and both monitors were dimmed over DDC about 1.1 s after the request.
  - Posted synthetic input did not wake them. A second request answered `already-away`.
  - `--away unblank` answered in 0.13 s. Brightness was back 0.45 s later (LG 99, Edge 100, read back), and the quiet lifted.
- Seen live 2026-11-27: a real Home Assistant auto-off blanked at 11:01:59; his USB Receiver mouse turned the displays on at 11:07:44 and the app logged "back: mouse move" and restored brightness at 11:07:51, with no pointer-tap timeouts. The ~7 s from the first HID tickle to recognised input is unexplained (no input was logged in between); check the first-move timing on the next real return. The Dock still landed on the Edge and took until 11:08:04 to move back.

See [installation](installation.md) for building and permissions.
