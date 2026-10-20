when defined(windows):
  import std/[unittest, os, osproc, streams, strutils, monotimes, times]
  import nim_termctl
  import windows_console_fixture

  const childCompleted = "TERMCTL_PRIVATE_CONSOLE_RESIZE_CASES_COMPLETED"

  type
    WinCoord {.importc: "COORD", header: "<windows.h>", pure, final.} = object
      x {.importc: "X".}: int16
      y {.importc: "Y".}: int16
    WinRect {.importc: "SMALL_RECT", header: "<windows.h>", pure, final.} = object
      left {.importc: "Left".}: int16
      top {.importc: "Top".}: int16
      right {.importc: "Right".}: int16
      bottom {.importc: "Bottom".}: int16
    WinConsoleInfo {.importc: "CONSOLE_SCREEN_BUFFER_INFO", header: "<windows.h>", pure, final.} = object
      dwSize: WinCoord
      dwCursorPosition: WinCoord
      wAttributes: uint16
      srWindow: WinRect
      dwMaximumWindowSize: WinCoord

  proc currentStandardHandle(which: uint32): pointer {.importc: "GetStdHandle", header: "<windows.h>", stdcall.}
  proc currentProcess(): pointer {.importc: "GetCurrentProcess", header: "<windows.h>", stdcall.}
  proc processHandleCount(process: pointer; count: ptr uint32): int32 {.importc: "GetProcessHandleCount", header: "<windows.h>", stdcall.}
  proc waitForHandle(handle: pointer; milliseconds: uint32): uint32 {.importc: "WaitForSingleObject", header: "<windows.h>", stdcall.}
  proc consoleInfo(handle: pointer; info: ptr WinConsoleInfo): int32 {.importc: "GetConsoleScreenBufferInfo", header: "<windows.h>", stdcall.}
  proc largestWindow(handle: pointer): WinCoord {.importc: "GetLargestConsoleWindowSize", header: "<windows.h>", stdcall.}
  proc setWindow(handle: pointer; absolute: int32; rectangle: ptr WinRect): int32 {.importc: "SetConsoleWindowInfo", header: "<windows.h>", stdcall.}

  proc handles(): uint32 =
    if processHandleCount(currentProcess(), addr result) == 0:
      raise newException(IOError, "GetProcessHandleCount failed")

  proc runWindowsCases() =
    let console = openOwnedTestConsole()
    suite "L3: actual private Windows console resize path":
      test "kernel input readiness, real resize record and actual drain":
        check signalEventHandle() == nil
        let baseline = handles()
        installWinchHandler()
        defer:
          uninstallWinchHandler()
          uninstallCtrlCHandler()
        check signalEventHandle() != nil
        check handles() == baseline + 1
        discard pollWindowBufferSize()
        check injectWindowBufferSizeEvent(120, 40)
        check waitForHandle(consoleInputHandle(), 1000) == 0
        let resized = pollWindowBufferSize()
        check resized.hadResize
        check resized.cols == 120
        check resized.rows == 40
        check not pollWindowBufferSize().hadResize

      test "uninstall restores modes and releases its actual wakeup handle":
        let baseline = handles()
        let pre = modes(console)
        installWinchHandler()
        check signalEventHandle() != nil
        uninstallWinchHandler()
        # Windows resize and Ctrl wakeup have explicitly separate lifecycles.
        uninstallCtrlCHandler()
        check signalEventHandle() == nil
        check modes(console) == pre
        check handles() == baseline

      test "terminalSize reports actual controlled private viewport dimensions":
        let output = currentStandardHandle(0xfffffff5'u32)
        var before: WinConsoleInfo
        check consoleInfo(output, addr before) != 0
        let largest = largestWindow(output)
        var columns = min(100, min(int(largest.x), int(before.dwSize.x)))
        var rows = min(30, min(int(largest.y), int(before.dwSize.y)))
        if columns < 2 or rows < 2:
          raise newException(IOError, "Private console cannot provide a real resizable viewport")
        let previousColumns = int(before.srWindow.right - before.srWindow.left + 1)
        let previousRows = int(before.srWindow.bottom - before.srWindow.top + 1)
        if columns == previousColumns and rows == previousRows:
          if columns > 2:
            dec columns
          elif rows > 2:
            dec rows
          else:
            raise newException(IOError, "No distinct valid private viewport available")
        var rectangle = WinRect(left: 0, top: 0, right: int16(columns - 1), bottom: int16(rows - 1))
        check setWindow(output, 1, addr rectangle) != 0
        var actual: WinConsoleInfo
        check consoleInfo(output, addr actual) != 0
        check int(actual.srWindow.right - actual.srWindow.left + 1) == columns
        check int(actual.srWindow.bottom - actual.srWindow.top + 1) == rows
        let size = terminalSize()
        check size.cols == columns
        check size.rows == rows
    if programResult == 0:
      echo childCompleted

  if paramCount() == 1 and paramStr(1) == rawConsoleChildArgument:
    runWindowsCases()
  else:
    suite "L3: retained private Windows console fixture":
      test "all native cases complete with actual console and child wait":
        let child = startProcess(getAppFilename(), args = @[rawConsoleChildArgument],
          options = {poStdErrToStdOut})
        try:
          let deadline = getMonoTime() + initDuration(seconds = 15)
          while child.running() and getMonoTime() < deadline:
            sleep(10)
          let timedOut = child.running()
          if timedOut:
            child.terminate()
          let exitCode = child.waitForExit()
          let output = child.outputStream.readAll()
          checkpoint output
          check not timedOut
          check exitCode == 0
          check childCompleted in output
        finally:
          if child.running():
            child.terminate()
          discard child.waitForExit()
          child.close()
else:
  ## tests/test_termctl_sigwinch_resize.nim - L3 spec test.
  ##
  ## Install the SIGWINCH handler, raise SIGWINCH at ourselves, and
  ## verify the self-pipe receives the byte. Then drain it and check the
  ## state is reset.
  ##
  ## We don't drive `pollEvent` end-to-end here because the public path
  ## reads from STDIN_FILENO which the test runner has captured for its
  ## own output - mixing in fake input would clobber unittest's own
  ## stdout. The lower-level `winchPipeReadFd` and `drainWinchPipe`
  ## hooks are the load-bearing primitives; testing them directly is a
  ## stronger contract.

  import std/[unittest, posix]
  import nim_termctl
  import test_helpers

  # Local SIGWINCH constant (std/posix doesn't declare it).
  var
    TestSIGWINCH {.importc: "SIGWINCH", header: "<signal.h>".}: cint

  suite "L3: SIGWINCH self-pipe":

    test "SIGWINCH writes a byte to the pipe":
      when defined(linux):
        let fdsBefore = countOpenFds()
        installWinchHandler()
        defer: uninstallWinchHandler()
        let fdsAfter = countOpenFds()
        check fdsAfter == fdsBefore + 2  # read + write end of the pipe

        check winchPipeReadFd() >= 0

        # Raise SIGWINCH at ourselves; the handler writes one byte.
        discard kill(getpid(), TestSIGWINCH)

        # Wait briefly for the byte to land.
        var rs: TFdSet
        FD_ZERO(rs)
        let fd = winchPipeReadFd()
        FD_SET(fd, rs)
        var tv: Timeval
        tv.tv_sec = posix.Time(1)
        tv.tv_usec = typeof(tv.tv_usec)(0)
        let n = select(fd + 1, addr rs, nil, nil, addr tv)
        check n == 1

        # drainWinchPipe consumes the byte.
        drainWinchPipe()

        # After drain, the pipe is empty (select with 0 timeout returns 0).
        FD_ZERO(rs)
        FD_SET(fd, rs)
        var tv0: Timeval
        tv0.tv_sec = posix.Time(0)
        tv0.tv_usec = typeof(tv0.tv_usec)(0)
        let n2 = select(fd + 1, addr rs, nil, nil, addr tv0)
        check n2 == 0
      else:
        skip()

    test "uninstall closes the pipe FDs cleanly":
      when defined(linux):
        let baseline = countOpenFds()
        installWinchHandler()
        uninstallWinchHandler()
        check countOpenFds() == baseline
        check winchPipeReadFd() == -1
      else:
        skip()

    test "terminalSize on a pty returns the kernel-recorded size":
      let (master, slave) = openPtyPair()
      defer:
        discard close(master)
        discard close(slave)
      # The default size on a fresh pty is 0x0; we set it via TIOCSWINSZ
      # to verify that terminalSize reads the up-to-date value.
      type
        WinsizeC {.importc: "struct winsize", header: "<sys/ioctl.h>",
                   pure, final.} = object
          ws_row: cushort
          ws_col: cushort
          ws_xpixel: cushort
          ws_ypixel: cushort
      var ws = WinsizeC(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
      var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
      proc cIoctl(fd: cint; request: culong): cint
        {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}
      check cIoctl(slave, TIOCSWINSZ, addr ws) == 0
      let sz = terminalSize(slave)
      check sz.cols == 100
      check sz.rows == 30
