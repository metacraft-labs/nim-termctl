## nim_termctl/cursor.nim - cursor positioning and movement.
##
## All sequences here are pure ANSI/VT and work identically on every
## platform that has VT processing enabled (which on Windows requires
## `ENABLE_VIRTUAL_TERMINAL_PROCESSING` - see `windows_backend.nim`).

# ---------------------------------------------------------------------------
# Sequence builders (pure - no I/O)
# ---------------------------------------------------------------------------

proc moveToSeq*(col, row: int): string =
  ## CSI Pl ; Pc H. Both arguments are 1-based at the protocol level; the
  ## public `moveTo` proc accepts 0-based and converts.
  "\x1b[" & $(row + 1) & ";" & $(col + 1) & "H"

proc moveUpSeq*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "A"

proc moveDownSeq*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "B"

proc moveRightSeq*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "C"

proc moveLeftSeq*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "D"

proc moveToColumnSeq*(col: int): string =
  "\x1b[" & $(col + 1) & "G"

proc moveToRowSeq*(row: int): string =
  "\x1b[" & $(row + 1) & "d"

proc moveToNextLineSeq*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "E"

proc moveToPreviousLineSeq*(n: int): string =
  if n <= 0: "" else: "\x1b[" & $n & "F"

proc savePositionSeq*(): string {.inline.} = "\x1b[s"
proc restorePositionSeq*(): string {.inline.} = "\x1b[u"

proc hideCursorSeq*(): string {.inline.} = "\x1b[?25l"
proc showCursorSeq*(): string {.inline.} = "\x1b[?25h"

proc enableBlinkingSeq*(): string {.inline.} = "\x1b[?12h"
proc disableBlinkingSeq*(): string {.inline.} = "\x1b[?12l"

proc deviceStatusReportSeq*(): string {.inline.} =
  ## CSI 6n - asks the terminal to report cursor position. The reply comes
  ## back on stdin as `ESC[<row>;<col>R`. Used by `position()` in
  ## terminal.nim, which round-trips through the input parser.
  "\x1b[6n"

type
  CursorShape* = enum
    ## DECSCUSR cursor-shape values.
    csDefault    = 0
    csBlinkBlock = 1
    csSteadyBlock = 2
    csBlinkUnderline = 3
    csSteadyUnderline = 4
    csBlinkBar = 5
    csSteadyBar = 6

proc setCursorShapeSeq*(s: CursorShape): string =
  ## DECSCUSR: CSI Ps SP q. Sets the cursor shape.
  "\x1b[" & $int(s) & " q"
