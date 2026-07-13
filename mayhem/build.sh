#!/usr/bin/env bash
#
# mayhem/build.sh — build the AprilTag fuzz harness, its standalone reproducer, and the
# behavioral test oracle for AprilTools.
#
# AprilTools itself is a thin OpenCV CLI over the vendored AprilTag library (apriltag/):
# it decodes frames to grayscale and runs apriltag_detector_detect(). OpenCV is not in the
# base image and is not the code under test, so we build the AprilTag library (the fuzzed
# code) with sanitizers + DWARF, and link:
#   - /mayhem/apriltools_fuzz              libFuzzer harness (Mayhem target)
#   - /mayhem/apriltools_fuzz-standalone   run-once reproducer (no libFuzzer runtime)
#   - /mayhem/apriltools_oracle            behavioral oracle, NORMAL flags (test.sh runs it)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
# AprilTag sources are vendored under mayhem/apriltag (pinned copy of the apriltag
# submodule) so the image builds air-gapped from committed content alone — a fresh
# checkout's build context carries only the submodule gitlink, not its contents.
AT="$SRC/mayhem/apriltag"
INC="-I$AT"
OUT=/mayhem
BLD="$SRC/mayhem/.build"
rm -rf "$BLD"; mkdir -p "$BLD/san" "$BLD/test"

# Generated tag-family tables are large data files — compile at -O0 (fast, no perf cost at
# run time); the rest of the library at -O1.
TAGS=$(cd "$AT" && ls tag*.c)
LIBSRC=$(cd "$AT" && ls apriltag.c apriltag_pose.c apriltag_quad_thresh.c common/*.c)

# build_lib <objdir> <flags> <archive> — compile the AprilTag library into a static archive.
build_lib() {
  local objdir="$1" flags="$2" ar="$3" f pids=0
  for f in $TAGS; do
    "$CC" $flags -O0 $INC -c "$AT/$f" -o "$objdir/$(basename "$f").o" &
    pids=$((pids+1)); [ "$pids" -ge "$MAYHEM_JOBS" ] && { wait; pids=0; }
  done
  wait; pids=0
  for f in $LIBSRC; do
    "$CC" $flags -O1 $INC -c "$AT/$f" -o "$objdir/$(echo "$f" | tr / _).o" &
    pids=$((pids+1)); [ "$pids" -ge "$MAYHEM_JOBS" ] && { wait; pids=0; }
  done
  wait
  rm -f "$ar"; ar rcs "$ar" "$objdir"/*.o
}

# 1) The fuzzed code: AprilTag library with sanitizers + DWARF < 4.
build_lib "$BLD/san" "$SANITIZER_FLAGS $DEBUG_FLAGS" "$BLD/libapriltag_san.a"

# 2) Harness — libFuzzer engine build + standalone run-once reproducer.
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INC \
  "$SRC/mayhem/fuzz_apriltools.c" "$BLD/libapriltag_san.a" -lpthread -lm \
  -o "$OUT/apriltools_fuzz"
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
  "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/fuzz_apriltools.c" "$BLD/libapriltag_san.a" -lpthread -lm \
  -o "$OUT/apriltools_fuzz-standalone"

# 3) Test oracle — independent NORMAL-flags build (no sanitizer) so it stays an honest
#    functional oracle. $COVERAGE_FLAGS (empty by default) instruments it when requested.
build_lib "$BLD/test" "$COVERAGE_FLAGS" "$BLD/libapriltag_test.a"
"$CC" -O1 $COVERAGE_FLAGS $INC \
  "$SRC/mayhem/oracle_detect.c" "$BLD/libapriltag_test.a" -lpthread -lm \
  -o "$OUT/apriltools_oracle"
