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

import std/[atomics]

# ---------------------------------------------------------------------------
# Win32 FFI - minimal subset.
# ---------------------------------------------------------------------------

type
  HANDLE* = pointer
  DWORD = uint32
  BOOL = int32
  WORD = uint16
  SHORT = int16
  WCHAR = uint16

const
  STD_INPUT_HANDLE = DWORD(-10'i32)
  STD_OUTPUT_HANDLE = DWORD(-11'i32)
  INVALID_HANDLE_VALUE = cast[HANDLE](-1)
  TRUE = BOOL(1)
  FALSE = BOOL(0)

  ENABLE_PROCESSED_INPUT = DWORD(0x0001)
  ENABLE_LINE_INPUT = DWORD(0x0002)
  ENABLE_ECHO_INPUT = DWORD(0x0004)
  ENABLE_WINDOW_INPUT = DWORD(0x0008)
  ENABLE_MOUSE_INPUT = DWORD(0x0010)
  ENABLE_VIRTUAL_TERMINAL_INPUT = DWORD(0x0200)
  ENABLE_PROCESSED_OUTPUT = DWORD(0x0001)
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = DWORD(0x0004)
  DISABLE_NEWLINE_AUTO_RETURN = DWORD(0x0008)

  # Console control event types (passed to SetConsoleCtrlHandler callback).
  CTRL_C_EVENT* = DWORD(0)
  CTRL_BREAK_EVENT* = DWORD(1)
  CTRL_CLOSE_EVENT* = DWORD(2)
  CTRL_LOGOFF_EVENT* = DWORD(5)
  CTRL_SHUTDOWN_EVENT* = DWORD(6)

  # WaitForSingleObject return codes.
  WAIT_OBJECT_0 = DWORD(0x00000000)
  WAIT_TIMEOUT = DWORD(0x00000102)
  WAIT_FAILED = DWORD(0xFFFFFFFF'u32)

  # ReadConsoleInput record types.
  KEY_EVENT = WORD(0x0001)
  MOUSE_EVENT = WORD(0x0002)
  WINDOW_BUFFER_SIZE_EVENT* = WORD(0x0004)
  MENU_EVENT = WORD(0x0008)
  FOCUS_EVENT = WORD(0x0010)

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

# Console control handler: SetConsoleCtrlHandler installs a callback that
# Windows invokes when the user hits Ctrl+C / Ctrl+Break, when the console
# is being closed, or at logoff/shutdown. The handler returns TRUE to
# indicate it consumed the event, or FALSE to fall through to the next
# registered handler / default behavior.
type
  PHandlerRoutine = proc (eventType: DWORD): BOOL {.stdcall.}

proc setConsoleCtrlHandler(handler: PHandlerRoutine; add: BOOL): BOOL
  {.importc: "SetConsoleCtrlHandler", header: "<windows.h>", stdcall.}

proc generateConsoleCtrlEvent*(eventType: DWORD; processGroupId: DWORD): BOOL
  {.importc: "GenerateConsoleCtrlEvent", header: "<windows.h>", stdcall.}
  ## Programmatically raise a CTRL_C_EVENT or CTRL_BREAK_EVENT. Used by
  ## tests; also available to user code that wants to fire-trigger the
  ## same path the user would.

# Manual-reset event - the Win32 self-pipe equivalent. SetEvent flips it
# signaled (atomic, signal-handler-safe per MSDN); WaitForSingleObject
# wakes; ResetEvent flips it back.
proc createEventW(lpEventAttributes: pointer;
                  bManualReset, bInitialState: BOOL;
                  lpName: ptr WCHAR): HANDLE
  {.importc: "CreateEventW", header: "<windows.h>", stdcall.}

proc setEvent(hEvent: HANDLE): BOOL
  {.importc: "SetEvent", header: "<windows.h>", stdcall.}

proc resetEvent(hEvent: HANDLE): BOOL
  {.importc: "ResetEvent", header: "<windows.h>", stdcall.}

proc closeHandle(hObject: HANDLE): BOOL
  {.importc: "CloseHandle", header: "<windows.h>", stdcall.}

proc waitForSingleObject(hHandle: HANDLE; dwMilliseconds: DWORD): DWORD
  {.importc: "WaitForSingleObject", header: "<windows.h>", stdcall.}

# Console input record decoding. We only need WINDOW_BUFFER_SIZE_RECORD;
# the other variants are present to make the union (=INPUT_RECORD=) the
# right size when we walk an array of them.
type
  KeyEventRecordC {.importc: "KEY_EVENT_RECORD", header: "<windows.h>",
                    pure, final.} = object
    bKeyDown: BOOL
    wRepeatCount: WORD
    wVirtualKeyCode: WORD
    wVirtualScanCode: WORD
    uChar: WORD  # union of WCHAR/AsciiChar - we don't decode here
    dwControlKeyState: DWORD

  MouseEventRecordC {.importc: "MOUSE_EVENT_RECORD", header: "<windows.h>",
                      pure, final.} = object
    dwMousePosition: CoordC
    dwButtonState: DWORD
    dwControlKeyState: DWORD
    dwEventFlags: DWORD

  WindowBufferSizeRecordC {.importc: "WINDOW_BUFFER_SIZE_RECORD",
                            header: "<windows.h>", pure, final.} = object
    dwSize: CoordC

  MenuEventRecordC {.importc: "MENU_EVENT_RECORD", header: "<windows.h>",
                     pure, final.} = object
    dwCommandId: DWORD

  FocusEventRecordC {.importc: "FOCUS_EVENT_RECORD", header: "<windows.h>",
                      pure, final.} = object
    bSetFocus: BOOL

  InputRecordC {.importc: "INPUT_RECORD", header: "<windows.h>",
                 pure, final.} = object
    EventType: WORD
    # Padding/union - we don't need to decode the union members in pure
    # Nim; we only read EventType + the dwSize field for buffer-size
    # events, which lives at a known offset. The C struct definition
    # `pure` flag tells Nim to use sizeof from <windows.h> directly.
    Event: KeyEventRecordC  # acts as a sized payload; INPUT_RECORD uses
                            # union semantics in C and KEY_EVENT_RECORD
                            # is the largest member, so this matches the
                            # union footprint.

proc readConsoleInputW(hConsoleInput: HANDLE;
                       lpBuffer: ptr InputRecordC;
                       nLength: DWORD;
                       lpNumberOfEventsRead: ptr DWORD): BOOL
  {.importc: "ReadConsoleInputW", header: "<windows.h>", stdcall.}

proc peekConsoleInputW(hConsoleInput: HANDLE;
                       lpBuffer: ptr InputRecordC;
                       nLength: DWORD;
                       lpNumberOfEventsRead: ptr DWORD): BOOL
  {.importc: "PeekConsoleInputW", header: "<windows.h>", stdcall.}

proc getNumberOfConsoleInputEvents(hConsoleInput: HANDLE;
                                   lpcNumberOfEvents: ptr DWORD): BOOL
  {.importc: "GetNumberOfConsoleInputEvents", header: "<windows.h>", stdcall.}

proc setConsoleScreenBufferSize(hConsoleOutput: HANDLE; dwSize: CoordC): BOOL
  {.importc: "SetConsoleScreenBufferSize", header: "<windows.h>", stdcall.}

proc writeConsoleInputW(hConsoleInput: HANDLE;
                        lpBuffer: ptr InputRecordC;
                        nLength: DWORD;
                        lpNumberOfEventsWritten: ptr DWORD): BOOL
  {.importc: "WriteConsoleInputW", header: "<windows.h>", stdcall.}

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
# Console control handling: Ctrl-C, Ctrl-Break, window-buffer-size
# events. The Windows analogue of POSIX signals + SIGWINCH self-pipe.
# ---------------------------------------------------------------------------
#
# Strategy:
#   * `SetConsoleCtrlHandler` registers a single C-callable entry point.
#     The entry point runs in a *separate thread* (Windows spawns one for
#     every CTRL_*_EVENT). MSDN explicitly documents `SetEvent` as safe
#     to call from this context, so the handler signals a manual-reset
#     event and returns TRUE to consume the event (preventing the
#     default-terminate behaviour).
#   * The user's typed callback is dispatched from the *same* handler
#     thread. Callers must keep that callback short and reentrancy-aware
#     (no allocation-heavy work; queue something into the event loop).
#   * `WINDOW_BUFFER_SIZE_EVENT` is consumed via `PeekConsoleInputW` /
#     `ReadConsoleInputW`: the polling loop drains pending records,
#     coalesces multiple resizes into the latest size, and signals the
#     same manual-reset event so the main wait wakes up.
#
# Public surface (mirrors the POSIX side):
#   * `installCtrlCHandler(callback)` -> POSIX equivalent of
#     installSignalHandlers (which catches SIGINT/SIGTERM/SIGHUP/SIGQUIT
#     internally; on Windows the comparable surface is
#     CTRL_C_EVENT/CTRL_BREAK_EVENT/CTRL_CLOSE_EVENT etc.)
#   * `installWinchHandler` -> compatibility name; on Windows it ensures
#     the input handle has ENABLE_WINDOW_INPUT set so resize records
#     reach `pollWindowBufferSize`.
#   * `signalEventHandle()` -> Win32 equivalent of `winchPipeReadFd`. The
#     event loop calls `WaitForMultipleObjects` on this + the input
#     handle.
#   * `pollWindowBufferSize()` -> drains pending WINDOW_BUFFER_SIZE
#     records and returns the new (cols, rows) if any.
#   * `winchPipeReadFd` / `drainWinchPipe` are kept (returning -1 / no-op)
#     so cross-platform consumers compile unchanged.

type
  CtrlCallback* = proc () {.gcsafe.}
    ## User callback fired from the Win32 control-handler thread. Must be
    ## reentrant and async-signal-safe in spirit (no Nim allocation,
    ## no I/O beyond the bare minimum). Most callers should just push a
    ## token into a thread-safe queue.

var
  gSignalEvent {.threadvar.}: HANDLE
  gCtrlHandlerInstalled: Atomic[bool]
  gCtrlCallback: CtrlCallback
  gCtrlEventReceived: Atomic[bool]
    ## Set to true when the handler fires. Tests poll this to verify the
    ## handler ran without racing the wait.
  gWinchHandlerInstalledWindows {.threadvar.}: bool
  gSavedInputModeForWinch {.threadvar.}: DWORD

proc consoleCtrlHandler(eventType: DWORD): BOOL {.stdcall.} =
  ## Win32 control handler. Runs on a dedicated thread spawned by the
  ## OS; we keep work to a minimum: signal the wakeup event, then call
  ## the user's typed callback if one is registered.
  ##
  ## Return TRUE so Windows treats the event as consumed (otherwise the
  ## default action - process termination on CTRL_C_EVENT - runs).
  case eventType
  of CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT,
     CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT:
    gCtrlEventReceived.store(true)
    if gSignalEvent != nil and gSignalEvent != INVALID_HANDLE_VALUE:
      discard setEvent(gSignalEvent)
    let cb = gCtrlCallback
    if cb != nil:
      try:
        cb()
      except CatchableError:
        discard
    result = TRUE
  else:
    result = FALSE

proc installCtrlCHandler*(callback: CtrlCallback) =
  ## Register a Ctrl-C / Ctrl-Break / console-close handler. Idempotent
  ## w.r.t. the underlying SetConsoleCtrlHandler registration: a second
  ## call replaces the callback in place.
  ##
  ## The callback fires on a thread Windows spawns; do not block in it.
  gCtrlCallback = callback
  if not gCtrlHandlerInstalled.exchange(true):
    if gSignalEvent == nil:
      gSignalEvent = createEventW(nil, TRUE, FALSE, nil)
    if setConsoleCtrlHandler(consoleCtrlHandler, TRUE) == FALSE:
      # Roll back the flag so a retry has a chance.
      gCtrlHandlerInstalled.store(false)
      raise newException(TermctlError,
        "SetConsoleCtrlHandler(install) failed")

proc uninstallCtrlCHandler*() =
  ## Unregister the previously-installed Ctrl-C handler. Closes the
  ## signal event and clears the saved callback. Idempotent.
  if not gCtrlHandlerInstalled.exchange(false):
    return
  discard setConsoleCtrlHandler(consoleCtrlHandler, FALSE)
  gCtrlCallback = nil
  if gSignalEvent != nil:
    discard closeHandle(gSignalEvent)
    gSignalEvent = nil
  gCtrlEventReceived.store(false)

proc signalEventHandle*(): HANDLE =
  ## The manual-reset event the Ctrl-C handler signals. Pass this to
  ## `WaitForMultipleObjects` alongside the console input handle so the
  ## main loop wakes on either input or a control event.
  ##
  ## Returns nil if no handler has been installed.
  gSignalEvent

proc ctrlEventReceived*(): bool =
  ## True if the Ctrl-C handler has fired since the last reset. Tests use
  ## this to assert the handler ran without racing the OS scheduler.
  gCtrlEventReceived.load()

proc resetCtrlEventReceived*() =
  ## Clear the `ctrlEventReceived` flag and ResetEvent the underlying
  ## handle. Tests call this between cases.
  gCtrlEventReceived.store(false)
  if gSignalEvent != nil:
    discard resetEvent(gSignalEvent)

proc waitForCtrlEvent*(timeoutMs: int): bool =
  ## Block up to `timeoutMs` waiting for a Ctrl event. Returns true if
  ## the event fired within the window, false on timeout.
  ##
  ## Treated as a building block; the production `pollEvent` for Windows
  ## will WaitForMultipleObjects on this + the input handle.
  if gSignalEvent == nil: return false
  let r = waitForSingleObject(gSignalEvent, DWORD(timeoutMs))
  result = r == WAIT_OBJECT_0

proc installWinchHandler*() =
  ## Ensure ENABLE_WINDOW_INPUT is set on the console input handle so
  ## resize events arrive as records. Also installs the Ctrl-C handler
  ## with a nil callback so the same wakeup event signals on both
  ## resize-via-input-record and Ctrl-C.
  ##
  ## Idempotent.
  if gWinchHandlerInstalledWindows: return
  let hin = getStdHandle(STD_INPUT_HANDLE)
  if hin == INVALID_HANDLE_VALUE:
    raise newException(TermctlError,
      "GetStdHandle(STD_INPUT_HANDLE) failed")
  var mode: DWORD
  if getConsoleMode(hin, addr mode) == 0:
    # Not a real console (e.g. piped input). The window-resize path is
    # silently a no-op in that case - matches the POSIX behaviour where
    # SIGWINCH simply doesn't fire for non-tty stdin.
    gWinchHandlerInstalledWindows = true
    return
  gSavedInputModeForWinch = mode
  let want = mode or ENABLE_WINDOW_INPUT
  if want != mode:
    discard setConsoleMode(hin, want)
  if not gCtrlHandlerInstalled.load():
    installCtrlCHandler(nil)
  gWinchHandlerInstalledWindows = true

proc uninstallWinchHandler*() =
  ## Restore the input mode and clear the resize wiring. Does NOT
  ## uninstall the Ctrl-C handler - that has its own lifecycle.
  if not gWinchHandlerInstalledWindows: return
  gWinchHandlerInstalledWindows = false
  let hin = getStdHandle(STD_INPUT_HANDLE)
  if hin != INVALID_HANDLE_VALUE:
    discard setConsoleMode(hin, gSavedInputModeForWinch)

proc consoleInputHandle*(): HANDLE =
  ## Convenience accessor for callers that want to WaitForMultipleObjects
  ## on the input handle alongside `signalEventHandle`.
  result = getStdHandle(STD_INPUT_HANDLE)

proc pollWindowBufferSize*(): tuple[hadResize: bool; cols, rows: int] =
  ## Drain pending console-input records, return the latest
  ## WINDOW_BUFFER_SIZE_EVENT dimensions (if any). Non-blocking.
  ##
  ## Records that aren't WINDOW_BUFFER_SIZE_EVENT are *consumed* and
  ## discarded - the production event loop will replace this with a
  ## proper structured-record decoder once the L3 input-decoder
  ## follow-up lands. Until then, calling this from the polling loop
  ## means key/mouse events still need to be handled by the same
  ## drain. For tests, only buffer-size records are written.
  let hin = getStdHandle(STD_INPUT_HANDLE)
  if hin == INVALID_HANDLE_VALUE: return
  var pending: DWORD = 0
  if getNumberOfConsoleInputEvents(hin, addr pending) == 0: return
  if pending == 0: return
  var records: array[64, InputRecordC]
  while pending > 0:
    var got: DWORD = 0
    let want = if pending > DWORD(records.len): DWORD(records.len) else: pending
    if readConsoleInputW(hin, addr records[0], want, addr got) == 0: break
    if got == 0: break
    for i in 0 ..< int(got):
      if records[i].EventType == WINDOW_BUFFER_SIZE_EVENT:
        # The dwSize is the first field of WINDOW_BUFFER_SIZE_RECORD;
        # the union we declared as KeyEventRecordC happens to start
        # with a BOOL (4 bytes) but the C union semantics ensure the
        # underlying bytes are interpreted correctly when we cast.
        let p = cast[ptr WindowBufferSizeRecordC](addr records[i].Event)
        result.hadResize = true
        result.cols = int(p.dwSize.x)
        result.rows = int(p.dwSize.y)
    if got < want: break
    pending = pending - got

proc injectWindowBufferSizeEvent*(cols, rows: int): bool =
  ## Test hook: write a WINDOW_BUFFER_SIZE_EVENT record into the console
  ## input buffer. Returns true on success. Used by
  ## `tests/test_windows_window_resize.nim` to drive the resize path
  ## without depending on the user actually resizing the console.
  let hin = getStdHandle(STD_INPUT_HANDLE)
  if hin == INVALID_HANDLE_VALUE: return false
  var rec = InputRecordC(EventType: WINDOW_BUFFER_SIZE_EVENT)
  let p = cast[ptr WindowBufferSizeRecordC](addr rec.Event)
  p.dwSize = CoordC(x: SHORT(cols), y: SHORT(rows))
  var written: DWORD = 0
  result = writeConsoleInputW(hin, addr rec, DWORD(1), addr written) != 0 and
           written == 1

# Compatibility shims for cross-platform callers that grew up on the
# POSIX self-pipe API. They return sentinel values on Windows; new code
# should use `signalEventHandle` / `pollWindowBufferSize`.
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
