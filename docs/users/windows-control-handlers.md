# Windows control-handler ownership

Windows dispatches console control callbacks synchronously on an OS-created
thread. Keep callbacks short, reentrant, and free of Nim allocation; synchronize
access to captured mutable state. Handler installation does not move callback
execution to an application event loop.

Use `acquireCtrlCHandler(callback)` when a registration has a lexical lifetime:

```nim
block:
  var registration = acquireCtrlCHandler(callback)
  # Use the console while this noncopyable value remains alive.
# The installing thread retires and drains the callback before releasing it.
```

`CtrlRegistration` is a value owner. It cannot be copied or moved to another
thread. Replacing the process registration retires the previous generation;
that generation's owner still keeps its handles and captured callback alive
until its real in-flight callbacks return. A delayed callback uninstalling
itself cannot uninstall a newer generation.

The existing `installCtrlCHandler(callback)` and `uninstallCtrlCHandler()` names
remain available. Legacy installation retains an automatic value owner on the
main Nim thread or a Nim-created worker. Main normal return releases its global
owner; a worker's registered thread-destruction hook releases its owners before
its heap is destroyed. Explicit uninstall remains idempotent and also drains
retired roots on their owner. Cleanup is not delegated to remembering a manual
close call or to eventual garbage collection.

Captured callback registration must occur on its Nim owner thread. An OS control
callback cannot acquire or replace a captured owner; such an attempt refuses
before changing the active registration. Reentrant self-uninstall is supported:
it retires that callback's generation, with final destruction deferred to its
actual owner. Arbitrary external C-thread legacy installation is not a supported
Nim-owner lifetime contract.

`signalEventHandle()` retains its existing borrowed-handle API. Coordinate
external uses with registration lifetime; it does not transfer ownership or
promise validity across concurrent uninstall. `waitForCtrlEvent(timeoutMs)`
instead holds an internal duplicate while waiting. Retirement wakes a pending
wait and returns `false`; a later generation cannot satisfy that old wait.
`-1` requests an infinite wait. Other timeout values must fit a Win32 `DWORD`.

Automatic owner cleanup describes normal Nim scope/thread teardown and the
main-owner exit fallback. Abrupt process termination, default console-event
termination, and non-owner process-level exit do not establish that another
thread's Nim destructors ran. The OS releases process resources on termination;
this is distinct from normal destructor execution. No arbitrary foreign-thread
closure-heap ownership guarantee is added.

Native callbacks require the selected Nim runtime's supported foreign-thread
GC and native TLS configuration. Unsupported configurations refuse callback
installation instead of silently disabling it. The mandatory Windows route runs
the original test suites, real console-event controls, and ownership controls
under the original ORC/release/threads-on recipe. Passing that recipe does not
establish the separate ARC, refc, other mode/threading, or architecture gates.

The public `CtrlCallback` type has no narrowed exception effect. As before,
`CatchableError` failures are consumed. Other Nim `Exception` values remain
fatal: the C callback boundary invokes the real C `abort()` rather than allowing
Nim unwinding into Win32 or silently swallowing a defect. Fatal process exit
is not normal owner-destructor qualification. Callbacks must still avoid Nim
allocation; the additive native catchable-error control preallocates its error
on the installer, dispatches through the OS, then drains before releasing it.
The mandatory native child inventory also raises separately owner-preallocated
base `Exception` and `AssertionDefect` objects from real OS callbacks. It requires
a flushed static prethrow marker and actual abnormal process exit without a
success marker. A silently consumed fatal callback instead drains and exits zero,
which is rejected. No destructor or handle-cleanup claim is made for fatal exit.
