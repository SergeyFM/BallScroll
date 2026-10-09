# PRD — BallScroll

**Product:** BallScroll — a native macOS menu-bar utility that makes the Logitech
Marble/Trackman T-BC21 trackball scroll (hold a button, roll the ball).
**Bundle ID:** `com.sergey.BallScroll` · **Version:** 1.0 (build 1)
**Platform:** macOS 26+, Apple Silicon (arm64). Developed and verified on a Mac
Studio (M2 Ultra), macOS 26.7.1, Swift 6.4 / SDK 27 via Command Line Tools (no
full Xcode — the app is compiled with `swiftc` and assembled into a `.app` by
hand).

**Status: v1.0 IMPLEMENTED and verified working on the target machine.** This
document is a complete re-specification of the *current, shipped app*: every
requirement below describes behavior that exists in `Sources/BallScroll/` today,
including exact constants, strings, defaults and event formats. An implementer
should be able to recreate the app from this document alone.

It owns the trackball's scroll path directly and provides what generic
scroll utilities lack here: a scroll-direction invert, and vertical-only
scrolling with an optional horizontal mode.

---

## 1. Problem & product summary

The user's trackball (**Logitech Marble Mouse / Trackman T-BC21**) has four
buttons and a ball but **no scroll wheel**. BallScroll is a menu-bar agent app:

- While the user **holds the configured "scroll button"**, ball movement is
  converted into scroll-wheel events and the original pointer moves are
  **consumed** (the cursor does not drift).
- **Vertical-only scrolling by default**; horizontal is an explicit toggle.
- **Scroll direction invert** (default ON — the user's preferred convention).
- Speed, inertia, and deadzone tuning; selectable scroll button via live probe.
- Launch at login; two TCC permissions handled with in-app status + deep links.
- When disabled or not running, the trackball behaves 100% natively.

The scroll button is a dedicated button (default: the small-right extra
button). A quick tap on it does **nothing** (no click passthrough); its only
function is hold-to-scroll. The small buttons' default back/forward functions do
not work on macOS anyway, so nothing is lost by owning the button.

### Verified device facts (measured on this machine — trust these, not vendor docs)

| Fact | Value |
|---|---|
| USB level | `idVendor = 0x46D` (Logitech), **USB `idProduct = 0xC3C`** ("USB Trackball") |
| **IOHID layer ProductID** | **`0xC408`** — the ID that `IOHIDManagerSetDeviceMatching` actually matches. Matching 0xC3C at the HID layer yields **zero** devices (verified empirically). Use `{"VendorID": 0x46D, "ProductID": 0xC408}`. |
| IOHID input report | `len >= 3`; **byte 0 = button bitmask** (bit n-1 = libinput `btn_n`). Bits: largeLeft=0, emulated middle=1 (not a real button), largeRight=2, smallLeft(side)=3, **smallRight(extra)=4** |
| CoreGraphics `.mouseEventButtonNumber` (measured) | large left = **0**; small right (the scroll button, "extra" side button) = **4**. Code carries a fallback default of 3 (the standard macOS number for an extra/secondary mouse button) until the probe records the real one. |
| Ball motion in CG events | The move/dragged event's built-in `.mouseEventDeltaX/Y` fields (pixels). |
| Coexisting input devices | Bluetooth Magic Mouse + built-in trackpad ⇒ scoping by device-unique button number is mandatory (see §4.1). |

The T-BC21 has **no discrete middle button** (middle = emulated two-button
combo), so it cannot be the scroll activator.

---

## 2. Scope

### Implemented in v1 (everything in §4–§13 of this doc)
Hold-to-scroll, vertical-only default + horizontal toggle, direction invert,
speed slider, inertia with decay-time tuning, deadzone, scroll-button picker
with live probe (single + sequential modes), device connection status, both TCC
permissions with prompts/polling/deep-links, launch at login (auto-registered),
single-instance guard, sleep/wake recovery, menu-bar icon with attention badge,
Marble Mouse app/menu icons, opt-in debug log file.

### Out of scope / future (not implemented; do not build unless asked)
- Toggle-lock mode (click to arm, click to release — libinput `ScrollButtonLock`).
- Per-app exclusions ("disable for apps listed below").
- Double-tap half-page scroll.
- Tap passthrough (quick tap on the scroll button → native click). Off by design.
- Per-axis direction invert (one global invert only today).
- Modifier-gated horizontal (⌥ for horizontal instead of the plain toggle).
- Pointer acceleration / sensitivity, DPI switching, arbitrary button remapping.

---

## 3. Permissions (TCC) — two grants, both required

| Permission | Gates what | Check API | Request API | Settings deep link |
|---|---|---|---|---|
| **Accessibility** | the active `CGEventTap` (consume + post events) | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` (system prompt, once per code identity) | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| **Input Monitoring** | raw IOHID enumeration + input reports (the device gate, §5) | `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted` | `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` (system prompt) | `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` |

Why both: an active CG session tap needs Accessibility. Input Monitoring is
needed because the app reads raw IOHID reports for device presence and button
probing — `CGEventGetSource` is **absent in this SDK**, so a CG event cannot be
attributed to its HID device; instead the gate owns presence, and gesture
scoping uses a device-unique button number (§4.1).

Behavior:
- **On launch**, if either permission is missing the app fires the native
  system prompts (after a 0.8 s delay; no custom modal dialog — an `.accessory`
  app has no window to host one).
- **A background poller** re-checks both grants every **1.5 s** until both are
  granted, then stops. This is what actually arms the app after the user flips
  the toggles in System Settings — critical because a menu-bar (`.accessory`)
  app **never receives `NSApplication.didBecomeActiveNotification`** reliably,
  so an activation-hook-only re-check is dead code. (The app also hooks
  `didBecomeActiveNotification` as a cheap extra refresh, and re-checks on
  wake.)
- On **Accessibility** change → install or remove the event tap.
- On **Input Monitoring** change to granted → **restart the IOHID gate** (it
  opened before the grant and would otherwise see no device). A non-zero
  `IOHIDManagerOpen` result (e.g. `kIOReturnNoResources`, −536870174) while the
  device enumerates = Input Monitoring missing for this process, not a
  disconnect. Do not read it as "device gone".
- **Fresh grants may need a process restart / reboot** to take effect on some
  macOS versions — the poller + wake path cover the common cases.
- The settings window shows a warning row per missing permission: orange
  ⚠︎ + "`<name>` permission required" + **"Open System Settings…"** button.
- Code identity matters: TCC binds grants to the signing identity (CDHash).
  Ad-hoc signing changes it every build and orphans grants — sign with the
  stable self-signed identity from §12.

---

## 4. Core scroll engine (the heart of the app)

**Architecture:**
- **ONE active CG session event tap is the entire gesture hot path.** No IOHID
  in it. (The original dual pipeline — IOHID activity gate + CG tap — mixed two
  clock domains: an IOHID callback timestamp vs `CACurrentMediaTimeNow()` in
  the tap reads millions of seconds stale, so "trackball active" was always
  false and every gesture bailed to pass-through. The IOHID gate is therefore
  **cold-path only**: connection status + button probing.)
- Hold detection = `event.getIntegerValueField(.mouseEventButtonNumber)` on the
  down/up event equals the configured activator number.
- Ball movement while held = the move/dragged event's built-in
  `.mouseEventDeltaX/Y`, accumulated, consumed, with the cursor re-pinned each
  move via `CGWarpMouseCursorPosition`.

### 4.1 Device scoping (implicit)
The activator is a **button number**, and only the T-BC21 sends its extra
buttons — Magic Mouse and the trackpad can never arm a gesture. All other
events pass through untouched at every state. No per-event IOHID lookup (that's
why the tap is fast enough to stay native-feeling).

### 4.2 Event tap
- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .defaultTap /* active: may consume */, eventsOfInterest: mask)`.
- **Mask** (bitwise OR of `1 << rawValue`): `mouseMoved`,
  `leftMouseDragged | otherMouseDragged | rightMouseDragged`,
  `leftMouseDown | leftMouseUp`, `rightMouseDown | rightMouseUp`,
  `otherMouseDown | otherMouseUp`. (Scroll-wheel events are not tapped; nothing
  rewrites them.)
- Source created via `CFMachPortCreateRunLoopSource`, added to the **main run
  loop, `.commonModes`**, then `CGEvent.tapEnable`.
- **Self-heal:** if the callback receives `.tapDisabledByTimeout` or
  `.tapDisabledByUserInput`, re-enable the tap and pass the event through.
- Install only when Accessibility is trusted and the engine is enabled; remove
  (disable + invalidate) otherwise. On wake from sleep, reinstall (replace).

### 4.3 State machine
All state lives on the **main run loop only** (tap callback and gate callbacks
are both scheduled there; no cross-thread handoff).

```
IDLE ──activator down──▶ ARMED (pin cursor at event location; consume the down)
ARMED ──move past deadzone──▶ SCROLLING (post .began frame carrying that move's delta)
ARMED ──activator up (no scroll yet)──▶ IDLE  (a tap does nothing; consume the up)
SCROLLING ──activator up──▶ IDLE (end scroll; inertia tail if any)
```

Rules per state, in the tap callback:

- **Probe mode override:** while a button probe is active (settings picker or
  first-run), every down records `lastSeenCGButton` and drives the live red
  feedback (`noteActivator(pressed:)`), every paired up clears it, and **all
  events pass through** (the probe never consumes).
- `IDLE`: only the activator's **down** arms (consume it — no click leaks).
  Everything else passes through. On the activator's down/up, also drive live
  "button held" feedback for the settings window (red while held).
- `ARMED`: the activator's **up** → disarm, consume (tap = nothing). Any move
  (`mouseMoved`/any `*Dragged`) → accumulate + consume (no cursor drift). Any
  other button's event passes through untouched while holding.
- `SCROLLING`: moves accumulate + consume; the activator's **up** ends scrolling
  (consume it). No watchdog: a pure hold with no motion simply stays armed until
  the paired up arrives — moves are what scroll, and the up always ends it.

**Arming (`arm`):** capture `pinnedLocation = event.location`; zero the
accumulators and velocity. If an inertia tail from a previous gesture is still
running, post its `.ended` frame and stop it — never leave a began-without-ended
sequence (apps key on the final phase).

**Cursor pin:** after every accumulated move, `CGWarpMouseCursorPosition(pinnedLocation)`
(consumed moves can still cause sub-pixel drift; the warp is belt-and-suspenders).

### 4.4 Deadzone (FR-13)
While `ARMED`, accumulate `.mouseEventDeltaX/Y` into `(armedDX, armedDY)`.
Scrolling starts when **either** `abs(armedDX)` or `abs(armedDY)` reaches the
configured deadzone (pixels, default 2; slider 0–100). Before that the moves
are consumed (no drift, no scroll) — this absorbs ball wobble / hand tremor.

### 4.5 Scroll output (exact event format — replicate precisely)
For each move in `SCROLLING` (and the deadzone-crossing frame), build:

```swift
CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: Int32(verticalPx.rounded()),   // axis 1 = VERTICAL, pixels
        wheel2: Int32(horizontalPx.rounded()), // axis 2 = HORIZONTAL, pixels
        wheel3: 0)
```

Then set (raw field numbers — this SDK's Swift overlay lacks the subscripts, so
use `CGEventField(rawValue:)`):

| Field | Value | Notes |
|---|---|---|
| **88** (`IsContinuous`) | `1` | every frame — smooth/continuous scroll |
| **99** (`ScrollPhase`) | `phase.rawValue` | `.began=1`, `.changed=2`, `.ended=3` — explicit phases, not left unset |
| `.scrollWheelEventPointDeltaAxis1` | same rounded vertical px | point-delta fields kept **consistent** with the wheel fields (set them equal) |
| `.scrollWheelEventPointDeltaAxis2` | same rounded horizontal px | |
| **101** | `4` | **only on `.changed` frames**; an empirically required "magic" value for smooth continuous scrolling |

Post with `ev.post(tap: .cghidEventTap)`. Release the event.

**Phase discipline:**
- First scroll frame after deadzone is `.began` and **carries that move's delta**
  (folding began+first-changed into one frame keeps a 60 Hz pipeline lossless).
- Subsequent moves: `.changed`.
- On release from `SCROLLING`: **do not post `.ended` immediately** if an inertia
  tail will run — the tail continues the same gesture and posts the final
  `.ended`. Posting `.ended` before the momentum deltas makes apps treat them as
  "outside a gesture" and some drop them. If there is no tail (inertia off or
  below threshold), post `.ended` right away.
- **Inertia tail frames must be posted through the same wheel-field path** (real
  `wheel1/wheel2` pixel deltas). An earlier bug built momentum events with
  `wheel1/wheel2 = 0` and only the point-delta fields — but a continuous
  pixel-wheel reads its movement from `wheel1/wheel2`, so every momentum frame
  moved 0 px and the effect was invisible.

### 4.6 Translation (where the features live)
For a move delta `(dx, dy)` in CG pixels:

- `verticalPx = dy * speed`
- `horizontalPx = dx * speed` **only if horizontal scrolling is enabled**, else 0.
- Multiply both by `sign = invertDirection ? -1 : +1`.

Settings are read **live per event** from the model — every toggle/slider applies
immediately, even mid-scroll; no engine restart.

- **Vertical-only by default** (G1): horizontal component ignored unless the
  user enables it.
- **Invert** (G2): one global sign flip, from the menu-bar quick toggle or
  settings. **Default ON** in v1 (user's preferred convention).

### 4.7 Inertia / momentum tail (FR-7)
- **Velocity tracking during scroll:** `CACurrentMediaTimeNow()` is a
  monotonic mach-time clock returning **NANOSECONDS** (it multiplies ticks by
  numer/denom but omits the ÷1e9 its name implies — a dt of ~2×10⁷ means 20 ms).
  Convert to **seconds** before dividing. Instantaneous posted speed per axis:
  `inst = delta * speed / dtSec` px/s; guard `dtSec > 0.001` (skip
  same-timestamp batches). Smooth into `(velocity.x, velocity.y)` with a light
  low-pass: `v += (inst − v) * 0.4`. Track both axes so horizontal flings get
  inertia too.
- **On release from SCROLLING**, start a tail only if `emulateInertia` is on
  **and** release speed `|v| > 25` posted px/s (below that it's a nudge, not a
  fling). Otherwise no tail.
- **Tail dynamics** — the lever is "how long after release it takes to stop":
  - Tick every **1/60 s** (timer `tolerance = 0.01`, main run loop, common modes).
  - Decay `T = max(0.02 s, inertiaDecayMs / 1000)` (slider: **25 ms…1000 ms**,
    default 80, log-scaled in the UI).
  - Frame gain `f = e^(−4·t/T)` (pure exponential, perfectly smooth — ≈91% of
    release speed at t=T/5, ~2 % (imperceptible) exactly at T).
  - Each frame posts `.changed` with `v_y·f·tick` (and `v_x·f·tick` for axis 2
    only if horizontal is enabled), with the current invert sign.
  - Stop when per-frame movement `f·|v| < 0.5 px/frame` (lands just after T) or
    the state machine re-armed; then post the final `.ended`.

### 4.8 Live "button held" feedback (settings UI)
Driven by **real button edges** from the tap: `noteActivator(pressed: true)` on
the activator's down, `false` on the paired up (hopped to main). The settings
button stays **bright red for exactly as long as the trackball button is held** —
no timed flash (a quick tap must not miss it, and a long hold must stay red).
A 5 s safety `DispatchWorkItem` clears the state if an up event is ever lost
(e.g. trackball unplugged mid-press).

---

## 5. TrackballGate — IOHID cold path (presence + probing)

`TrackballGate.swift`. Owns one `IOHIDManager`:

- **Match:** `[("VendorID", 0x46D), ("ProductID", 0xC408)]` (HID-layer IDs — §1).
- **Schedule on the MAIN run loop** (`CFRunLoopGetMain()`, common modes) — a
  bare `RunLoop` on a GCD worker thread can trap under this SDK, and the main
  loop is already spinning. All gate callbacks therefore fire on main (keep them
  light); state is additionally lock-guarded.
- **Input report callback:** `len >= 3`; byte 0 = button bitmask; diff against
  previous mask → fire `onPress(bit, timestamp)` / `onRelease` on edges.
- **Device matching/removal callbacks:** update `connected`; deliver
  `onChange(Bool)` on main. If devices are already present at start (device
  plugged in before launch), call `IOHIDManagerCopyDevices` and count via the CF
  API — casting the CFSet to `[IOHIDDevice]` always fails.
- **`IOHIDManagerOpen != 0`** (e.g. `kIOReturnNoResources`) → Input Monitoring
  not granted for this process; log it, keep going (gate sees no reports until
  the grant; AppDelegate restarts the gate when the grant appears).

Roles (cold path only — never consulted per gesture event):
1. **Connection status** → menu-bar icon badge, dropdown status line, settings
   device row (`prefs.trackballConnected`).
2. **Button probing** (§8.4): `onPress` while a probe is active records the
   physical bit for the probed position.

Button bit indices: `largeLeft=0, middleEmul=1 (not real), largeRight=2,
smallLeft=3, smallRight=4` — default activator = `smallRight`.

---

## 6. App shell & lifecycle (`main.swift`, `AppDelegate.swift`)

- Entry: plain `NSApplication.shared` + `AppDelegate`, `app.run()` (no @main,
  no storyboard). Info.plist has `LSUIElement = true`.
- **Launch sequence** (`applicationDidFinishLaunching`), in order:
  1. **Single-instance guard:** other running apps with bundle ID
     `com.sergey.BallScroll` (excluding own pid) → log and terminate. Two
     instances with the same bundle ID both consume/post events and fight.
  2. `NSApp.setActivationPolicy(.accessory)` (menu-bar only).
  3. Create `NSStatusItem` (variable length) and build the menu (§7.1).
  4. **Re-apply the icon once on the next run-loop turn**: `statusItem.button`
     can be nil on the first turn after creation; without this, the menu bar
     shows nothing (or a stale icon) until the first click.
  5. Wire engine callbacks: `onProbeButtonPressed` (gate bit edge → after a
     **0.15 s delay** on main, so the engine-side CG down has landed first and
     `lastSeenCGButton` is fresh) → `prefs.handleProbedButton(bit:)`;
     `onProbeCGDown` → `prefs.lastSeenCGButton`.
  6. Start the engine: `BallScrollEngine.shared.start(prefs:, enabled:)` —
     initially enabled only if both permissions are already granted.
  7. Hook `didBecomeActiveNotification` → permission re-check (cheap extra; the
     poller is the real mechanism, §3).
  8. **Combine sinks** on `prefs.$trackballConnected`, `$hasAccessibilityPermission`,
     `$hasInputMonitoringPermission` → `rebuildMenu()` immediately, so the icon's
     "!" badge clears the moment state changes (fixes: icon stuck on the
     attention mark until a click).
  9. Register `NSWorkspace.didWakeNotification` → `engine.handleWake()` (reinstall
     tap) + menu refresh.
  10. **Launch-at-login: auto-enable on first launch** — if the login item is
      not registered, set it (idempotent). The app is intended as a normal
      always-on utility.
  11. Start the permission poller (§3).
  12. **First-run flow:** if either permission is missing → fire native prompts
      (0.8 s delay). Else, if the button probe was never completed → open the
      Settings window and `startSequentialProbe()`.
- **Quit:** stop engine (remove tap, stop gate), persist preferences.
- `NSSupportsAutomaticTermination = false`, `NSSupportsSuddenTermination = false`.

---

## 7. UI specification

### 7.1 Menu bar
- **Icon:** the Marble Mouse device drawn as a **template image** (monochrome +
  alpha cutouts, §8), 18 pt @2x. `isTemplate = true` so macOS tints it for
  light/dark bars — a colored status image would vanish on one of them. When
  attention is needed (`!(Accessibility && Input Monitoring && trackball
  connected)`), an **"!" badge** (dot + bar, black) is drawn top-right; the
  icon's accessibility description switches to "BallScroll — attention needed".
- **Dropdown menu** (NSMenu), top to bottom:
  1. Disabled status line, one of:
     - `"Permissions needed (Accessibility / Input Monitoring)"` — either grant missing
     - `"Trackball not detected"` — grants OK, device absent
     - `"BallScroll is functioning."` / `"BallScroll is not enabled."` — device present, user toggle on/off
  2. Separator
  3. `"Enable"` / `"Disable"` — global on/off (persists; engine `isEnabled`
     = Accessibility && Input Monitoring && user-enabled)
  4. `"Invert scroll direction: Normal"` / `": Inverted"` — one-click flip, persists
  5. Separator
  6. `"Show Preferences…"` (⌘,)
  7. `"Quit BallScroll"` (⌘Q)

### 7.2 Settings window
**Container:** `NSWindowController` hosting a SwiftUI view via
`NSHostingController`. Title `"BallScroll"`. Style `[.titled, .closable,
.miniaturizable]` — **fixed width (540 pt), no resize**, height follows the
content exactly (no dead space). `window.appearance = NSAppearance(named: .aqua)`
**forced**, so toggles/sliders keep full color when the window is unfocused.
Closing the window (via `windowWillClose`) fires a callback that switches the
app back to `.accessory`.

**Activation policy dance:** opening settings → `setActivationPolicy(.regular)`
+ activate (Dock icon appears while the window is open — "normal app" feel);
closing → back to `.accessory` (menu-bar only).

**Layout:** single page, **no tabs**, left-aligned VStack `spacing: 18`,
`padding: 16`: `scrollSection` — divider — `behaviorSection` — divider —
`generalSection`. Every option row carries a SwiftUI native `.help("…")` hover
tooltip (verbatim texts below). All changes call `prefs.persist()` on change and
apply live to the engine.

**Section 1 — Scroll button:**
- HStack (spacing 26): on the left a **decorative red ball** (74 pt, not
  clickable; radial gradient + the shared icon's speckle texture + 2 pt dark
  ring). On the right:
  - **One big "Set scroll button" button** (240×54, corner radius 8): SF Symbol
    `cursorarrow.click.2` + semibold label, white text on the fill. Resting
    fill: dark grey `rgb(0.32, 0.34, 0.37)`. **While the currently-set trackball
    button is physically held: bright red `rgb(1.0, 0.24, 0.2)`** (edge-driven,
    §4.8). While a probe is active the label switches to "Press it on the
    trackball" (clicking again cancels).
    - Tooltip: *"Click, then press the trackball button you want to use for scroll. While that button is held on the trackball, this button stays bright red."*
  - **Status text:** `"Currently selected button: <N>"` (13 pt semibold,
    monospaced digits) where N = the CG `.mouseEventButtonNumber` — **code-first
    UI, no button-name labels**.
    - Tooltip: *"This is the button number macOS sees when you press your scroll button. Press and hold that button on the trackball — \"Set scroll button\" above turns bright red while you're holding it, proving it's wired up. Change it by clicking the button and pressing a different one."*
  - **While probing:** blue dot (7 pt) + caption — sequential mode shows the
    step text, single mode shows *"Waiting — press the button you want to use for scrolling."* + a small **Cancel** button.
- If the sequential probe was never completed: a small **"Probe all buttons…"**
  button under the section.
    - Tooltip: *"Walks through every trackball button in turn and records each one. Usually not needed — the \"Set scroll button\" flow above is enough for a single scroll button."*

**Section 2 — Behavior (top to bottom):**
1. Toggle (switch) **"Invert scroll direction"** — default **ON**.
   Tooltip: *"Reverses the scroll direction: rolling the ball forward scrolls down instead of up (or vice versa)."*
2. Toggle **"Enable horizontal scrolling"** — default **OFF**.
   Tooltip: *"Rolling the ball side to side scrolls horizontally (wide pages, timelines). Off = only vertical scrolling."*
3. **"Scroll speed"** label + right-aligned value (1 decimal) + **Slider 1…20**
   (continuous; default 3).
   Tooltip: *"How far the page moves per unit of ball rotation. Higher = faster scrolling."*
4. Toggle **"Emulate inertia effect"** — default **ON**.
   Tooltip: *"Adds a short glide after you stop rolling, so scrolling feels like it has momentum instead of stopping instantly."*
5. **"Inertia decay time"** label + right-aligned value — displayed `"<n> ms"`
   below 100, else `"<s>s"`. **Log-scaled slider** (position 0…1 ↔ decay
   25…1000 ms; `value = min·(max/min)^position`) — fine precision at the low
   end, coarser toward 1 s. **Disabled while inertia is off.**
   Tooltip: *"How long the scroll keeps coasting AFTER you release — a smooth brake from your release speed down to a stop. Lower = stops almost immediately (25 ms ≈ no visible inertia); higher = it keeps rolling for a while (1 s is a long roll-out). The scale is logarithmic, so the left half gives fine control in the low range where 'barely any inertia' lives."*
6. **"Scroll deadzone"** label + right-aligned value `"<n> px"` + **Slider 0…100**
   (default 2).
   Tooltip: *"How much tiny ball wobble (in pixels of raw movement) to ignore before scrolling starts. Stops a loose/wobbly ball or hand tremor from causing accidental scroll jumps. 0 = off (most responsive)."*

**Section 3 — General:**
1. Toggle **"Automatically start at login"** (SMAppService-backed, §9).
   Tooltip: *"Launch BallScroll automatically when you sign in to macOS, so your trackball scroll button works from boot. While the settings window is open the app also shows its icon in the Dock; when it's closed only the menu-bar icon remains."*
2. Divider, then **device status row:** green/red dot (10 pt) + text:
   - connected: `"Logitech USB Trackball (0x46D:0xC3C) connected"`
   - not connected, IM granted: `"Trackball not connected"`
   - IM missing: `"Trackball not detected — needs Input Monitoring"`
3. Conditional **permission rows** (only for missing grants): orange
   ⚠︎ + `"<Permission> permission required"` + **"Open System Settings…"**
   button (deep links, §3).
4. Divider, then **About footer:** 28 pt app icon (shared renderer) +
   `"BallScroll <CFBundleShortVersionString>"` (semibold) and caption
   *"Hold the scroll button and roll to scroll."*

### 7.3 Button probe flows (`PreferencesModel`)
Two modes, both driven by real device events:

**Single (picker) — "Set scroll button":**
1. Click → `probeActivePosition = <any>`, `probeSequential = false`; any press wins.
2. User presses a trackball button: the gate's bit edge + (0.15 s later)
   `handleProbedButton(bit:)` runs; the engine's CG down has already recorded
   `lastSeenCGButton`.
3. Record: swap-disambiguate the bit if another position claimed it; then
   `activatorBit = <bit>`, **`activatorCGButton = lastSeenCGButton`** (the
   number the engine actually matches), end probe, persist.
4. Status: `"Scroll button set — Button <N>."` (code-first confirmation).

**Sequential ("Probe all buttons…", first run):**
1. Walk `largeLeft → largeRight → smallLeft → smallRight`; per step status:
   `"Now press the \"<displayName>\" button on the trackball…"`.
2. Each press records `probedBits[position] = bit` (with swap-disambiguation so
   each physical button stays 1:1), advances to the next step, persists.
3. After the fourth: `probeCompleted = true`, status
   `"Done — all button bits recorded."`

Physical bit resolution: `bit(for:) = probedBits[pos] ?? pos.defaultBit` —
probed values replace the libinput-derived defaults (0/2/3/4); until probed,
the engine still works from factory defaults (it matches the CG number anyway).

---

## 8. Icon & branding (`BallScrollIconRenderer.swift`, `Resources/`)

One **shared draw function** renders the device in two modes so all icon
surfaces match (app icon, menu-bar icon, settings decorative ball/footer):

**Device geometry** (in a square of side `s`): superellipse "pebble" body
(`n = 3.2`, half-widths `hw = 0.315·s`, `hh = 0.34·s`, centered slightly above
middle: `cy − 0.005·s`). Trackball center at `(cx, cy + 0.52·hh)`; ball radius
`0.13·s`; recessed well radius `0.168·s`. Two click buttons
(`w = 0.132·s`, `h = 0.078·s`, gap offset `0.066·s` from center, row at
`cy − 0.152·s`) and a narrow wheel slot between them (`w = 0.05·s`, same row).

**Template mode (menu bar):** body = solid black silhouette; ball socket
(`0.9·ballR` radius, leaving a rim so it reads as an indented well), both
button slots (inset + rounded) and the wheel slot are **cut out to
transparent** (`compositingOperation = .clear`) so the menu-bar background shows
through — a detailed, recognizable trackball at 18 pt instead of one merged
blob. `isTemplate = true` → macOS tints per bar theme. Warning state adds the
"!" badge (black dot + rounded bar, top-right).

**Color mode (app icon / settings):** dark rounded-square face
(gradient `rgb(0.145, 0.157, 0.188) → rgb(0.078, 0.090, 0.114)`, corner radius
`22.37 %`). Flat dark-grey pebble body (`rgb(0.27, 0.295, 0.34)`). Recessed
well: black 40 %-alpha stroke, width `max(1, 0.024·s)`. Glossy red ball:
radial gradient `rgb(0.99, 0.47, 0.42) → rgb(0.93, 0.20, 0.23) →
rgb(0.58, 0.06, 0.10)`, relative center `(−0.32, +0.4)`; white highlight oval
(alpha 0.8→0) at −65°. **Texture speckles:** 128 deterministic dots in
ball-radius units — uniform-area disk fill (golden angle `π(3−√5)`, max radius
0.94), per-dot size jitter 0.6–1.4× a base of `0.027·ballR`, black at 34 %
alpha, clamped to ≥ 0.5 px — dense even field like the real Marble Mouse
surface (deterministic, no RNG, so icon and settings ball always match).
Buttons: grey `rgb(0.42, 0.45, 0.5)` rounded rects; wheel:
`rgb(0.5, 0.53, 0.58)` with 3 dark grooves (stroke `rgb(0.2, 0.215, 0.245)`,
alpha 0.9).

**App icon file:** `Resources/make_icon.swift` (standalone AppKit script)
renders the same device into a full-face dark rounded square for all iconset
scales (its body uses a 3-stop vertical gradient + subtle rim — the one place
the standalone .icns differs slightly from the in-app flat-grey body) →
`iconutil -c icns AppIcon.iconset -o AppIcon.icns`. `Resources/AppIcon.icns`
ships in the bundle; Info.plist sets `CFBundleIconFile = AppIcon`. The settings
decorative ball (74 pt) re-uses `ballSpeckles` + the same gradient colors.
(`Resources/red_ball.webp` is a design reference image, not used at runtime.)

---

## 9. Launch at login (`LoginItem.swift`)

- `SMAppService.mainApp` (macOS 13+ API; no helper bundle needed).
- `isRegistered` ⇔ `status == .enabled`; toggle calls `register()` /
  `unregister()`, logs + returns false on error.
- The settings toggle binds to it (persist via the service, re-read status).
- AppDelegate **auto-registers on launch** if not registered (the app is a
  normal always-on utility). The login item must point at the **`/Applications`
  bundle** — hence the installer step in build.sh (§12).

---

## 10. Configuration (UserDefaults, domain `com.sergey.BallScroll`)

All keys, types and **shipped defaults**:

| Key | Type | Default | Range/notes |
|---|---|---|---|
| `BallScrollEnabled` | Bool | **true** | global on/off (menu bar + engine) |
| `InvertScrollDirection` | Bool | **true** | v1 default is INVERTED (user preference) |
| `EnableHorizontalScrolling` | Bool | **false** | vertical-only default |
| `ScrollSpeedMultiplier` | Double | **3.0** | slider 1…20 continuous |
| `EmulateInertiaEffect` | Bool | **true** | momentum tail on/off |
| `InertiaDecayMs` | Double | **80.0** | 25…1000 ms, log slider in UI; brake-to-stop time (§4.7) |
| `InertiaStrength` | Double | — (legacy) | old 0.1…3.0 lever, kept **only** for one-time migration: if `InertiaDecayMigrated` is unset and a legacy value exists → `decay = clamp(40 + old·300, 25…1000)`, set flag, persist. (A dedicated flag is required because `register(defaults:)` puts a default under the new key, so "unset" can't be detected otherwise.) |
| `InertiaDecayMigrated` | Bool | false | migration flag (set true after migration) |
| `ScrollDeadzonePx` | Double | **2.0** | slider 0…100 px; either-axis crossing starts scroll |
| `ActivatorButtonBit` | Int | **4** (= smallRight) | physical HID bit of the activator (probe-updated) |
| `ActivatorButtonCGNumber` | Int | 3 (fallback) | CG `.mouseEventButtonNumber` the engine matches; **4 on the verified device** (set by probe) |
| `ProbedButtonBits` | JSON `[positionRaw: bit]` | `{}` | probe results; position raws 0=largeLeft, 1=largeRight, 2=smallLeft, 3=smallRight |
| `ButtonProbeCompleted` | Bool | false | sequential probe finished → hides "Probe all buttons…" and gates first-run flow |

Persist on every settings change + on quit. `loginItemEnabled` is **not** a
UserDefaults value — it mirrors the SMAppService registration state.

Debug flag (separate concern): `BallScrollDebugLog` Bool, or env
`BALLSCROLL_DEBUG_LOG`, enables §13.

---

## 11. Architecture & file map

```
Sources/BallScroll/
├── main.swift              # entry: NSApplication + AppDelegate, app.run()
├── AppDelegate.swift       # menu bar shell, status item + dropdown, permission
│                           #   prompts/poller/wake, first-run flow, activation policy dance
├── BallScrollEngine.swift  # the event tap + state machine + scroll posting + inertia
├── TrackballGate.swift     # IOHIDManager (cold path): presence + probe edges; DebugLog
├── AXPermissions.swift     # the two TCC checks/prompts/deep links
├── Settings.swift          # PreferencesModel (ObservableObject) + keys/defaults/probe logic
├── SettingsWindow.swift    # NSWindowController + SwiftUI single-page settings
└── BallScrollIconRenderer.swift  # shared device drawing (template + color modes)
Resources/
├── Info.plist              # bundle metadata (§12)
├── AppIcon.icns            # generated by make_icon.swift via iconutil
├── make_icon.swift         # standalone AppKit iconset generator script
└── red_ball.webp           # design reference (not used at runtime)
build.sh                    # compile + bundle + sign + install (§12)
```

**Threading model:** everything UI- and gesture-relevant runs on the **main run
loop**: tap callback (scheduled there), IOHID callbacks (manager scheduled on
the main loop, common modes), inertia timer, permission poller. Gate state is
additionally lock-guarded (cheap; defensive). Settings values are plain
`@Published` properties read directly by the tap callback each event — no
actors, no hops, allocation-light (native-feeling latency is a hard requirement).

**Why this shape (keep it if recreating):**
- Single CG tap for the whole gesture path — one active session tap handles
  hold detection, movement capture and scroll posting with no second pipeline.
- IOHID cold path only — mixing an IOHID activity check into the per-event path
  is how this project first failed (two clock domains; see pitfalls §15).
- Device scoping by device-unique button number (not per-event source lookup —
  `CGEventGetSource` doesn't exist in this SDK).

---

## 12. Build, signing & install (`build.sh`, `Resources/Info.plist`)

**Compile (no Xcode):**
```bash
xcrun swiftc -O -target arm64-apple-macosx26.0 \
  -framework AppKit -framework SwiftUI -framework CoreGraphics \
  -framework IOKit -framework ServiceManagement -framework Combine \
  Sources/BallScroll/*.swift -o build/BallScroll.app/Contents/MacOS/BallScroll
```
Assemble the bundle: `Contents/MacOS/BallScroll`, `Contents/Info.plist`,
`Contents/Resources/AppIcon.icns`, `PkgInfo = "APPL????"`; strip quarantine.

**Info.plist essentials:**
`CFBundleIdentifier = com.sergey.BallScroll`; `CFBundleExecutable/Name/
DisplayName = BallScroll`; `CFBundleIconFile = AppIcon`;
`CFBundleShortVersionString = 1.0`, `CFBundleVersion = 1`;
`LSUIElement = true`; `NSPrincipalClass = NSApplication`;
`LSMinimumSystemVersion = 26.0`; `NSSupportsAutomaticTermination/Sudden
Termination = false`.

**Signing — the stable-identity requirement (do not skip):** TCC binds grants
to code identity. **Ad-hoc signing changes the CDHash on every rebuild → each
rebuild looks like a new app and silently drops the Accessibility/Input
Monitoring grants** (the classic "I already enabled it" churn). Sign with a
stable self-signed identity:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout bsdev.key.pem -out bsdev.crt -subj "/CN=BallScroll Development"
openssl pkcs12 -export -out bsdev.p12 -inkey bsdev.key.pem -in bsdev.crt
security import bsdev.p12 -k ~/Library/Keychains/login.keychain-db
codesign --force --sign "BallScroll Development" BallScroll.app
```

build.sh checks for the identity (`security find-identity -p codesigning | grep
"BallScroll Development"`) and falls back to ad-hoc only when absent, so a fresh
machine still builds. (Gotcha: `security find-identity -v` does NOT list a
self-signed cert — drop the `-v`, or trust it first.)

**Install:** canonical copy is **`/Applications/BallScroll.app`** (the login
item and TCC both track that bundle): `pkill -f "BallScroll.app/Contents/MacOS/BallScroll"`,
`rm -rf /Applications/BallScroll.app`, `cp -R build/... /Applications/`,
re-sign there, strip quarantine. Never run the app from `build/` alongside an
installed copy (second instance, same bundle ID → double event handling).

**Coexistence:** avoid running other utilities that consume the same mouse
button or rewrite scroll events at the same time — two active event taps on the
same button double-transform events.

---

## 13. Debug logging (`DebugLog` in TrackballGate.swift)

Opt-in trace of gate + state-machine events (ARMED/SCROLLING/RELEASE with
deltas, velocities, tail start/stop, tap install, gate open result):

- Enabled by env `BALLSCROLL_DEBUG_LOG` **or** UserDefaults
  `BallScrollDebugLog = 1` (the UserDefaults key survives reboot when the app is
  launched by LaunchServices, which env vars don't).
- Writes to NSLog **and** appends lines `[BallScroll] …` to a plain-text file:
  default `~/ballscroll_debug.log`, overridable via env
  `BALLSCROLL_DEBUG_LOG_FILE` (`~` expanded). File writes are lock-guarded;
  high-frequency report logging is throttled (≥1 s apart) while state
  transitions log unthrottled.

---

## 14. Acceptance criteria (verified on the target machine)

1. Holding the scroll button and rolling **up/down** scrolls the focused window
   vertically; a purely sideways roll produces no scroll (horizontal off).
2. Toggling horizontal on makes sideways rolls scroll horizontally; persists.
3. Flipping invert (menu or settings) reverses direction immediately, even
   mid-scroll; persists across app and Mac restarts. Default is inverted.
4. A quick tap on the scroll button emits no click and scrolls nothing;
   holding + rolling never moves the cursor (pinning works).
5. "Set scroll button" picker: click, press a different physical button → it
   becomes the activator (its CG number + bit recorded, red feedback proves the
   wiring); persists. Sequential probe records all four buttons.
6. Speed slider (1–20), inertia toggle, decay-time log slider (25 ms–1 s),
   deadzone slider apply live and persist. Inertia produces a real momentum
   glide that brakes to a stop in ≈ the set decay time.
7. Works in major apps (Safari, Chrome, Finder, Notes, Xcode).
8. Magic Mouse and trackpad are completely unaffected (device scoping holds).
9. Unplug/replug the trackball: status updates, scrolling resumes without an
   app restart. Sleep/wake: tap reinstalled, works after wake.
10. After reboot: login item starts the app (from /Applications), permissions
    hold (stable signing identity), scrolling works.
11. With a permission missing: native prompt on launch, warning rows in
    settings, "!" badge + status line in the menu; granting (poller or
    re-check) arms the app with no relaunch.
12. Disabled or quit: trackball behaves 100% natively (tap removed / pass-through).
13. Menu-bar icon visible at launch in both light and dark bars, "!" badge
    tracks real state (cleared by state change without a click).

---

## 15. Pitfalls checklist (hard-won — read before reimplementing)

1. **HID-layer ProductID ≠ USB idProduct.** Match IOHID on `0x46D:0xC408`,
   not the USB-level `0xC3C` (verified: 0 devices vs 1).
2. **One clock domain.** Never compare an IOHID callback timestamp against
   `CACurrentMediaTimeNow()` in the tap — they read millions of seconds apart.
3. **`CACurrentMediaTimeNow()` returns nanoseconds.** Divide by 1e9 before
   using as seconds (or your velocity is ~10⁻⁶ px/s and inertia never fires).
4. **Inertia frames need real `wheel1/wheel2` pixel deltas** — point-delta-only
   momentum events move 0 px.
5. **Phase order matters:** the final `.ended` must come after all momentum
   frames; a began-without-ended or ended-then-changed confuses apps.
6. **Ad-hoc signing churns TCC.** Stable self-signed identity + stable bundle ID
   or grants die on every rebuild. If they're already stale: `tccutil reset
   Accessibility com.sergey.BallScroll` / `… ListenEvent …`, then re-grant.
7. **`.accessory` apps don't get `didBecomeActiveNotification`.** Poll the TCC
   state (1.5 s) until granted — a fresh grant also sometimes needs a restart.
8. **`statusItem.button` can be nil on the first run-loop turn** — re-apply the
   icon once async or the menu bar item is invisible/stale at launch.
9. **Menu-bar icon must be a template** (black + alpha, `isTemplate = true`)
   or it vanishes in one bar theme. Cut details to transparency for detail at 18 pt.
10. **`IOHIDManagerOpen = kIOReturnNoResources` (−536870174)** with the device
    enumerating = Input Monitoring missing, not "device gone".
11. **A bare `RunLoop` on a GCD thread can trap** for IOHID scheduling — use
    the main run loop. `IOHIDManagerCopyDevices` returns a CFSet — count via
    the CF API, don't cast to an array.
12. **C `k`-prefixed IOKit constants import verbatim** (`kIOHIDRequestTypeListenEvent`);
    the Swift dot form doesn't exist for these.
13. **Synthetic self-test before blaming hardware:** post a `CGEvent` and check
    your own tap callback fires; if synthetic events are seen but physical ones
    aren't, it's "nobody at the device" (or wrong session), not a broken tap.
    CLI-launched probes can miss GUI-session input — test inside the `open`-launched `.app`.

---

## 16. Future work (post-v1, not in the app)

- Toggle-lock mode (radio: hold-to-scroll / toggle lock).
- Per-app exclusion list; modifier-gated horizontal (⌥) as an alternative to
  the plain toggle.
- Double-tap half-page scroll; optional tap passthrough on a quick tap of the
  activator.
- Per-axis invert; per-app speed profiles if ever wanted.
