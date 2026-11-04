// =============================================================================
// File: SOFT_LOGIC/flex/npu_flex_axil_csr.sv
// Module: npu_flex_axil_csr
// Project: CrocoScale SoC — 8-Bank (4x2) eFPGA NPU Control & Status Registers
//
// Description:
//   Ultra-lean write-only AXI4-Lite Slave MMIO register block for the 8-bank
//   (4x2) soft-logic NPU controller. Completion status is signaled via
//   usr_irq_o[0] (sticky done flag, cleared automatically on START/START_DRAIN).
//
//   Register Map (Byte Offset / Word Index addr[4:2]):
//     0x00 (0): REG_CONFIG      [0]=AUTO_DRAIN, [1]=START (W1P), [2]=START_DRAIN (W1P),
//                               [4]=MODE_1X1, [5]=LUT_EN, [6]=POOL_EN, [7]=POOL_S1_EN,
//                               [18:8]=TOTAL_PASSES[10:0], [26:24]=CFG_CIN[10:8],
//                               [27]=TILE_X[4], [28]=TILE_Y[4], [29]=IMG_W[8], [30]=IMG_H[8]
//     0x04 (1): REG_ACT_BASE    [31:6]=ACT_BASE[31:6] (64B-aligned; [31:25] shared with WEIGHT,
//                               [31:22] shared with OUT, BIAS, QUANT, LUT)
//     0x08 (2): REG_WEIGHT_BASE [24:5]=WEIGHT_BASE[24:5] (32B-aligned, 32 MB window)
//     0x0C (3): REG_OUT_BASE    [21:6]=OUT_BASE[21:6]    (64B-aligned, 4 MB window)
//     0x10 (4): REG_BIAS_BASE   [21:5]=BIAS_BASE[21:5]   (32B-aligned, 4 MB window)
//     0x14 (5): REG_QUANT_BASE  [21:5]=QUANT_BASE[21:5]  (32B-aligned, 4 MB window)
//     0x18 (6): REG_LUT_BASE    [21:8]=LUT_BASE[21:8]    (256B-aligned, 4 MB window)
//     0x1C (7): REG_GEOM        [3:0]=TILE_X[3:0], [7:4]=TILE_Y[3:0], [15:8]=IMG_W[7:0],
//                               [23:16]=IMG_H[7:0], [31:24]=CFG_CIN[7:0]
// =============================================================================

`timescale 1ns / 1ps

module npu_flex_axil_csr #(
    parameter int AXI_ADDR_WIDTH = 10,
    parameter int AXI_DATA_WIDTH = 32,
    parameter int DEFAULT_H      = 32,
    parameter int DEFAULT_W      = 32,
    parameter int DEFAULT_CIN    = 128
) (
    input  wire                          clk_i,
    input  wire                          rst_n,

    // AXI4-Lite Slave Interface (Write-Only; Read Channel Tied Off)
    input  wire [AXI_ADDR_WIDTH-1:0]     s_axil_awaddr,
    input  wire [2:0]                    s_axil_awprot,
    input  wire                          s_axil_awvalid,
    output logic                         s_axil_awready,

    input  wire [AXI_DATA_WIDTH-1:0]     s_axil_wdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0] s_axil_wstrb,
    input  wire                          s_axil_wvalid,
    output logic                         s_axil_wready,

    output logic [1:0]                   s_axil_bresp,
    output logic                         s_axil_bvalid,
    input  wire                          s_axil_bready,

    input  wire [AXI_ADDR_WIDTH-1:0]     s_axil_araddr,
    input  wire [2:0]                    s_axil_arprot,
    input  wire                          s_axil_arvalid,
    output logic                         s_axil_arready,

    output logic [AXI_DATA_WIDTH-1:0]     s_axil_rdata,
    output logic [1:0]                   s_axil_rresp,
    output logic                         s_axil_rvalid,
    input  wire                          s_axil_rready,

    // Decoded Control & Configuration Outputs
    output logic                         start_pulse_o,
    output logic                         start_drain_pulse_o,
    output logic                         auto_drain_o,
    output logic                         mode_1x1_o,
    output logic                         lut_en_o,
    output logic                         pool_en_o,
    output logic                         pool_s1_en_o,
    output logic [10:0]                  total_passes_o,
    output logic [4:0]                   tile_x_o,
    output logic [4:0]                   tile_y_o,
    output logic [8:0]                   img_w_o,
    output logic [8:0]                   img_h_o,
    output logic [10:0]                  cfg_cin_o,
    output logic [31:0]                  act_base_o,
    output logic [31:0]                  weight_base_o,
    output logic [31:0]                  out_base_o,
    output logic [31:0]                  bias_base_o,
    output logic [31:0]                  quant_base_o,
    output logic [31:0]                  lut_base_o,
    output logic [3:0]                   usr_irq_o,

    // Hardware Completion Event Input
    input  wire                          fsm_done_i
);

    localparam logic [2:0] REG_IDX_CONFIG      = 3'd0;
    localparam logic [2:0] REG_IDX_ACT_BASE    = 3'd1;
    localparam logic [2:0] REG_IDX_WEIGHT_BASE = 3'd2;
    localparam logic [2:0] REG_IDX_OUT_BASE    = 3'd3;
    localparam logic [2:0] REG_IDX_BIAS_BASE   = 3'd4;
    localparam logic [2:0] REG_IDX_QUANT_BASE  = 3'd5;
    localparam logic [2:0] REG_IDX_LUT_BASE    = 3'd6;
    localparam logic [2:0] REG_IDX_GEOM        = 3'd7;

    wire unused_ok = &{1'b0, s_axil_awaddr[AXI_ADDR_WIDTH-1:5], s_axil_awaddr[1:0],
                       s_axil_awprot, s_axil_wstrb, s_axil_wdata[31], s_axil_wdata[23:19], s_axil_wdata[3],
                       s_axil_araddr, s_axil_arprot, s_axil_arvalid, s_axil_rready};

    // Lean Storage Registers (REG_ACT_BASE owns shared upper bits [31:25] / [31:22])
    logic        reg_auto_drain;
    logic        reg_mode_1x1;
    logic        reg_lut_en;
    logic        reg_pool_en;
    logic        reg_pool_s1_en;
    logic [10:0] reg_total_passes;
    logic        reg_done;

    logic [4:0]  reg_tile_x;
    logic [4:0]  reg_tile_y;
    logic [8:0]  reg_img_w;
    logic [8:0]  reg_img_h;
    logic [10:0] reg_cfg_cin;

    logic [31:6] reg_act_base;
    logic [24:5] reg_weight_base;
    logic [21:6] reg_out_base;
    logic [21:5] reg_bias_base;
    logic [21:5] reg_quant_base;
    logic [21:8] reg_lut_base;

    assign auto_drain_o   = reg_auto_drain;
    assign mode_1x1_o     = reg_mode_1x1;
    assign lut_en_o       = reg_lut_en;
    assign pool_en_o      = reg_pool_en;
    assign pool_s1_en_o   = reg_pool_s1_en;
    assign total_passes_o = reg_total_passes;

    assign tile_x_o       = reg_tile_x;
    assign tile_y_o       = reg_tile_y;
    assign img_w_o        = reg_img_w;
    assign img_h_o        = reg_img_h;
    assign cfg_cin_o      = reg_cfg_cin;

    assign act_base_o     = {reg_act_base[31:6],    6'd0};
    assign weight_base_o  = {reg_act_base[31:25], reg_weight_base[24:5], 5'd0};
    assign out_base_o     = {reg_act_base[31:22], reg_out_base[21:6],    6'd0};
    assign bias_base_o    = {reg_act_base[31:22], reg_bias_base[21:5],   5'd0};
    assign quant_base_o   = {reg_act_base[31:22], reg_quant_base[21:5],  5'd0};
    assign lut_base_o     = {reg_act_base[31:22], reg_lut_base[21:8],    8'd0};
    assign usr_irq_o      = {3'b000, reg_done};

    // AXI-Lite Write Channel Handshake & Single-Cycle Commit
    wire write_req = s_axil_awvalid && s_axil_wvalid && !s_axil_bvalid;
    assign s_axil_awready = write_req;
    assign s_axil_wready  = write_req;
    assign s_axil_bresp   = 2'b00;

    // AXI-Lite Read Channel Tied Off (Unused)
    assign s_axil_arready = 1'b0;
    assign s_axil_rvalid  = 1'b0;
    assign s_axil_rdata   = 32'd0;
    assign s_axil_rresp   = 2'b00;

    always_ff @(posedge clk_i) begin
        if (!rst_n) begin
            s_axil_bvalid       <= 1'b0;
            start_pulse_o       <= 1'b0;
            start_drain_pulse_o <= 1'b0;
            reg_auto_drain      <= 1'b1;
            reg_mode_1x1        <= 1'b0;
            reg_lut_en          <= 1'b0;
            reg_pool_en         <= 1'b0;
            reg_pool_s1_en      <= 1'b0;
            reg_total_passes    <= 11'd0;
            reg_done            <= 1'b0;
            reg_tile_x          <= 5'd0;
            reg_tile_y          <= 5'd0;
            reg_img_w           <= 9'(DEFAULT_W);
            reg_img_h           <= 9'(DEFAULT_H);
            reg_cfg_cin         <= 11'(DEFAULT_CIN);
            reg_act_base        <= 26'h000_0000;
            reg_weight_base     <= 20'h0_1000;
            reg_out_base        <= 16'h0400;
            reg_bias_base       <= 17'h0_1800;
            reg_quant_base      <= 17'h0_1880;
            reg_lut_base        <= 14'h0320;
        end else begin
            start_pulse_o       <= 1'b0;
            start_drain_pulse_o <= 1'b0;

            if (fsm_done_i) begin
                reg_done <= 1'b1;
            end

            if (write_req) begin
                s_axil_bvalid <= 1'b1;
                case (s_axil_awaddr[4:2])
                    REG_IDX_CONFIG: begin
                        reg_auto_drain      <= s_axil_wdata[0];
                        start_pulse_o       <= s_axil_wdata[1];
                        start_drain_pulse_o <= s_axil_wdata[2];
                        if (s_axil_wdata[1] || s_axil_wdata[2]) begin
                            reg_done <= 1'b0;
                        end
                        reg_mode_1x1        <= s_axil_wdata[4];
                        reg_lut_en          <= s_axil_wdata[5];
                        reg_pool_en         <= s_axil_wdata[6];
                        reg_pool_s1_en      <= s_axil_wdata[7];
                        reg_total_passes    <= s_axil_wdata[18:8];
                        reg_cfg_cin[10:8]   <= s_axil_wdata[26:24];
                        reg_tile_x[4]       <= s_axil_wdata[27];
                        reg_tile_y[4]       <= s_axil_wdata[28];
                        reg_img_w[8]        <= s_axil_wdata[29];
                        reg_img_h[8]        <= s_axil_wdata[30];
                    end
                    REG_IDX_ACT_BASE: begin
                        reg_act_base    <= s_axil_wdata[31:6];
                    end
                    REG_IDX_WEIGHT_BASE: begin
                        reg_weight_base <= s_axil_wdata[24:5];
                    end
                    REG_IDX_OUT_BASE: begin
                        reg_out_base    <= s_axil_wdata[21:6];
                    end
                    REG_IDX_BIAS_BASE: begin
                        reg_bias_base   <= s_axil_wdata[21:5];
                    end
                    REG_IDX_QUANT_BASE: begin
                        reg_quant_base  <= s_axil_wdata[21:5];
                    end
                    REG_IDX_LUT_BASE: begin
                        reg_lut_base    <= s_axil_wdata[21:8];
                    end
                    REG_IDX_GEOM: begin
                        reg_tile_x[3:0]  <= s_axil_wdata[3:0];
                        reg_tile_y[3:0]  <= s_axil_wdata[7:4];
                        reg_img_w[7:0]   <= s_axil_wdata[15:8];
                        reg_img_h[7:0]   <= s_axil_wdata[23:16];
                        reg_cfg_cin[7:0] <= s_axil_wdata[31:24];
                    end
                endcase
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end
        end
    end

endmodule

