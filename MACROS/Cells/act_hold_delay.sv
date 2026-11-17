`timescale 1ns / 1ps

/* ===============================================================================================
 * ASIC Hold Delay Chain
 * Process: IHP 130nm CMOS5L (sg13cmos5l_stdcell)
 * Drop-in replacement for RTL act_hold_delay.sv when hardening act_bank_container.
 *
 * STAGES cascaded sg13cmos5l_dlygate4sd3_1 cells per bit (largest delay cell of the library,
 * ~0.27-0.30 / 0.40 / 0.60 ns fast / typ / slow each). The cells are named
 * <instance>.gen_bit[b].gen_stage[s].u_dly, so the u_hold_dly_* instances in act_bank_container
 * are matched by RSZ_DONT_TOUCH_RX in the container config and the resizer neither removes nor
 * resizes them.
 * =============================================================================================== */

module act_hold_delay #(
    parameter int WIDTH  = 1,
    parameter int STAGES = 12
)(
    input  wire [WIDTH-1:0] d_i,
    output wire [WIDTH-1:0] d_o
);

    generate
        for (genvar b = 0; b < WIDTH; b++) begin : gen_bit
            wire [STAGES:0] tap;
            assign tap[0] = d_i[b];

            for (genvar s = 0; s < STAGES; s++) begin : gen_stage
                // Power pins are connected in PnR
                /* verilator lint_off PINMISSING */
                (* keep *)
                sg13cmos5l_dlygate4sd3_1 u_dly (
                    .A(tap[s]),
                    .X(tap[s+1])
                );
                /* verilator lint_on PINMISSING */
            end

            assign d_o[b] = tap[STAGES];
        end
    endgenerate

endmodule
