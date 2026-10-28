# Synchronous FIFO with a self-checking SystemVerilog testbench

Parameterized synchronous FIFO, a class-based testbench (generator, driver,
monitor, queue-based scoreboard, covergroups), bound SVA assertions, a
constrained-random coverage-closure test, and a 10-bug mutation setup that
checks the testbench actually catches bugs. Plain SystemVerilog classes and
mailboxes, no UVM library.

Simulated on **Cadence Xcelium 25.03** (EDA Playground): the golden design
passes the full `regress` test with 0 scoreboard errors, 0 assertion failures
and 100% functional coverage.

## Files

```
sync_fifo.sv       DUT (+ BUG_* injection switches)
fifo_sva.sv        assertions + cover properties, bound into the DUT
fifo_if.sv         interface with driver/monitor clocking blocks
fifo_tb_pkg.sv     txn, generator, driver, monitor, scoreboard, coverage, env, tests
tb_top.sv          clock, DUT, test launcher, PASS/FAIL verdict
run.sh             one compile + run          (SIM=questa|vcs|xrun)
regress.sh         golden regression: tests x seeds x 4 geometries
bug_regress.sh     mutation campaign: every bug must make the TB FAIL
```

`run.sh`, `regress.sh` and `bug_regress.sh` are for a local command-line flow
and expect the files under `rtl/`, `sva/`, `tb/` and `sim/` folders. They have
not been run yet, so use the EDA Playground flow below.

## Design spec

| Item | Behaviour |
|---|---|
| Parameters | `DATA_W` (>=2), `DEPTH` (power of 2; TB needs >=4). Defaults: 8 and 16 |
| Reset | synchronous, active-low |
| Write | `wr_en && !full` accepted |
| Read | `rd_en && !empty` accepted; `rdata` + `rdata_valid` appear **one cycle later** (registered read) |
| Overflow | `wr_en && full`: write ignored, `overflow` pulses next cycle |
| Underflow | `rd_en && empty`: read ignored, `underflow` pulses next cycle |
| Simultaneous rd+wr | decisions use the *current* flags, no same-cycle bypass: at full the read wins (write -> overflow); at empty the write wins (read -> underflow) |
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

Nine classes in `fifo_tb_pkg.sv`: `fifo_txn` (one cycle of random stimulus),
`fifo_obs` (one cycle of sampled pins), `fifo_generator`, `fifo_driver`,
`fifo_monitor`, `fifo_scoreboard`, `fifo_coverage`, `fifo_env`, `fifo_test`.

**Scoreboard.** Each monitored cycle is one observation: outputs are the state
after the previous edge, inputs are what the DUT sees at this edge. Per cycle
it (1) checks `full/empty/count/rdata_valid/rdata/overflow/underflow` against
the queue model, then (2) advances the model (`pop_front` for an accepted read,
`push_back` for an accepted write, clear on reset). Comparisons use `!==`, so X
is a failure. Checking starts after the first reset edge.

**Stimulus.** `wr_en` and `rd_en` are constrained with adjustable probability
weights, so phases can push the FIFO toward full or empty. `wdata` is biased
toward the corners (5% all-zeros, 5% all-ones, 90% other).

**Assertions (`fifo_sva`, 17 asserts + 6 covers).** Flags consistent with
`count`, `count` follows accepted writes/reads, `overflow`/`underflow` raised
exactly one cycle after the illegal op (and never spuriously), a rejected
write/read leaves occupancy untouched, `rdata_valid` iff an accepted read,
`rdata` holds when not reading, no X on status pins, reset clears everything.
Failures bump `fail_cnt`, which `tb_top` includes in the verdict. The module is
attached to the DUT with `bind`, so the RTL needs no changes.

**Coverage**

| Covergroup | What it measures |
|---|---|
| `cg_ops` | occupancy level (empty/one/mid/almost-full/full) x operation (idle/wr/rd/wr+rd) = 20 cross bins, plus level transitions (empty<->one, almost-full<->full, 3-cycle stays at full/empty) |
| `cg_data` | written data corners: all-zeros, all-ones, other |
| `cg_flags` | `overflow` / `underflow` observed on the pins, and back-to-back |
| `cg_rst` | reset applied while empty / mid-level / full |

## Tests

Select with `+TEST=<name>` (default `regress`):

| Test | What it does |
|---|---|
| `smoke` | fill, overfill, drain, underdrain, then simultaneous rd+wr (about 60 cycles) |
| `random` | 5000 cycles, 50% write / 50% read |
| `write_heavy` | 5000 cycles, 80% writes |
| `read_heavy` | 5000 cycles, 80% reads |
| `bursty` | alternating near-saturating fill and drain bursts |
| `reset` | resets while empty, mid-level and full, including mid-traffic |
| `closure` | random stimulus until every covergroup is 100% |
| `regress` | all of the above in order, then the closure loop |

**Coverage closure.** `closure` loops: pick random wr/rd weights (5-95%) and a
random length, run the phase, sometimes inject a reset, drain, read
`get_inst_coverage()`; stop at 100% on every covergroup (or on the first
scoreboard error, or after 1000 rounds, which counts as FAIL). The verdict
fails if coverage is not closed.

## Running on EDA Playground

Needs a validated account for the commercial simulators.

1. **Design pane:** paste `sync_fifo.sv`.
2. **Testbench pane:** add tabs `fifo_if.sv`, `fifo_tb_pkg.sv`, `fifo_sva.sv`, `tb_top.sv`. In `testbench.sv` (the default tab) put:
   ```
   `include "fifo_if.sv"
   `include "fifo_tb_pkg.sv"
   `include "fifo_sva.sv"
   `include "tb_top.sv"
   ```
   (or paste the interface into `testbench.sv` and include the other three).
3. **Simulator:** Cadence Xcelium 25.03.
4. **Compile Options:** `-timescale 1ns/1ns -sysv -coverage functional`
5. **Run Options:** `-access +rw` (add `+TEST=smoke` etc. to pick a test; separate plusargs with a space).
6. Click **Run**. The last lines are the verdict:
   ```
   RESULT: PASS scoreboard_errors=0 sva_failures=0 coverage=100.00 closure_rounds=0
   ```

To inject a bug, add `+define+BUG_<NAME>` to Compile Options (one bug per run).
Failing runs print many assertion lines and can hit the Playground's 5000-line
output limit, so use `+TEST=smoke` for bug runs.

## Golden run result (Xcelium 25.03, seed 1, `regress`)

```
[SB]  cycles=16995 checked=16994 writes=4994 reads=4933 data_compares=4933
      overflow_events=3403 underflow_events=3484 errors=0
[COV] cg_ops=100.00% cg_data=100.00% cg_flags=100.00% cg_rst=100.00% | total=100.00%
[TB]  coverage closed after 0 closure rounds
RESULT: PASS scoreboard_errors=0 sva_failures=0 coverage=100.00 closure_rounds=0
```

## Bug injection (mutation testing)

Each bug is a `+define+BUG_<NAME>` compile switch (`` `ifdef ``) in
`sync_fifo.sv`; with none defined the RTL is the golden design. Define only one
per build. A bug the testbench misses would "escape" and point to a hole in the
testbench.

| Bug | What is broken | Result in Xcelium |
|---|---|---|
| `FULL_OFF_BY_ONE` | `full` asserts at DEPTH-1 | CAUGHT (`smoke`): scoreboard (first error cycle 20, FULL mismatch) + SVA `a_full_def` |
| `WPTR_WRAP` | write pointer skips slot 0 after wrap | CAUGHT (`smoke`): scoreboard only (first error cycle 47, DATA mismatch), 0 SVA failures |
| `DATA_ALLONES` | all-ones data stored with bit 0 flipped | CAUGHT (`smoke`): scoreboard only (first error cycle 33, `0xfe` vs `0xff`), 0 SVA failures |
| `RESET_RPTR` | reset does not re-clear the read pointer | CAUGHT (`reset`): scoreboard only (first error cycle 47), 0 SVA failures. Not visible in `smoke`, which has no mid-traffic reset |
| `OVERFLOW_WRITE` | write accepted while full | not yet run |
| `UNDERFLOW_READ` | read accepted while empty | not yet run |
| `SIMUL_COUNT` | rd+wr in the same cycle counts +1 | not yet run |
| `NO_OVERFLOW_FLAG` | `overflow` never pulses | not yet run |
| `UNDERFLOW_FLAG_CORNER` | no `underflow` when wr+rd at empty | not yet run |
| `LAST_ENTRY_DROP` | wr+rd at almost-full counted but not stored | not yet run |

The bugs caught by the scoreboard only (`WPTR_WRAP`, `DATA_ALLONES`,
`RESET_RPTR`) show where flag/count assertions are blind: the end-to-end data
check is what catches them. Update the last six rows as each one is run.

## Simulator support

Needs a simulator with class, covergroup and SVA support (Questa, VCS, Xcelium,
Riviera-PRO). Icarus does not support this testbench, and Verilator's covergroup
support is incomplete.
