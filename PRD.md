# PRD — BallScroll

**Target:** macOS on Apple Silicon (Mac Studio, M2 Ultra)
**Owner/author:** Sergey
**Status:** Ready for development (v2.1, 2026-10-06) — all decisions resolved
**Build vs. buy:** **BUILD** (decided). Replaces Abnormal Mouse's scroll function.

---

## 1. Problem statement

The user works with a **Logitech Marble Mouse / Trackman (model T-BC21)** — an old USB
trackball that has **four buttons and a ball, but no scroll wheel**. To scroll on macOS the
user currently relies on **Abnormal Mouse** ("Move to Scroll"): hold **button 5**, roll the ball.

Two concrete pain points with Abnormal Mouse:

1. **No scroll-direction control.** No way to invert the direction; it doesn't match the
   trackpad ("natural" scrolling) convention.
2. **Scroll fires in every direction.** Abnormal Mouse converts the ball's 2D movement into
   scroll on both axes, so any sideways/diagonal roll scrolls horizontally. The user wants
   scrolling **limited to vertical (up/down)** by default, with horizontal available as an
   explicit setting.

Additionally, the small left/right buttons' default functions (browser back/forward)
**don't work on macOS anyway**, so the chosen scroll button has no other job to preserve —
its single purpose is: **press it, and the ball scrolls.**

BallScroll is a thin native menu-bar utility (look & feel modeled on Abnormal Mouse) that owns
the trackball's scroll path and fixes exactly these gaps, without regressing the rest of today's
experience (speed control, inertia, launch at login).

---

## 2. Verified facts (inspected on this machine)

Everything below was read directly from the running system — not assumed.

**Host**
- Mac Studio, Apple Silicon (M2 Ultra).
- **macOS 26.7.1** (build 25G241), arm64.
- Toolchain: **Swift 6.4** (swiftlang-6.4.0.34.1), SDK **27.0** via CommandLineTools.
  Note: only Command Line Tools are currently active — no full Xcode installed. A
  developer installing Xcode gets the SwiftUI/AppKit build flow for free; otherwise
  assemble the `.app` with `swiftc` + hand-written Info.plist (both work for this scope).
- Abnormal Mouse is installed and running: `/Applications/AbnormalMouse.app`, bundle
  `com.intii.AbnormalMouse`, version `2023.12`.

**Connected device (the trackball)**
- Enumerated as `USB Trackball`, class `IOUSBHostDevice`, USB address 2, behind the
  "USB 2.0 Hub [MTT]".
- **`idVendor = 1133 (decimal) = 0x046D = Logitech`**, **`idProduct = 50184 (decimal) =
  0xC3C`**, product name string `USB Trackball`. → This is the **Logitech Marble /
  Trackman T-BC21**.
- A Bluetooth **Magic Mouse** is also present. ⇒ The utility **must filter events by
  device** so it only affects the trackball and never hijacks the Magic Mouse / built-in
  trackpad.

**Current Abnormal Mouse configuration** (from `~/Library/Preferences/com.intii.AbnormalMouse.plist`)
- Feature in use: **"Move to Scroll"** (the "Scroll and Swipe" tab). Mechanism per the app's
  own UI strings: *"Hold activator then move your mouse to scroll."* — it turns **2D pointer
  movement** into scroll while a button is held. Root cause of pain point #2 (both axes).
- Activator: `MoveToScrollKeyCombination = {"activator":{"code":4,"type":"mouse"},"modifiers":[]}`
  → **`code: 4`, type mouse = Abnormal Mouse's "button 5" (0-indexed internally).** The user's
  scroll button.
- `MoveToScrollSpeedMultiplier = 3`, `MoveToScrollInertiaEffect = true`.
- Abnormal Mouse's **only** scroll knobs are a "Scroll speed" slider and an inertia toggle.
  **No direction-invert, no axis-lock** — confirming both gaps are real product holes.

**Device button model (T-BC21), per vendor docs + Linux libinput records for `0x46D:0xC3C`**
- Four physical buttons + a trackball; **no scroll wheel**, no dedicated middle button.
  Middle-click is *emulated* by pressing both large buttons at once (not a real discrete
  event, so it **cannot** be used as the scroll button).

  | Physical button (T-BC21) | Linux libinput event | macOS CoreGraphics (best estimate — confirm via probe, §8.6) | Abnormal Mouse label |
  |---|---|---|---|
  | Large left | `btn_left` (1) | Left Mouse Down, buttonNumber 1 | Button 1 |
  | Large right | `btn_right` (3) | Right Mouse Down, buttonNumber 2 | Button 2 |
  | (emulated) middle | `btn_middle` (2, emu.) | *two-button combo, not discrete* | Button 3 |
  | Small left (side) | `btn_side` (8) | Other Mouse Down, buttonNumber 3 | Button 4 |
  | Small right (extra) | `btn_extra` (9) | Other Mouse Down, buttonNumber 4 | **Button 5** ← current scroll button |

- Linux treats this exact device with a `scroll-button` capability and exposes **two knobs
  that map 1:1 to the user's asks**: `scroll-wheel-emulation-button` (which button is held) and
  **`HorizontalScrolling false`** (vertical-only). Strong prior-art that the requested behavior
  is a well-defined, proven model.

**Conclusion:** The device cannot scroll natively; hold-button-to-scroll is the canonical
mechanism (Abnormal Mouse, Linux libinput, GNOME, Sway all implement it that way). The two gaps
are simply **not exposed** by Abnormal Mouse, so a thin utility that owns the scroll path can
add them cleanly.

---

## 3. Decisions (resolved)

| # | Question | Decision |
|---|----------|----------|
| D1 | App name | **BallScroll** (working name kept) |
| D2 | Default function of the scroll button | **None.** The small buttons' default functions don't work on macOS anyway. Button's single purpose: **press → ball scrolls**. No tap passthrough in v1 (door left open, FR-18). |
| D3 | Horizontal scrolling | **Setting, default OFF.** "Enable horizontal scrolling" checkbox in the Scroll tab (ON = 2D scroll like Abnormal Mouse; OFF = vertical-only). |
| D4 | Build vs. buy | **Build.** This PRD is the spec for it. |

**Additional requirements (from owner, 2026-10-06):**
- Look & feel **similar to Abnormal Mouse** (menu-bar app, tabbed settings window, sliders with
  explanatory intro text, status line in the menu).
- **Starts on reboot / launch at login** (like Abnormal Mouse's "Automatically start at login").
- **Speed and inertia settings** (like Abnormal Mouse's "Scroll speed" slider + inertia toggle).
- **The scroll button must be selectable in settings** (button picker with live probe + the
  T-BC21 button diagram).

---

## 4. Goals / non-goals

### Goals
- **G1 — Vertical-only by default.** While the activator is held, only vertical (up/down)
  scrolling is produced from the ball's vertical motion; sideways roll scrolls nothing.
  Horizontal available via a settings toggle, default off. (Pain point #2 / D3.)
- **G2 — Invertible direction.** One-tap toggle flips scroll direction; persisted. (Pain point #1.)
- **G3 — Dedicated-button semantics.** The chosen button does exactly one thing: hold it, the
  ball scrolls. No click passthrough, no ambiguity. (D2.)
- **G4 — Reliability & scope.** Affects only the T-BC21 (device filter); Magic Mouse/trackpad
  never touched. Works in major apps (Safari, Chrome, Finder, Notes, Xcode).
- **G5 — Abnormal-Mouse-grade quality of life.** Speed slider, inertia toggle, launch at login,
  enable/disable — all present, matching how AM feels. (Owner requirement.)
- **G6 — Low overhead.** Menu-bar utility; near-zero CPU when idle.

### Non-goals (v1)
- Pointer acceleration / cursor sensitivity / linear-cursor (LinearMouse territory).
- DPI switching, remapping buttons to arbitrary actions, pinch/zoom gestures.
- Replacing AM's "Swipe", "Tap and Click", "Zoom & Rotate" features.
- Linux/other platforms.

---

## 5. Users & primary workflow

**User:** a single power user on one Mac Studio, working with the T-BC21 all day.

**Primary workflow (the job to be done):**
> "I hold button 5, roll the ball up or down, and whatever window is under the cursor scrolls
> **vertically**, in the direction I expect. A sideways roll does nothing scroll-wise."

**Secondary:** "I can flip the scroll direction from a menu and it sticks across reboots."
**Secondary:** "I can change which button is the scroll button in settings, pick my speed and
inertia feel, and BallScroll starts itself after I reboot."

---

## 6. Functional requirements

### 6.1 MVP (must ship)

| ID | Requirement |
|----|-------------|
| FR-1 | **Hold-to-scroll.** While the configured *activator* button is held, ball movement produces scroll events. On release, scrolling stops immediately (after any inertia tail). The button's down/up events are **consumed** — no click is emitted; the button has no other function (D2). |
| FR-2 | **Vertical-only by default.** Scroll is generated from the ball's **vertical** axis only; the horizontal component of ball motion does not scroll. (G1) |
| FR-3 | **Horizontal scrolling — settings option, default OFF.** Checkbox "Enable horizontal scrolling" in the Scroll tab. When ON: scroll is generated from both ball axes (2D, like Abnormal Mouse). When OFF: vertical-only. Persisted; applied immediately. (D3) |
| FR-4 | **Direction invert.** Toggle "Invert scroll direction" in both the menu bar dropdown and settings. Persisted; applied immediately, even mid-scroll. (G2) |
| FR-5 | **Scroll button selectable in settings.** The Scroll tab shows the T-BC21 button layout (4 buttons + ball diagram) and lets the user pick which physical button is the activator. Defaults to **button 5 (small right)**. Persisted. Selection uses the live button probe (FR-10) so it maps to the real device event. (Owner req.) |
| FR-6 | **Scroll speed.** Slider "Scroll speed" with explanatory intro text (AM-style copy: how much ball motion is scaled into scroll). Range ≈ 1–20, **default 3** (matches current AM config). Persisted; applied live. |
| FR-7 | **Inertia.** Checkbox "Emulate inertia effect", **default ON** (matches current AM config), with intro text about why it matters in some apps. Persisted; applied live. |
| FR-8 | **Device filter.** All behavior applies only to the trackball identified by vendor/product `0x046D:0xC3C` (matched at runtime). Magic Mouse / trackpad events are never modified or consumed. |
| FR-9 | **Suppress cursor while scrolling.** While in scroll mode (activator held, ball moving) the original pointer-move events are consumed so the cursor does not drift. |
| FR-10 | **Button probe (first run).** Present the button diagram; user presses each trackball button and the app records its real CoreGraphics signature (event type + `buttonNumber`). Persist the name→signature map. Makes "button 5" robust across OS versions instead of hard-coded (the §2 table is a best-effort estimate to be confirmed by the probe). |
| FR-11 | **Enable/disable + launch at login.** Global on/off toggle in the menu bar ("BallScroll is functioning." status line, AM-style) + "Automatically start at login" checkbox in General. When off/quit, the trackball behaves 100% natively. Login item via SMAppService (or a bundled helper app, as AM ships `LaunchAtLoginHelper.app`). Must survive reboot. |
| FR-12 | **Permission handling.** Detect and request Accessibility (and Input Monitoring if needed) on first launch, with an in-app explanation panel ("NeedAccessibility" parity) that links to System Settings and re-checks on focus change. Accessibility is the primary/required permission (mouse event tap); Input Monitoring only if a later version adds keyboard-driven features. |
| FR-13 | **Deadzone / threshold.** A small minimum ball-movement deadzone before scroll starts (jitter absorption). Tunable in Advanced, sensible default. |

### 6.2 Nice-to-have (v1.1+)

| ID | Requirement |
|----|-------------|
| FR-14 | **Toggle-lock mode.** Optional alternative to hold-to-scroll (mirrors libinput `ScrollButtonLock`): one click turns scrolling ON, next click OFF — no need to keep holding. Clean here because the button has no other function (D2). Default mode stays hold-to-scroll; exposed as a radio in the Scroll tab. |
| FR-15 | **Per-app exclusions.** "Disable BallScroll for apps listed below" list (AM Advanced parity). |
| FR-16 | **Double-tap half-page scroll.** Double-tap the activator to jump a half page up/down (AM "Half Page Scroll" parity). |
| FR-17 | **Per-axis direction invert.** Separate vertical/horizontal invert when horizontal scrolling is enabled. (v1 has one global invert, FR-4.) |
| FR-18 | **Optional tap passthrough.** If the user ever wants a quick tap on the scroll button to pass through as a native click (e.g. back/forward). Off by default; v1 consumes taps per D2. |
| FR-19 | **Modifier-gated horizontal.** Refinement of FR-3: instead of 2D-always when enabled, hold ⌥ while scrolling for horizontal. Offered as an alternate behavior if the plain toggle feels lossy in practice. |

---

## 7. Non-functional requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | **Look & feel parity with Abnormal Mouse.** Menu-bar app; settings window organized in tabs (*Scroll* / *Advanced* / *General+About*) with sliders that carry explanatory intro text beneath them, checkboxes with tips, and a status line in the dropdown. Same mental model as AM: open → enable → tune speed/inertia → quit to menu bar. (Owner req.) |
| NFR-2 | **Latency.** Scroll must feel native — no perceptible lag between ball motion and scroll. O(1) per-event processing, no allocations in the hot path. |
| NFR-3 | **Idle cost.** Near-zero CPU when idle (event tap only; no timers/polling). No keystroke reading unless a modifier feature is added. |
| NFR-4 | **Reliability.** Survives trackball disconnect/reconnect (re-detect), sleep/wake, permission re-grants; recovers if the system disables the tap (re-enable + notify). Launch-at-login survives reboot. |
| NFR-5 | **Privacy.** No data leaves the machine; config stored locally (`UserDefaults`). |
| NFR-6 | **Distribution.** Self-contained, code-signed `.app` (ad-hoc signing is fine for local use — see §8.10 TCC note). Minimum macOS: match current host (macOS 26); test on the actual Mac Studio / M2 Ultra. |

---

## 8. Technical approach (recommended)

**Stack:** Swift + AppKit menu-bar app; SwiftUI for the settings window. CoreGraphics event
tap for capture/posting — exactly how Abnormal Mouse, LinearMouse, Scroll Reverser and Mac
Smooth Scroll all do it.

**8.1 Capture.** One `CGEventTapCreate` (session level, head-insert) with a mask covering:
mouse moved; left/right down+up; **other-mouse** down+up (side buttons); scroll wheel
(passthrough). Single tap preferred over active+passive pairs to avoid interfering with other
tools (Scroll Reverser documents why two taps can cause side effects). Run on the main run
loop in common modes.

**8.2 Device filter (FR-8).** Identify the trackball by HID vendor/product `0x046D:0xC3C` via
the event source / IOHID lookup. Only matching events are transformed; all others return
untouched (protects the Magic Mouse/trackpad).

**8.3 State machine (simplified by D2 — no tap branch).**
- `IDLE` → activator **down** (source = trackball) → consume the down event, enter `ARMED`.
- In `ARMED`: accumulate ball deltas. Movement beyond the **deadzone** → `SCROLLING`.
  Activator released before deadzone → consume the up, return to `IDLE` (a tap does nothing —
  per D2). No click is ever emitted by the activator.
- In `SCROLLING`: for each mouse-moved event → compute scroll delta (§8.4), post a synthetic
  scroll-wheel event, **consume** the original move (return `NULL`, FR-9). Activator **up** →
  flush inertia tail, return to `IDLE`.

**8.4 Translation (the two features live here).**
- **Vertical-only / 2D:** take ball Y delta; horizontal scroll = 0 unless FR-3 is enabled, in
  which case also take X. (Optional ⌥-gate per FR-19.)
- **Invert:** multiply resulting delta by −1 when enabled (FR-4).
- **Speed & inertia:** scale by the multiplier; exponential-decay tail for inertia (FR-6/7).

**8.5 Posting.** `CGEventCreateScrollWheelEvent` with **pixel units** (`kCGScrollEventUnitPixel`)
for smooth scrolling; post at the HID/session tap point. Set delta fields consistently —
Scroll Reverser documents an ordering constraint when rewriting `pointDelta`/fixed-point fields;
follow it for smooth-scroll fidelity. Release posted events.

**8.6 Button identity (FR-10/5).** Do **not** hard-code "button 5". First run: button-probe
dialog with the T-BC21 diagram; capture each pressed button's real signature
(`kCGEventOtherMouseDown` + `kCGMouseEventButtonNumber`, etc.) and persist a name→signature map.
The settings picker (FR-5) lists these probed names, defaulting to the one matching today's AM
button 5 (small right).

**8.7 Permissions.** `AXIsProcessTrustedWithOptions` check; in-app "grant permission" panel that
opens System Settings → Privacy & Security → Accessibility / Input Monitoring and re-checks on
window focus change (AM ships the same flow — parity).

**8.8 Launch at login.** `SMAppService.mainApp.register()` (macOS 13+) or bundled Login Item
helper, mirroring AM's `LaunchAtLoginHelper.app`. NFR-4: must actually work after reboot
(test explicitly).

**8.9 Language choice — Swift (evaluated against Rust).** The core is C-API FFI
(CoreGraphics event tap, posted scroll events, IOKit device lookup), which is the same cost in
any language; at mouse-event rates (60–125 Hz) Swift's ARC overhead is unmeasurable vs. Rust, and
every prior art (Abnormal Mouse, LinearMouse) is Swift/Obj-C. The differentiator is the UI:
"ABM-like look & feel" means native AppKit status item + tabbed settings — hours in
Swift/SwiftUI, materially more work via `objc2`/`cacao` in Rust (and cross-platform UI kits
fight the native look). Swift is also first-class for `SMAppService`, TCC/permission flows, and
`NSStatusItem`. **Decision: Swift + AppKit/SwiftUI.** Revisit if the app grows into a general
input engine (IOHID consumer driver, heavy DSP) or needs a Linux build — Rust is the right
candidate then; a Rust-core/Swift-shell hybrid buys nothing at v1 size.

**8.10 Build configuration & dev prerequisites (verified 2026-10-06).**
- **Bundle ID:** `com.sergey.BallScroll` (UserDefaults domain follows suit — never reuse
  Abnormal Mouse's `com.intii.AbnormalMouse`).
- **Code identity & TCC pitfall:** Accessibility permission is bound to the app's code
  identity. During development, ad-hoc sign consistently; changing the bundle ID or
  signing invalidates the granted permission and it must be re-granted (classic dev-loop
  gotcha).
- **Coexistence with Abnormal Mouse:** quit AM (or disable its "Move to Scroll") while
  developing/testing BallScroll — two active event taps on the same button will
  double-transform events. Final state: BallScroll replaces AM for scrolling (D4).
- **Swift concurrency:** Swift 6.4 default strict-concurrency mode applies; the event-tap
  callback runs on the main run loop — keep it allocation-light and free of actor hops
  (NFR-2).

---

## 9. UX / settings surface (sketch — modeled on Abnormal Mouse)

**Menu bar icon → dropdown:**
- Status line: **"BallScroll is functioning." / "is not enabled."** (AM-style)
- ✅ Enable / Disable (global toggle) — FR-11
- Invert scroll direction: **Normal / Inverted** (click to flip) — FR-4
- Show Preferences…
- Quit

**Preferences window:**

*Scroll tab* (the heart of the app — mirrors AM's "Scroll and Swipe" tab):
- Tip: *"Hold [Button 5] then roll the ball to scroll."* (AM-style usage tip, dynamic per chosen button)
- **Scroll button picker** — T-BC21 diagram (large L/R, small L/R + ball); click a button in the
  UI then press it on the device (probe, FR-10). Default: small right. — FR-5
- **Invert scroll direction** ☐ — with tip explaining it aligns the ball with trackpad natural
  scrolling. — FR-4
- **Enable horizontal scrolling** ☐ (default OFF) — tip: "Off = vertical only. On = rolling
  sideways also scrolls horizontally." — FR-3
- **Scroll speed** [slider, default 3] + intro text (AM-style: "controls how much ball motion is
  scaled into scrolling…"). — FR-6
- **Emulate inertia effect** ☑ (default ON) + intro text (AM-style). — FR-7
- Mode radio: **Hold to scroll** (default) / Toggle lock (v1.1, FR-14).

*Advanced tab:*
- Deadzone threshold (FR-13)
- Disable BallScroll for apps listed below — list (v1.1, FR-15)
- Optional ⌥-gated horizontal (v1.1, FR-19)

*General / About:*
- ✅ Automatically start at login (FR-11) — AM's exact label from its General tab
- Device status: "Logitech USB Trackball (0x46D:0xC3C) detected"
- Version, About.

**First-run flow:** permission prompt → "press each button" probe (with diagram) → confirm
activator (pre-selected: small right) → done.

---

## 10. Acceptance criteria (definition of done)

1. With BallScroll **on**, holding the chosen button and rolling the ball **up/down** scrolls
   the focused window vertically; a purely sideways roll produces **no scroll**. (FR-2 / G1)
2. "Enable horizontal scrolling" is **off by default**; turning it on makes sideways rolls
   scroll horizontally; persisted. (FR-3 / D3)
3. Flipping the direction toggle immediately reverses scroll direction; persists across app and
   Mac restarts. (FR-4 / G2)
4. The chosen button does **only** scrolling: a quick tap emits no click and scrolls nothing;
   holding + rolling never moves the cursor. (FR-1/9 / D2)
5. Changing the scroll button in settings (via probe + diagram) works and persists; default is
   small right (button 5). (FR-5/10)
6. Speed slider and inertia toggle behave like Abnormal Mouse's (sensible defaults 3 / on),
   apply live, persist. (FR-6/7)
7. Works in Safari, Chrome, Finder, Notes and Xcode. (Per-app exclusions — v1.1/FR-15 —
   disable it only for listed apps.) (G4)
8. The **Magic Mouse and trackpad behave exactly as before** with the app running (device
   filter holds). (FR-8)
9. After unplugging/replugging the trackball and after sleep/wake, scrolling still works without
   restarting the app. (NFR-4)
10. **After reboot**, BallScroll is running and scrolling works (launch at login verified for
    real). (FR-11)
11. With **no** permission granted, the app clearly says so and doesn't crash; after granting,
    it starts working. (FR-12)
12. When toggled **off** or quit, the trackball acts 100% natively. (FR-11)

---

## 11. Prior art & alternatives considered

**Why not just reconfigure existing tools (informed by D4 = build):**
- **Abnormal Mouse (current):** "Move to Scroll" has no direction-invert and no axis-lock —
  the exact two gaps. Root cause confirmed by its UI strings + config (converts *2D* motion to
  scroll). Its other tabs are out of scope. **Rejected as the solution** for these two features;
  BallScroll is modeled on its UX but replaces its scroll function.
- **LinearMouse:** per-axis scroll reverse, linear scroll, button→action mapping. But its model
  is *wheel/modifier → scroll* and *button → mapped action*; it does **not** do
  "hold a button + roll the ball = scroll" (the core trackball feature). Two simultaneous event
  taps risk conflicts. Possible *secondary* tool only.
- **Scroll Reverser (pilotmoon):** per-axis + per-app invert; proven event-field mutation
  ordering (§8.5 reference). No button-hold ball-scroll.
- **ScrollAnywhere** (browser ext): middle/right/left hold-to-scroll, *web only*; already ships
  "Fixed axis X/Y lock (strict)" — strong prior-art that vertical-only is an expected option.
  Insufficient scope for a whole-desktop trackball.
- **Mac Smooth Scroll:** wheel→smooth-scroll; has "axis lock" in profiles — more prior-art for
  axis locking. Wheel-oriented, not ball-oriented.
- **Mac Mouse Fix / BetterTouchTool:** capable commercial tools that could approximate this; the
  build-vs-buy call was made (build) for a lean, purpose-specific utility.

**Reference behavior model (port from Linux):** `scroll_method on_button_down` +
`HorizontalScrolling false` for `1133:50184:Logitech_USB_Trackball`. BallScroll is essentially
the macOS equivalent of that, implemented via a CoreGraphics event tap.

---

## 12. Milestones / release plan

- **M0 — Spike (de-risk the hard parts).** Throwaway Swift/Py event tap that: detects
  `0x046D:0xC3C`; on button-5 held, converts Y motion → posted pixel scroll with invert +
  vertical-only; consumes the move (no cursor drift). *Exit:* scroll works in Safari/Notes,
  Magic Mouse untouched. Confirms §8.2–8.5 and the real CoreGraphics signature of button 5
  (feeds FR-10's default mapping).
- **M1 — MVP.** Menu-bar `.app`: FR-1…FR-4, 8, 9, 12 (scroll core + invert + device filter +
  permissions). Meets AC #1, #3, #4, #8.
- **M2 — Full v1 (owner requirements).** FR-5…FR-7, 10, 11, 13 + settings window (Scroll /
  Advanced / General) with AM-style UI: button picker + probe, horizontal toggle, speed slider,
  inertia checkbox, launch-at-login. Meets **all** ACs #1–#12 (excl. v1.1 items).
- **M3 — Nice-to-haves.** FR-14…FR-19 as time allows (toggle-lock, exclusions, half-page,
  per-axis invert, tap passthrough, ⌥-gated horizontal).

---

## 13. Open questions (remaining)

None blocking — all four original decisions resolved (§3). Non-blocking notes:
- Exact CoreGraphics button number for "button 5" will be confirmed by the M0 spike / first-run
  probe (FR-10); §2 table is a well-grounded estimate.
- Whether to also fix the small buttons' back/forward (D2 says not needed) — deliberately out
  of scope; FR-18 leaves the door open.
