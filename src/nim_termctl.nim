## nim_termctl - cross-platform terminal control for Nim.
##
## Public entry point. Re-exports terminal/cursor/style/event/queue/parser
## modules so callers write `import nim_termctl` and get the entire
## surface.
##
## Quick example:
##
## ```nim
## import std/[options, times, unicode]
## import nim_termctl
##
## block:
##   var raw = enableRawMode()
##   var alt = enterAltScreen()
##   hideCursor()
##   defer: showCursor()
##   setForeground(rgb(255, 64, 64))
##   moveTo(10, 5)
##   write("Hello!")
##   resetStyle()
##   var er = newEventReader()
##   while true:
##     let ev = pollEvent(er, initDuration(milliseconds = 100))
##     if ev.isSome:
##       let e = ev.get()
##       if e.kind == ekKey and e.key.code == kcEsc:
##         break
## # raw and alt destructors restore termios + leave alt-screen.
## ```
##
## The full design rationale - including the no-`ref` / no-`ptr` charter
## constraints and the testing-rigor matrix - lives in
## `Front-Ends/IsoNim/isonim-tui.milestones.org` (sections "L3:
## nim-termctl" and "Memory-safety + testing-rigor charter") in the
## codetracer-specs repo.

import nim_termctl/terminal
import nim_termctl/event
import nim_termctl/event_reader
import nim_termctl/parser
import nim_termctl/image

export terminal
export event
export event_reader
export parser except ParserState  # internal FSM tag - tests import directly
export image
