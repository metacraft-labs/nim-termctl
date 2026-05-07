## nim_termctl/terminal.nim - high-level terminal operations.
##
## This is the user-facing wrapper that combines the platform backend
## (POSIX or Windows) with the cursor/style/queue helpers. The RAII
## handles `RawMode`, `AltScreen`, etc. come from the backend; this file
## adds the convenience procs (`size`, `clear`, `scrollUp`, `setTitle`,
## `position`, `write`).

import std/strutils
import ./cursor

when defined(windows):
  import ./windows_backend
  export windows_backend
else:
  import std/posix
  import ./posix_backend
  export posix_backend

# ---------------------------------------------------------------------------
# Writers - the production sink for queue.nim and the bare-write helpers.
# ---------------------------------------------------------------------------

when not defined(windows):
  proc writeStdout(s: string) =
    ## Production stdout sink for `queue.nim`. Synchronous; raises on real
    ## errors (not on EAGAIN).
    if s.len > 0:
      writeStringRaw(STDOUT_FILENO, s)
else:
  proc writeStdout(s: string) =
    if s.len > 0:
      stdout.write s
      stdout.flushFile()

proc write*(s: string) {.inline.} =
  ## Write a string to stdout immediately. The terminal will see it on
  ## the next select/poll cycle.
  writeStdout(s)

proc writeBytes*(b: openArray[byte]) =
  ## Write raw bytes to stdout. Used by tests that need to feed
  ## arbitrary byte streams (e.g. an event-decode corpus replay).
  if b.len == 0: return
  var s = newString(b.len)
  for i, by in b: s[i] = char(by)
  writeStdout(s)

# ---------------------------------------------------------------------------
# Cursor wrappers - public 0-based coordinates.
# ---------------------------------------------------------------------------

proc moveTo*(col, row: int) {.inline.} =
  ## Move the cursor to (col, row), 0-based. The protocol is 1-based;
  ## this proc adds 1.
  writeStdout(moveToSeq(col, row))

proc moveUp*(n: int = 1) {.inline.} = writeStdout(moveUpSeq(n))
proc moveDown*(n: int = 1) {.inline.} = writeStdout(moveDownSeq(n))
proc moveLeft*(n: int = 1) {.inline.} = writeStdout(moveLeftSeq(n))
proc moveRight*(n: int = 1) {.inline.} = writeStdout(moveRightSeq(n))
proc moveToColumn*(col: int) {.inline.} = writeStdout(moveToColumnSeq(col))
proc moveToRow*(row: int) {.inline.} = writeStdout(moveToRowSeq(row))
proc moveToNextLine*(n: int = 1) {.inline.} =
  writeStdout(moveToNextLineSeq(n))
proc moveToPreviousLine*(n: int = 1) {.inline.} =
  writeStdout(moveToPreviousLineSeq(n))

proc savePosition*() {.inline.} = writeStdout(savePositionSeq())
proc restorePosition*() {.inline.} = writeStdout(restorePositionSeq())

proc hideCursor*() {.inline.} = writeStdout(hideCursorSeq())
proc showCursor*() {.inline.} = writeStdout(showCursorSeq())

proc setCursorShape*(s: CursorShape) {.inline.} =
  writeStdout(setCursorShapeSeq(s))

# ---------------------------------------------------------------------------
# Title / clear / scroll
# ---------------------------------------------------------------------------

proc setTitle*(s: string) =
  ## OSC 0/2 - set window title. We use OSC 2 (window title) which most
  ## terminals accept; OSC 0 sets icon+window which is unwanted on
  ## modern setups.
  writeStdout("\x1b]2;" & s & "\x07")

type
  ClearMode* = enum
    cmAll       ## Whole screen, scrollback preserved.
    cmFromCursorDown
    cmFromCursorUp
    cmCurrentLine
    cmFromCursorRight
    cmFromCursorLeft
    cmPurge     ## Whole screen + scrollback (CSI 3J).

proc clear*(mode: ClearMode = cmAll) =
  ## Clear part or all of the screen.
  case mode
  of cmAll: writeStdout("\x1b[2J\x1b[H")
  of cmFromCursorDown: writeStdout("\x1b[J")
  of cmFromCursorUp: writeStdout("\x1b[1J")
  of cmCurrentLine: writeStdout("\x1b[2K")
  of cmFromCursorRight: writeStdout("\x1b[K")
  of cmFromCursorLeft: writeStdout("\x1b[1K")
  of cmPurge: writeStdout("\x1b[2J\x1b[3J\x1b[H")

proc scrollUp*(n: int = 1) =
  ## CSI Ps S - scroll the visible area up by `n` lines (revealing
  ## blank lines at the bottom).
  if n <= 0: return
  writeStdout("\x1b[" & $n & "S")

proc scrollDown*(n: int = 1) =
  if n <= 0: return
  writeStdout("\x1b[" & $n & "T")

# ---------------------------------------------------------------------------
# size() - portable terminal-size query
# ---------------------------------------------------------------------------

proc size*(): tuple[cols, rows: int] {.inline.} =
  ## Returns the current terminal size in (cols, rows). Raises
  ## `TermctlError` if the call fails (e.g. fd isn't a tty).
  terminalSize()

# ---------------------------------------------------------------------------
# position() - synchronous cursor-position query
# ---------------------------------------------------------------------------
#
# Sends CSI 6n; reads stdin until it sees the response `ESC[<row>;<col>R`.
# This is a blocking primitive and assumes raw mode is active (otherwise
# the terminal driver echoes the response back as text). Callers that
# need non-blocking position info should track moves themselves.

when not defined(windows):
  import std/posix as cposix

  proc position*(): tuple[col, row: int] =
    ## Returns the current cursor position (0-based). Raw mode must be
    ## active for the reply to come through as raw bytes rather than
    ## being echoed.
    writeStdout(deviceStatusReportSeq())
    var buf: array[64, byte]
    var i = 0
    var seenEsc = false
    var s = ""
    while i < buf.len:
      let n = cposix.read(STDIN_FILENO, addr buf[i], 1)
      if n <= 0: break
      let ch = char(buf[i])
      if not seenEsc:
        if ch == '\x1b': seenEsc = true
      else:
        s.add ch
        if ch == 'R': break
      inc i
    # Expect "[<row>;<col>R"
    if s.len < 4 or s[0] != '[' or s[^1] != 'R':
      return (col: 0, row: 0)
    let inner = s[1 .. s.len - 2]
    let parts = inner.split(';')
    if parts.len != 2:
      return (col: 0, row: 0)
    try:
      let row = parseInt(parts[0]) - 1
      let col = parseInt(parts[1]) - 1
      result = (col: col, row: row)
    except CatchableError:
      result = (col: 0, row: 0)
else:
  proc position*(): tuple[col, row: int] =
    ## Windows: query via the console screen buffer info.
    cursorPositionFromBuffer()

# ---------------------------------------------------------------------------
# Style emission - thin wrappers
# ---------------------------------------------------------------------------

import ./style
export style

proc setForeground*(c: Color) {.inline.} = writeStdout(fgSeq(c))
proc setBackground*(c: Color) {.inline.} = writeStdout(bgSeq(c))
proc setAttributes*(attrs: Attrs) {.inline.} = writeStdout(attrSeq(attrs))
proc resetStyle*() {.inline.} = writeStdout(resetSeq())

# ---------------------------------------------------------------------------
# Queue / execute - re-export
# ---------------------------------------------------------------------------

import ./queue
export queue

proc stdoutSink*(s: string) =
  ## Default sink for QueueWriter.flush. Closure-typed.
  writeStdout(s)
