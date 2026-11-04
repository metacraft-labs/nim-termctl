## Owned real Win32 console used only by the isolated Windows test children.
## No emulated terminal or product API replacement is used.
##
## Each Windows console test re-executes its own binary as a child that
## detaches from the runner's console and allocates a private one, so the
## product's console-mode changes never touch the parent's console. The
## child is selected by an ENVIRONMENT variable, not by a command-line
## argument: `std/unittest` treats every command-line argument as a test
## filter (`testsFilters.incl(paramStr(i))` in `ensureInitialized`), so an
## argument selector made the child run no test at all while still exiting
## zero. The child also counts the cases that actually passed and reports
## completion only when that count is the number the parent expects, so a
## child that silently runs nothing can never satisfy the parent again.
when not defined(windows):
  {.error: "windows_console_fixture is Windows-only".}

import std/[os, osproc, streams, strtabs, monotimes, times, unittest]

type
  ConsoleHandle = pointer
  ConsoleMode* = culong
    ## Win32 `DWORD` is `unsigned long`; GCC >=14 errors on passing
    ## `uint32*` where the real header expects `LPDWORD`.
  ConsoleBool = int32
  OwnedTestConsole* = object
    input, output: ConsoleHandle
    oldInput, oldOutput: ConsoleHandle
    active: bool

const
  privateConsoleChildVariable* = "NIM_TERMCTL_PRIVATE_CONSOLE_CHILD"
    ## Set (to `privateConsoleChildValue`) only in the isolated child's
    ## environment; see the module comment for why it is not an argument.
  privateConsoleChildValue = "1"
  privateConsoleChildTimeout = initDuration(seconds = 15)
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

proc isPrivateConsoleChild*(): bool =
  ## True in the isolated child started by `runPrivateConsoleChild`. The
  ## child must receive no arguments, or `std/unittest` would filter its
  ## cases by them.
  getEnv(privateConsoleChildVariable) == privateConsoleChildValue and
    paramCount() == 0

# ---------------------------------------------------------------------------
# Child side: count the cases that really ran.
# ---------------------------------------------------------------------------

type
  CaseCounter = ref object of OutputFormatter
    ## Counts finished cases by status. A `ref` is what `std/unittest`'s
    ## formatter interface requires; it never leaves this test fixture.
    passed, failed, skipped: int

method testEnded(counter: CaseCounter; testResult: TestResult) {.gcsafe.} =
  case testResult.status
  of TestStatus.OK: inc counter.passed
  of TestStatus.FAILED: inc counter.failed
  of TestStatus.SKIPPED: inc counter.skipped

var gCaseCounter: CaseCounter

proc countPrivateConsoleCases*() =
  ## Call in the child before its first `suite`. Keeps the default console
  ## formatter (its failure output is what the parent prints) and adds the
  ## counter beside it: adding any formatter suppresses the implicit default.
  gCaseCounter = CaseCounter()
  addOutputFormatter(defaultConsoleFormatter())
  addOutputFormatter(gCaseCounter)

proc reportPrivateConsoleCompletion*(marker: string; expectedCases: int) =
  ## Call in the child after its suites. Prints `marker` only when exactly
  ## `expectedCases` cases passed and none failed or was skipped; otherwise
  ## prints the counts and makes the child exit non-zero.
  doAssert gCaseCounter != nil, "countPrivateConsoleCases was not called"
  let c = gCaseCounter
  if programResult == 0 and c.passed == expectedCases and c.failed == 0 and
      c.skipped == 0:
    echo marker
  else:
    echo "private console child incomplete: passed=", c.passed, " failed=",
      c.failed, " skipped=", c.skipped, " expected=", expectedCases
    if programResult == 0:
      programResult = 1

# ---------------------------------------------------------------------------
# Parent side: run the child and collect everything it wrote.
# ---------------------------------------------------------------------------

type PrivateConsoleChildRun* = object
  timedOut*: bool
  exitCode*: int
  output*: string

proc runPrivateConsoleChild*(): PrivateConsoleChildRun =
  ## Re-executes this test binary as the isolated private-console child,
  ## with the parent's environment plus the child selector and NO arguments,
  ## and waits up to 15 s for it. stdout and stderr are merged.
  var env = newStringTable(modeCaseInsensitive)
  for key, value in envPairs():
    env[key] = value
  env[privateConsoleChildVariable] = privateConsoleChildValue
  let child = startProcess(getAppFilename(), env = env,
    options = {poStdErrToStdOut})
  try:
    let deadline = getMonoTime() + privateConsoleChildTimeout
    while child.running() and getMonoTime() < deadline:
      sleep(10)
    result.timedOut = child.running()
    if result.timedOut:
      child.terminate()
    result.exitCode = child.waitForExit()
    result.output = child.outputStream.readAll()
  finally:
    if child.running():
      child.terminate()
    discard child.waitForExit()
    child.close()

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
  if not isPrivateConsoleChild():
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
