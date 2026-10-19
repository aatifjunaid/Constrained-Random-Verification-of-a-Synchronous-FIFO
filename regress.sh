#!/usr/bin/env bash
# Golden-RTL regression: every test x several seeds x several geometries.
# All runs must print "RESULT: PASS". Exit status 1 if any does not.
#   SIM=questa ./regress.sh
cd "$(dirname "$0")"
SEEDS=${SEEDS:-"1 2 3 4 5"}
TESTS="smoke random write_heavy read_heavy bursty reset closure regress"
CONFIGS=("" "+define+FIFO_DEPTH=4" "+define+FIFO_DEPTH=8 +define+FIFO_DATA_W=16" "+define+FIFO_DEPTH=64 +define+FIFO_DATA_W=32")
fail=0; total=0
for cfg in "${CONFIGS[@]}"; do
  for t in $TESTS; do
    for s in $SEEDS; do
      total=$((total+1))
      # tests that are not meant to close coverage on their own only need to be error-free;
      # run.sh's verdict already accounts for that (only closure/regress require 100%).
      res=$(./run.sh "$t" "$s" $cfg 2>&1 | grep '^RESULT:' | tail -1)
      case "$res" in
        *PASS*) ;;
        *) fail=$((fail+1)); echo "FAIL cfg='${cfg:-default}' test=$t seed=$s -> ${res:-<no RESULT line>}" ;;
      esac
    done
  done
done
echo "golden regression: $((total-fail))/$total passed"
[ "$fail" -eq 0 ]
