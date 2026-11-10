`timescale 1ns/1ps
// =============================================================================
// fsm.v - Control FSM for the Convolution Engine
// =============================================================================
// States:
//   IDLE          : Wait for valid_in + mode
//   LOAD_KERNEL   : Accept K coefficients via data_in, write to coeff_ram
//   STREAM_SAMPLE : Accept 1 sample, push into sample_shreg
//   MAC_CLEAR     : One-cycle state to synchronously clear the accumulator
//   MAC_ITERATE   : K*DW-cycle loop: acc += h[k] * x[n-k], one bit of h[k]
//                   per cycle (shift-add), k = 0..K-1
//   OUTPUT_STATE  : Present result, assert valid_out for 1 cycle
//
// Design decision: We insert MAC_CLEAR between STREAM_SAMPLE and MAC_ITERATE
// so the accumulator is cleared BEFORE the first multiply-accumulate cycle.
// This avoids a race between acc_clr and mac_en on the same clock edge.
// =============================================================================

module fsm #(
    parameter DW = 8,
    parameter K  = 8
) (
    input  wire                      clk,
    input  wire                      rst_n,

    // Control inputs
    input  wire                      mode,       // 0=load_kernel, 1=stream
    input  wire                      valid_in,   // new byte ready on data_in
    input  wire                      start,      // trigger MAC sequence
    input  wire signed [DW-1:0]      data_in,

    // Outputs (mixed: valid_out and result are registered for timing safety)
    output reg  signed [DW-1:0]      result,
    output reg                       valid_out,

    // coeff_ram write port
    output reg                       coeff_wr_en,
    output reg  [$clog2(K)-1:0]      coeff_wr_addr,
    output reg  signed [DW-1:0]      coeff_wr_data,

    // sample_shreg
    output reg                       shreg_shift_en,
    output reg                       shreg_clr,
    output reg  signed [DW-1:0]      shreg_new_sample,

    // mac_unit
    output reg                       mac_en,
    output reg                       acc_clr,
    output reg  [$clog2(K)-1:0]      mac_coeff_addr,
    output reg  [$clog2(K)-1:0]      mac_samp_addr,
    output reg  [$clog2(DW)-1:0]     mac_bit,        // coefficient bit (shift-add MAC)

    // mac_unit result
    input  wire signed [DW-1:0]      mac_result
);

    // ------------------------------------------------------------------
    // State encoding
    // ------------------------------------------------------------------
    localparam [2:0]
        IDLE          = 3'd0,
        LOAD_KERNEL   = 3'd1,
        STREAM_SAMPLE = 3'd2,
        MAC_CLEAR     = 3'd3,   // one-cycle accumulator clear
        MAC_ITERATE   = 3'd4,
        OUTPUT_STATE  = 3'd5;

    reg [2:0] state, next_state;

    // K-1 at counter width (avoids 32-bit compare width warnings)
    /* verilator lint_off WIDTHTRUNC */
    localparam [$clog2(K)-1:0] K_MINUS_1 = K - 1;
    /* verilator lint_on WIDTHTRUNC */

    // MAC counter: {tap k, coefficient bit} = 0..K*DW-1 during MAC_ITERATE.
    // The shift-add MAC unit handles one coefficient bit per cycle, so one
    // output takes K*DW = 64 MAC cycles (area: no array multiplier).
    localparam BW = $clog2(DW);
    localparam CW = $clog2(K) + BW;
    localparam [CW-1:0] CNT_LAST = K*DW - 1;

    reg [CW-1:0] cnt;
    // coefficient load counter: counts 0..K-1 during LOAD_KERNEL
    reg [$clog2(K)-1:0] coeff_cnt;

    // ------------------------------------------------------------------
    // State register
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    // ------------------------------------------------------------------
    // MAC iteration counter
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= {CW{1'b0}};
        else if (state == MAC_ITERATE)
            cnt <= cnt + 1'b1;
        else
            cnt <= {CW{1'b0}};
    end

    // ------------------------------------------------------------------
    // Coefficient load counter
    // coeff_cnt starts at 1 when entering LOAD_KERNEL because the IDLE
    // output logic already wrote coeff_ram[0] on the transition cycle.
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            coeff_cnt <= {$clog2(K){1'b0}};
        else if (state == IDLE && next_state == LOAD_KERNEL)
            coeff_cnt <= {{($clog2(K)-1){1'b0}}, 1'b1};  // start at 1
        else if (state == LOAD_KERNEL && valid_in)
            coeff_cnt <= (coeff_cnt == K_MINUS_1) ? {$clog2(K){1'b0}} : coeff_cnt + 1'b1;
        else if (state == IDLE)
            coeff_cnt <= {$clog2(K){1'b0}};
    end

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (valid_in) begin
                    if (mode == 1'b0)
                        next_state = LOAD_KERNEL;
                    else if (start)
                        next_state = STREAM_SAMPLE;
                end
            end

            LOAD_KERNEL: begin
                if (valid_in && (coeff_cnt == K_MINUS_1))
                    next_state = IDLE;
            end

            STREAM_SAMPLE: begin
                // Sample was already pushed in IDLE->STREAM_SAMPLE transition.
                // Immediately proceed to clear + iterate.
                next_state = MAC_CLEAR;
            end

            MAC_CLEAR: begin
                // One cycle to clear accumulator, then start iterating
                next_state = MAC_ITERATE;
            end

            MAC_ITERATE: begin
                if (cnt == CNT_LAST)
                    next_state = OUTPUT_STATE;
            end

            OUTPUT_STATE: begin
                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Combinational output logic
    // ------------------------------------------------------------------
    always @(*) begin
        // Defaults - all inactive
        coeff_wr_en      = 1'b0;
        coeff_wr_addr    = {$clog2(K){1'b0}};
        coeff_wr_data    = {DW{1'b0}};
        shreg_shift_en   = 1'b0;
        shreg_clr        = 1'b0;
        shreg_new_sample = {DW{1'b0}};
        mac_en           = 1'b0;
        acc_clr          = 1'b0;
        mac_coeff_addr   = {$clog2(K){1'b0}};
        mac_samp_addr    = {$clog2(K){1'b0}};
        mac_bit          = {BW{1'b0}};
        valid_out        = 1'b0;

        case (state)
            IDLE: begin
                // Capture first byte on the same cycle as the IDLE->LOAD_KERNEL or
                // IDLE->STREAM_SAMPLE transition, so no byte is lost.
                if (valid_in && mode == 1'b0) begin
                    // First coefficient: write to coeff_ram[0]
                    coeff_wr_en   = 1'b1;
                    coeff_wr_addr = {$clog2(K){1'b0}};
                    coeff_wr_data = data_in;
                    shreg_clr     = 1'b1;  // reset sample shreg on new kernel
                end else if (valid_in && mode == 1'b1 && start) begin
                    // First (and only) sample for this MAC: push into shreg
                    shreg_shift_en   = 1'b1;
                    shreg_new_sample = data_in;
                end
            end

            LOAD_KERNEL: begin
                if (valid_in) begin
                    coeff_wr_en   = 1'b1;
                    coeff_wr_addr = coeff_cnt;
                    coeff_wr_data = data_in;
                end
                // Clear sample shift register at the very start of a new kernel load
                // (handled in IDLE->LOAD_KERNEL above for coeff_cnt=0)
                shreg_clr = valid_in && (coeff_cnt == 0);
            end

            STREAM_SAMPLE: begin
                // Sample was already pushed via IDLE output logic.
                // This state is a pass-through to MAC_CLEAR.
            end

            MAC_CLEAR: begin
                acc_clr = 1'b1;    // Synchronously clear accumulator this cycle
            end

            MAC_ITERATE: begin
                mac_en         = 1'b1;
                mac_coeff_addr = cnt[CW-1:BW];
                mac_samp_addr  = cnt[CW-1:BW];
                mac_bit        = cnt[BW-1:0];
            end

            OUTPUT_STATE: begin
                valid_out = 1'b1;  // combinatorial pulse
            end

            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Result register: latched when state == OUTPUT_STATE
    // valid_out is combinatorial (driven in always @(*) block above).
    // The TB must wait ONE extra cycle after detecting valid_out=1 before
    // reading result, because result updates on the SAME posedge that
    // OUTPUT_STATE is entered (nonblocking assign).
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            result <= {DW{1'b0}};
        else if (state == OUTPUT_STATE)
            result <= mac_result;
    end

endmodule
