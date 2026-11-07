`timescale 1ns / 1ps

module act_bank_container #(
    parameter int ACTIVATION_WIDTH = 8,
    parameter int ACT_WORDS        = 512,
    parameter int WEIGHT_WIDTH     = 8,
    parameter int XBAR_SEL_WIDTH   = 4,
    // Delay cells per SRAM input bit (ASIC act_hold_delay only)
    parameter int HOLD_DLY_STAGES  = 12,

    localparam int ACT_ADDR_WIDTH  = $clog2(ACT_WORDS)
)(
    // West Interface (facing Slice 2 / eFPGA Fabric)
    input  wire                                           clk_i,
    input  wire                                           act_we,
    input  wire        [ACT_ADDR_WIDTH-1:0]               act_addr,
    input  wire signed [ACTIVATION_WIDTH-1:0]             act_wdata,
    output wire signed [ACTIVATION_WIDTH-1:0]             act_rdata_west,

    input  wire signed [WEIGHT_WIDTH-1:0]                 weight_in_west,
    input  wire                                           weight_shift_en_west,
    input  wire        [XBAR_SEL_WIDTH-1:0]               xbar_sel_west,
    output wire signed [ACTIVATION_WIDTH-1:0]             out_act_west,

    // East Interface (facing Slice 4 / Compute Core)
    output wire                                           clk_o,
    output wire signed [ACTIVATION_WIDTH-1:0]             act_rdata_east,
    output wire signed [WEIGHT_WIDTH-1:0]                 weight_in_east,
    output wire                                           weight_shift_en_east,
    output wire        [XBAR_SEL_WIDTH-1:0]               xbar_sel_east,
    input  wire signed [ACTIVATION_WIDTH-1:0]             out_act_east
);

    wire signed [ACTIVATION_WIDTH-1:0] sram_rdata;

    // -------------------------------------------------------------------------
    // Hold delay at the SRAM inputs.
    // act_addr/act_wdata/act_we come straight from the eFPGA NPU_SLICE output
    // registers, clocked by the same UserCLK the eFPGA forwards as clk_i, so the
    // data can change shortly after the SRAM clock edge. In the ASIC flow of this
    // container, act_hold_delay (MACROS/Cells) inserts delay-cell chains for the
    // hold check at the eFPGA interface; in all other flows it is a feedthrough.
    // act_we is delayed before sram_bank splits it into WEN/REN.
    // -------------------------------------------------------------------------
    wire                               sram_we;
    wire        [ACT_ADDR_WIDTH-1:0]   sram_addr;
    wire signed [ACTIVATION_WIDTH-1:0] sram_wdata;

    act_hold_delay #(
        .WIDTH (ACT_ADDR_WIDTH),
        .STAGES(HOLD_DLY_STAGES)
    ) u_hold_dly_addr (
        .d_i(act_addr),
        .d_o(sram_addr)
    );

    act_hold_delay #(
        .WIDTH (ACTIVATION_WIDTH),
        .STAGES(HOLD_DLY_STAGES)
    ) u_hold_dly_wdata (
        .d_i(act_wdata),
        .d_o(sram_wdata)
    );

    act_hold_delay #(
        .WIDTH (1),
        .STAGES(HOLD_DLY_STAGES)
    ) u_hold_dly_we (
        .d_i(act_we),
        .d_o(sram_we)
    );

    sram_bank #(
        .DATA_WIDTH(ACTIVATION_WIDTH),
        .DEPTH     (ACT_WORDS)
    ) act_sram_inst (
        .clk_i(clk_i),
        .we   (sram_we),
        .addr (sram_addr),
        .wdata(sram_wdata),
        .rdata(sram_rdata)
    );

    // Local SRAM read data drives both West (Fabric readback) and East (Compute Core)
    assign act_rdata_west = sram_rdata;
    assign act_rdata_east = sram_rdata;

    // Clock feedthrough to East side
    assign clk_o = clk_i;

    // West-to-East feedthrough channels
    assign weight_in_east       = weight_in_west;
    assign weight_shift_en_east = weight_shift_en_west;
    assign xbar_sel_east        = xbar_sel_west;

    // East-to-West feedthrough channel (drained activations from Slice 5/4 to Fabric)
    assign out_act_west = out_act_east;

endmodule
