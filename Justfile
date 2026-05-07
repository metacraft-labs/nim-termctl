## Justfile - nim-termctl.
##
## Recipe taxonomy:
##   * Top-level aggregates: `build`, `test`, `lint`, `format` / `fmt`.
##   * `test` runs the *default* matrix point (orc + release + threads:on)
##     for fast iteration. The full charter matrix lives under `test-all`
##     and the per-axis recipes (`test-arc`, `test-asan`, etc.) -- those
##     are what CI invokes per matrix cell.
##   * Hermetic flags (`--skipParentCfg --skipUserCfg`) are baked into
##     `nim-flags` so every invocation gets the same isolation.

alias t := test
alias fmt := format

# Path lookups - keep the source layout discoverable.
src-paths := "--path:src --path:tests"

# Hermetic + style checks - applied to every nim invocation in this file.
nim-flags := "--skipParentCfg --skipUserCfg --styleCheck:usages --styleCheck:error"

# The ordered list of test files. Adding a new test_*.nim here gates it
# on CI.
tests := "tests/test_termctl_raw_mode_round_trip.nim tests/test_termctl_alt_screen_round_trip.nim tests/test_termctl_signal_safe_restore.nim tests/test_termctl_panic_safe_restore.nim tests/test_termctl_event_decode_corpus.nim tests/test_termctl_sigwinch_resize.nim tests/test_termctl_no_leaks.nim tests/test_api_invariants.nim"

# --- Default targets (per repo-requirements.md) ---

# Build: compile every test file as a sanity check (no run).
build:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "Building $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -o:test-logs/$(basename $t .nim) $t 2>&1 | tee -a test-logs/build.log; \
    done

# Test: run the default matrix point (orc + release + threads:on).
test: test-orc

# Lint: nim check + nixfmt --check.
lint: lint-nim lint-nix

lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} --mm:orc src/nim_termctl.nim 2>&1 | tee test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} --mm:orc $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      nimpretty src/nim_termctl.nim src/nim_termctl/*.nim tests/*.nim; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

format-nix:
    nixfmt flake.nix

# Single-source-of-truth version bump.
bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' nim_termctl.nimble

# --- Charter matrix (memory managers x compile modes x threading) ---
#
# Each `test-<axis>` recipe runs the full test list under one configuration.
# CI runs them in parallel via the matrix in .github/workflows/ci.yml.

# Memory-manager axes.
test-arc:
    just _matrix arc release on
    just _matrix arc debug on
    just _matrix arc danger on

test-orc:
    just _matrix orc release on
    just _matrix orc debug on
    just _matrix orc danger on

test-refc:
    just _matrix refc release on
    just _matrix refc debug on
    just _matrix refc danger on

# Threading off - only meaningful on a couple of points; expensive to do
# combinatorially.
test-threads-off:
    just _matrix orc release off
    just _matrix arc release off

# Sanitizers (Linux/amd64 only).
test-asan:
    @mkdir -p test-logs
    @for mode in release danger; do \
      for t in {{tests}}; do \
        echo "[asan/$mode] $t"; \
        CC=clang CXX=clang++ \
        nim c {{nim-flags}} {{src-paths}} \
          --mm:orc -d:$mode -d:useMalloc \
          --cc:clang \
          --passC:-fsanitize=address --passL:-fsanitize=address \
          --debugger:native \
          -r $t 2>&1 | tee -a test-logs/asan-$mode.log; \
      done; \
    done

test-ubsan:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[ubsan] $t"; \
      CC=clang CXX=clang++ \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc \
        --cc:clang \
        --passC:-fsanitize=undefined --passL:-fsanitize=undefined \
        -r $t 2>&1 | tee -a test-logs/ubsan.log; \
    done

test-tsan:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[tsan] $t"; \
      CC=clang CXX=clang++ \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc --threads:on \
        --cc:clang \
        --passC:-fsanitize=thread --passL:-fsanitize=thread \
        -r $t 2>&1 | tee -a test-logs/tsan.log; \
    done

test-lsan:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[lsan] $t"; \
      CC=clang CXX=clang++ \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc \
        --cc:clang \
        --passC:-fsanitize=leak --passL:-fsanitize=leak \
        -r $t 2>&1 | tee -a test-logs/lsan.log; \
    done

# Valgrind memcheck - the secondary leak verification beyond LSan.
#
# `--child-silent-after-fork=yes` is required so spurious fork-time
# noise doesn't masquerade as a leak. `--error-exitcode=1` plus
# `set -euo pipefail` plus `${PIPESTATUS[0]}` means valgrind errors
# actually fail the recipe (without those, the `tee` pipe masks the
# exit code and the recipe always exits 0).
test-valgrind:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    for t in {{tests}}; do
      out=test-logs/valgrind-$(basename $t .nim)
      echo "[valgrind] $t"
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc \
        --debugger:native \
        -o:$out $t 2>&1 | tee -a test-logs/valgrind.log
      valgrind --leak-check=full --show-leak-kinds=all --error-exitcode=1 \
        --child-silent-after-fork=yes \
        --suppressions=tests/valgrind.supp \
        $out 2>&1 | tee -a test-logs/valgrind.log
      ec=${PIPESTATUS[0]}
      if [ $ec -ne 0 ]; then
        echo "valgrind reported errors for $t (exit=$ec)"
        exit $ec
      fi
    done

# Heavy-weight (100k cycle) leak tests - opt-in.
test-leaks-heavy:
    @mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} \
      --mm:orc -d:release -d:nimTermctlHeavy \
      -r tests/test_termctl_no_leaks.nim 2>&1 | tee test-logs/leaks-heavy.log

# Convenience aggregate: everything CI runs on a Linux runner.
test-all: test-arc test-orc test-refc test-threads-off
    @echo "Charter primary matrix complete."

# Internal: one matrix cell.  $1=mm, $2=mode, $3=threads
_matrix mm mode threads:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[{{mm}}/{{mode}}/threads:{{threads}}] $t"; \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:{{mm}} -d:{{mode}} --threads:{{threads}} \
        -r $t 2>&1 | tee -a test-logs/{{mm}}-{{mode}}-threads-{{threads}}.log; \
    done

# Clean test-logs and nim caches - useful before a fresh CI-style run.
clean:
    rm -rf test-logs nim-cache
    find tests -maxdepth 1 -type f -executable -name "test_*" -not -name "*.nim" -delete

# Benchmarks - placeholder; perf work lands with M9/M10 driver integrations.
bench:
    @echo "nim-termctl has no benchmarks yet - perf work lands with M9/M10."

# Run the smoke example to make sure the README stays accurate.
test-readme:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} --mm:orc \
      tests/smoke.nim 2>&1 | tee test-logs/readme.log
