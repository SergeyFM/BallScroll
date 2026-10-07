# BallScroll — Reboot Checklist

The app is built, signed (ad-hoc), and was running healthy for 15h pre-reboot
(`AXTrusted=true`, event tap installed). It is **paused** — the only thing it's
waiting on is a device, which needs **Input Monitoring**, and that grant only
takes effect after a reboot.

## What changed in this build (cdhash `ccf86e52…`)
- The device gate now reads **raw IOHID** (this SDK has no `CGEventGetSource`),
  so it needs **Input Monitoring** in addition to Accessibility. The app now:
  - requests *both* on first run,
  - re-checks both when it's activated and **restarts the gate** if Input
    Monitoring was just granted (no relaunch needed after that),
  - shows both in the menu + Settings banner.

## Step-by-step
1. **Reboot.**
2. After login, BallScroll should be running (or start it — see launch note).
3. Watch `~/ballscroll_debug.log`. When the gate sees the trackball it logs:
   ```
   DEVICE CONNECTED
   ```
4. **Then tell me** (or just use the trackball). I'll read the log, confirm
   the button bits + ball deltas, and verify hold-to-scroll end to end.

## Launch note (pick one)
- **Auto at login** — I can enable the SMAppService login item now so it
  starts on its own after reboot. (Default I'd recommend.)
- **Manual** — `open ~/Documents/Trackball_mac_utility/build/BallScroll.app`
  (or run `./build/BallScroll.app/Contents/MacOS/BallScroll` with
  `BALLSCROLL_DEBUG_LOG=1`).

## If the gate still shows no device after reboot
- Confirm BallScroll is in **System Settings → Privacy & Security**:
  - *Accessibility* (on) — for the event tap.
  - *Input Monitoring → ListenEvent* / HID (on) — for the raw gate.
- The log line `IOHIDManagerOpen=0` + `connected=false` after a reboot means
  the HID grant is still pending; toggle BallScroll in Input Monitoring and it
  will be picked up on the next activation (the gate restarts automatically).
