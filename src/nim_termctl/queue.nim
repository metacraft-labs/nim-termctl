## nim_termctl/queue.nim - batching writer for terminal control sequences.
##
## Mirrors Crossterm's `queue!` / `execute!` macros. The basic problem:
## emitting one CSI per `write(2)` is dramatically slower than batching
## hundreds of CSIs into one write. `queue` accumulates strings into a
## buffer; `execute` accumulates and then flushes.
##
## Usage:
##
## ```nim
## var w = newQueueWriter()
## w.queue moveToSeq(0, 0)
## w.queue resetSeq()
## w.queue fgSeq(rgb(255, 0, 0))
## w.queue "Hello"
## w.flush()    # one write to stdout
## ```
##
## All public types are value `object`s. The buffer is a `string` so
## destruction releases it via Nim's normal seq/string destructor.

type
  QueueWriter* = object
    ## A simple in-memory buffer that callers fill via `queue` and drain
    ## via `flush`. No `ref`. No destructor needed - the inner `string`
    ## owns its own memory.
    buf*: string

proc newQueueWriter*(initialCap: int = 256): QueueWriter =
  ## Construct a writer with an initial buffer capacity. Capacity is a
  ## hint - the buffer will grow as needed.
  result.buf = newStringOfCap(initialCap)

proc queue*(w: var QueueWriter; data: string) {.inline.} =
  ## Append a control sequence (or any string) to the buffer.
  w.buf.add data

proc queue*(w: var QueueWriter; data: openArray[string]) =
  ## Append several control sequences in order.
  for s in data: w.buf.add s

proc len*(w: QueueWriter): int {.inline.} = w.buf.len

proc reset*(w: var QueueWriter) {.inline.} =
  ## Discard the buffer without flushing. Useful for tests and for
  ## callers that need to abandon a partially-built batch.
  w.buf.setLen(0)

proc takeBuffer*(w: var QueueWriter): string =
  ## Move the buffer out of the writer. After this, `w.buf` is empty.
  result = move(w.buf)

proc flush*(w: var QueueWriter; sink: proc (s: string) {.closure.}) =
  ## Hand the buffer to `sink` and clear it. The default flush goes to
  ## stdout - see `terminal.nim`'s `flushToStdout` for the production
  ## sink. Tests use a closure that captures into a `string` buffer for
  ## assertions.
  if w.buf.len > 0:
    sink(w.buf)
    w.buf.setLen(0)

# ---------------------------------------------------------------------------
# `execute` template - queue + flush in one go.
# ---------------------------------------------------------------------------

template execute*(w: var QueueWriter; sink: proc (s: string) {.closure.};
                  body: untyped) =
  ## Run `body` with `w` available, then flush.
  ##
  ## Example:
  ## ```nim
  ## w.execute(stdoutSink):
  ##   w.queue moveToSeq(0, 0)
  ##   w.queue "Hello"
  ## ```
  body
  w.flush(sink)
