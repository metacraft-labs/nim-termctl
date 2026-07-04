## Reprobuild project file for nim-termctl.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** ``nim-termctl`` is a
## pure-Nim leaf library — cross-platform terminal control (raw mode,
## alt-screen, mouse capture, cursor/SGR control, structured key/mouse
## event decoding, signal-safe restoration, Win32 console-mode + ConPTY).
## It has NO in-scope sibling build dependency: it compiles purely against
## its own ``src/`` tree and the Nim stdlib (``std/posix``, ``std/termios``,
## Win32 ``importc`` surfaces). The ``test_helpers.nim`` module mentions
## nim-pty as an optional aid but the shipped code opens a pty pair via a
## direct ``openpty(3)`` ``importc`` — there is no ``../nim-pty`` path, no
## sibling binary, and no sibling ``requires`` — so there is no
## ``uses: "<sibling>"`` edge, only the toolchain floor.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``nim-stackable-hooks/repro.nim``
## leaf recipes:
##
## * Declares the upstream tool dependencies via ``uses:`` so consumers
##   that depend on this repo (via ``uses: "nim_termctl"``) pick up the
##   same toolchain floor the nimble file's ``requires "nim >= 2.0.0"``
##   implies.
## * Declares ``library nim_termctl`` so consumers can express a workspace
##   dependency on this repo. The importable umbrella is
##   ``src/nim_termctl.nim`` (re-exporting the submodules under
##   ``src/nim_termctl/``); the ``src/`` tree is what the repo's
##   ``Justfile`` puts on ``--path`` (``--path:src``).
## * Emits, per test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template". The BUILD halves collect into ``test-builds``
##   and the EXECUTE halves into ``test`` so ``repro build test`` /
##   ``repro test`` materialise the runnable closure.
##
## **Module search path.** This repo has NO ``config.nims`` — the
## ``Justfile`` supplies ``--path:src --path:tests`` explicitly on every
## ``nim c``. Every test ``import nim_termctl`` (from ``src/``) and the
## POSIX tests additionally ``import test_helpers`` (a sibling under
## ``tests/``), so each BUILD edge passes ``paths = @["src", "tests"]`` to
## reproduce the ``Justfile``'s ``--path`` set exactly.
##
## **Per-test platform gating.** Each edge is gated at extraction to
## mirror the target file's own OS adaptation, so the corpus this host
## runs matches what the repo's own ``nim c -r`` would run:
##
##   * POSIX-only tests ``import std/posix`` (and often ``std/termios``)
##     unconditionally — they compile + run on Linux/macOS but not
##     Windows. Gated ``when not defined(windows)``:
##       ``test_api_invariants`` (``import std/[unittest, posix]``),
##       ``test_termctl_alt_screen_round_trip`` (``std/[unittest, posix,
##       strutils]``), ``test_termctl_raw_mode_round_trip`` /
##       ``test_termctl_panic_safe_restore`` /
##       ``test_termctl_signal_safe_restore`` /
##       ``test_termctl_no_leaks`` (all ``std/[unittest, posix, termios]``),
##       ``test_termctl_sigwinch_resize`` (``std/[unittest, posix]`` +
##       an ``importc "SIGWINCH"``). Their bodies further wrap the
##       Linux-specific ``/proc``/``ioctl`` checks in ``when defined(linux)``
##       arms, but the unconditional ``posix`` import is the compile gate:
##       Windows can't build them, this Linux host runs them to exit 0.
##   * Portable tests — no ``posix`` import, compile + run on every host:
##       ``test_termctl_event_decode_corpus`` (``std/[unittest, unicode]``
##       only); ``test_windows_signals_compile`` (references the
##       cross-platform ``installCtrlCHandler`` surface, real runtime
##       ``check``s on every host); and the two Windows runtime tests
##       ``test_windows_ctrl_c_handler`` / ``test_windows_window_resize``,
##       whose ``when not defined(windows): <skip() suite> else: <Win32
##       runtime>`` head compiles + runs to exit 0 off Windows (the
##       non-Windows arm is a passing ``skip()`` suite — a real unittest
##       run, exit 0).
##
## ``tests/smoke.nim`` is intentionally excluded: it is a stale
## README-example stub that references a removed API (``moveToSeq``) and
## fails to compile even under ``nim check`` on this repo's own tip. It is
## not in the ``Justfile``'s ``tests`` list nor any recipe ``just build`` /
## ``just test`` / ``test-all`` run, so it is not a runnable test on any
## host and yields no edge.
##
## No test file is macOS-only or Linux-only *at compile time* here (unlike
## nim-stackable-hooks): the Linux/macOS split is a runtime ``when
## defined(linux)`` concern inside the POSIX files, not an ``{.error.}``
## compile gate. So on this Linux host every test file yields a runnable
## edge; only Windows would drop the POSIX-only set.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. Without it
## ``repro build`` refuses to run with "typed tool provisioning is
## required for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge below, and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edges. It
# re-exports ``repro_project_dsl`` so the import order is unimportant.
import ct_test_nim_unittest

type
  TermctlTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

const portableTestSpecs: seq[TermctlTestSpec] = @[
  # Tests that compile + run to exit 0 on every host (Linux/macOS/Windows).
  # ``test_termctl_event_decode_corpus`` imports only ``std/[unittest,
  # unicode]`` + ``nim_termctl`` — pure parser exercise, no OS gate.
  TermctlTestSpec(source: "tests/test_termctl_event_decode_corpus.nim",
    binary: "build/test-bin/test_termctl_event_decode_corpus"),
  # NOTE: ``tests/smoke.nim`` is deliberately NOT modelled. It is a stale
  # README-example stub that references a non-existent API (``moveToSeq``)
  # and does not compile even under ``nim check`` on this repo's own tip.
  # It is absent from the ``Justfile``'s ``tests`` list and from every
  # build/test recipe that ``just build`` / ``just test`` / ``test-all``
  # run (only the unused ``test-readme`` recipe touches it, via ``nim
  # check``). It is not a runnable test on this — or any — host, so it
  # yields no edge here.
  # ``test_windows_signals_compile`` references the cross-platform
  # ``installCtrlCHandler`` symbol and asserts it is non-nil on every
  # host; the Windows-only symbol block is behind ``when defined(windows)``.
  TermctlTestSpec(source: "tests/test_windows_signals_compile.nim",
    binary: "build/test-bin/test_windows_signals_compile"),
  # The two Windows runtime tests open with ``when not defined(windows):
  # <suite with skip()> else: <Win32 runtime>``. Off Windows they compile
  # to a passing ``skip()`` suite — a real unittest run that exits 0.
  TermctlTestSpec(source: "tests/test_windows_ctrl_c_handler.nim",
    binary: "build/test-bin/test_windows_ctrl_c_handler"),
  TermctlTestSpec(source: "tests/test_windows_window_resize.nim",
    binary: "build/test-bin/test_windows_window_resize"),
]

const posixOnlyTestSpecs: seq[TermctlTestSpec] = @[
  # These ``import std/posix`` (most also ``std/termios``) unconditionally
  # — they build + run on Linux/macOS but not Windows. Gated
  # ``when not defined(windows)`` at extraction below.
  TermctlTestSpec(source: "tests/test_api_invariants.nim",
    binary: "build/test-bin/test_api_invariants"),
  TermctlTestSpec(source: "tests/test_termctl_raw_mode_round_trip.nim",
    binary: "build/test-bin/test_termctl_raw_mode_round_trip"),
  TermctlTestSpec(source: "tests/test_termctl_alt_screen_round_trip.nim",
    binary: "build/test-bin/test_termctl_alt_screen_round_trip"),
  TermctlTestSpec(source: "tests/test_termctl_signal_safe_restore.nim",
    binary: "build/test-bin/test_termctl_signal_safe_restore"),
  TermctlTestSpec(source: "tests/test_termctl_panic_safe_restore.nim",
    binary: "build/test-bin/test_termctl_panic_safe_restore"),
  TermctlTestSpec(source: "tests/test_termctl_sigwinch_resize.nim",
    binary: "build/test-bin/test_termctl_sigwinch_resize"),
  TermctlTestSpec(source: "tests/test_termctl_no_leaks.nim",
    binary: "build/test-bin/test_termctl_no_leaks"),
]

package nim_termctl:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below); the nimble file requires ``nim >= 2.0.0``. ``gcc`` is
    # the C back-end ``nim c`` shells out to. Sufficient for the path-mode
    # resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

  # Library declaration — the ``src/`` tree the ``Justfile`` puts on
  # ``--path:src`` is importable when this package is consumed via
  # ``uses: "nim_termctl"``. The umbrella is ``src/nim_termctl.nim``;
  # consumers may also import the submodules under ``src/nim_termctl/``.
  library nim_termctl

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile-only BUILD edge + one EXECUTE edge per test file. BUILD
    # halves collect into ``test-builds``; EXECUTE halves collect into
    # ``test`` (each execute edge transitively depends on its build edge).
    #
    # This repo has NO ``config.nims``; the ``Justfile`` compiles every
    # test with ``--path:src --path:tests``. The tests ``import
    # nim_termctl`` (src/) and the POSIX tests ``import test_helpers``
    # (tests/), so ``paths = @["src", "tests"]`` reproduces that search
    # set. ``-d:release`` mirrors the ``Justfile``'s default matrix point
    # (``--mm:orc -d:release --threads:on``); ``buildNimUnittest.build``
    # defaults ``threadsOn = true`` and Nim 2.x defaults ``--mm:orc``.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src", "tests"],
        actionId = "nim_termctl.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false``: the BUILD edge already owns the
      # binary basename as its implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (mirrors the two-edge
      # shape in reprobuild's / nim-stackable-hooks' ``repro.nim``).
      let executeEdge = edge.testBinary.run(
        actionId = "nim_termctl.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    # Portable tests — always in the graph.
    for spec in portableTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    # POSIX-only tests — ``import std/posix`` unconditionally, so they
    # compile/run on Linux + macOS but not Windows. Gated at extraction so
    # they never enter the graph on a Windows host.
    when not defined(windows):
      for spec in posixOnlyTestSpecs:
        emitTestPair(spec.source, spec.binary,
          testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
