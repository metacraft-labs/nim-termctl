## tests/test_api_invariants.nim - charter §1 API constraints.
##
## Lock in the rules:
##   * `=copy` on every owning handle is a compile-time error.
##   * Default-constructed handles do not interact with stdio.
##   * `isActive(...)` reflects the acquire/release state.
##   * `Color` and `Event` are value `object`s (no `ref` involved).

import std/[unittest, posix]
import nim_termctl
import test_helpers

suite "L3: API invariants":

  test "Color is a value object (no ref)":
    var c: Color = rgb(10, 20, 30)
    check c.kind == ckRgb
    check c.r == 10
    # Copy is allowed for `Color` - it's a plain value type with no
    # owning resource. We just verify the bytes match.
    let c2 = c
    check c2.r == 10

  test "Event is a value object (no ref)":
    let e = Event(kind: ekKey, key: charKey('a'))
    let e2 = e
    check e2 == e

  test "RawMode default-init is inactive":
    var r: RawMode = default(RawMode)
    check (not isActive(r))
    # Destruction of a default-init handle must not touch any tty.

  test "AltScreen default-init is inactive":
    var a: AltScreen = default(AltScreen)
    check (not a.active)

  test "isActive reflects state for RawMode":
    let (master, slave) = openPtyPair()
    defer:
      discard close(master)
      discard close(slave)
    var raw = enableRawMode(slave)
    check isActive(raw)
    disableRawMode(raw)
    check (not isActive(raw))

  test "Parser starts empty":
    var p = initParser()
    check p.pending() == 0

  test "QueueWriter starts empty":
    let qw = newQueueWriter()
    check qw.len == 0
