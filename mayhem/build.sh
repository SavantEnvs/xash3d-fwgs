#!/usr/bin/env bash
#
# mayhem/build.sh — build xash3d-fwgs' libFuzzer entry points and its unit-test suite.
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem, offline and re-runnable.
#
#   build-fuzz/    sanitized engine (libxash.so with the Fuzz_* hooks), via waf `-T sanitize --enable-fuzzer`
#   build-tests/   plain engine + the upstream unit tests (`--enable-tests`), run by mayhem/test.sh
#   run-fuzzer-<t> one libFuzzer binary per hook; it dlopens /mayhem/build-fuzz/engine/libxash.so
#   run-fuzzer-<t>-standalone  the same entry linked against the run-once driver (no libFuzzer runtime)
#
# NB: waf only accepts --enable-fuzzer together with `-T sanitize`, which adds -fsanitize=address,undefined
# itself, so an empty SANITIZER_FLAGS cannot switch the engine's sanitizers off (the harness binaries do honor it).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Bundled deps (libbacktrace, ...) are git submodules already present in the tree; never fetch here.
test -f 3rdparty/libbacktrace/libbacktrace/configure || { echo "submodules missing: checkout with submodules: recursive" >&2; exit 1; }

# 1) Sanitized engine for fuzzing. `-8` forces a 64-bit build; WAFLOCK keeps a separate lock file per out dir.
(
  export WAFLOCK=.lock-waf_fuzz
  export CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LINKFLAGS="$SANITIZER_FLAGS"
  ./waf configure --out=build-fuzz -8 -T sanitize --enable-fuzzer --enable-bundled-deps
  ./waf build --targets=xash -j"$MAYHEM_JOBS"
)

# 2) One harness per Fuzz_* hook (run-fuzzer.c with an empty-input guard), fuzzer + standalone.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o

while read -r target func; do
  pad=()
  [ "$target" = sound-loadmpg ] && pad=(-DMIN_SIZE=32768)
  common=("${pad[@]}" -DFUNC="\"$func\"" -DLIB="\"$SRC/build-fuzz/engine/libxash.so\"" mayhem/harness.c /tmp/lsan_off.o -ldl)
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${common[@]}" -o "/mayhem/run-fuzzer-$target"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/standalone_main.o "${common[@]}" -o "/mayhem/run-fuzzer-$target-standalone"
done <<'LIST'
sound-loadmpg Fuzz_Sound_LoadMPG
sound-parseid3tag Fuzz_Sound_ParseID3Tag
sound-loadwav Fuzz_Sound_LoadWAV
image-loadbmp Fuzz_Image_LoadBMP
image-loadpng Fuzz_Image_LoadPNG
image-loaddds Fuzz_Image_LoadDDS
image-loadtga Fuzz_Image_LoadTGA
image-loadspr Fuzz_Image_LoadSPR
mod-loadmodel Fuzz_Mod_LoadModel
mod-loadspritemodel Fuzz_Mod_LoadSpriteModel
LIST

# 3) Upstream unit tests with the project's normal flags (no sanitizers), separate out dir.
(
  unset CFLAGS CXXFLAGS LINKFLAGS
  export WAFLOCK=.lock-waf_tests
  export CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LINKFLAGS="$COVERAGE_FLAGS"
  ./waf configure --out=build-tests -8 --enable-tests --enable-bundled-deps
  ./waf build -j"$MAYHEM_JOBS"
)
