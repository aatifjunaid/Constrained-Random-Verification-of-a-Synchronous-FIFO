# Synchronous FIFO with a self-checking SystemVerilog testbench

Parameterized synchronous FIFO, a class-based testbench (driver, monitor,
queue-based scoreboard, covergroups), bound SVA assertions, a constrained-random
coverage-closure test, and a 10-bug mutation campaign that proves the testbench
actually catches bugs.

```
rtl/sync_fifo.sv        DUT (+ BUG_* injection switches)
sva/fifo_sva.sv         assertions + cover properties, bound into the DUT
tb/fifo_if.sv           interface, driver/monitor clocking blocks
tb/fifo_tb_pkg.sv       txn, generator, driver, monitor, scoreboard, coverage, env, tests
tb/tb_top.sv            clock, DUT, test launcher, PASS/FAIL verdict
sim/run.sh              one compile + run   (SIM=questa|vcs|xrun)
sim/regress.sh          golden regression: tests x seeds x 4 geometries
sim/bug_regress.sh      mutation campaign: every bug must make the TB FAIL
model/mirror.py         Python mirror of everything above (see "Status")
```

## Design spec

| Item | Behaviour |
|---|---|
| Parameters | `DATA_W` (>=2), `DEPTH` (power of 2; TB needs >=4) |
| Reset | synchronous, active-low |
| Write | `wr_en && !full` accepted |
| Read | `rd_en && !empty` accepted; `rdata` + `rdata_valid` appear **one cycle later** |
| Overflow | `wr_en && full`: write ignored, `overflow` pulses next cycle |
| Underflow | `rd_en && empty`: read ignored, `underflow` pulses next cycle |
| Simultaneous rd+wr | decisions use *current* flags: at full the read wins (write -> overflow); at empty the write wins (read -> underflow) |
| Status | `full`, `empty`, `count` (0..DEPTH) |

## Testbench architecture

```
 generator --mbx--> driver --(drv_cb)--> [ fifo_if ] --> DUT (+ bound fifo_sva)
                                              |
                                          (mon_cb, preponed sampling)
                                              v
                                           monitor --mbx--> scoreboard (SV queue model)
                                                     \-mbx-> coverage   (4 covergroups)
```

**Scoreboard.** Each monitored cycle is one observation: outputs are the state
after the previous edge, inputs are what the DUT sees at this edge. So per cycle
it (1) checks `full/empty/count/rdata_valid/rdata/overflow/underflow` against
the queue model, then (2) advances the model (`pop_front` for an accepted read,
`push_back` for an accepted write, clear on reset). Comparisons use `!==`, so X
is a failure. Checking starts after the first reset edge.

**Assertions (`fifo_sva`, 17 asserts + 6 covers)** - flags consistent with
`count`, `count` follows accepted writes/reads, `overflow`/`underflow` raised
exactly one cycle after the illegal op (and never spuriously), a rejected
write/read leaves occupancy untouched, `rdata_valid` iff an accepted read,
`rdata` holds when not reading, no X on status pins, reset clears everything.
Failures bump `fail_cnt`, which `tb_top` includes in the verdict.

**Coverage**

| Covergroup | What it measures |
|---|---|
| `cg_ops` | occupancy level (empty/one/mid/almost-full/full) x operation (idle/wr/rd/wr+rd) = 20 cross bins, plus level transitions (empty<->one, almost-full<->full, 3-cycle stays at full/empty) |
| `cg_data` | written data corners: all-zeros, all-ones, other |
| `cg_flags` | `overflow` / `underflow` observed on the pins, and back-to-back |
| `cg_rst` | reset applied while empty / mid-level / full |

## Running

```bash
cd sim
SIM=questa ./run.sh regress 1                    # one run; last line is RESULT: PASS|FAIL ...
SIM=questa ./run.sh closure 7 +define+FIFO_DEPTH=8 +define+FIFO_DATA_W=16
SIM=questa ./regress.sh                          # golden: all tests x 5 seeds x 4 geometries
SIM=questa ./bug_regress.sh                      # mutation campaign
```

Tests (`+TEST=`): `smoke random write_heavy read_heavy bursty reset closure regress`.
`regress` runs all directed/random tests, then the closure loop.

**Coverage closure.** `closure` loops: pick random wr/rd weights (5-95 %) and a
random length, run the phase, sometimes inject a reset, drain, read
`get_inst_coverage()`; stop at 100 % on every covergroup (or on the first
scoreboard error, or after 1000 rounds -> FAIL). The verdict fails if coverage
is not closed.

Needs a simulator with class + covergroup + SVA support (Questa, VCS, Xcelium,
Riviera/EDA Playground). Icarus does not support this testbench; Verilator's
covergroup support is incomplete.

## Bug injection (mutation testing)

Each bug is a `+define+BUG_<NAME>` in `rtl/sync_fifo.sv`. `bug_regress.sh`
builds each one and requires `RESULT: FAIL`. "Caught by" below is from the
Python mirror (same checks); in a real run the cycle numbers will differ.

| Bug | What is broken | Caught by | Why it is interesting |
|---|---|---|---|
| `OVERFLOW_WRITE` | write accepted while full | scoreboard + SVA | basic overflow protection |
| `UNDERFLOW_READ` | read accepted while empty | scoreboard + SVA | basic underflow protection |
| `FULL_OFF_BY_ONE` | `full` asserts at DEPTH-1 | scoreboard + SVA | flag arithmetic |
| `SIMUL_COUNT` | rd+wr same cycle -> count +1 | scoreboard + SVA | needs simultaneous traffic mid-level |
| `NO_OVERFLOW_FLAG` | `overflow` never pulses | scoreboard + SVA | status-pin bug, data path fine |
| `UNDERFLOW_FLAG_CORNER` | no `underflow` when wr+rd at empty | scoreboard + SVA | needs the (EMPTY, wr+rd) cross bin |
| `WPTR_WRAP` | write pointer skips slot 0 after wrap | **scoreboard only** | only visible after a full wrap |
| `DATA_ALLONES` | all-ones data written with bit 0 flipped | **scoreboard only** | needs the all-ones data bin |
| `LAST_ENTRY_DROP` | wr+rd at almost-full counted but not stored | **scoreboard only** | needs the (ALMOST_FULL, wr+rd) cross bin; count looks right, data is wrong |
| `RESET_RPTR` | reset does not re-clear read pointer | **scoreboard only** | needs a reset after reads, then more traffic |

The four "scoreboard only" bugs are exactly where assertions about flags and
counts are blind: the end-to-end data check is what catches them.

## Status - what has and has not been run

* **The SystemVerilog has not been compiled or simulated.** No HDL simulator
  was available where this was written. Expect to fix small tool-specific
  nits on first compile (e.g. a warning-as-error setting, or a clocking-block
  `#1step` preference).
* `model/mirror.py` is a Python re-implementation of the RTL (golden + all 10
  bugs), scoreboard, assertions, covergroup bins and test phases. Results
  (`python3 model/mirror.py --seeds 20`, geometries 4x8, 8x16, 16x8, 64x32):
  * golden: 0 scoreboard errors, 0 assertion failures, coverage closed on every seed;
  * `closure` alone, cold start, 40 seeds per geometry: closed every time,
    median 14-20 rounds (about 300-4,300 cycles), worst case 88 rounds;
  * no single directed test closes coverage on its own (each leaves 2-16 holes);
  * 10/10 bugs caught on every seed.
  This validates the reference-model rules, the stimulus, the coverage
  definitions and the bug detectability. It does **not** prove the SV compiles
  or that simulator semantics (clocking-block timing, assertion sampling)
  match the mirror.
* First thing to do on a real simulator: run `./regress.sh` then
  `./bug_regress.sh`; if a bug "ESCAPES" there but is caught in the mirror,
  suspect a testbench timing issue rather than a weak stimulus.
