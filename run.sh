#!/usr/bin/env bash
# One compile + one run.
#   SIM=questa|vcs|xrun  ./run.sh <test> <seed> [defines...]
# examples:
#   SIM=questa ./run.sh regress 1
#   SIM=vcs    ./run.sh closure 7 +define+FIFO_DEPTH=8 +define+FIFO_DATA_W=16
#   SIM=xrun   ./run.sh regress 3 +define+BUG_WPTR_WRAP
# Prints the simulator log; the last "RESULT:" line is the verdict.
set -euo pipefail
SIM=${SIM:-questa}
TEST=${1:-regress}; SEED=${2:-1}; shift 2 || true
DEFS=("$@")
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES=("$ROOT/rtl/sync_fifo.sv" "$ROOT/sva/fifo_sva.sv" "$ROOT/tb/fifo_if.sv" "$ROOT/tb/fifo_tb_pkg.sv" "$ROOT/tb/tb_top.sv")

# one build dir per define-set so parallel/bug builds never collide
TAG=$(echo "${DEFS[*]:-golden}" | tr -c 'A-Za-z0-9_\n' '_')
B="$ROOT/sim/build/$SIM/$TAG"; mkdir -p "$B"; cd "$B"

case "$SIM" in
  questa)
    vlib work >/dev/null
    vlog -sv -work work "${DEFS[@]}" "${FILES[@]}" >compile.log 2>&1 || { cat compile.log; echo "RESULT: FAIL compile"; exit 1; }
    vsim -c -work work tb_top -sv_seed "$SEED" +TEST="$TEST" -do "run -all; quit -f" ;;
  vcs)
    vcs -full64 -sverilog -timescale=1ns/1ps "${DEFS[@]}" "${FILES[@]}" -o simv >compile.log 2>&1 || { cat compile.log; echo "RESULT: FAIL compile"; exit 1; }
    ./simv +ntb_random_seed="$SEED" +TEST="$TEST" ;;
  xrun)
    xrun -sv -64bit -svseed "$SEED" "${DEFS[@]}" "${FILES[@]}" +TEST="$TEST" -access +r -top tb_top ;;
  *) echo "unknown SIM=$SIM (questa|vcs|xrun)"; exit 2 ;;
esac
