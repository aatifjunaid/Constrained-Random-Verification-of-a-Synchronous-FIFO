#!/usr/bin/env bash
# Mutation campaign: inject each bug into the RTL, run the "regress" test with
# a few seeds, and require the TB to FAIL. A bug that gets "PASS" has ESCAPED
# and means the testbench has a hole.
#   SIM=questa ./bug_regress.sh
cd "$(dirname "$0")"
SEEDS=${SEEDS:-"1 2 3"}
BUGS="BUG_OVERFLOW_WRITE BUG_UNDERFLOW_READ BUG_FULL_OFF_BY_ONE BUG_WPTR_WRAP BUG_SIMUL_COUNT \
BUG_DATA_ALLONES BUG_LAST_ENTRY_DROP BUG_NO_OVERFLOW_FLAG BUG_UNDERFLOW_FLAG_CORNER BUG_RESET_RPTR"
escaped=0
printf "%-28s %-9s %-10s %-8s %s\n" BUG VERDICT SCOREBOARD SVA "first error (cycle)"
for b in $BUGS; do
  caught=0
  for s in $SEEDS; do
    out=$(./run.sh regress "$s" +define+$b 2>&1)
    res=$(echo "$out" | grep '^RESULT:' | tail -1)
    if echo "$res" | grep -q FAIL; then
      sb=$(echo "$res"  | sed -n 's/.*scoreboard_errors=\([0-9]*\).*/\1/p')
      sv=$(echo "$res"  | sed -n 's/.*sva_failures=\([0-9]*\).*/\1/p')
      fc=$(echo "$out"  | sed -n 's/.*first scoreboard error at cycle \([0-9]*\).*/\1/p' | head -1)
      printf "%-28s %-9s %-10s %-8s %s\n" "$b" "CAUGHT" "$sb" "$sv" "${fc:--}"
      caught=1; break
    fi
  done
  if [ $caught -eq 0 ]; then
    printf "%-28s %-9s\n" "$b" "ESCAPED"; escaped=$((escaped+1))
  fi
done
echo "bugs escaped: $escaped"
[ "$escaped" -eq 0 ]
