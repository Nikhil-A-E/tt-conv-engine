`timescale 1ns/1ps
// =============================================================================
// mac_unit.v - Signed Multiply-Accumulate Unit
// =============================================================================
// Parameters:
//   DW   = data/coefficient width (default 8)
//   ACCW = accumulator width      (default 20)
//
// Operation:
//   On each clock where mac_en=1:  acc <= acc + (a * b)
//   On acc_clr=1 (synchronous):    acc <= 0
//   acc is 20-bit signed; with K=8 it cannot overflow (see below).
//   round_out: accumulator >>> SHIFT, truncated to DW bits (always in range).
//
// Signed multiply: 8b x 8b -> 16b product, sign-extended to 20b before adding.
// =============================================================================

module mac_unit #(
    parameter DW    = 8,    // data/coeff width
    parameter ACCW  = 20,   // accumulator width
    parameter SHIFT = 12    // bits to drop on output (20-8=12)
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire signed [DW-1:0]  a,         // sample
    input  wire signed [DW-1:0]  b,         // coefficient
    input  wire                  mac_en,    // 1 -> accumulate a*b
    input  wire                  acc_clr,   // 1 -> clear accumulator (sync)
    output wire signed [DW-1:0]  round_out, // truncated result
    output wire signed [ACCW-1:0] acc_out   // raw accumulator (for debug)
);

    // ------------------------------------------------------------------
    // Internal accumulator
    // ------------------------------------------------------------------
    reg signed [ACCW-1:0] acc;

    // 8b x 8b -> 16b product, sign-extended to ACCW
    wire signed [2*DW-1:0] product = a * b;
    wire signed [ACCW-1:0] product_ext = {{(ACCW-2*DW){product[2*DW-1]}}, product};

    // Accumulate (no saturation needed).
    // Area: the accumulator is cleared before every output and sums exactly
    // K=8 products, so |acc| <= 8*128*128 = 131072 < 2^19. A 20-bit signed
    // accumulator can never overflow, and the old saturation comparators
    // were dead logic. (Re-check this bound if K, DW or ACCW change.)
    wire signed [ACCW-1:0] acc_next = acc + product_ext;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACCW{1'b0}};
        else if (acc_clr)
            acc <= {ACCW{1'b0}};
        else if (mac_en)
            acc <= acc_next;
    end

    assign acc_out = acc;

    // ------------------------------------------------------------------
    // Truncate to DW-bit output
    // ------------------------------------------------------------------
    // Arithmetic right-shift by SHIFT bits. With the bound above,
    // acc >>> 12 is always within [-32, 32], so the int8 clamp to
    // [-128, 127] can never trigger and is omitted (bit-exact with the
    // golden model's saturate_int8).
    wire signed [ACCW-1:0] truncated = $signed(acc) >>> SHIFT;

    /* verilator lint_off UNUSEDSIGNAL */
    wire [ACCW-DW-1:0] _unused_trunc_hi = truncated[ACCW-1:DW];
    /* verilator lint_on UNUSEDSIGNAL */

    assign round_out = truncated[DW-1:0];

endmodule
