`timescale 1ns / 1ps

/* ===============================================================================================
 * Hold delay at the activation SRAM inputs (behavioral / FPGA version)
 * Plain feedthrough. The ASIC flow of the act_bank_container macro uses
 * MACROS/Cells/act_hold_delay.sv instead, which inserts the delay-cell chains.
 * =============================================================================================== */

module act_hold_delay #(
    parameter int WIDTH  = 1,
    parameter int STAGES = 12
)(
    input  wire [WIDTH-1:0] d_i,
    output wire [WIDTH-1:0] d_o
);

    assign d_o = d_i;

endmodule
