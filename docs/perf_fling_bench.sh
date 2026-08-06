#!/bin/bash
# Library-grid fling benchmark.
#
# Reusable harness for any "does this change make the library scroll better?" question. It measures
# the grid, not a specific change: the arm being tested is selected with whatever PerfScrollHook
# flags the experiment adds, passed straight through on the command line.
#
# usage: perf_fling_bench.sh <label> [--ez someFlag true ...]
#   PERF_ROUNDS=5 PERF_WARMUP_ROUNDS=3 PERF_SWIPES=12 PERF_OUT=/tmp/perf_<label>.csv
#
# e.g.  perf_fling_bench.sh async       --ez landscapistImage false
#       perf_fling_bench.sh landscapist --ez landscapistImage true
#
# Every guard here exists because a run without it produced garbage. Do not "simplify" them:
#
#   x=10   left margin of the grid, outside every card's hit rect (cards start at x=22). A gesture
#            that lands on a card opens the game, and the run then measures the detail screen —
#            which reads as smooth, monotonic "session drift" rather than as the bug it is.
#   250ms  short swipes (~60ms) do not generate enough MOVE events and degrade into a tap; 250ms is
#            unambiguously a drag and still ~1800px/s, i.e. a real fling.
#   0.7s   between swipes, so the fling settles and consecutive gestures do not coalesce.
#   upward gestures only while measuring: a downward gesture at item 0 activates PullToRefreshBox,
#            which rebuilds the paged library.
#   scrollToStart broadcast to return to the top, so the reset costs no measured frames and cannot
#            trigger pull-to-refresh. scrollToItem loses to a fling that is still settling, so it
#            waits for the fling to die and is sent twice.
#   warmup rounds are active flings: waiting alone does not execute the hot ART/Compose paths.
#   gfxinfo is reset per round, never by restarting the process — a restart throws away the JIT
#            code and measures a colder app than the one under test.
#   the library tab bar is verified before AND after; a run that navigated away is discarded.
#
# Reports every round separately plus the mean, so the spread between rounds stays visible instead
# of being averaged away. Interleave the arms (A B A B) when comparing: a single A-then-B ordering
# flatters whichever arm ran while the device was cooler.

set -u

LABEL="${1:?usage: perf_fling_bench.sh <label> [--ez flag value ...]}"
shift
ROUNDS="${PERF_ROUNDS:-5}"
WARMUP_ROUNDS="${PERF_WARMUP_ROUNDS:-3}"
SWIPES="${PERF_SWIPES:-12}"
PKG=app.gamenative
OUT="${PERF_OUT:-/tmp/perf_${LABEL}.csv}"

on_library() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  adb shell cat /sdcard/ui.xml 2>/dev/null | grep -q 'Steam ('
}

scroll_to_start() {
  sleep 1.5
  adb shell am broadcast -a app.gamenative.PERF_FLAGS --ez scrollToStart true >/dev/null 2>&1
  sleep 1
  adb shell am broadcast -a app.gamenative.PERF_FLAGS --ez scrollToStart true >/dev/null 2>&1
  sleep 1.5
}

fling_pass() {
  local gap="$1"
  for _ in $(seq 1 "$SWIPES"); do
    adb shell input swipe 10 620 10 180 250
    sleep "$gap"
  done
}

# gfxinfo keeps its histogram for the whole process lifetime unless reset, so every round must
# reset first or later rounds inherit earlier frames.
read_metrics() {
  adb shell dumpsys gfxinfo "$PKG" 2>/dev/null | awk '
    /Total frames rendered:/ { f=$NF }
    /Janky frames:/          { jc=$3; jp=$4; gsub(/[()%]/,"",jp) }
    /50th percentile:/       { p50=$3; gsub(/ms/,"",p50) }
    /90th percentile:/       { p90=$3; gsub(/ms/,"",p90) }
    /95th percentile:/       { p95=$3; gsub(/ms/,"",p95) }
    END { printf "%s,%s,%s,%s,%s,%s", f, jc, jp, p50, p90, p95 }
  '
}

if ! on_library; then
  echo "$LABEL: ПРОПУСК — не на экране библиотеки до старта" >&2
  exit 1
fi

# Whatever flags select the arm under test.
if [ "$#" -gt 0 ]; then
  adb shell am broadcast -a app.gamenative.PERF_FLAGS "$@" >/dev/null 2>&1
  sleep 1
fi

scroll_to_start
for _ in $(seq 1 "$WARMUP_ROUNDS"); do
  fling_pass 0.5
  scroll_to_start
  # JIT compilation, finalizers, image loading and GC continue after the gesture stream settles.
  sleep 2
done

echo "round,frames,janky,janky_pct,p50,p90,p95" > "$OUT"
printf "%s: %s rounds x %s swipes\n" "$LABEL" "$ROUNDS" "$SWIPES"

for round in $(seq 1 "$ROUNDS"); do
  adb shell dumpsys gfxinfo "$PKG" reset >/dev/null 2>&1
  fling_pass 0.7
  sleep 1
  local_metrics="$(read_metrics)"
  echo "$round,$local_metrics" >> "$OUT"
  printf "  round %s: %s\n" "$round" "$local_metrics"
  scroll_to_start
  sleep 2
done

if ! on_library; then
  echo "$LABEL: ОТБРАКОВАН — свайп увёл с библиотеки" >&2
  exit 1
fi

awk -F, 'NR>1 {f+=$2; jc+=$3; jp+=$4; p50+=$5; p90+=$6; p95+=$7; n++}
  END { printf "%s MEAN: frames=%.0f janky=%.0f (%.1f%%) p50=%.1fms p90=%.1fms p95=%.1fms\n",
        "'"$LABEL"'", f/n, jc/n, jp/n, p50/n, p90/n, p95/n }' "$OUT"
echo "raw: $OUT"
