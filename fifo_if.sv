`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// fifo_if : DUT-facing interface with separate driver / monitor clocking blocks
//   drv_cb : drives 1ns after the clock edge (no race with the DUT)
//   mon_cb : samples in the preponed region (#1step) = the values the DUT
//            actually sees at the edge
//-----------------------------------------------------------------------------
interface fifo_if #(
  parameter int DATA_W = 8,
  parameter int DEPTH  = 16
) (
  input logic clk
);
  logic                     rst_n;
  logic                     wr_en;
  logic [DATA_W-1:0]        wdata;
  logic                     rd_en;
  logic [DATA_W-1:0]        rdata;
  logic                     rdata_valid;
  logic                     full;
  logic                     empty;
  logic [$clog2(DEPTH):0]   count;
  logic                     overflow;
  logic                     underflow;


  // drv_cb decides when the testbench drives signals (1 ns after the clock edge).
  //mon_cb decides when it samples them (just before the edge).
  //That avoids races with the DUT.
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output rst_n, wr_en, wdata, rd_en; //drives the dut; DUT’s inputs are clk, rst_n, wr_en, wdata and rd_en
  endclocking                           // clk comes from tb_top rather than the driver. 

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, wr_en, wdata, rd_en;
    input rdata, rdata_valid, full, empty, count, overflow, underflow;
  endclocking
endinterface
