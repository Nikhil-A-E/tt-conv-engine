`timescale 1ns/1ps
// =============================================================================
// conv_core.v - Convolution Core (structural assembly, no serial I/O)
// =============================================================================
// Instantiates: mac_unit, coeff_ram, sample_shreg, fsm
// Exposes byte-parallel interface for easy standalone testing.
// =============================================================================

module conv_core #(
    parameter DW    = 8,
    parameter K     = 8,
    parameter ACCW  = 20,
    parameter SHIFT = 12
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // User-facing control (byte-parallel)
    input  wire                  mode,       // 0=load_kernel, 1=stream
    input  wire                  valid_in,
    input  wire                  start,
    input  wire signed [DW-1:0]  data_in,

    output wire signed [DW-1:0]  result,
    output wire                  valid_out
);

    // ------------------------------------------------------------------
    // Internal wires
    // ------------------------------------------------------------------
    wire                      coeff_wr_en;
    wire [$clog2(K)-1:0]      coeff_wr_addr;
    wire signed [DW-1:0]      coeff_wr_data;

    wire [$clog2(K)-1:0]      coeff_rd_addr;
    wire signed [DW-1:0]      coeff_rd_data;

    wire                      shreg_shift_en;
    wire                      shreg_clr;
    wire signed [DW-1:0]      shreg_new_sample;
    wire [$clog2(K)-1:0]      shreg_rd_addr;
    wire signed [DW-1:0]      shreg_rd_data;

    wire                      mac_en;
    wire                      acc_clr;
    wire signed [DW-1:0]      mac_result;
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [ACCW-1:0]    acc_debug;   // debug only, not used
    /* verilator lint_on UNUSEDSIGNAL */

    wire signed [DW-1:0]      fsm_result;

    // ------------------------------------------------------------------
    // Instances
    // ------------------------------------------------------------------
    fsm #(.DW(DW), .K(K)) u_fsm (
        .clk             (clk),
        .rst_n           (rst_n),
        .mode            (mode),
        .valid_in        (valid_in),
        .start           (start),
        .data_in         (data_in),
        .result          (fsm_result),
        .valid_out       (valid_out),
        .coeff_wr_en     (coeff_wr_en),
        .coeff_wr_addr   (coeff_wr_addr),
        .coeff_wr_data   (coeff_wr_data),
        .shreg_shift_en  (shreg_shift_en),
        .shreg_clr       (shreg_clr),
        .shreg_new_sample(shreg_new_sample),
        .mac_en          (mac_en),
        .acc_clr         (acc_clr),
        .mac_coeff_addr  (coeff_rd_addr),
        .mac_samp_addr   (shreg_rd_addr),
        .mac_result      (mac_result)
    );

    coeff_ram #(.DW(DW), .K(K)) u_coeff_ram (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (coeff_wr_en),
        .wr_addr  (coeff_wr_addr),
        .wr_data  (coeff_wr_data),
        .rd_addr  (coeff_rd_addr),
        .rd_data  (coeff_rd_data)
    );

    sample_shreg #(.DW(DW), .K(K)) u_shreg (
        .clk        (clk),
        .rst_n      (rst_n),
        .shift_en   (shreg_shift_en),
        .clr        (shreg_clr),
        .new_sample (shreg_new_sample),
        .rd_addr    (shreg_rd_addr),
        .rd_data    (shreg_rd_data)
    );

    mac_unit #(.DW(DW), .ACCW(ACCW), .SHIFT(SHIFT)) u_mac (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (shreg_rd_data),
        .b         (coeff_rd_data),
        .mac_en    (mac_en),
        .acc_clr   (acc_clr),
        .round_out (mac_result),
        .acc_out   (acc_debug)
    );

    assign result = fsm_result;

endmodule
