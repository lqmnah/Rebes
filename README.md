# Rebes! 👍

**Your Mac, sorted.** An all-in-one, open-source macOS utility: junk cleaner,
AlDente-style battery charge control, fan control, and live system monitoring —
one liquid-glass app plus a menu bar companion. One app instead of three:
CleanMyMac + Macs Fan Control + AlDente → **Rebes!**

Free to use and share with credit to **Rebes!** — reselling is not permitted
(see [License](#license)).

*"Rebes" is Indonesian slang for "beres" — done, sorted, handled. When Rebes
finishes a job, it tells you: **Beres!***

> ⚠️ **Safety first:** Rebes writes to the SMC (fans, battery charging) through
> a hard-whitelisted root helper. It ships with multiple fail-safes, but you
> use it at your own risk — see [Disclaimer](#disclaimer).

## Features

### 🔋 Battery Charge Control (AlDente-style)
- **Charge limit (20–100%)** on Apple Silicon via the firmware-managed charge
  band (SMC `bfF0`/`bfD0`/`bfE0` — the same facility macOS's native Charge
  Limit uses). The firmware enforces the limit itself, **including during
  sleep**, and the limit **persists across reboots**.
- **Sailing mode** — charging resumes only after the battery drifts a few
  percent below the limit (native firmware hysteresis).
- **Heat protection** — pauses charging when the battery runs hot, with flip
  hysteresis so it never oscillates.
- **Top Up** — one-shot full charge, then back to your limit.
- **Discharge to limit / Calibration** — on machines whose firmware exposes an
  adapter-disable key (probed at runtime).
- **MagSafe LED control** — system / off / green-at-limit (probed at runtime).
- Runtime **capability probe**: firmware band → `CHTE` gate → `CH0B`/`CH0C`
  legacy gate → graceful "unsupported" fallback. No version sniffing.
- All of it lives in one **Battery** tab, AlDente-style, together with live
  power stats: Current (A), Voltage (V), Power (W) and System Load (W, from
  SMC power telemetry), plus capacity/health/cycles/history charts.

### 🧹 Cleaning
- **Smart Scan** — user-level junk (app caches, logs, DerivedData,
  npm/Homebrew/pip/bun). Trash-only after confirmation, deny-first path
  whitelist.
- **Smart Care** — one click scans junk, Trash, startup items and temps, one
  recommendation screen, cleans everything to Trash.
- **Large Files**, **Space Lens** drill-down size map, SHA-256 **Duplicate
  Finder**.
- **Uninstaller** — apps + leftovers; only bundle-id/exact matches
  pre-selected, fuzzy matches flagged and unchecked.

### 🌡 Fans & Monitoring
- Live per-fan RPM with hardware min/max, Auto/Manual, clamped RPM slider.
- **Automatic fan curve** runs inside the root daemon — works with the app
  closed, survives reboots, relocks firmware control on exit.
- Dashboard: disk ring, CPU/memory/network meters, temperatures, battery
  detail (AlDente-style specs, history charts).

### 📎 Menu Bar Companion
- Configurable label: any mix of CPU %, memory %, CPU temp, fan RPM, battery %
  — the battery uses the native macOS glyph (proportional fill + charging
  bolt), rendered text-first like the system item.
- Rounded floating glass panel (our own borderless window — no square system
  chrome) that always fits its content exactly.
- Editable sections: health score, stat cards, network row, fan quick control,
  quick actions — toggle each in Settings.
- Quick actions: **Speed Up (purge RAM)** right on the Memory card, Keep
  Awake, hidden files, empty Trash (confirmed), lock screen, keyboard-cleaning
  lock, ⌘Q quit.

### 🛠 Maintenance
- Flush DNS and Purge RAM — through the root daemon when Full Access is on
  (**no password prompts**), single admin prompt otherwise.
- Startup items (`~/Library/LaunchAgents`) enable/disable.
- Show Dock icon toggle — run Rebes as a clean menu-bar-only app.

## One-Time Full Access

Fan and battery writes require root. Two modes:

1. **Default** — each action runs the bundled helper through the macOS admin
   password prompt.
2. **Full Access (recommended)** — Settings → "Enable Full Access" installs
   `RebesHelper` as a root launchd daemon (one admin prompt, once). The app
   talks to it over XPC; no passwords again. The fan curve and the charge-limit
   loop live here. Uninstall any time from the same screen.

**Trust model:** the daemon accepts XPC only from processes code-signed with
the app's identifier whose executable lives inside a `Rebes.app` bundle, and
every SMC write is validated against a hard whitelist
(`Sources/RebesCore/Whitelist.swift`) — charge keys accept only their
documented safe values, fan targets are clamped to bounds the helper re-reads
from the hardware itself, and the discharge RPC has a hard 20% floor.
Anything else is refused. Sensor-read failures trip a 3-strikes fail-safe
that restores firmware control, and the daemon re-checks hardware state at
startup so even an unclean crash can't leave the adapter disabled.

> **Ad-hoc signing caveat:** release builds are ad-hoc signed (no paid
> Developer ID), so the XPC signature check pins an identifier rather than a
> certificate anchor. A local process running as your user could in principle
> re-sign itself to match; the whitelist bounds what it could do (no
> arbitrary SMC writes, discharge floored at 20%). If you build from source
> with your own Developer ID, tighten the requirement in
> `connectionIsTrusted` for a fully hardened install.

## Compatibility
- **Apple Silicon only** (arm64 binary — Intel Macs are not supported), any
  M-family chip, **macOS 15.0+**.
- Charge-limit features depend on **firmware**, not chip generation: the
  firmware charge band ships with macOS 26.4-era firmware and later; older
  firmware falls back to gate keys where present, and unsupported machines
  degrade gracefully. Desktops without a battery simply hide the battery
  features.
- Fan control requires a machine with fans (fanless MacBook Airs get a
  friendly notice).
- Tested on MacBook Pro (M1 Pro, macOS 27) and Mac Studio (macOS 26.5);
  other Apple Silicon Macs are expected to work via the runtime probes.
- Building: Swift 6 CommandLineTools are enough — no Xcode.

## Install

Download the DMG from [Releases](../../releases), drag to Applications, launch,
and grant the permissions you want to use. Everything is optional — Rebes
degrades gracefully.

## Build from source

```bash
swift run RebesSelfTest   # policy & whitelist self-test (must print PASS)
./scripts/build-app.sh    # selftest + release build + .app assembly + codesign
./scripts/make-dmg.sh     # optional: drag-to-install DMG
open dist/Rebes.app
```

## Architecture
- **Rebes** — SwiftUI app: views, dashboard, menu bar companion.
- **RebesCore** — `SafeCleaner` (deny-first whitelist, Trash-only),
  `JunkScanner`, `DiskScanner`, `LeftoverMatcher`, `BatteryReader`,
  `SystemStats`, `AppSettings`, `AdminShell`, `HelperClient` (XPC + fallback),
  SMC layer, and the SMC write whitelist.
- **RebesHelper** — the ONLY SMC writer. CLI mode (admin-prompt fallback) and
  XPC daemon mode (launchd root daemon; runs the fan-curve and charge-loop
  engines). Read-only `probe` subcommand for diagnostics.
- **RebesSelfTest** — executable self-test (CommandLineTools cannot run XCTest
  bundles): path whitelist, SMC write whitelist, charge-band validation,
  leftover matcher.
- **Built-in test harnesses** (hidden dev flags, inert in normal runs):
  `--ui-shots <dir>` renders every key screen to PNGs, `--panel-probe <dir>`
  opens the real menu bar panel and dumps its window hierarchy, and
  `--click-probe <file>` synthesizes real mouse clicks to verify hit-testing —
  all without needing screen-recording or accessibility permissions.

## Credits
- SMC interface adapted from [exelban/stats](https://github.com/exelban/stats)
  (MIT) — see `docs/THIRD-PARTY.md`.
- Firmware charge-band mechanism (`bfF0`/`bfD0`/`bfE0`) documented by
  [charlie0129/batt](https://github.com/charlie0129/batt) (research reference;
  no code copied).
- Inspired by CleanMyMac, [AlDente](https://apphousekitchen.com),
  Macs Fan Control, MenuMeters and One Menu.

## Disclaimer

Rebes manipulates the SMC (fan targets, battery charging). This is the same
class of operation AlDente, batt and Macs Fan Control perform, guarded by a
strict whitelist and fail-safes — but hardware control always carries risk.
The software is provided **as is**, without warranty of any kind. See
[LICENSE](LICENSE).

## License

**Rebes! License (Fair Source)** — free to use, modify and redistribute with
visible credit to **"Rebes!"**; selling the software or derivatives is **not
permitted**. See [LICENSE](LICENSE). Third-party portions (e.g. the SMC layer
from exelban/stats) remain under their original licenses.
