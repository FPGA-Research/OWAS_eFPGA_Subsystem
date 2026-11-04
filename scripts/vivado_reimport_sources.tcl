# ==============================================================================
# OWAS eFPGA Subsystem -- Vivado Clean In-Place Source Reimport & OOC Setup
# ==============================================================================
# Usage in Vivado Tcl Console:
#   source <path_to_repo>/scripts/vivado_reimport_sources.tcl
# ==============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

puts "======================================================================"
puts ">>> Starting OWAS eFPGA Subsystem Clean Source Reimport & OOC Setup <<<"
puts "======================================================================"

# ------------------------------------------------------------------------------
# Clean existing simulation sources from sim_1 (Preserves files on disk!)
# ------------------------------------------------------------------------------
puts "==> Clearing current simulation sources from sim_1..."
set old_sim_files [get_files -quiet -of_objects [get_filesets sim_1]]
if {[llength $old_sim_files] > 0} {
    remove_files -fileset sim_1 $old_sim_files
    puts "    Removed [llength $old_sim_files] old simulation files from sim_1."
}

# ------------------------------------------------------------------------------
# Clean existing design sources from sources_1 (Preserves files on disk!)
# ------------------------------------------------------------------------------
puts "==> Clearing current design sources from sources_1..."
set old_src_files [get_files -quiet -of_objects [get_filesets sources_1]]
if {[llength $old_src_files] > 0} {
    remove_files $old_src_files
    puts "    Removed [llength $old_src_files] old design source references from sources_1."
}

# ------------------------------------------------------------------------------
# Add Verilog & SystemVerilog sources from FILE_LISTS/vivado/efpga_subsystem_vivado.f
# and FILE_LISTS/libs/axi_lib.f (Recursively resolves nested -f filelists in Tcl)
# ------------------------------------------------------------------------------
puts "==> Adding curated Vivado Verilog/SystemVerilog sources in-place..."

proc resolve_filelist {flist_path repo_root visited_var} {
    upvar 1 $visited_var visited
    set norm_flist [file normalize $flist_path]
    if {[lsearch -exact $visited $norm_flist] != -1 || ![file exists $norm_flist]} {
        return [list]
    }
    lappend visited $norm_flist
    set flist_dir [file dirname $norm_flist]
    set result [list]

    set fp [open $norm_flist r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} {
            continue
        }
        if {[regexp {^-[fc]\s+(\S+)} $line -> sub_rel]} {
            set cand1 [file normalize "$flist_dir/$sub_rel"]
            set cand2 [file normalize "$repo_root/FILE_LISTS/$sub_rel"]
            set cand3 [file normalize "$repo_root/$sub_rel"]
            if {[file exists $cand1]} {
                set sub_files [resolve_filelist $cand1 $repo_root visited]
            } elseif {[file exists $cand2]} {
                set sub_files [resolve_filelist $cand2 $repo_root visited]
            } else {
                set sub_files [resolve_filelist $cand3 $repo_root visited]
            }
            foreach sf $sub_files {
                if {[lsearch -exact $result $sf] == -1} {
                    lappend result $sf
                }
            }
        } else {
            set abs_path [file normalize "$repo_root/$line"]
            if {[file exists $abs_path]} {
                if {[lsearch -exact $result $abs_path] == -1} {
                    lappend result $abs_path
                }
            } else {
                puts "    WARNING: File not found on disk: $abs_path"
            }
        }
    }
    close $fp
    return $result
}

set visited_flists [list]
set v_files [concat \
    [resolve_filelist "$repo_root/FILE_LISTS/libs/axi_lib.f" $repo_root visited_flists] \
    [resolve_filelist "$repo_root/FILE_LISTS/vivado/efpga_subsystem_vivado.f" $repo_root visited_flists] \
]

if {[llength $v_files] > 0} {
    add_files -norecurse $v_files
    puts "    Added [llength $v_files] curated Verilog/SystemVerilog files from FILE_LISTS/vivado/efpga_subsystem_vivado.f + axi_lib.f."
}

# ------------------------------------------------------------------------------
# Add Simulation Sources (Soft-Logic Controllers, Boundary Harness & TBs) to sim_1
# ------------------------------------------------------------------------------
puts "==> Adding Soft-Logic controllers, boundary harness, and testbenches to sim_1..."
set sim_only_files [concat \
    [glob -nocomplain "$repo_root/SOFT_LOGIC/minimal/*.sv"] \
    [glob -nocomplain "$repo_root/SOFT_LOGIC/flex/*.sv"] \
    [glob -nocomplain "$repo_root/TEST/NPU/TestBenches/*.sv"] \
    [list \
        [file normalize "$repo_root/TEST/SoftLogic/common/efpga_boundary_harness.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/common/load_fabric_bitstream.svh"] \
        [file normalize "$repo_root/TEST/SoftLogic/flex/eFPGA_top_flex_harness.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/minimal/system/tb_npu_minimal_functional.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/minimal/system/tb_npu_minimal_benchmark.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/flex/system/tb_npu_flex_functional.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/flex/system/tb_npu_flex_crossbar_stress.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/flex/system/tb_npu_flex_3x3_benchmark.sv"] \
        [file normalize "$repo_root/TEST/SoftLogic/flex/system/tb_npu_flex_yolo_tiny.sv"] \
        [file normalize "$repo_root/TEST/eFPGA_Subsystem/TestBenches/tb_efpga_manager.sv"] \
    ] \
]
foreach sf $sim_only_files {
    if {[file exists $sf]} {
        add_files -fileset sim_1 -norecurse $sf
    }
}
set_property include_dirs [list [file normalize "$repo_root/TEST/SoftLogic/common"]] [get_filesets sim_1]
puts "    Added Soft-Logic controllers, boundary harness, and all testbenches to sim_1."

# Exclude full FABulous fabric top from default harness simulation so sim_1 resolves eFPGA_top to eFPGA_top_flex_harness.sv
set fab_synth_only [list \
    [file normalize "$repo_root/OWAS_Fabric/Fabric/eFPGA_top.v"] \
    [file normalize "$repo_root/OWAS_Fabric/Fabric/eFPGA.v"] \
]
foreach ff $fab_synth_only {
    set fobj [get_files -quiet -of_objects [get_filesets sources_1] $ff]
    if {$fobj ne ""} {
        set_property used_in_simulation false $fobj
    }
}
puts "    Marked real eFPGA_top.v and eFPGA.v as USED_IN_SIMULATION = 0 (synthesis/implementation only)."

# ------------------------------------------------------------------------------
# Configure Top Module (Zero compiler defines required; 100% filelist-driven)
# ------------------------------------------------------------------------------
puts "==> Configuring top module (100% filelist-driven architecture)..."
set_property verilog_define {} [get_filesets sources_1]
set_property verilog_define {} [get_filesets sim_1]
set_property top efpga_subsystem_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# ------------------------------------------------------------------------------
# Configure Dynamic Simulation MEM_DIR & High-Speed xsim Defaults
# ------------------------------------------------------------------------------
puts "==> Configuring portable simulation MEM_DIR plusarg and xsim performance flags..."
set golden_dir [file normalize "$repo_root/TEST/GoldenReference"]
set_property -dict [list \
    xsim.elaborate.debug_level {off} \
    xsim.simulate.log_all_signals {false} \
    xsim.simulate.xsim.more_options "-testplusarg MEM_DIR=$golden_dir" \
] [get_filesets sim_1]

# ------------------------------------------------------------------------------
# Attach DRC Crash Prevention Hook (disable_drc.tcl) & Clear Stale Checkpoints
# ------------------------------------------------------------------------------
puts "==> Attaching DRC loop & stack overflow crash prevention hook..."
set proj_dir [get_property DIRECTORY [current_project]]
set drc_hook [file normalize "$proj_dir/disable_drc.tcl"]
if {![file exists $drc_hook]} {
    set drc_hook [file normalize "$repo_root/scripts/disable_drc.tcl"]
}

if {[file exists $drc_hook]} {
    set_property STEPS.OPT_DESIGN.TCL.PRE   $drc_hook [get_runs impl_1]
    set_property STEPS.PLACE_DESIGN.TCL.PRE $drc_hook [get_runs impl_1]
    set_property STEPS.ROUTE_DESIGN.TCL.PRE $drc_hook [get_runs impl_1]
    puts "    Attached disable_drc.tcl to OPT_DESIGN, PLACE_DESIGN, and ROUTE_DESIGN on impl_1."
} else {
    puts "    WARNING: disable_drc.tcl not found at $drc_hook!"
}

# Clear stale incremental checkpoints and reset runs for clean target migration
catch {
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
    set_property INCREMENTAL_CHECKPOINT "" [get_runs synth_1]
    set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs impl_1]
    set_property INCREMENTAL_CHECKPOINT "" [get_runs impl_1]
}
foreach r [get_runs] {
    catch { reset_run $r }
}
puts "    Cleared stale incremental checkpoints and reset synthesis/implementation/OOC runs."

# Disable crash-prone post-opt DRC report on soft-fabric loops
catch { set_property IS_ENABLED false [get_report_configs -quiet -of_objects [get_runs impl_1] impl_1_opt_report_drc_0] }

# ------------------------------------------------------------------------------
# Configure Out-Of-Context (OOC) for Active FABulous Tiles
# ------------------------------------------------------------------------------
puts "==> Configuring Out-Of-Context (OOC) modules to prevent loop overload..."

set ooc_modules [list \
    FLUT51PSDM \
    AXIL_S_IO_W \
    AXI_M_IO_W \
    EXT_PMOD \
    NPU_ACCUM_N \
    NPU_ACCUM_S \
    NPU_CTRL_CFG \
    NPU_SLICE \
    N_term_IO_W \
    N_term_NPU_SLICE \
    SOC_DEBUG_IO \
    S_term_IO_W \
    S_term_NPU_SLICE \
]

foreach mod $ooc_modules {
    if {[get_filesets -quiet $mod] eq ""} {
        if {[catch {create_fileset -blockset -define_from $mod $mod} err]} {
            puts "    \[INFO\] OOC blockset for '$mod': $err"
        } else {
            puts "    \[OK\] Configured OOC blockset for: $mod"
        }
    } else {
        puts "    \[OK\] OOC blockset '$mod' already exists."
    }
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "======================================================================"
puts ">>> Setup Complete! Curated sources linked with OOC & DRC hooks.   <<<"
puts "======================================================================"
