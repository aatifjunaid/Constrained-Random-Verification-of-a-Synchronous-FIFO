`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// fifo_tb_pkg : class-based self-checking testbench for sync_fifo
//
//   fifo_txn        one clock cycle of stimulus (rand wr_en / rd_en / wdata)
//   fifo_obs        one clock cycle of observed pins
//   fifo_generator  constrained-random phases (weights steer fill/drain)
//   fifo_driver     drives the interface through the driver clocking block
//   fifo_monitor    samples every cycle -> scoreboard + coverage mailboxes
//   fifo_scoreboard SV queue reference model, cycle-accurate checker
//   fifo_coverage   covergroups (ops x level, transitions, data, flags, reset)
//   fifo_env        wires everything together
//   fifo_test       named tests, incl. a coverage-closure loop
//
// FIFO geometry comes from +define+FIFO_DATA_W / +define+FIFO_DEPTH so the same
// testbench regresses across configurations.
//-----------------------------------------------------------------------------

`ifndef FIFO_DATA_W
  `define FIFO_DATA_W 8
`endif
`ifndef FIFO_DEPTH
  `define FIFO_DEPTH 16
`endif

package fifo_tb_pkg;

  localparam int DATA_W = `FIFO_DATA_W;
  localparam int DEPTH  = `FIFO_DEPTH;
  localparam int CNT_W  = $clog2(DEPTH) + 1;
  localparam bit [DATA_W-1:0] DATA_MAX = '1;

  localparam int unsigned MAX_ERR_PRINT   = 10;
  localparam int unsigned MAX_CLOSURE_RND = 1000;

  typedef virtual fifo_if #(DATA_W, DEPTH) vif_t;

  // Occupancy classes used by coverage. Needs DEPTH >= 4 so that every class
  // is reachable (checked in tb_top).
  typedef enum int unsigned {
    LV_EMPTY, LV_ONE, LV_MID, LV_ALMOST_FULL, LV_FULL
  } level_e;

  function automatic level_e to_level(int unsigned c);
    if      (c == 0)       return LV_EMPTY;
    else if (c == DEPTH)   return LV_FULL;
    else if (c == 1)       return LV_ONE;
    else if (c == DEPTH-1) return LV_ALMOST_FULL;
    else                   return LV_MID;
  endfunction

  //===========================================================================
  // Transaction : one cycle of stimulus
  //===========================================================================
  class fifo_txn;
    rand bit              wr_en;
    rand bit              rd_en;
    rand bit [DATA_W-1:0] wdata;
         bit              rst_n = 1'b1;   // 0 -> hold reset this cycle

    // Knobs (percent probability of asserting wr_en / rd_en). Not rand.
    int unsigned wr_weight = 50;
    int unsigned rd_weight = 50;

    constraint c_wr   { wr_en dist { 1'b1 := wr_weight, 1'b0 := (100 - wr_weight) }; }
    constraint c_rd   { rd_en dist { 1'b1 := rd_weight, 1'b0 := (100 - rd_weight) }; }
    // Bias data toward the corners (all-zeros / all-ones) but keep most random
    constraint c_data { wdata dist { 0 := 5, DATA_MAX := 5, [1:DATA_MAX-1] :/ 90 }; }
  endclass

  //===========================================================================
  // Observation : one cycle of sampled pins (4-state so X is visible)
  //===========================================================================
  class fifo_obs;
    logic                rst_n, wr_en, rd_en;
    logic [DATA_W-1:0]   wdata, rdata;
    logic                rdata_valid, full, empty, overflow, underflow;
    logic [CNT_W-1:0]    count;
  endclass

  //===========================================================================
  // Generator : constrained-random phases
  //===========================================================================
  class fifo_generator;
    mailbox #(fifo_txn) mbx;
    int unsigned        n_sent = 0;

    function new(mailbox #(fifo_txn) mbx);
      this.mbx = mbx;
    endfunction

    // `cycles` random cycles with the given wr/rd probabilities (percent)
    task run_phase(int unsigned cycles, int unsigned wr_w, int unsigned rd_w);
      fifo_txn t;
      repeat (cycles) begin
        t = new();
        t.wr_weight = wr_w;
        t.rd_weight = rd_w;
        if (!t.randomize()) $fatal(1, "[GEN] randomize() failed");
        mbx.put(t);
        n_sent++;
      end
    endtask

    // `cycles` cycles of reset. wr/rd/wdata stay random: the DUT must ignore
    // them while in reset.
    task run_reset(int unsigned cycles);
      fifo_txn t;
      repeat (cycles) begin
        t = new();
        if (!t.randomize()) $fatal(1, "[GEN] randomize() failed");
        t.rst_n = 1'b0;
        mbx.put(t);
        n_sent++;
      end
    endtask
  endclass

  //===========================================================================
  // Driver
  //===========================================================================
  class fifo_driver;
    vif_t               vif;
    mailbox #(fifo_txn) mbx;
    int unsigned        n_driven = 0;

    function new(vif_t vif, mailbox #(fifo_txn) mbx);
      this.vif = vif;
      this.mbx = mbx;
    endfunction

    task run();
      fifo_txn t;
      // Safe values from time 0 so the DUT never sees X on its inputs
      vif.rst_n = 1'b0;
      vif.wr_en = 1'b0;
      vif.rd_en = 1'b0;
      vif.wdata = '0;
      forever begin
        @(vif.drv_cb);
        if (mbx.try_get(t)) begin
          vif.drv_cb.rst_n <= t.rst_n;
          vif.drv_cb.wr_en <= t.wr_en;
          vif.drv_cb.rd_en <= t.rd_en;
          vif.drv_cb.wdata <= t.wdata;
          n_driven++;
        end else begin
          // nothing queued: idle bus, hold rst_n
          vif.drv_cb.wr_en <= 1'b0;
          vif.drv_cb.rd_en <= 1'b0;
        end
      end
    endtask
  endclass

  //===========================================================================
  // Monitor : passive, samples every cycle
  //===========================================================================
  class fifo_monitor;
    vif_t               vif;
    mailbox #(fifo_obs) to_sb;
    mailbox #(fifo_obs) to_cov;

    function new(vif_t vif, mailbox #(fifo_obs) to_sb, mailbox #(fifo_obs) to_cov);
      this.vif    = vif;
      this.to_sb  = to_sb;
      this.to_cov = to_cov;
    endfunction

    task run();
      fifo_obs o;
      forever begin
        @(vif.mon_cb);
        o = new();
        o.rst_n       = vif.mon_cb.rst_n;
        o.wr_en       = vif.mon_cb.wr_en;
        o.rd_en       = vif.mon_cb.rd_en;
        o.wdata       = vif.mon_cb.wdata;
        o.rdata       = vif.mon_cb.rdata;
        o.rdata_valid = vif.mon_cb.rdata_valid;
        o.full        = vif.mon_cb.full;
        o.empty       = vif.mon_cb.empty;
        o.count       = vif.mon_cb.count;
        o.overflow    = vif.mon_cb.overflow;
        o.underflow   = vif.mon_cb.underflow;
        to_sb.put(o);
        to_cov.put(o);       // consumers only read; sharing the handle is safe
      end
    endtask
  endclass

  //===========================================================================
  // Scoreboard : SV-queue reference model + cycle-accurate checker
  //
  // Timing convention. One observation = pins sampled just before clock edge k:
  //   * outputs  (full/empty/count/rdata_valid/rdata/overflow/underflow)
  //       reflect DUT state AFTER edge k-1
  //   * inputs   (wr_en/rd_en/wdata/rst_n) are what the DUT sees AT edge k
  // So per observation we (1) CHECK the outputs against the model's state,
  // then (2) UPDATE the model with the inputs.
  //===========================================================================
  class fifo_scoreboard;
    mailbox #(fifo_obs) mbx;

    // reference model
    bit [DATA_W-1:0] q[$];

    // expected registered outputs (set by the previous edge)
    bit              exp_rvalid = 0;
    bit              exp_ovf    = 0;
    bit              exp_unf    = 0;
    bit [DATA_W-1:0] exp_rdata  = '0;
    bit              seen_reset = 0;      // checks start after the first reset edge

    // statistics
    int unsigned n_cycles = 0, n_checked = 0, n_errors = 0;
    int unsigned n_wr = 0, n_rd = 0, n_ovf = 0, n_unf = 0, n_data_cmp = 0;
    int unsigned first_err_cycle = 0;

    function new(mailbox #(fifo_obs) mbx);
      this.mbx = mbx;
    endfunction

    task run();
      fifo_obs o;
      forever begin
        mbx.get(o);
        n_cycles++;
        check(o);
        update_model(o);
      end
    endtask

    function void err(string what, string detail);
      n_errors++;
      if (n_errors == 1) first_err_cycle = n_cycles;
      if (n_errors <= MAX_ERR_PRINT)
        $error("[SB] cycle %0d: %s mismatch: %s", n_cycles, what, detail);
    endfunction

    // ---- (1) compare DUT outputs with the model ---------------------------
    function void check(fifo_obs o);
      bit exp_full, exp_empty;
      if (!seen_reset) return;               // DUT state is X before first reset
      n_checked++;
      exp_full  = (q.size() == DEPTH);
      exp_empty = (q.size() == 0);

      if (o.full  !== exp_full)
        err("FULL",  $sformatf("got %b exp %b (model size %0d)", o.full, exp_full, q.size()));
      if (o.empty !== exp_empty)
        err("EMPTY", $sformatf("got %b exp %b (model size %0d)", o.empty, exp_empty, q.size()));
      if (o.count !== CNT_W'(q.size()))
        err("COUNT", $sformatf("got %0d exp %0d", o.count, q.size()));

      if (o.rdata_valid !== exp_rvalid)
        err("RDATA_VALID", $sformatf("got %b exp %b", o.rdata_valid, exp_rvalid));
      else if (exp_rvalid) begin
        n_data_cmp++;
        if (o.rdata !== exp_rdata)
          err("DATA", $sformatf("got 0x%0h exp 0x%0h", o.rdata, exp_rdata));
      end

      if (o.overflow  !== exp_ovf)
        err("OVERFLOW",  $sformatf("got %b exp %b", o.overflow, exp_ovf));
      if (o.underflow !== exp_unf)
        err("UNDERFLOW", $sformatf("got %b exp %b", o.underflow, exp_unf));
    endfunction

    // ---- (2) advance the model by one clock edge --------------------------
    function void update_model(fifo_obs o);
      bit full_now, empty_now, do_wr, do_rd;

      if (o.rst_n !== 1'b1) begin            // synchronous reset
        q.delete();
        exp_rvalid = 0; exp_ovf = 0; exp_unf = 0; exp_rdata = '0;
        seen_reset = 1;
        return;
      end
      if (!seen_reset) return;

      full_now  = (q.size() == DEPTH);
      empty_now = (q.size() == 0);
      do_wr     = (o.wr_en === 1'b1) && !full_now;
      do_rd     = (o.rd_en === 1'b1) && !empty_now;

      exp_ovf    = (o.wr_en === 1'b1) && full_now;     // write while full
      exp_unf    = (o.rd_en === 1'b1) && empty_now;    // read  while empty
      exp_rvalid = do_rd;

      // Decisions above use the pre-edge size, so pop-then-push is exact
      if (do_rd) begin exp_rdata = q.pop_front(); n_rd++; end
      if (do_wr) begin q.push_back(o.wdata);      n_wr++; end
      if (exp_ovf) n_ovf++;
      if (exp_unf) n_unf++;
    endfunction

    function void report();
      $display("[SB]  cycles=%0d checked=%0d writes=%0d reads=%0d data_compares=%0d overflow_events=%0d underflow_events=%0d errors=%0d",
               n_cycles, n_checked, n_wr, n_rd, n_data_cmp, n_ovf, n_unf, n_errors);
    endfunction
  endclass

  //===========================================================================
  // Functional coverage
  //===========================================================================
  class fifo_coverage;
    mailbox #(fifo_obs) mbx;

    // values the covergroups look at
    level_e          lvl;
    bit              wr, rd, ovf, unf;
    bit [DATA_W-1:0] wd;
    logic            prev_rstn = 1'bx;

    // 1) What operation happens at which occupancy, and how occupancy moves
    covergroup cg_ops;
      option.per_instance = 1;
      option.name         = "cg_ops";

      cp_op : coverpoint {wr, rd} {
        bins idle    = {2'b00};
        bins wr_only = {2'b10};
        bins rd_only = {2'b01};
        bins wr_rd   = {2'b11};
      }
      cp_lvl : coverpoint lvl;               // one bin per level_e value

      // every operation at every occupancy, incl. write@full, read@empty,
      // wr+rd@full, wr+rd@empty, wr+rd@almost-full ...
      cx_lvl_op : cross cp_lvl, cp_op;

      cp_lvl_trans : coverpoint lvl {
        bins empty_to_one = (LV_EMPTY       => LV_ONE);
        bins one_to_empty = (LV_ONE         => LV_EMPTY);
        bins af_to_full   = (LV_ALMOST_FULL => LV_FULL);
        bins full_to_af   = (LV_FULL        => LV_ALMOST_FULL);
        bins full_stay3   = (LV_FULL  [*3]);
        bins empty_stay3  = (LV_EMPTY [*3]);
      }
    endgroup

    // 2) Data corners on accepted-or-attempted writes
    covergroup cg_data;
      option.per_instance = 1;
      option.name         = "cg_data";
      cp_wdata : coverpoint wd iff (wr) {
        bins all_zeros = {0};
        bins all_ones  = {DATA_MAX};
        bins others    = {[1:DATA_MAX-1]};
      }
    endgroup

    // 3) Error-reporting flags actually observed on the pins
    covergroup cg_flags;
      option.per_instance = 1;
      option.name         = "cg_flags";
      cp_ovf : coverpoint ovf {
        bins pulse    = {1};
        bins b2b      = (1 => 1);
      }
      cp_unf : coverpoint unf {
        bins pulse    = {1};
        bins b2b      = (1 => 1);
      }
    endgroup

    // 4) Reset applied at different occupancies (level = pre-reset level)
    covergroup cg_rst;
      option.per_instance = 1;
      option.name         = "cg_rst";
      cp_rst_lvl : coverpoint lvl {
        bins at_empty = {LV_EMPTY};
        bins at_mid   = {LV_ONE, LV_MID, LV_ALMOST_FULL};
        bins at_full  = {LV_FULL};
      }
    endgroup

    function new(mailbox #(fifo_obs) mbx);
      this.mbx = mbx;
      cg_ops   = new();
      cg_data  = new();
      cg_flags = new();
      cg_rst   = new();
    endfunction

    task run();
      fifo_obs o;
      forever begin
        mbx.get(o);
        sample_obs(o);
      end
    endtask

    function void sample_obs(fifo_obs o);
      if ($isunknown(o.count)) begin         // before first reset edge
        prev_rstn = o.rst_n;
        return;
      end
      lvl = to_level(o.count);
      wr  = (o.wr_en === 1'b1);
      rd  = (o.rd_en === 1'b1);
      wd  = o.wdata;
      ovf = (o.overflow  === 1'b1);
      unf = (o.underflow === 1'b1);

      if (o.rst_n === 1'b1) begin
        cg_ops.sample();
        cg_data.sample();
        cg_flags.sample();
      end else if (prev_rstn === 1'b1) begin  // first cycle of a reset
        cg_rst.sample();
      end
      prev_rstn = o.rst_n;
    endfunction

    function bit closed();
      return (cg_ops.get_inst_coverage()   >= 99.999) &&
             (cg_data.get_inst_coverage()  >= 99.999) &&
             (cg_flags.get_inst_coverage() >= 99.999) &&
             (cg_rst.get_inst_coverage()   >= 99.999);
    endfunction

    function real total();
      return (cg_ops.get_inst_coverage()  + cg_data.get_inst_coverage() +
              cg_flags.get_inst_coverage() + cg_rst.get_inst_coverage()) / 4.0;
    endfunction

    function void report();
      $display("[COV] cg_ops=%6.2f%% cg_data=%6.2f%% cg_flags=%6.2f%% cg_rst=%6.2f%% | total=%6.2f%%",
               cg_ops.get_inst_coverage(), cg_data.get_inst_coverage(),
               cg_flags.get_inst_coverage(), cg_rst.get_inst_coverage(), total());
    endfunction
  endclass

  //===========================================================================
  // Environment
  //===========================================================================
  class fifo_env;
    vif_t               vif;
    mailbox #(fifo_txn) gen2drv;
    mailbox #(fifo_obs) mon2sb, mon2cov;
    fifo_generator      gen;
    fifo_driver         drv;
    fifo_monitor        mon;
    fifo_scoreboard     sb;
    fifo_coverage       cov;

    function new(vif_t vif);
      this.vif = vif;
      gen2drv  = new();
      mon2sb   = new();
      mon2cov  = new();
      gen = new(gen2drv);
      drv = new(vif, gen2drv);
      mon = new(vif, mon2sb, mon2cov);
      sb  = new(mon2sb);
      cov = new(mon2cov);
    endfunction

    task start();
      fork
        drv.run();
        mon.run();
        sb.run();
        cov.run();
      join_none
    endtask

    // Wait until everything generated so far has been driven, observed,
    // checked and sampled.
    task drain();
      wait (drv.n_driven == gen.n_sent);
      repeat (4) @(posedge vif.clk);
      #1;
    endtask
  endclass

  //===========================================================================
  // Tests (select with +TEST=<name>; default "regress")
  //===========================================================================
  class fifo_test;
    fifo_env env;
    string   name;
    int unsigned closure_rounds = 0;

    function new(vif_t vif, string name);
      this.env  = new(vif);
      this.name = name;
    endfunction

    // fill, overfill, drain, underdrain, then simultaneous traffic from empty
    task t_smoke();
      env.gen.run_phase(DEPTH + 4, 100,   0);   // write-only  -> full, overflow
      env.gen.run_phase(DEPTH + 4,   0, 100);   // read-only   -> empty, underflow
      env.gen.run_phase(DEPTH,     100, 100);   // wr+rd from empty
    endtask

    task t_random();       env.gen.run_phase(5000, 50, 50); endtask
    task t_write_heavy();  env.gen.run_phase(5000, 80, 20); endtask
    task t_read_heavy();   env.gen.run_phase(5000, 20, 80); endtask

    // alternate near-saturating fill and drain bursts
    task t_bursty();
      repeat (20) begin
        env.gen.run_phase($urandom_range(2*DEPTH, 3*DEPTH), 90, 10);
        env.gen.run_phase($urandom_range(2*DEPTH, 3*DEPTH), 10, 90);
      end
    endtask

    // resets at every occupancy class, including mid-traffic
    task t_reset();
      repeat (6) begin
        env.gen.run_phase($urandom_range(DEPTH, 3*DEPTH), $urandom_range(10, 90), $urandom_range(10, 90));
        env.gen.run_reset($urandom_range(1, 3));
      end
      env.gen.run_phase(2*DEPTH, 100,   0);  env.gen.run_reset(2);   // reset while full
      env.gen.run_reset(1);
      env.gen.run_phase(DEPTH/2, 100,   0);  env.gen.run_reset(1);   // reset mid-level
      env.gen.run_phase(2*DEPTH, 100,   0);
      env.gen.run_phase(2*DEPTH,   0, 100);  env.gen.run_reset(2);   // reset while empty
      env.gen.run_phase(DEPTH,    60,  40);
    endtask

    // Constrained-random until every covergroup is 100%: each round picks new
    // random wr/rd weights and length, occasionally resets. Stops early on the
    // first scoreboard error (a failing run needs no more stimulus).
    task t_closure();
      int unsigned wr_w, rd_w, cyc;
      while (!env.cov.closed() && env.sb.n_errors == 0 &&
             closure_rounds < MAX_CLOSURE_RND) begin
        wr_w = $urandom_range(5, 95);
        rd_w = $urandom_range(5, 95);
        cyc  = $urandom_range(DEPTH, 8*DEPTH);
        env.gen.run_phase(cyc, wr_w, rd_w);
        if ($urandom_range(0, 2) == 0) env.gen.run_reset($urandom_range(1, 3));
        env.drain();
        closure_rounds++;
      end
    endtask

    task run();
      env.start();
      env.gen.run_reset(3);                    // power-on reset
      case (name)
        "smoke":       t_smoke();
        "random":      t_random();
        "write_heavy": t_write_heavy();
        "read_heavy":  t_read_heavy();
        "bursty":      t_bursty();
        "reset":       t_reset();
        "closure":     t_closure();
        "regress": begin                       // everything, then close coverage
          t_smoke();
          t_random();
          t_write_heavy();
          t_read_heavy();
          t_bursty();
          t_reset();
          env.drain();
          t_closure();
        end
        default: $fatal(1, "Unknown +TEST=%s (smoke|random|write_heavy|read_heavy|bursty|reset|closure|regress)", name);
      endcase
      env.drain();
    endtask
  endclass

endpackage
