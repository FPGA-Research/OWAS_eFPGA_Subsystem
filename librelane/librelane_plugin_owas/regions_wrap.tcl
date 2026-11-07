# SPDX-License-Identifier: Apache-2.0
# Entry script for the Regions.* step variants: installs the detailed_placement
# hook, then runs the original LibreLane script unchanged.
source $::env(_REGIONS_HOOK_TCL)
# Optional debug hook (e.g. dump fence outsiders instead of legalizing).
if { [info exists ::env(REGIONS_DIAG_TCL)] } {
    source $::env(REGIONS_DIAG_TCL)
}
# Optional repeated hold repair (HOLD_REPAIR_REPEATS) and post-GRT hold-repair setup
# margin (GRT_HOLD_REPAIR_SETUP_MARGIN), see hold_repeat.tcl. Config variables only
# arrive with _env.tcl (sourced later by the original script), so the plugin passes
# these as _REGIONS_HOLD_REPEATS / _REGIONS_HOLD_SETUP_MARGIN in the process env.
if { [info exists ::env(_REGIONS_HOLD_REPEATS)] || [info exists ::env(_REGIONS_HOLD_SETUP_MARGIN)] } {
    source $::env(_REGIONS_HOLD_REPEAT_TCL)
}
# Optional improve_placement after legalization (DPL_IMPROVE_PLACEMENT_SEED, only passed to
# Regions.DetailedPlacement), see improve_placement.tcl. Wraps the detailed_placement hook above.
if { [info exists ::env(_REGIONS_DPO_SEED)] } {
    source $::env(_REGIONS_DPO_TCL)
}
# Optional extra global_route options (GRT_RESISTANCE_AWARE / GRT_CRITICAL_NETS_PERCENTAGE).
if { [info exists ::env(_GRT_EXTRA_TCL)] } {
    source $::env(_GRT_EXTRA_TCL)
}
source $::env(_REGIONS_ORIG_SCRIPT)
