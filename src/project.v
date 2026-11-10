/*
 * Copyright (c) 2026 Nikhil
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns/1ps

// =============================================================================
// tt_um_nikhil_a_e_conv - Tiny Tapeout top level
// =============================================================================
// Wraps conv_top (8-tap MAC-based FIR / 1D convolution engine) for the TT
// harness and makes the pin interface safe to drive from an asynchronous
// host (e.g. the RP2040 on the TT demo board):
//
//   * 2-flop synchronizer on valid_in
//   * valid_in is rising-edge detected: one host pulse = exactly one byte,
//     no matter how many clock cycles the host holds it high
//   * uio[4] "done" is a sticky flag (set when a result is ready, cleared by
//     the next valid_in) so a slow host can poll it instead of trying to
//     catch the 1-cycle valid_out strobe on uio[2]
//
// Host protocol: set ui_in, mode and start FIRST, then raise valid_in, hold
// it for at least 3 clock cycles, then lower it. Keep ui_in/mode/start
// unchanged until valid_in is low again. Always load a kernel after reset.
//
// Pins:
//   ui_in[7:0]  : data in (coefficient when mode=0, sample when mode=1)
//   uo_out[7:0] : result (signed int8), held until the next result
//   uio[0]      : mode      (in)  0 = load kernel, 1 = stream samples
//   uio[1]      : valid_in  (in)  rising edge = take byte on ui_in
//   uio[2]      : valid_out (out) 1-cycle strobe when uo_out updates
//   uio[3]      : start     (in)  must be 1 with mode=1 to run a sample
//   uio[4]      : done      (out) sticky: result ready on uo_out
//   uio[7:5]    : unused (inputs)
// =============================================================================

module tt_um_nikhil_a_e_conv (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // ------------------------------------------------------------------
    // valid_in synchronizer + rising-edge detect
    // Only valid_in needs a synchronizer: by protocol ui_in, mode and start
    // are set before valid_in rises and held until it falls, so they are
    // stable for >= 2 cycles before valid_pulse samples them (area: saves
    // 20 flops vs. synchronizing every input).
    // ------------------------------------------------------------------
    reg [2:0] valid_s;          // [1:0] synchronizer, [2] edge-detect history

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_s <= 3'b000;
        else
            valid_s <= {valid_s[1:0], uio_in[1]};
    end

    // One-cycle pulse per rising edge of valid_in
    wire valid_pulse = valid_s[1] & ~valid_s[2];

    // ------------------------------------------------------------------
    // Convolution engine
    // ------------------------------------------------------------------
    wire [7:0] core_uo_out;
    wire [7:0] core_uio_out;
    wire [7:0] core_uio_oe;

    conv_top #(.DW(8), .K(8), .ACCW(20), .SHIFT(10)) u_conv (
        .clk     (clk),
        .rst_n   (rst_n),
        .ui_in   (ui_in),
        .uo_out  (core_uo_out),
        .uio_in  ({4'b0000, uio_in[3], 1'b0, valid_pulse, uio_in[0]}),
        .uio_out (core_uio_out),
        .uio_oe  (core_uio_oe)
    );

    wire valid_out = core_uio_out[2];

    // ------------------------------------------------------------------
    // Sticky "done" flag for slow hosts
    // ------------------------------------------------------------------
    reg done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done <= 1'b0;
        else if (valid_pulse)
            done <= 1'b0;
        else if (valid_out)
            done <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Outputs: uio[2] and uio[4] are outputs, the rest are inputs
    // ------------------------------------------------------------------
    assign uo_out  = core_uo_out;
    assign uio_out = {3'b000, done, 1'b0, valid_out, 2'b00};
    assign uio_oe  = 8'b0001_0100;

    // List all unused inputs to prevent warnings
    wire _unused = &{ena, uio_in[7:4], uio_in[2], core_uio_out[7:3],
                     core_uio_out[1:0], core_uio_oe, 1'b0};

endmodule
