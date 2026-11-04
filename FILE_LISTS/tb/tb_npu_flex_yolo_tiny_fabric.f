# tb_npu_flex_yolo_tiny on the real FABulous fabric (set parameter FABRIC_SIM=1).
-f ../internal/fabulous.f
-f ../npu.f
-f ../internal/efpga_connector.f
TEST/AXI_VIP/arbiter.v
TEST/AXI_VIP/priority_encoder.v
TEST/AXI_VIP/axi_interconnect.v
TEST/AXI_VIP/axi_axil_adapter.v
TEST/AXI_VIP/axi_axil_adapter_wr.v
TEST/AXI_VIP/axi_axil_adapter_rd.v
TEST/AXI_VIP/axi_ram.v
TEST/SoftLogic/flex/system/tb_npu_flex_yolo_tiny.sv

