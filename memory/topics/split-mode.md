# Split dashboard and regular display

Updated: 2026-10-27 (archived session).

Arthur wanted widgets and normal app windows on the Xeneon Edge at the same time. The original app supported only a full dashboard or a regular display (plus a terminal-only side panel), so a custom split mode was built, installed and enabled.

## Controls and current behavior

- Menu bar choices: Dashboard, Split and Regular display. Settings → General selects dashboard side (left/right) and width.
- Arthur's dashboard is on the right, with normal windows using the left side. The final reported dashboard frame was 480 × 690 logical points after preserving the 30-point menu bar area. Earlier width settings should not be treated as the final configuration.
- The dashboard begins below the Edge's menu bar, preserving the full clock/status area; both widgets shrink to fit the shorter panel.
- macOS still sees the full physical display area. The implementation handles overlapping app windows by moving/resizing them into the open part of the Edge; it does not establish a smaller macOS display boundary.
- Placement now responds to windows moving, resizing or opening. It waits until the mouse drag ends before snapping a window out from under the dashboard, with a 3-second periodic check as fallback.
- A lock-screen guard avoids placement errors when macOS hides other apps' windows while locked.
- macOS parks the Dock on the Edge during most wakes (the Edge reconnects before the LG, and the LG often drops out briefly) and shrinks the Edge's windows to clear it. With "Keep the Dock off the Edge" on, the app checks once a second, moves the Dock right after unlock, retries with backoff, and restores the Edge windows' frames saved in memory at lock or sleep (no continuous recording, by Arthur's choice; frames are dropped 20 s after unlock). Added 2026-10-30/31; Arthur confirmed the Dock move works.
- Intended touch behavior is dashboard interaction within the dashboard and ordinary touchscreen behavior in the remaining area; assistant touch testing was unavailable.

## Evidence and outstanding checks

Unit tests, including new split tests, passed. The initial version moved Messages and a window titled “Greg” into the open area, and both remained stable after 20 seconds. The final menu-bar placement was checked with screens awake. Final event-driven snapping was installed but could not be tested live while the Mac was locked; touch also remains unverified by the assistant.

An upstream pull request was opened for split mode and later updated with the menu-bar and snapping fixes. The archived conversation does not provide its URL or report a merge.

Dashboard contents and layout: [custom widgets](dashboard-widgets.md).
