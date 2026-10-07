# BallScroll — Status & Reboot Notes

## Current state: WORKING (verified on this machine)
Hold the small-right button (T‑BC21), roll → cursor pins, page scrolls.
Verified: 16/16 clean `ARMED → SCROLLING → RELEASE` cycles in
`~/ballscroll_debug.log`.

Architecture (modeled on Abnormal Mouse's MoveToScroll, same repo as the
reference behavior):
- **One active CG session event tap** is the entire gesture path — no IOHID in
  the hot loop. (The earlier dual-pipeline design mixed two clocks — IOHID's
  callback time vs `CACurrentMediaTimeNow()` in the tap — so "trackball active"
  was computed wrong and every gesture bailed to pass-through.)
- Hold detection = the tap's `CGEventField.mouseEventButtonNumber` == activator.
  This device's extra button reports **button number 4** (measured; stored in
  `ActivatorButtonCGNumber`). Left button = 0.
- Ball movement while held = the move event's built-in `mouseEventDeltaX/Y`,
  consumed (no cursor drift) + `CGWarpMouseCursorPosition` re-pin each move.
- Scroll output = pixel-unit wheel events, `isContinuous=1`, explicit scroll
  phases (began/changed/ended) — AM's exact event format.
- Device scoping is implicit (like AM): only the T‑BC21 has button 4, so Magic
  Mouse / trackpad events can't arm a gesture (FR‑8). The IOHID gate is now
  cold-path only: connection status for the menu bar + first-run button probe.

## Permissions (the churn is fixed)
- Signed with a **stable self-signed identity** "BallScroll Development"
  (login keychain, cert `/tmp/bsdev.crt`, PKCS12 password `ballscroll`).
  Ad-hoc signing changed the CDHash every build → TCC treated each rebuild as a
  new app and dropped grants (the "it's always been on" problem). `build.sh`
  now signs with that identity (ad-hoc fallback only if the cert is missing).
- Grants that matter: **Accessibility** (event tap) + **Input Monitoring**
  (raw IOHID gate). Both currently ON; a rebuild no longer invalidates them.
- App self-arms via a background poller when grants change (no modal dialogs,
  no relaunch needed).

## Reboot notes
- If BallScroll isn't running after login: `open ~/Documents/Trackball_mac_utility/build/BallScroll.app`
  (login item via SMAppService is available in Settings).
- Health check: `head ~/ballscroll_debug.log` should show
  `engine.start (AM-style single tap): AXTrusted=true enabled=true`,
  `gate started: open=0 connected=true` (open=0 = Input Monitoring OK),
  `event tap installed`.
- If a grant ever drops again (e.g. macOS update): toggle BallScroll back on in
  System Settings → Privacy & Security → Accessibility and Input Monitoring.

## Tuning knobs (UserDefaults `com.sergey.BallScroll`)
- `ActivatorButtonCGNumber` — which button arms (default 4 = small right).
- `ScrollSpeedMultiplier` (3), `InvertScrollDirection`,
  `EnableHorizontalScrolling`, `EmulateInertiaEffect` (off — inertia tail was
  disabled during bring-up; safe to re-enable and test), `ScrollDeadzonePx` (2).
- Debug logging: set `BallScrollDebugLog=1` to keep writing the log file.
