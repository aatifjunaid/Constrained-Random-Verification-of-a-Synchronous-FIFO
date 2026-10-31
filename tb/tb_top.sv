`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// tb_top : clock, DUT, interface, test launcher, pass/fail verdict
//
//   +TEST=<name>   smoke|random|write_heavy|read_heavy|bursty|reset|closure|regress
//   +WAVES         dump waves.vcd
//
// The last lines printed are machine-parsable by sim/run.sh:
//   RESULT: PASS|FAIL scoreboard_errors=N sva_failures=M coverage=XX.XX ...
//-----------------------------------------------------------------------------
module tb_top;
  import fifo_tb_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  fifo_if #(.DATA_W(DATA_W), .DEPTH(DEPTH)) vif (clk);

  sync_fifo #(.DATA_W(DATA_W), .DEPTH(DEPTH)) dut (
    .clk         (clk),
    .rst_n       (vif.rst_n),
    .wr_en       (vif.wr_en),
    .wdata       (vif.wdata),
    .rd_en       (vif.rd_en),
    .rdata       (vif.rdata),
    .rdata_valid (vif.rdata_valid),
    .full        (vif.full),
    .empty       (vif.empty),
    .count       (vif.count),
    .overflow    (vif.overflow),
    .underflow   (vif.underflow)
  );

  initial begin
    if ($test$plusargs("WAVES")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, tb_top);
    end
  end

  // Hard timeout so a hung test can never stall a regression
  initial begin
    #200ms;
    $display("RESULT: FAIL timeout");
    $fatal(1, "simulation timeout");
  end

  initial begin
    fifo_test    t;
    string       tname;
    int unsigned sva_fails;
    bit          cov_ok;
    bit          tb_ok;

    if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0)
      $fatal(1, "FIFO_DEPTH must be a power of two >= 4 (got %0d)", DEPTH);
    if (DATA_W < 2)
      $fatal(1, "FIFO_DATA_W must be >= 2 (got %0d)", DATA_W);

    if (!$value$plusargs("TEST=%s", tname)) tname = "regress";

    $display("---- sync_fifo TB : test=%s DATA_W=%0d DEPTH=%0d ----", tname, DATA_W, DEPTH);
    t = new(vif, tname);
    t.run();

    sva_fails = dut.u_sva.fail_cnt;
    t.env.sb.report();
    t.env.cov.report();

    // Tests that are supposed to close coverage must actually close it
    cov_ok = !(tname == "closure" || tname == "regress") || t.env.cov.closed();
    tb_ok  = (t.env.sb.n_errors == 0) && (sva_fails == 0) &&
             (t.env.sb.n_checked > 0) && cov_ok;

    if (t.env.sb.n_errors != 0)
      $display("[TB]  first scoreboard error at cycle %0d", t.env.sb.first_err_cycle);
    if (!cov_ok)
      $display("[TB]  coverage NOT closed after %0d closure rounds", t.closure_rounds);
    else if (tname == "closure" || tname == "regress")
      $display("[TB]  coverage closed after %0d closure rounds", t.closure_rounds);

    $display("RESULT: %s scoreboard_errors=%0d sva_failures=%0d coverage=%0.2f closure_rounds=%0d",
             tb_ok ? "PASS" : "FAIL", t.env.sb.n_errors, sva_fails,
             t.env.cov.total(), t.closure_rounds);
    $finish;
  end
endmodule
