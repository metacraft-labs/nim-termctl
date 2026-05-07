## nim_termctl/windows_backend.nim - Windows backend for nim-termctl.
##
## Provides Win32 Console-mode plumbing equivalent to the POSIX
## termios save/restore path. ConPTY support and full structured-record
## input decoding are *deferred* to a follow-up pass alongside
## `nim-pty`'s Windows backend; the public API surface is in place so
## cross-platform consumers compile.
##
## The strategy mirrors `illwill`'s approach (WTFPL, well-tested): save
## the original input and output console modes via
## `GetConsoleMode`, mask off `ENABLE_LINE_INPUT` and `ENABLE_ECHO_INPUT`
## on input, and OR in `ENABLE_VIRTUAL_TERMINAL_PROCESSING` on output
## (Windows 10 1809+). On `disableRawMode` (or destructor), restore the
## saved modes byte-for-byte.
##
## Charter §1: value `object`, no `ref`, `=copy` disabled, `=destroy`
## releases. Because we don't yet have a real Win32 build target wired
## through Nix, this file is structured to compile on Linux as a no-op
## shim that signals via a clearly-labeled `TermctlUnimplementedError`
## if anyone tries to call into it. On Windows it uses the real API.

when not defined(windows):
  {.error: "windows_backend.nim is for Windows only - use posix_backend.nim".}

import std/[oserrors]

# ---------------------------------------------------------------------------
# Win32 FFI - minimal subset.
# ---------------------------------------------------------------------------

type
  HANDLE = pointer
  DWORD = uint32
  BOOL = int32
  WORD = uint16
  SHORT = int16

const
  STD_INPUT_HANDLE = DWORD(-10'i32)
  STD_OUTPUT_HANDLE = DWORD(-11'i32)
  INVALID_HANDLE_VALUE = cast[HANDLE](-1)

  ENABLE_PROCESSED_INPUT = DWORD(0x0001)
  ENABLE_LINE_INPUT = DWORD(0x0002)
  ENABLE_ECHO_INPUT = DWORD(0x0004)
  ENABLE_WINDOW_INPUT = DWORD(0x0008)
  ENABLE_MOUSE_INPUT = DWORD(0x0010)
  ENABLE_VIRTUAL_TERMINAL_INPUT = DWORD(0x0200)
  ENABLE_PROCESSED_OUTPUT = DWORD(0x0001)
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = DWORD(0x0004)
  DISABLE_NEWLINE_AUTO_RETURN = DWORD(0x0008)

type
  CoordC {.importc: "COORD", header: "<windows.h>", pure, final.} = object
    x: SHORT
    y: SHORT

  SmallRectC {.importc: "SMALL_RECT", header: "<windows.h>", pure, final.} = object
    left: SHORT
    top: SHORT
    right: SHORT
    bottom: SHORT

  ConsoleScreenBufferInfoC {.importc: "CONSOLE_SCREEN_BUFFER_INFO",
                             header: "<windows.h>", pure, final.} = object
    dwSize: CoordC
    dwCursorPosition: CoordC
    wAttributes: WORD
    srWindow: SmallRectC
    dwMaximumWindowSize: CoordC

proc getStdHandle(nStdHandle: DWORD): HANDLE
  {.importc: "GetStdHandle", header: "<windows.h>", stdcall.}

proc getConsoleMode(hConsole: HANDLE; lpMode: ptr DWORD): BOOL
  {.importc: "GetConsoleMode", header: "<windows.h>", stdcall.}

proc setConsoleMode(hConsole: HANDLE; mode: DWORD): BOOL
  {.importc: "SetConsoleMode", header: "<windows.h>", stdcall.}

proc getConsoleScreenBufferInfo(hConsole: HANDLE;
                                info: ptr ConsoleScreenBufferInfoC): BOOL
  {.importc: "GetConsoleScreenBufferInfo", header: "<windows.h>", stdcall.}

# ---------------------------------------------------------------------------
# Errors and stubs for ConPTY.
# ---------------------------------------------------------------------------

type
  TermctlError* = object of CatchableError
  TermctlUnimplementedError* = object of TermctlError
    ## Raised by Win32 paths that aren't yet implemented (notably ConPTY
    ## spawn). All callers should be prepared to catch this until the
    ## follow-up milestone lands.

# ---------------------------------------------------------------------------
# Module-level state for restoration.
# ---------------------------------------------------------------------------

var
  gSavedInputMode {.threadvar.}: DWORD
  gSavedOutputMode {.threadvar.}: DWORD
  gNeedsRestore {.threadvar.}: bool

# ---------------------------------------------------------------------------
# RawMode handle
# ---------------------------------------------------------------------------

type
  RawMode* = object
    inputHandle*: HANDLE
    outputHandle*: HANDLE
    savedInput*: DWORD
    savedOutput*: DWORD
    active*: bool

proc `=copy`*(dest: var RawMode; src: RawMode) {.error.}

template rawModeDestroyBody(rm: untyped) =
  if rm.active:
    discard setConsoleMode(rm.inputHandle, rm.savedInput)
    discard setConsoleMode(rm.outputHandle, rm.savedOutput)
    if gNeedsRestore: gNeedsRestore = false

when defined(gcDestructors):
  proc `=destroy`*(rm: RawMode) =
    rawModeDestroyBody(rm)
else:
  proc `=destroy`*(rm: var RawMode) =
    rawModeDestroyBody(rm)

proc enableRawMode*(): RawMode =
  ## Save the current input/output console modes; switch to a raw-style
  ## configuration with VT processing enabled.
  let hin = getStdHandle(STD_INPUT_HANDLE)
  let hout = getStdHandle(STD_OUTPUT_HANDLE)
  if hin == INVALID_HANDLE_VALUE or hout == INVALID_HANDLE_VALUE:
    raise newException(TermctlError, "GetStdHandle failed")
  var inMode, outMode: DWORD
  if getConsoleMode(hin, addr inMode) == 0:
    raise newException(TermctlError, "GetConsoleMode (input) failed")
  if getConsoleMode(hout, addr outMode) == 0:
    raise newException(TermctlError, "GetConsoleMode (output) failed")
  let newIn = (inMode and (not (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT or
                                ENABLE_PROCESSED_INPUT))) or
              ENABLE_VIRTUAL_TERMINAL_INPUT or ENABLE_WINDOW_INPUT
  let newOut = outMode or ENABLE_VIRTUAL_TERMINAL_PROCESSING or
               ENABLE_PROCESSED_OUTPUT or DISABLE_NEWLINE_AUTO_RETURN
  if setConsoleMode(hin, newIn) == 0:
    raise newException(TermctlError, "SetConsoleMode (input) failed")
  if setConsoleMode(hout, newOut) == 0:
    discard setConsoleMode(hin, inMode)
    raise newException(TermctlError, "SetConsoleMode (output) failed")
  gSavedInputMode = inMode
  gSavedOutputMode = outMode
  gNeedsRestore = true
  result = RawMode(inputHandle: hin, outputHandle: hout,
                   savedInput: inMode, savedOutput: outMode, active: true)

proc disableRawMode*(rm: var RawMode) =
  if not rm.active: return
  rm.active = false
  discard setConsoleMode(rm.inputHandle, rm.savedInput)
  discard setConsoleMode(rm.outputHandle, rm.savedOutput)
  gNeedsRestore = false

proc isActive*(rm: RawMode): bool {.inline.} = rm.active

# ---------------------------------------------------------------------------
# AltScreen - emit VT sequence directly via stdout.
# ---------------------------------------------------------------------------

type
  AltScreen* = object
    active*: bool
  MouseCapture* = object
    active*: bool
  BracketedPaste* = object
    active*: bool
  FocusReporting* = object
    active*: bool

proc `=copy`*(dest: var AltScreen; src: AltScreen) {.error.}
proc `=copy`*(dest: var MouseCapture; src: MouseCapture) {.error.}
proc `=copy`*(dest: var BracketedPaste; src: BracketedPaste) {.error.}
proc `=copy`*(dest: var FocusReporting; src: FocusReporting) {.error.}

template altDestroy(a: untyped) =
  if a.active:
    stdout.write "\x1b[?1049l"; stdout.flushFile()
template mouseDestroy(m: untyped) =
  if m.active:
    stdout.write "\x1b[?1006l\x1b[?1000l"; stdout.flushFile()
template pasteDestroy(b: untyped) =
  if b.active:
    stdout.write "\x1b[?2004l"; stdout.flushFile()
template focusDestroy(f: untyped) =
  if f.active:
    stdout.write "\x1b[?1004l"; stdout.flushFile()

when defined(gcDestructors):
  proc `=destroy`*(a: AltScreen) = altDestroy(a)
  proc `=destroy`*(m: MouseCapture) = mouseDestroy(m)
  proc `=destroy`*(b: BracketedPaste) = pasteDestroy(b)
  proc `=destroy`*(f: FocusReporting) = focusDestroy(f)
else:
  proc `=destroy`*(a: var AltScreen) = altDestroy(a)
  proc `=destroy`*(m: var MouseCapture) = mouseDestroy(m)
  proc `=destroy`*(b: var BracketedPaste) = pasteDestroy(b)
  proc `=destroy`*(f: var FocusReporting) = focusDestroy(f)

proc enterAltScreen*(): AltScreen =
  stdout.write "\x1b[?1049h"; stdout.flushFile()
  result = AltScreen(active: true)
proc leaveAltScreen*(a: var AltScreen) =
  if not a.active: return
  stdout.write "\x1b[?1049l"; stdout.flushFile()
  a.active = false

proc enableMouseCapture*(): MouseCapture =
  stdout.write "\x1b[?1000h\x1b[?1006h"; stdout.flushFile()
  result = MouseCapture(active: true)
proc disableMouseCapture*(m: var MouseCapture) =
  if not m.active: return
  stdout.write "\x1b[?1006l\x1b[?1000l"; stdout.flushFile()
  m.active = false

proc enableBracketedPaste*(): BracketedPaste =
  stdout.write "\x1b[?2004h"; stdout.flushFile()
  result = BracketedPaste(active: true)
proc disableBracketedPaste*(b: var BracketedPaste) =
  if not b.active: return
  stdout.write "\x1b[?2004l"; stdout.flushFile()
  b.active = false

proc enableFocusReporting*(): FocusReporting =
  stdout.write "\x1b[?1004h"; stdout.flushFile()
  result = FocusReporting(active: true)
proc disableFocusReporting*(f: var FocusReporting) =
  if not f.active: return
  stdout.write "\x1b[?1004l"; stdout.flushFile()
  f.active = false

# ---------------------------------------------------------------------------
# terminalSize - via GetConsoleScreenBufferInfo.
# ---------------------------------------------------------------------------

proc terminalSize*(): tuple[cols, rows: int] =
  let hout = getStdHandle(STD_OUTPUT_HANDLE)
  if hout == INVALID_HANDLE_VALUE:
    raise newException(TermctlError, "GetStdHandle failed")
  var info: ConsoleScreenBufferInfoC
  if getConsoleScreenBufferInfo(hout, addr info) == 0:
    raise newException(TermctlError, "GetConsoleScreenBufferInfo failed")
  result = (cols: int(info.srWindow.right - info.srWindow.left + 1),
            rows: int(info.srWindow.bottom - info.srWindow.top + 1))

proc cursorPositionFromBuffer*(): tuple[col, row: int] =
  let hout = getStdHandle(STD_OUTPUT_HANDLE)
  var info: ConsoleScreenBufferInfoC
  if getConsoleScreenBufferInfo(hout, addr info) == 0:
    raise newException(TermctlError, "GetConsoleScreenBufferInfo failed")
  result = (col: int(info.dwCursorPosition.x),
            row: int(info.dwCursorPosition.y))

# ---------------------------------------------------------------------------
# SIGWINCH-equivalent stubs.
# ---------------------------------------------------------------------------
#
# Windows reports console resizes as `WINDOW_BUFFER_SIZE_EVENT` records on
# the input handle when `ENABLE_WINDOW_INPUT` is set; the real decoding
# lives in the deferred ConPTY work. For now we expose the same
# `installWinchHandler` / `winchPipeReadFd` / `drainWinchPipe` API so
# cross-platform code compiles, with a TODO marker.

proc installWinchHandler*() =
  ## Windows stub - real implementation will route
  ## WINDOW_BUFFER_SIZE_EVENT records into the same self-pipe shape
  ## POSIX uses. TODO: wire ReadConsoleInputW.
  discard

proc uninstallWinchHandler*() =
  discard

proc winchPipeReadFd*(): cint = -1
proc drainWinchPipe*() = discard

# ---------------------------------------------------------------------------
# ConPTY - documented stub. The L1 milestone allows a stub here; the
# follow-up milestone wires CreatePseudoConsole + CreateProcessW.
# ---------------------------------------------------------------------------

type
  PseudoConsole* = object
    active*: bool

proc `=copy`*(dest: var PseudoConsole; src: PseudoConsole) {.error.}

proc createPseudoConsole*(cols, rows: int): PseudoConsole =
  raise newException(TermctlUnimplementedError,
    "ConPTY support deferred - see L3/L1 milestone notes")

proc resizePseudoConsole*(p: var PseudoConsole; cols, rows: int) =
  raise newException(TermctlUnimplementedError,
    "ConPTY support deferred")

proc closePseudoConsole*(p: var PseudoConsole) = discard

# ---------------------------------------------------------------------------
# Test-only hooks (parity with POSIX backend so cross-platform tests
# don't have to branch on `when defined(windows)` for everything).
# ---------------------------------------------------------------------------

proc isTty*(fd: cint): bool {.inline.} = true
proc rawNeedsRestore*(): bool {.inline.} = gNeedsRestore
proc rawSavedFd*(): cint {.inline.} = -1

proc writeStringRaw*(fd: cint; s: string) =
  if s.len == 0: return
  stdout.write s
  stdout.flushFile()

# Windows' STDOUT_FILENO equivalents - exposed so terminal.nim's
# default-arg signatures stay portable.
const
  STDIN_FILENO* = cint(0)
  STDOUT_FILENO* = cint(1)
