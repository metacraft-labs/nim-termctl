## tests/smoke.nim - tiny "the README example compiles" check.
##
## Builds-only - no run. We don't actually execute it because it would
## want a real terminal. The test recipe in the Justfile compiles it
## via `nim check` rather than `-r`.

import std/[options, times, unicode]
import nim_termctl

when isMainModule:
  # This block exists only so the unused-import warnings don't fire.
  var qw = newQueueWriter()
  qw.queue moveToSeq(0, 0)
  qw.queue fgSeq(rgb(255, 64, 64))
  qw.queue resetSeq()
  let s = takeBuffer(qw)
  doAssert s.len > 0

  var er = newEventReader()
  er.feedString("a")
  let evs = drain(er)
  doAssert evs.len == 1
  doAssert evs[0].key.rune == Rune(int('a'))

  let caps = detectImageSupport()
  discard caps

  # Reference type/value to keep the import meaningful.
  var c: Color = named(ncRed)
  doAssert c.kind == ckNamed

  # Timeouts compile.
  discard initDuration(milliseconds = 100)

  echo "smoke ok"
