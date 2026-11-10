`timescale 1ns/1ps
// =============================================================================
// mac_unit.v - Signed Shift-Add Multiply-Accumulate Unit
// =============================================================================
// Parameters:
//   DW   = data/coefficient width (default 8)
//   ACCW = accumulator width      (default 20)
//
// Operation:
//   On each clock where mac_en=1, ONE bit of the coefficient b is processed:
//     acc <= acc + b[bit_idx] * (a << bit_idx)      for bit_idx = 0..DW-2
//     acc <= acc - b[DW-1]    * (a << (DW-1))       for bit_idx = DW-1
//   Running bit_idx = 0..DW-1 adds exactly a*b (two's-complement b), so DW
//   cycles per tap replace a full DWxDW array multiplier (area: one shared
//   ACCW-bit adder instead of ~DW^2 adder cells).
//   On acc_clr=1 (synchronous):    acc <= 0
//   acc is 20-bit signed; with K=8 it cannot overflow (see below).
//   round_out: accumulator >>> SHIFT, truncated to DW bits (always in range).
// =============================================================================

module mac_unit #(
    parameter DW    = 8,    // data/coeff width
    parameter ACCW  = 20,   // accumulator width
    parameter SHIFT = 12    // bits to drop on output (20-8=12)
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire signed [DW-1:0]     a,         // sample
    input  wire signed [DW-1:0]     b,         // coefficient
    input  wire [$clog2(DW)-1:0]    bit_idx,   // which bit of b this cycle
    input  wire                     mac_en,    // 1 -> accumulate one partial product
    input  wire                     acc_clr,   // 1 -> clear accumulator (sync)
    output wire signed [DW-1:0]     round_out, // truncated result
    output wire signed [ACCW-1:0]   acc_out    // raw accumulator (for debug)
);

    // ------------------------------------------------------------------
    // Internal accumulator
    // ------------------------------------------------------------------
    reg signed [ACCW-1:0] acc;

    // Partial product: a sign-extended to ACCW and shifted left by bit_idx.
    // The MSB of b has negative weight, so it is subtracted as ~x + 1.
    wire [ACCW-1:0] a_ext   = {{(ACCW-DW){a[DW-1]}}, a};
    wire [ACCW-1:0] a_shift = a_ext << bit_idx;
    wire            b_bit   = b[bit_idx];
    localparam [$clog2(DW)-1:0] LAST_BIT = DW - 1;
    wire            neg     = (bit_idx == LAST_BIT);
    wire [ACCW-1:0] addend  = {ACCW{b_bit}} & (a_shift ^ {ACCW{neg}});
    wire            cin     = b_bit & neg;

    // acc + addend + cin with a single adder (carry-in via an extra LSB)
    wire [ACCW:0]   sum_w    = {acc, 1'b1} + {addend, cin};
    wire [ACCW-1:0] acc_next = sum_w[ACCW:1];

    // Area: the accumulator is cleared before every output and sums exactly
    // K=8 products, so |acc| <= 8*128*128 = 131072 < 2^19 (partial sums
    // inside one tap stay within +/-16384 of that). A 20-bit signed
    // accumulator can never overflow, so no saturation logic is needed.
    // (Re-check this bound if K, DW or ACCW change.)
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
    wire               _unused_sum_lsb  = sum_w[0];
    /* verilator lint_on UNUSEDSIGNAL */

    assign round_out = truncated[DW-1:0];

endmodule
