# Contributing to Rebes!

Thanks for helping make Macs everywhere a little more *beres*. 👍

## Ground rules

- **Safety is the product.** Anything that writes to the SMC goes through
  `RebesHelper` and must be validated against `HelperWhitelist` **at the call
  site**. New SMC keys need: documented semantics (with a source), whitelist
  rules, a fail-safe path, and self-test coverage. PRs that bypass the
  whitelist are rejected outright.
- **Deletions are Trash-only** and must pass `SafeCleaner.isAllowed`
  (deny-first). Never add a code path that permanently deletes user files
  without an explicit, worded confirmation.
- **No Xcode assumption.** The project must build with Swift CommandLineTools
  alone: platform cap `.macOS(.v15)`, no `@Observable` macro (use
  `ObservableObject`), no XCTest (extend `RebesSelfTest` instead).

## Dev loop

```bash
swift build                # must be error-free
swift run RebesSelfTest    # must print PASS
./scripts/build-app.sh     # assembles + codesigns dist/Rebes.app
```

## Style

Match the surrounding code: SwiftUI + `ObservableObject` state classes,
comment only what the code can't say (constraints, hardware gotchas), design
tokens from `Theme.swift`. UI copy is short, warm, confident — see the
existing views for the voice.

## Known sharp edges (read before touching)

- Never run a subprocess (or anything that pumps the run loop) inside a state
  object initializer — SwiftUI layout re-entrancy crashes (SIGABRT). Load
  async in `onAppear`.
- Daemon signal handling uses `DispatchSource.makeSignalSource` — never C
  signal handlers (SMC/dispatch calls are async-signal-unsafe).
- Engines (fan curve, charge loop) own ALL their SMC writes on one serial
  queue; per-call RPC handlers must route through the engine, never write
  directly.

## Reporting bugs

Include: macOS version, Mac model, `RebesHelper probe` output (read-only
diagnostics), and Console logs if the daemon is involved.
