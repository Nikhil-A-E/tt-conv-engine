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
//   round_out: accumulator >>> SHIFT, saturated to DW-bit signed.
// =============================================================================

module mac_unit #(
    parameter DW    = 8,    // data/coeff width
    parameter ACCW  = 20,   // accumulator width
    parameter SHIFT = 10    // bits to drop on output
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
    /* verilator lint_off WIDTHTRUNC */
    localparam [$clog2(DW)-1:0] LAST_BIT = DW - 1;
    /* verilator lint_on WIDTHTRUNC */
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
    // Truncate and saturate to DW-bit output
    // ------------------------------------------------------------------
    // Arithmetic right-shift by SHIFT bits, then clamp to [-128, 127].
    // With SHIFT=10 and the bound above, acc >>> 10 is within [-127, 128];
    // the clamp is needed only for the single worst case
    // 8 x (-128) x (-128) = 131072 -> 128 -> 127.
    wire signed [ACCW-1:0] truncated = $signed(acc) >>> SHIFT;

    // Fits in DW bits iff all bits above the DW-bit sign equal the sign
    wire            t_sign = truncated[ACCW-1];
    wire            t_fits = (truncated[ACCW-2:DW-1] == {(ACCW-DW){t_sign}});

    localparam [DW-1:0] OUT_MAX = {1'b0, {(DW-1){1'b1}}};  //  127
    localparam [DW-1:0] OUT_MIN = {1'b1, {(DW-1){1'b0}}};  // -128

    /* verilator lint_off UNUSEDSIGNAL */
    wire               _unused_sum_lsb  = sum_w[0];
    /* verilator lint_on UNUSEDSIGNAL */

    assign round_out = t_fits ? truncated[DW-1:0] : (t_sign ? OUT_MIN : OUT_MAX);

endmodule
