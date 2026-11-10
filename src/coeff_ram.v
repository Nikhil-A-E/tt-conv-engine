`timescale 1ns/1ps
// =============================================================================
// coeff_ram.v - Coefficient RAM (K x 8-bit signed, single-port read/write)
// =============================================================================
// Write: wr_en=1, wr_addr, wr_data on rising edge
// Read:  async read via rd_addr -> rd_data
// Depth = K (default 8), Width = DW (default 8)
// =============================================================================

module coeff_ram #(
    parameter DW = 8,   // data width
    parameter K  = 8    // number of taps / RAM depth
) (
    input  wire                          clk,
    input  wire                          rst_n,
    // Write port
    input  wire                          wr_en,
    input  wire [$clog2(K)-1:0]          wr_addr,
    input  wire signed [DW-1:0]          wr_data,
    // Read port (async)
    input  wire [$clog2(K)-1:0]          rd_addr,
    output wire signed [DW-1:0]          rd_data
);

    reg signed [DW-1:0] mem [0:K-1];

    // Area: no reset on the storage flops (plain DFFs are ~20% smaller than
    // async-reset DFFs). Contents are undefined after reset until a kernel is
    // loaded; the protocol always loads a kernel before streaming.
    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_rst_n = rst_n;
    /* verilator lint_on UNUSEDSIGNAL */

    assign rd_data = mem[rd_addr];

endmodule
