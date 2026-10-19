`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// fifo_sva : protocol / safety assertions for sync_fifo
//
// Bound into the DUT (bind at the bottom of this file), so it checks every
// instance and needs no changes to the RTL or the testbench.
//
// `fail_cnt` is read by tb_top so that an assertion failure fails the test
// even if the scoreboard stays quiet.
//-----------------------------------------------------------------------------
module fifo_sva #(
  parameter int DATA_W = 8,
  parameter int DEPTH  = 16
) (
  input logic                      clk,
  input logic                      rst_n,
  input logic                      wr_en,
  input logic [DATA_W-1:0]         wdata,
  input logic                      rd_en,
  input logic [DATA_W-1:0]         rdata,
  input logic                      rdata_valid,
  input logic                      full,
  input logic                      empty,
  input logic [$clog2(DEPTH):0]    count,
  input logic                      overflow,
  input logic                      underflow
);

  int unsigned fail_cnt = 0;

  // What the FIFO *should* accept this cycle, from its own (sampled) flags
  wire do_wr = wr_en && !full;
  wire do_rd = rd_en && !empty;

  `define SVA_FAIL(MSG) begin fail_cnt++; $error("[SVA] %s", MSG); end

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // ---------------------------------------------------------- structural
  a_no_x: assert property (
      !$isunknown({full, empty, count, overflow, underflow, rdata_valid}))
    else `SVA_FAIL("status outputs contain X/Z")

  a_rdata_no_x: assert property (rdata_valid |-> !$isunknown(rdata))
    else `SVA_FAIL("rdata is X/Z while rdata_valid")

  a_flags_exclusive: assert property (!(full && empty))
    else `SVA_FAIL("full and empty asserted together")

  a_count_range: assert property (count <= DEPTH)
    else `SVA_FAIL("count exceeds DEPTH")

  a_full_def: assert property (full == (count == DEPTH))
    else `SVA_FAIL("full flag inconsistent with count")

  a_empty_def: assert property (empty == (count == 0))
    else `SVA_FAIL("empty flag inconsistent with count")

  // ------------------------------------------------ occupancy bookkeeping
  a_count_update: assert property (
      1'b1 |=> int'(count) == int'($past(count)) + int'($past(do_wr)) - int'($past(do_rd)))
    else `SVA_FAIL("count did not follow accepted writes/reads")

  // ------------------------------------------------------------ OVERFLOW
  // write while full is reported next cycle ...
  a_overflow_flag: assert property ((wr_en && full) |=> overflow)
    else `SVA_FAIL("overflow flag missing after write-while-full")

  // ... the flag is never raised spuriously ...
  a_overflow_no_spurious: assert property (overflow |-> $past(wr_en && full))
    else `SVA_FAIL("overflow flag raised without write-while-full")

  // ... and the rejected write must not disturb occupancy
  a_overflow_no_corrupt: assert property (
      (wr_en && full && !rd_en) |=> $stable(count))
    else `SVA_FAIL("write-while-full changed occupancy")

  // ----------------------------------------------------------- UNDERFLOW
  a_underflow_flag: assert property ((rd_en && empty) |=> underflow)
    else `SVA_FAIL("underflow flag missing after read-while-empty")

  a_underflow_no_spurious: assert property (underflow |-> $past(rd_en && empty))
    else `SVA_FAIL("underflow flag raised without read-while-empty")

  a_underflow_no_corrupt: assert property (
      (rd_en && empty && !wr_en) |=> ($stable(count) && !rdata_valid))
    else `SVA_FAIL("read-while-empty changed state or produced valid data")

  // ------------------------------------------------------- read-data timing
  a_rvalid_follows_read: assert property (do_rd |=> rdata_valid)
    else `SVA_FAIL("accepted read not followed by rdata_valid")

  a_rvalid_only_after_read: assert property (!do_rd |=> !rdata_valid)
    else `SVA_FAIL("rdata_valid without an accepted read")

  a_rdata_hold: assert property (!do_rd |=> $stable(rdata))
    else `SVA_FAIL("rdata changed without an accepted read")

  // --------------------------------------------------------------- reset
  // Not gated by the default disable: this is the reset check itself.
  a_reset_state: assert property (@(posedge clk) disable iff (1'b0)
      !rst_n |=> (count == 0 && empty && !full && !overflow && !underflow && !rdata_valid))
    else `SVA_FAIL("state not cleared by reset")

  // ------------------------------------------------- scenario cover points
  c_overflow:        cover property (wr_en && full);
  c_underflow:       cover property (rd_en && empty);
  c_wr_rd_at_full:   cover property (wr_en && rd_en && full);
  c_wr_rd_at_empty:  cover property (wr_en && rd_en && empty);
  c_back2back_ovf:   cover property ((wr_en && full) ##1 (wr_en && full));
  c_fill_to_full:    cover property ((count == DEPTH-1) ##1 full);

  `undef SVA_FAIL
endmodule

bind sync_fifo fifo_sva #(.DATA_W(DATA_W), .DEPTH(DEPTH)) u_sva (.*);
