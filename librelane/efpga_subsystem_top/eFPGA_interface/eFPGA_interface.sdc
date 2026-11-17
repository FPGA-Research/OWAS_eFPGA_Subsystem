if {![info exists OWAS_INSTANCE]} {error "Set OWAS_INSTANCE to the exact eFPGA instance path"}
if {![info exists OWAS_EARLY_DERATE]} {set OWAS_EARLY_DERATE 0.044891}
if {![info exists OWAS_LATE_DERATE]} {set OWAS_LATE_DERATE 1.0}

if {$OWAS_EARLY_DERATE <= 0 || $OWAS_LATE_DERATE < $OWAS_EARLY_DERATE} {error "Require 0 < early <= late"}
set _owas_cell [get_cells -quiet [regsub -all {[][\\*?]} $OWAS_INSTANCE {\\&}]]

if {[llength $_owas_cell] != 1 || [get_property $_owas_cell ref_name] ne "eFPGA"} {error "Expected exactly one eFPGA instance"}

set_timing_derate -early -data -cell_delay $OWAS_EARLY_DERATE $_owas_cell
set_timing_derate -late  -data -cell_delay $OWAS_LATE_DERATE $_owas_cell

set_timing_derate -early -clock -cell_delay 0.647517 $_owas_cell
set_timing_derate -late  -clock -cell_delay 1.0 $_owas_cell

unset _owas_cell
