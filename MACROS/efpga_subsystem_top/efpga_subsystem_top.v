`timescale 1ns / 1ps

(* blackbox *)
module efpga_subsystem_top #(
    parameter int NUM_SLOTS        = 1,
    parameter int AXI_ID_WIDTH     = 8,
    parameter [31:0] HW_VERSION    = 32'hFAB00001,
    parameter int WEIGHT_SPLIT     = 8,
    parameter int USE_LADDER_CLOCKS = 1
) (
`ifdef USE_POWER_PINS
    inout  wire                                 VDD,
    inout  wire                                 VSS,
`endif
    input  wire                                 clk_i,
    input  wire                                 rst_efpga_connector_n_i,
    input  wire                                 rst_efpga_connector_i,
    input  wire                                 rst_efpga_fabric_n_i,
    input  wire [NUM_SLOTS*4-1:0]               rst_efpga_slot_n_i,
    input  wire [NUM_SLOTS-1:0]                 rst_efpga_npu_n_i,

    // AXI4-Lite Slave: Global Manager Interface
    input  wire [31:0]                          s_axil_mgr_awaddr,
    input  wire [2:0]                           s_axil_mgr_awprot,
    input  wire                                 s_axil_mgr_awvalid,
    output wire                                 s_axil_mgr_awready,
    input  wire [31:0]                          s_axil_mgr_wdata,
    input  wire [3:0]                           s_axil_mgr_wstrb,
    input  wire                                 s_axil_mgr_wvalid,
    output wire                                 s_axil_mgr_wready,
    output wire [1:0]                           s_axil_mgr_bresp,
    output wire                                 s_axil_mgr_bvalid,
    input  wire                                 s_axil_mgr_bready,
    input  wire [31:0]                          s_axil_mgr_araddr,
    input  wire [2:0]                           s_axil_mgr_arprot,
    input  wire                                 s_axil_mgr_arvalid,
    output wire                                 s_axil_mgr_arready,
    output wire [31:0]                          s_axil_mgr_rdata,
    output wire [1:0]                           s_axil_mgr_rresp,
    output wire                                 s_axil_mgr_rvalid,
    input  wire                                 s_axil_mgr_rready,

    // AXI4-Lite Slave: Slot Control Interface
    input  wire [NUM_SLOTS*32-1:0]              s_axil_ctrl_awaddr,
    input  wire [NUM_SLOTS*3-1:0]               s_axil_ctrl_awprot,
    input  wire [NUM_SLOTS-1:0]                 s_axil_ctrl_awvalid,
    output wire [NUM_SLOTS-1:0]                 s_axil_ctrl_awready,
    input  wire [NUM_SLOTS*32-1:0]              s_axil_ctrl_wdata,
    input  wire [NUM_SLOTS*4-1:0]               s_axil_ctrl_wstrb,
    input  wire [NUM_SLOTS-1:0]                 s_axil_ctrl_wvalid,
    output wire [NUM_SLOTS-1:0]                 s_axil_ctrl_wready,
    output wire [NUM_SLOTS*2-1:0]               s_axil_ctrl_bresp,
    output wire [NUM_SLOTS-1:0]                 s_axil_ctrl_bvalid,
    input  wire [NUM_SLOTS-1:0]                 s_axil_ctrl_bready,
    input  wire [NUM_SLOTS*32-1:0]              s_axil_ctrl_araddr,
    input  wire [NUM_SLOTS*3-1:0]               s_axil_ctrl_arprot,
    input  wire [NUM_SLOTS-1:0]                 s_axil_ctrl_arvalid,
    output wire [NUM_SLOTS-1:0]                 s_axil_ctrl_arready,
    output wire [NUM_SLOTS*32-1:0]              s_axil_ctrl_rdata,
    output wire [NUM_SLOTS*2-1:0]               s_axil_ctrl_rresp,
    output wire [NUM_SLOTS-1:0]                 s_axil_ctrl_rvalid,
    input  wire [NUM_SLOTS-1:0]                 s_axil_ctrl_rready,

    // AXI4 Full Master: Slot DMA Interface
    output wire [NUM_SLOTS*AXI_ID_WIDTH-1:0]    m_axi_dma_awid,
    output wire [NUM_SLOTS*32-1:0]              m_axi_dma_awaddr,
    output wire [NUM_SLOTS*8-1:0]               m_axi_dma_awlen,
    output wire [NUM_SLOTS*3-1:0]               m_axi_dma_awsize,
    output wire [NUM_SLOTS*2-1:0]               m_axi_dma_awburst,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_awlock,
    output wire [NUM_SLOTS*4-1:0]               m_axi_dma_awcache,
    output wire [NUM_SLOTS*3-1:0]               m_axi_dma_awprot,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_awvalid,
    input  wire [NUM_SLOTS-1:0]                 m_axi_dma_awready,
    output wire [NUM_SLOTS*32-1:0]              m_axi_dma_wdata,
    output wire [NUM_SLOTS*4-1:0]               m_axi_dma_wstrb,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_wlast,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_wvalid,
    input  wire [NUM_SLOTS-1:0]                 m_axi_dma_wready,
    input  wire [NUM_SLOTS*AXI_ID_WIDTH-1:0]    m_axi_dma_bid,
    input  wire [NUM_SLOTS*2-1:0]               m_axi_dma_bresp,
    input  wire [NUM_SLOTS-1:0]                 m_axi_dma_bvalid,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_bready,
    output wire [NUM_SLOTS*AXI_ID_WIDTH-1:0]    m_axi_dma_arid,
    output wire [NUM_SLOTS*32-1:0]              m_axi_dma_araddr,
    output wire [NUM_SLOTS*8-1:0]               m_axi_dma_arlen,
    output wire [NUM_SLOTS*3-1:0]               m_axi_dma_arsize,
    output wire [NUM_SLOTS*2-1:0]               m_axi_dma_arburst,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_arlock,
    output wire [NUM_SLOTS*4-1:0]               m_axi_dma_arcache,
    output wire [NUM_SLOTS*3-1:0]               m_axi_dma_arprot,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_arvalid,
    input  wire [NUM_SLOTS-1:0]                 m_axi_dma_arready,
    input  wire [NUM_SLOTS*AXI_ID_WIDTH-1:0]    m_axi_dma_rid,
    input  wire [NUM_SLOTS*32-1:0]              m_axi_dma_rdata,
    input  wire [NUM_SLOTS*2-1:0]               m_axi_dma_rresp,
    input  wire [NUM_SLOTS-1:0]                 m_axi_dma_rlast,
    input  wire [NUM_SLOTS-1:0]                 m_axi_dma_rvalid,
    output wire [NUM_SLOTS-1:0]                 m_axi_dma_rready,

    // External Padring PMOD Interface
    input  wire [7:0]                           pmod_io_i,
    output wire [7:0]                           pmod_io_o,
    output wire [7:0]                           pmod_io_oe_o,

    // External BitBang Configuration Interface
    input  wire                                 efpga_cfg_sclk_i,
    input  wire                                 efpga_cfg_sdata_i,

    // Interrupt Lines to CPU and SoC Subsystems
    output wire [3:0]                           efpga_usr_irq_o,
    output wire [NUM_SLOTS-1:0]                 efpga_fault_irq_o
);

endmodule
