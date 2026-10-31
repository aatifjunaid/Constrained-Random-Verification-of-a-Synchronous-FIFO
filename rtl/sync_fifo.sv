`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// sync_fifo : parameterized synchronous FIFO
//
//  * Single clock, synchronous active-low reset
//  * DEPTH must be a power of two (>= 2); DATA_W >= 2
//  * Registered read: rdata/rdata_valid appear ONE cycle after an accepted read
//  * Illegal operations are safely ignored AND reported:
//        write while full  -> write ignored, `overflow`  pulses next cycle
//        read  while empty -> read  ignored, `underflow` pulses next cycle
//  * Accept decisions use the CURRENT full/empty (no same-cycle bypass):
//        full  & wr & rd -> read accepted, write rejected (overflow)
//        empty & wr & rd -> write accepted, read rejected (underflow)
//
//  Bug injection (mutation testing): compile with +define+BUG_<NAME>.
//  Define exactly one BUG_ macro per build. With none defined the RTL is the
//  golden design.
//-----------------------------------------------------------------------------
module sync_fifo #(
  parameter int DATA_W = 8,
  parameter int DEPTH  = 16
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // write side
  input  logic                     wr_en,
  input  logic [DATA_W-1:0]        wdata,
  // read side
  input  logic                     rd_en,
  output logic [DATA_W-1:0]        rdata,
  output logic                     rdata_valid,
  // status
  output logic                     full,
  output logic                     empty,
  output logic [$clog2(DEPTH):0]   count,
  output logic                     overflow,
  output logic                     underflow
);

  localparam int AW = $clog2(DEPTH);

  logic [DATA_W-1:0] mem [DEPTH];
  logic [AW-1:0]     wptr, rptr;
  logic [AW:0]       cnt;

  assign count = cnt;
  assign empty = (cnt == '0);

`ifdef BUG_FULL_OFF_BY_ONE
  assign full  = (cnt == (AW+1)'(DEPTH-1));      // BUG: full one entry early
`else
  assign full  = (cnt == (AW+1)'(DEPTH));
`endif

  // ---------------------------------------------------------------- accepts
  logic do_wr, do_rd;
`ifdef BUG_OVERFLOW_WRITE                          // these are called compiler directives. they happen before the simulation time, at compile time , and decide which line of the code gets compiled. 
  assign do_wr = wr_en;                           // BUG: write accepted when full
`else
  assign do_wr = wr_en && !full;
`endif
`ifdef BUG_UNDERFLOW_READ
  assign do_rd = rd_en;                           // BUG: read accepted when empty
`else
  assign do_rd = rd_en && !empty;
`endif

  // ------------------------------------------------------------- write data
  logic [DATA_W-1:0] wdata_eff;
  always_comb begin
    wdata_eff = wdata;
`ifdef BUG_DATA_ALLONES
    // BUG: corner-case data corruption (only exposed when wdata == all ones);  Buggy design: 0xFF written is stored as 0xFE, so you read back the wrong value.
    if (wdata == {DATA_W{1'b1}}) wdata_eff = wdata ^ {{(DATA_W-1){1'b0}}, 1'b1};                              // BUG_DATA_ALLONES: flips bit 0 only when wdata == all ones (0xFF -> 0xFE).
                                                                                                              // Corner-case fault. Caught by the scoreboard DATA check, because c_data biases
                                                                                                              // wdata toward 0 / all-ones. cg_data confirms those values were sent.
`endif
  end

  // Physical memory write enable (kept separate from do_wr, which drives count)
  logic mem_wr;
`ifdef BUG_LAST_ENTRY_DROP
  // BUG: a write at almost-full with a simultaneous read updates the count
  //      but never reaches the memory.
  assign mem_wr = do_wr && !((cnt == (AW+1)'(DEPTH-1)) && do_rd);
`else
  assign mem_wr = do_wr;
`endif

  // ------------------------------------------------------------- sequential
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr        <= '0;
`ifdef BUG_RESET_RPTR
      // BUG: reset only initialises rptr at power-up, never re-clears it
      if (^rptr === 1'bx) rptr <= '0;
`else
      rptr        <= '0;
`endif
      cnt         <= '0;
      rdata       <= '0;
      rdata_valid <= 1'b0;
      overflow    <= 1'b0;
      underflow   <= 1'b0;
    end else begin
      // ---- status pulses (registered, one cycle after the illegal op)
`ifdef BUG_NO_OVERFLOW_FLAG
      overflow    <= 1'b0;                        // BUG: flag never raised
`else
      overflow    <= wr_en && full;
`endif
`ifdef BUG_UNDERFLOW_FLAG_CORNER                  //the data being written this cycle can’t be read this cycle.hence a bug. 
      underflow   <= rd_en && empty && !wr_en;    // BUG: missed if wr_en also high
`else
      underflow   <= rd_en && empty;
`endif

      // ---- write path
      if (mem_wr) begin
        mem[wptr] <= wdata_eff;
`ifdef BUG_WPTR_WRAP
        wptr <= (wptr == AW'(DEPTH-1)) ? AW'(1) : wptr + 1'b1;   // BUG: skips slot 0
`else
        wptr <= wptr + 1'b1;
`endif
      end

      // ---- read path
      rdata_valid <= do_rd;
      if (do_rd) begin
        rdata <= mem[rptr];
        rptr  <= rptr + 1'b1;
      end

      // ---- occupancy
      case ({do_wr, do_rd})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
`ifdef BUG_SIMUL_COUNT
        2'b11:   cnt <= cnt + 1'b1;               // BUG: simultaneous rd+wr ignores the read
`else
        2'b11:   cnt <= cnt;
`endif
        default: cnt <= cnt;
      endcase
    end
  end

endmodule
