# Linux: app shortcuts on non-Latin keyboard layouts

## Overview

- With a non-Latin layout active (e.g. Russian in a `us,ru` XKB setup), every app shortcut in the
  Linux port stops working: GDK reports the layout-translated keyval, so pressing Ctrl+T delivers
  Ctrl+`е` (Cyrillic), which matches nothing in the keymap's Latin vocabulary, and the key falls
  through to the terminal.
- Fix: when the event keyval carries no ASCII, re-translate the HARDWARE keycode through the
  keyboard's XKB groups and match shortcuts against the first group that yields ASCII (the Latin
  layout, whichever group slot it occupies). This is the standard GTK-app fallback (upstream
  ghostty does the equivalent).
- Terminal text input is untouched: the fix feeds only shortcut matching; typing flows through the
  separate IM/raw path after `handleKey` returns false, so Russian text still reaches the shell
  as-is.

## Context (from discovery)

- `agterm-linux/Sources/AgtermLinux/GtkInterop.swift:58` — `chord(fromKeyval:state:)` builds the
  matcher `Chord` from the layout-translated keyval; the root cause lives here.
- `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift:157` — `handleKey(keyval:keycode:state:…)`
  is the single dispatch entry point (built-ins, leader custom commands, reserved chords, fixed
  fallback). Both key sources route through it: terminal surfaces
  (`GhosttySurface.keyPressed`) and the empty-window controller
  (`AppControllerCallbacks.onEmptyWindowKeyPressed`). The hardware keycode is already a parameter
  but unused for matching.
- `agterm-linux/Sources/AgtermLinux/GhosttySurface.swift:531` — `keyPressed` also derives
  `isInterrupt` (Ctrl+C detection for attention-status clearing) from the raw keyval, so it too
  misses on a non-Latin layout.
- `gdk_display_translate_key()` (GTK4, `gdk/gdkdisplay.h`) translates keycode+state+group →
  keyval; `gdk_keyval_to_unicode`/`gdk_keyval_to_lower` are pure library calls (no display
  needed).
- Tests: `agterm-linux/Tests/AgtermLinuxTests/` runs headless via `swift test` with
  `@testable import AgtermLinux` (see `LinuxKeymapTests.swift`), so app-target logic IS unit-testable
  here — but anything needing a live `GdkDisplay` is not. Testability therefore requires injecting
  the translator.
- Not a control-API change (no new command/state; the keep-in-sync audit does not apply); no
  settings toggle (nothing to hide); no agent-skill/site impact (behavioral fix, no new surface).

## Development Approach

- **testing approach**: Regular (code first, then tests) — but the group-scan core is written
  translator-injected from the start so it is testable headless.
- complete each task fully before moving to the next
- make small, focused changes on the `linux-port` branch — a deliberate exception to the
  worktree-by-default norm for a small localized fix (3 source files + 1 test file), maintainer-agreed
- every task with code changes includes tests where the code is headless-testable; the two
  one-line wiring call sites (GTK event path) are covered by the manual acceptance run instead
- all tests must pass before starting the next task
- update this plan file when scope changes during implementation

## Testing Strategy

- **unit tests** (`agterm-linux/Tests/AgtermLinuxTests/`, `swift test` in `agterm-linux/` with the
  mise swift 6.3.2 toolchain + the compat `LD_LIBRARY_PATH` prelude from `scripts/run-linux.sh`):
  cover the group-scan logic via an injected fake translator (no display needed).
- **e2e/UI tests**: none for this change — driving a real XKB group switch inside the existing
  Linux UI-test harness is not feasible; manual acceptance in an isolated dev instance instead
  (Post-Completion).
- `agtermCore` suite and `make lint` must stay green.

## Solution Overview

- New `latinKeyval(_:keycode:state:translate:)` helper in `GtkInterop.swift`:
  1. `gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval))` — if the keyval already yields ASCII
     (letters, digits, punctuation) or is a non-character keysym (arrows/F-keys → unicode 0),
     return it unchanged: zero overhead on Latin layouts.
  2. Otherwise scan XKB groups 0–3 through the injected `translate(keycode, state, group)`
     closure; return the first keyval whose lowered unicode is ASCII. Handles both `us,ru` and
     `ru,us` group orders.
  3. If no group yields ASCII (purely non-Latin config) or translation fails, return the original
     keyval — behavior identical to today.
- The default `translate` argument wraps `gdk_display_translate_key(gdk_display_get_default(), …)`;
  tests inject a fake keymap table. The event's modifier `state` is passed through so shifted
  symbols (`shift+5` → `%`) arrive in the same shape as native us-layout events and the existing
  shift-folding in `chord()` keeps working unmodified.
- Wire it at the top of `KeymapDispatch.handleKey` (shadowing `keyval` after the Escape check),
  which covers every shortcut consumer at once, and in `GhosttySurface.keyPressed`'s
  `isInterrupt` derivation.

## Technical Details

- `gdk_display_translate_key(display, keycode, GdkModifierType(state), group, &keyval, nil, nil, nil)`
  returns `gboolean`; a `0` return for a group means "no such translation" → continue scanning.
- TWO DISTINCT conditions (do not conflate — plan-review note):
  the EARLY-OUT is `unicode < 0x80` (unicode 0 INCLUDED, so Escape/arrows/F-keys return unchanged
  and never enter the scan loop);
  the SCAN-ACCEPT for a translated group is `unicode != 0 && unicode < 0x80` (a group yielding no
  character must not win the scan).
- The early-out keeps the leader-abort and fallback paths from ever seeing a translated value, and
  means Latin layouts (incl. German/AZERTY, whose ASCII differs per keycap) are always taken
  as-is — only genuinely non-Latin keyvals fall back to a Latin group.
- Digits are unshifted on both us and ru layouts, so the reserved Ctrl+1/2 chords and the digit
  fallback are unaffected either way.

## Implementation Steps

### Task 1: latinKeyval helper with injectable translator

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/GtkInterop.swift`
- Create: `agterm-linux/Tests/AgtermLinuxTests/LatinKeyvalTests.swift`

- [x] pre-check that `gdk_display_translate_key` resolves through the CGtk module (declaration
      confirmed in `/usr/include/gtk-4.0/gdk/gdkdisplay.h:125`; a quick compile probe verifies the
      Swift import exposes it — it is not yet referenced anywhere in the tree)
- [x] add `latinKeyval(_:keycode:state:translate:)` to `GtkInterop.swift` with the ASCII
      early-out (`unicode < 0x80`, 0 included), group 0–3 scan (accept `!= 0 && < 0x80`), and
      original-keyval fallback; default `translate` wraps `gdk_display_translate_key` on
      `gdk_display_get_default()` (nil display → passthrough)
- [x] write tests: ASCII keyvals and non-character keysyms (Escape, arrow) pass through untouched
      and never invoke the translator
- [x] write tests: Cyrillic keyval + fake `us@group0,ru@group1` table resolves to the Latin
      keyval; fake `ru@group0,us@group1` table resolves via group 1 (scan order)
- [x] write tests: translator returning nil/no-ASCII for all groups falls back to the original
      keyval (error path)
- [x] run `swift test` in `agterm-linux/` — must pass before task 2

### Task 2: route shortcut matching through latinKeyval

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/KeymapDispatch.swift`

- [ ] in `handleKey`, after the Escape check, shadow `keyval` with
      `latinKeyval(keyval, keycode: keycode, state: state)` so `chord(fromKeyval:)`, the reserved
      chords, and `fallbackShortcut` all see the Latin keyval
- [ ] confirm both call sites (`GhosttySurface.keyPressed`,
      `AppControllerCallbacks.onEmptyWindowKeyPressed`) are covered by this single hook (no other
      `chord(fromKeyval:)` callers — grep)
- [ ] covered by Task 1's unit tests + the manual acceptance run (the wiring line itself has no
      headless-observable behavior; noted per Development Approach)
- [ ] run `swift test` in `agterm-linux/` — must pass before task 3

### Task 3: layout-independent Ctrl+C interrupt detection

**Files:**
- Modify: `agterm-linux/Sources/AgtermLinux/GhosttySurface.swift`

- [ ] derive `baseScalar` in `keyPressed` from
      `latinKeyval(keyval, keycode: keycode, state: state)` so `isInterrupt` (attention-status
      clearing) recognizes Ctrl+C on a non-Latin layout
- [ ] verify the terminal-input path below (`ke.text` / `unshifted_codepoint`) still uses the RAW
      keyval — typing Cyrillic must be unchanged
- [ ] covered by Task 1's unit tests + the manual acceptance run (same wiring-only rationale)
- [ ] run `swift test` in `agterm-linux/` — must pass before task 4

### Task 4: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented
- [ ] full build: `cd agterm-linux && swift build` (run-linux.sh env prelude)
- [ ] run full test suite: `swift test` in `agterm-linux/` AND `cd agtermCore && swift test`
- [ ] run `make lint` (swiftlint strict) — zero findings
- [ ] launch the isolated dev instance for the user's manual acceptance
      (`AGTERM_STATE_DIR=/tmp/agterm-dev ./scripts/run-linux.sh`), then hands-off

### Task 5: [Final] Update documentation

- [ ] no README/site/agent-skill updates needed (no new surface) — re-confirm at completion
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** (user, in the isolated dev instance, layout switched to Russian):
- built-in shortcuts fire (Ctrl+T etc.), including with Shift in the chord
- leader-sequence custom commands fire (e.g. `ctrl+a>g`)
- reserved chords: Ctrl+Tab switcher, Ctrl+1/2
- Ctrl+C on a status-attention session clears the status (isInterrupt path)
- plain Russian typing reaches the shell unchanged; dead-key/compose input still works
- Latin layout behavior unchanged (regression check)

**External system updates**: none.
