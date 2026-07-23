# Keyboard Cleaning → True Full Keyboard Lock

Date: 2026-07-23 · Status: Approved by user · Target: build 112

## Problem

The current Keyboard Cleaning lock (`KeyboardBlocker` in `Sources/Rebes/KeyboardCleanView.swift`)
uses a `CGEventTap` at `.cgSessionEventTap` with a mask of only `keyDown | keyUp | flagsChanged`.
Keys leak through while the user wipes the keyboard:

1. **Media keys** (brightness, volume, play/pause, Mission Control) are `systemDefined` events
   (type 14), not in the mask → they fire.
2. **System shortcuts** (⌘Space, ⌘Tab, ⌘Q, …) are handled at HID level, before a session-level
   tap sees them → they fire.
3. **Globe/Fn key** actions (emoji picker, input-source switch) are handled below any event tap →
   unblockable via `CGEventTap`, period.
4. Touch ID / power button: hardware path, cannot be blocked by any software (documented
   limitation, not addressed).

## Goal

"Full keyboard off": while cleaning mode is active, **no key on any keyboard** (built-in or
external) reaches the system — letters, modifiers, shortcuts, media keys, and Globe alike.
Mouse/trackpad must stay alive for the unlock button.

Non-goals: blocking Touch ID/power (impossible), blocking the mouse, changing anything outside
the Keyboard Cleaning feature and the Permissions list.

## Approach (chosen: C — seizure + fallback)

### Primary: HID device seizure

New `KeyboardSeizer` wrapping `IOHIDManager`:

- Open with `kIOHIDOptionsTypeSeizeDevice` → exclusive ownership; seized devices deliver events
  to nothing else (apps, system shortcut handlers, brightness HUD, Globe handler all starve).
- Device matching covers the three HID top-level collections that carry keys:
  - Generic Desktop / Keyboard (usage page 0x01, usage 0x06)
  - Generic Desktop / Keypad (0x01/0x07)
  - Consumer / Consumer Control (0x0C/0x01) — media/brightness keys live here
- Seizes built-in and external keyboards. Trackpad/mouse are pointer devices, not matched.
- Fail-safe by design: IOKit releases the seizure automatically on app quit or crash.
- Requires **Input Monitoring** permission (user-space; no root, no helper/daemon changes).

### Fallback: improved CGEventTap

If Input Monitoring is denied or seizure open fails:

- Keep the existing session-level tap, but add `systemDefined` (type 14) to the event mask so
  media keys delivered to apps are also swallowed.
- Honest limitation: Globe key and possibly the brightness/volume HUD may still respond in this
  mode; the UI must say so.

If tap creation also fails → existing Accessibility-permission guidance (unchanged behavior).

### Safety auto-unlock

A 10-minute `Timer` starts when the lock engages and is cancelled on manual unlock. Even in a
broken window state the lock self-heals. `onDisappear` unlock (existing) stays.

## Components

### `KeyboardSeizer` (new, in `Sources/Rebes/`)

- `start() -> Bool`: create manager with seize option, set matching (3 collections), schedule on
  main run loop, open. Returns success.
- `stop()`: close + unschedule; nil out. Idempotent.

### `KeyboardBlocker` (modified)

- `enum Mode { case seized, tap }`, `@Published var mode: Mode?` (nil = not blocking).
- `start()`: check Input Monitoring access (`IOHIDCheckAccess`); attempt seizure → mode `.seized`;
  else fall back to upgraded tap → mode `.tap`; else `needsPermission = true`.
- `stop()`: releases whichever layer is active, cancels the auto-unlock timer, clears mode.
- Owns the 10-minute auto-unlock `Timer`.

### `KeyboardCleanView` (modified)

- Locked state shows a mode badge:
  - `.seized` → "FULL LOCK — all keys are dead, including media and Globe keys."
  - `.tap` → "PARTIAL LOCK — media/Globe keys may still respond. Grant Input Monitoring for a
    full lock." + button deep-linking to System Settings → Privacy & Security → Input Monitoring.
- Copy note in both modes: "No software can disable the Touch ID/power button — avoid pressing it
  while wiping."
- Caption in seized mode: "Auto-unlocks in 10:00" (counts down).
- Big "Re-enable Keyboard" button unchanged (mouse unlock).

### `PermissionsView` / `Permissions.swift` (small addition)

- Add **Input Monitoring** as a 5th permission row, same status/grant pattern as the existing
  four (needed for the full lock; the view explains why).

## Error handling

| Case | Behavior |
|---|---|
| Input Monitoring denied | Fallback tap, PARTIAL badge, settings deep-link |
| Seizure open fails (unexpected) | Same fallback path |
| App crash / `kill -9` while locked | IOKit auto-releases seizure; keyboard revives |
| 10 minutes elapsed | Auto-unlock via timer |
| User navigates away from the view | `onDisappear` → unlock (existing) |

## Testing

HID seizure cannot be unit-tested; verification is a manual checklist:

1. Lock in seized mode → letters, ⌘Space, ⌘Tab, ⌘Q, brightness, volume, play/pause, Globe: all dead.
2. Trackpad click on "Re-enable Keyboard" → keyboard back, "Beres!" stamp shows.
3. Re-lock → `kill -9` the app → keyboard revives immediately.
4. Re-lock → let the 10-minute timer expire → auto-unlock.
5. Fallback path: revoke Input Monitoring → lock → PARTIAL badge shows; letters/shortcuts blocked,
   copy honestly notes media/Globe may leak.
6. External keyboard (if available): also dead in seized mode.

## Files touched

- `Sources/Rebes/KeyboardCleanView.swift` — seizer, orchestrator, UI (main change).
- `Sources/Rebes/Permissions.swift` — add Input Monitoring to the permission model/check.
- `Sources/Rebes/PermissionsView.swift` — 5th permission row UI (Input Monitoring).

No changes to the helper daemon, XPC protocol, or any other feature.
