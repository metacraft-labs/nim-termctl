## Owned real Win32 console used only by the raw-mode test child.
## No emulated terminal or product API replacement is used.
when not defined(windows):
  {.error: "windows_console_fixture is Windows-only".}

import std/os

type
  ConsoleHandle = pointer
  ConsoleMode* = uint32
  ConsoleBool = int32
  OwnedTestConsole* = object
    input, output: ConsoleHandle
    oldInput, oldOutput: ConsoleHandle
    active: bool

const
  rawConsoleChildArgument* = "--termctl-private-raw-console-child"
  stdInput = 0xfffffff6'u32
  stdOutput = 0xfffffff5'u32
  # Win32's documented INVALID_HANDLE_VALUE sentinel at this FFI boundary.
  invalidHandle = cast[ConsoleHandle](-1)

proc allocConsole(): ConsoleBool {.importc: "AllocConsole", header: "<windows.h>", stdcall.}
proc freeConsole(): ConsoleBool {.importc: "FreeConsole", header: "<windows.h>", stdcall.}
proc getStdHandle(which: uint32): ConsoleHandle {.importc: "GetStdHandle", header: "<windows.h>", stdcall.}
proc setStdHandle(which: uint32; handle: ConsoleHandle): ConsoleBool {.importc: "SetStdHandle", header: "<windows.h>", stdcall.}
proc createFileA(name: cstring; access, sharing: uint32; security: pointer;
                 disposition, flags: uint32; templateFile: ConsoleHandle): ConsoleHandle
  {.importc: "CreateFileA", header: "<windows.h>", stdcall.}
proc closeHandle(handle: ConsoleHandle): ConsoleBool {.importc: "CloseHandle", header: "<windows.h>", stdcall.}
proc getConsoleMode(handle: ConsoleHandle; mode: ptr ConsoleMode): ConsoleBool {.importc: "GetConsoleMode", header: "<windows.h>", stdcall.}
proc setConsoleMode(handle: ConsoleHandle; mode: ConsoleMode): ConsoleBool {.importc: "SetConsoleMode", header: "<windows.h>", stdcall.}

proc `=copy`*(dest: var OwnedTestConsole; src: OwnedTestConsole) {.error.}

template destroyConsole(console: untyped) =
  if console.active:
    discard setStdHandle(stdInput, console.oldInput)
    discard setStdHandle(stdOutput, console.oldOutput)
    if console.input != nil and console.input != invalidHandle:
      discard closeHandle(console.input)
    if console.output != nil and console.output != invalidHandle:
      discard closeHandle(console.output)
    discard freeConsole()

when defined(gcDestructors):
  proc `=destroy`*(console: OwnedTestConsole) = destroyConsole(console)
else:
  proc `=destroy`*(console: var OwnedTestConsole) = destroyConsole(console)

proc modes*(console: OwnedTestConsole): tuple[input, output: ConsoleMode] =
  if getConsoleMode(console.input, addr result.input) == 0 or
      getConsoleMode(console.output, addr result.output) == 0:
    raise newException(IOError, "GetConsoleMode failed for owned test console")

proc openOwnedTestConsole*(): OwnedTestConsole =
  if paramCount() != 1 or paramStr(1) != rawConsoleChildArgument:
    raise newException(IOError, "Private console fixture requires isolated test child")
  result.oldInput = getStdHandle(stdInput)
  result.oldOutput = getStdHandle(stdOutput)
  # This is only the isolated child; detaching never changes its parent.
  discard freeConsole()
  if allocConsole() == 0:
    raise newException(IOError, "AllocConsole failed in isolated test child")
  result.active = true
  try:
    result.input = createFileA("CONIN$", 0xc0000000'u32, 3, nil, 3, 0, nil)
    result.output = createFileA("CONOUT$", 0xc0000000'u32, 3, nil, 3, 0, nil)
    if result.input == invalidHandle or result.output == invalidHandle:
      raise newException(IOError, "Opening private console handles failed")
    if setStdHandle(stdInput, result.input) == 0 or setStdHandle(stdOutput, result.output) == 0:
      raise newException(IOError, "Setting private child standard handles failed")
    let before = modes(result)
    # Real cooked baseline: LINE_INPUT, ECHO_INPUT, PROCESSED_INPUT on,
    # VIRTUAL_TERMINAL_INPUT off. Product acquisition must change it.
    if setConsoleMode(result.input, (before.input or 7'u32) and not 0x0200'u32) == 0:
      raise newException(IOError, "Setting real cooked input baseline failed")
  except:
    destroyConsole(result)
    result.active = false
    raise
