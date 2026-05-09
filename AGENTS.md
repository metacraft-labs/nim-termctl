# nim-termctl

Cross-platform terminal control for Nim - the Nim equivalent of Rust's
[Crossterm](https://github.com/crossterm-rs/crossterm).

## What this library does

`nim-termctl` *drives* a host terminal: raw mode, alt-screen, mouse
capture, cursor control, SGR colors, structured key/mouse event decoding,
signal-safe restoration, and Win32 console-mode + ConPTY support.

It is the *opposite half* of `nim-libvterm`:

- `nim-libvterm` *parses* terminal output coming from a child process.
- `nim-termctl` *produces* terminal control output to the host terminal.

Use cases:

- Production drivers for an interactive TUI (IsoNim-TUI's PosixDriver and
  WindowsDriver consume this).
- Any Nim TUI that needs raw mode, mouse capture, and structured key
  events without the buffer-model abstraction that libraries like
  `illwill` impose.
- Image emission via Sixel, Kitty graphics, or iTerm2 inline-image
  protocols (deferred encoders shipped in follow-up work).

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the default matrix point (orc + release + threads:on)
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

Charter matrix recipes (CI runs each as a separate matrix cell):

```sh
just test-arc        # arc memory manager, all three modes
just test-orc        # orc memory manager, all three modes
just test-refc       # refc memory manager, all three modes
just test-threads-off
just test-asan       # AddressSanitizer (Linux/clang)
just test-ubsan      # UndefinedBehaviorSanitizer
just test-tsan       # ThreadSanitizer
just test-lsan       # LeakSanitizer
just test-valgrind   # secondary leak verification
just test-leaks-heavy  # 100k-cycle leak budgets (slow; CI only)
just test-all        # everything that runs on a Linux runner
```

## Project structure

```
src/
  nim_termctl.nim                       # public top-level - re-exports backend + helpers
  nim_termctl/terminal.nim              # RawMode/AltScreen RAII handles, size, clear, scroll, title
  nim_termctl/cursor.nim                # moveTo, save/restore, position()
  nim_termctl/style.nim                 # Color variant, Attr enum, setForeground, setBackground
  nim_termctl/event.nim                 # Event variant, KeyEvent, MouseEvent, pollEvent, readEvent
  nim_termctl/queue.nim                 # queue/execute templates batching writes
  nim_termctl/parser.nim                # byte-stream -> typed-event parser
  nim_termctl/posix_backend.nim         # POSIX backend - termios, signals, SIGWINCH self-pipe
  nim_termctl/windows_backend.nim       # Windows backend - GetConsoleMode/SetConsoleMode + SetConsoleCtrlHandler + WINDOW_BUFFER_SIZE_EVENT drain
tests/
  test_termctl_raw_mode_round_trip.nim  # L3 spec test
  test_termctl_alt_screen_round_trip.nim
  test_termctl_signal_safe_restore.nim
  test_termctl_panic_safe_restore.nim
  test_termctl_event_decode_corpus.nim
  test_termctl_sigwinch_resize.nim
  test_termctl_no_leaks.nim             # charter leak-budget suite
  test_api_invariants.nim               # charter §1 API rules
  test_windows_signals_compile.nim      # cross-platform compile gate for Win32 signals
  test_windows_ctrl_c_handler.nim       # Windows-only: SetConsoleCtrlHandler runtime test
  test_windows_window_resize.nim        # Windows-only: WINDOW_BUFFER_SIZE_EVENT drain test
  test_helpers.nim                      # shared utilities (no test_ prefix -> not run on its own)
.github/workflows/ci.yml                # full charter matrix on every PR
flake.nix                               # nix devShell + checks
Justfile                                # all build/test/lint recipes
nim_termctl.nimble                      # single-source-of-truth version
```

## Architectural decisions

- **Value-typed RAII handles, no `ref`.** `RawMode`, `AltScreen`,
  `MouseCapture`, `BracketedPaste`, `FocusReporting`, and `EventReader`
  are value `object`s. `=copy` is disabled and `=destroy` restores the
  terminal to its pre-acquisition state. There is no "you must remember
  to call disable()" footgun.

- **Signal-safe restoration.** When `enableRawMode` first runs, it
  installs SIGINT/SIGTERM/SIGHUP handlers and registers an atexit hook.
  All three paths invoke an async-signal-safe restoration function that
  uses only `tcsetattr` and `write(2)` on the raw FD - no malloc, no
  Nim-level allocation. The destructor on `RawMode` runs the same
  function on normal scope exit (which is also what catches panics:
  Nim's destructor calls during stack unwinding restore termios before
  the process actually exits).

- **SIGWINCH via self-pipe.** A SIGWINCH handler writes a single byte
  to a non-blocking self-pipe; `pollEvent` includes the pipe's read
  end in its `select` set and translates the byte into an
  `ekResize` event with a fresh `ioctl(TIOCGWINSZ)` reading. This is
  the only POSIX-portable way to surface async signals to a sync event
  loop without TOCTOU.

- **Parser is incremental and stateful.** `parser.nim` carries a
  byte-buffer accumulator, an `escapeStartedAt` timestamp for
  bare-Escape disambiguation, and a `partialUtf8` continuation buffer.
  Mirrors the shape of Textual's `_xterm_parser.py` but in pure Nim.
  Input is fed from any byte source (`feed`); output is a queue of
  typed `Event`s that the public `pollEvent`/`readEvent` API drains.

- **`when defined(gcDestructors)` conditional `=destroy`.** Required so
  refc compiles - Nim 2.x's `proc =destroy(s: T)` is gated on
  `defined(gcDestructors)` (i.e. arc/orc); under `--mm:refc` the older
  `proc =destroy(s: var T)` signature is still enforced.

- **Image encoders are pure Nim.** Sixel, Kitty graphics, and iTerm2
  encoders are pure Nim - no FFI to libsixel (which is LGPL and would
  taint our MIT licensing). Floyd-Steinberg dithering and 256-color
  palette quantization for Sixel; base64 chunking for Kitty.

## Coding conventions

- `--styleCheck:usages --styleCheck:error` is enforced - use `camelCase`
  identifiers. The Justfile bakes this into every nim invocation.
- Public types are value `object`s. `ref object` is forbidden in the
  public API (charter §1).
- Public APIs never expose raw `ptr`. Use `openArray[T]`, `seq[byte]`,
  `string`, or typed handles.
- `cast` is forbidden in the public API; use sparingly internally and
  justify each use in a comment (currently only at the FFI boundary
  and where `openArray[byte]` needs to be exposed as `pointer` for
  libc `write(2)`).
- Every test is a real-stack integration test - no mocks. Tests
  exercise real ptys (POSIX) or real Win32 pseudo-consoles.

## Specs

The authoritative specifications for this library live in the
`codetracer-specs` repo:

- `Front-Ends/IsoNim/isonim-tui.milestones.org` - see "L3: nim-termctl"
  and the "Memory-safety + testing-rigor charter".

When user requests change the public API, update the spec in the same
change set.
