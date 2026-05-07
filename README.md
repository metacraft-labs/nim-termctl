# nim-termctl

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Cross-platform terminal control for Nim - the Nim equivalent of Rust's
[Crossterm](https://github.com/crossterm-rs/crossterm).

`nim-termctl` *drives* a host terminal: raw mode, alt-screen, mouse
capture, cursor control, SGR colors, structured key/mouse event decoding,
signal-safe restoration, and Win32 console-mode + ConPTY support.

It is the *opposite half* of [`nim-libvterm`](https://github.com/metacraft-labs/nim-libvterm):

- `nim-libvterm` *parses* terminal output coming from a child process.
- `nim-termctl` *produces* terminal control output to the host terminal.

## Quick example

```nim
import std/[options, times]
import nim_termctl

block:
  var raw = enableRawMode()             # destructor restores termios
  var alt = enterAltScreen()            # destructor leaves alt-screen
  hideCursor()
  defer: showCursor()

  setForeground(Color(kind: ckRgb, r: 255, g: 64, b: 64))
  moveTo(10, 5)
  write("Hello, terminal!")
  resetStyle()

  while true:
    let ev = pollEvent(initDuration(milliseconds = 100))
    if ev.isSome:
      let e = ev.get()
      case e.kind
      of ekKey:
        if e.key.code == kcChar and e.key.rune == Rune('q'):
          break
        if e.key.code == kcEsc:
          break
      of ekResize:
        # handle resize
        discard
      else: discard
  # raw and alt are destroyed here -- terminal restored.
```

See `AGENTS.md` for the project layout, charter constraints, and the
authoritative spec link.

## Status

L3 milestone of the IsoNim-TUI Phase G work. POSIX backend (Linux + macOS)
is the load-bearing path. Windows backend is a documented stub with
`SetConsoleMode` plumbing wired up; ConPTY support and full structured-
record input decoding ship in a follow-up alongside `nim-pty`'s Windows
backend.

License: MIT.
