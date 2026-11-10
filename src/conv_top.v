`timescale 1ns/1ps
// =============================================================================
// conv_top.v - Tiny Tapeout Top-Level Pin Wrapper
// =============================================================================
// Connects Tiny Tapeout harness pins to conv_core via serial_io.
//
// Pin mapping:
//   ui_in[7:0]  : serial data in (coefficient or sample)
//   uo_out[7:0] : serial result out (rounded int8 convolution output)
//   uio[0]      : mode     (in)  - 0=load_kernel, 1=stream
//   uio[1]      : valid_in (in)  - pulse when ui_in has data
//   uio[2]      : valid_out(out) - pulses when uo_out holds valid result
//   uio[3]      : start    (in)  - trigger MAC_ITERATE
//   uio[7:4]    : reserved (driven 0)
//   clk         : TT harness clock
//   rst_n       : TT active-low reset
// =============================================================================

module conv_top #(
    parameter DW    = 8,
    parameter K     = 8,
    parameter ACCW  = 20,
    parameter SHIFT = 10
) (
    input  wire        clk,
    input  wire        rst_n,

    // Tiny Tapeout pin interface
    input  wire [7:0]  ui_in,
    output wire [7:0]  uo_out,
    input  wire [7:0]  uio_in,
    output wire [7:0]  uio_out,
    output wire [7:0]  uio_oe     // direction: 1=output
);

    // ------------------------------------------------------------------
    // Internal signals
    // ------------------------------------------------------------------
    wire        mode, valid_in, start;
    wire signed [DW-1:0] data_to_core, data_from_core;
    wire                 core_valid;

    wire [7:0]  uo_out_int;
    wire [3:0]  uio_out_int;

    // ------------------------------------------------------------------
    // serial_io
    // ------------------------------------------------------------------
    serial_io #(.DW(DW)) u_serial_io (
        .clk       (clk),
        .rst_n     (rst_n),
        .ui_in     (ui_in),
        .uo_out    (uo_out_int),
        .uio_in    (uio_in[3:0]),
        .uio_out   (uio_out_int),
        .mode      (mode),
        .valid_in  (valid_in),
        .start     (start),
        .data_out  (data_to_core),
        .data_in   (data_from_core),
        .core_valid(core_valid)
    );

    // ------------------------------------------------------------------
    // conv_core
    // ------------------------------------------------------------------
    conv_core #(.DW(DW), .K(K), .ACCW(ACCW), .SHIFT(SHIFT)) u_conv_core (
        .clk       (clk),
        .rst_n     (rst_n),
        .mode      (mode),
        .valid_in  (valid_in),
        .start     (start),
        .data_in   (data_to_core),
        .result    (data_from_core),
        .valid_out (core_valid)
    );

    // ------------------------------------------------------------------
    // Pin assignments
    // ------------------------------------------------------------------
    assign uo_out  = uo_out_int;
    assign uio_out = {4'b0000, uio_out_int};

    // OE: uio[2] is output (valid_out), rest are inputs
    assign uio_oe  = 8'b00000100;

    /* verilator lint_off UNUSEDSIGNAL */
    wire [3:0] _unused_uio_in = uio_in[7:4];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
