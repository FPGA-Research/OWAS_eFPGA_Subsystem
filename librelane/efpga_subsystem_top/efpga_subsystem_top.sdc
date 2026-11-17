
set clock_port clk_i
create_clock [get_ports $clock_port] -name $clock_port -period $::env(CLOCK_PERIOD)
set clocks [get_clocks $clock_port]

set fab_user_clk_pins [get_pins {fabric_inst.eFPGA_inst/Tile_X10Y*_FAB_USER_CLK}]
create_generated_clock -name npu_act_clk \
    -source [get_ports $clock_port] -master_clock $clock_port \
    -divide_by 1 \
    $fab_user_clk_pins

set core_clk_bank "npu_inst.act_buffer_stage.gen_containers\[3\].container_inst"
create_generated_clock -name npu_core_clk \
    -source [get_pins $core_clk_bank/clk_i] -master_clock npu_act_clk \
    -edges {1 2 3} \
    [get_pins $core_clk_bank/clk_o]

set all_clks [get_clocks {clk_i npu_act_clk npu_core_clk}]

set input_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
puts "\[INFO] Setting output delay to: $output_delay_value"
puts "\[INFO] Setting input delay to: $input_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set clk_input [get_ports $clock_port]
set async_inputs [get_ports {efpga_cfg_sclk_i efpga_cfg_sdata_i}]

set sync_inputs [list]
foreach port [all_inputs] {
    if { $port != $clk_input && [lsearch $async_inputs $port] < 0 } {
        lappend sync_inputs $port
    }
}

set_input_delay $input_delay_value -clock $clocks $sync_inputs
set_output_delay $output_delay_value -clock $clocks [all_outputs]

set_false_path -from $async_inputs

if { ![info exists ::env(SYNTH_CLK_DRIVING_CELL)] } {
    set ::env(SYNTH_CLK_DRIVING_CELL) $::env(SYNTH_DRIVING_CELL)
}

set_driving_cell \
    -lib_cell [lindex [split $::env(SYNTH_DRIVING_CELL) "/"] 0] \
    -pin [lindex [split $::env(SYNTH_DRIVING_CELL) "/"] 1] \
    [concat $sync_inputs $async_inputs]

set_driving_cell \
    -lib_cell [lindex [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] 0] \
    -pin [lindex [split $::env(SYNTH_CLK_DRIVING_CELL) "/"] 1] \
    $clk_input

set cap_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0]
puts "\[INFO] Setting load to: $cap_load"
set_load $cap_load [all_outputs]

puts "\[INFO] Setting clock uncertainty to: $::env(CLOCK_UNCERTAINTY_CONSTRAINT)"
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $all_clks

puts "\[INFO] Setting clock transition to: $::env(CLOCK_TRANSITION_CONSTRAINT)"
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $all_clks

puts "\[INFO] Setting timing derate to: $::env(TIME_DERATING_CONSTRAINT)%"
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100.0]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100.0]]

set OWAS_INSTANCE fabric_inst.eFPGA_inst
source [file join [file dirname [info script]] eFPGA_interface eFPGA_interface.sdc]

set pmp_static_regs {}
foreach c [get_cells -quiet {efpga_connector_inst.manager_inst.gen_pmp.pmp_*_addr_reg* efpga_connector_inst.slot_gen*pmp_checks_4k*}] {
    set n [get_full_name $c]
    if {[regexp {gen_pmp\.pmp_(base|limit)_addr_reg(\\?\[[0-9]+\\?\])+_sg13cmos5l_dfrbpq_[0-9]+_Q$} $n] ||
        [regexp {pmp_checks_4k\\?\[[0-9]+\\?\]\.(read_en|write_en|req_priv|req_sec)_sg13cmos5l_dfrbpq_[0-9]+_Q$} $n]} {
        lappend pmp_static_regs $c
    }
}
puts "\[INFO\] PMP static regs excluded from hold into the eFPGA: [llength $pmp_static_regs] (expect 88)"
if { [llength $pmp_static_regs] > 0 } {
    set_false_path -hold -from $pmp_static_regs -to [get_pins fabric_inst.eFPGA_inst/*]
}

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}
