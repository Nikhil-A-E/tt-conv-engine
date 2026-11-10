`timescale 1ns/1ps
// =============================================================================
// sample_shreg.v - Sample Shift Register (K x 8-bit signed)
// =============================================================================
// shift_en=1: push new_sample into position 0, shift older samples down.
// rd_addr: async read of any tap (0 = newest, K-1 = oldest)
// clr: synchronous clear - reset on kernel reload (design decision)
// =============================================================================

module sample_shreg #(
    parameter DW = 8,
    parameter K  = 8
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      shift_en,   // push new_sample in
    input  wire                      clr,         // sync clear (kernel reload)
    input  wire signed [DW-1:0]      new_sample,
    input  wire [$clog2(K)-1:0]      rd_addr,
    output wire signed [DW-1:0]      rd_data
);

    reg signed [DW-1:0] shreg [0:K-1];

    // Area: plain DFFs with a synchronous clear instead of async-reset DFFs.
    // The history is cleared by clr, which the FSM asserts at the start of
    // every kernel load; the protocol always loads a kernel after reset, so
    // rst_n is not needed here (keeps rst_n a pure async reset elsewhere).
    integer i;
    always @(posedge clk) begin
        if (clr) begin
            for (i = 0; i < K; i = i + 1)
                shreg[i] <= {DW{1'b0}};
        end else if (shift_en) begin
            // Shift: shreg[K-1] <- shreg[K-2] <- ... <- shreg[0] <- new_sample
            for (i = K-1; i > 0; i = i - 1)
                shreg[i] <= shreg[i-1];
            shreg[0] <= new_sample;
        end
    end

    assign rd_data = shreg[rd_addr];

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_rst_n = rst_n;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
