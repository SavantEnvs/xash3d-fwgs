#!/usr/bin/env bash
#
# mayhem/test.sh — RUN xash3d-fwgs' own unit tests (built by mayhem/build.sh into build-tests/).
# The engine suite (xash_tests) asserts thousands of values and reports "Done! N passed, M failed";
# the library tests (filesystem/, public/, 3rdparty/) are assert-based executables run one by one.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x build-tests/engine/xash_tests ]; then echo "build-tests/engine/xash_tests missing (build.sh bug)" >&2; emit_ctrf xash3d-fwgs-tests 0 1 0; exit 1; fi

TESTS_DIR="$SRC/build-tests"
export LD_LIBRARY_PATH="$TESTS_DIR/filesystem${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
passed=0; failed=0

# Engine suite: the asserted counters come from the run itself. Require a plausible number of asserts,
# so a program that exits early (or an empty run) cannot pass.
out="$(cd "$TESTS_DIR/engine" && timeout 600 ./xash_tests -dev 2 -runtests 2>&1)"; rc=$?
done_line="$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Done! [0-9]+ passed, [0-9]+ failed' | tail -1)"
if [ -n "$done_line" ]; then
  ep="$(printf '%s' "$done_line" | sed -E 's/.*Done! ([0-9]+) passed, ([0-9]+) failed.*/\1/')"
  ef="$(printf '%s' "$done_line" | sed -E 's/.*Done! ([0-9]+) passed, ([0-9]+) failed.*/\2/')"
else
  ep=0; ef=1
fi
if [ "$rc" -ne 0 ] || [ "$ep" -lt 8000 ]; then ef=$(( ef + 1 )); fi
passed=$(( passed + ep )); failed=$(( failed + ef ))
printf 'engine suite: %s passed, %s failed (rc=%s)\n' "$ep" "$ef" "$rc"

# Library tests: each exits non-zero on a failed assertion. The filesystem ones also print "success".
for t in filesystem/test_caseinsensitive filesystem/test_filecopy filesystem/test_no-init filesystem/test_interface \
         3rdparty/MultiEmulator/test_sha256 \
         public/test_parsefile public/test_atoi public/test_utflib public/test_atlas public/test_fileext \
         public/test_swapstruct public/test_filebase public/test_build public/test_efp public/test_hullsize \
         public/test_strings public/test_siphash; do
  if [ ! -x "$TESTS_DIR/$t" ]; then echo "FAIL $t: not built"; failed=$(( failed + 1 )); continue; fi
  o="$(cd "$TESTS_DIR/$(dirname "$t")" && timeout 120 "./$(basename "$t")" 2>&1)"; r=$?
  case "$t" in filesystem/test_caseinsensitive|filesystem/test_filecopy|filesystem/test_no-init)
    printf '%s' "$o" | grep -qx success || r=1 ;;
  esac
  if [ "$r" -eq 0 ]; then passed=$(( passed + 1 )); else echo "FAIL $t (rc=$r)"; printf '%s\n' "$o" | tail -5; failed=$(( failed + 1 )); fi
done

emit_ctrf xash3d-fwgs-tests "$passed" "$failed" 0
