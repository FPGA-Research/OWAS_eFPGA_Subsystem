# SPDX-License-Identifier: Apache-2.0
# Optional extra global_route options, set by GRT_RESISTANCE_AWARE / GRT_CRITICAL_NETS_PERCENTAGE
# (the plugin passes them as _GRT_RESISTANCE_AWARE / _GRT_CRITICAL_NETS_PCT). Sourced only when one
# of them is set, before the step's original script, so every global_route call of the step
# (LibreLane's common/grt.tcl) gets them. The resizer's incremental routing reuses the settings.
if { [info commands __grt_extra_orig_global_route] eq "" } {
    rename global_route __grt_extra_orig_global_route
    proc global_route { args } {
        set extra [list]
        if { "-start_incremental" ni $args && "-end_incremental" ni $args } {
            if { [info exists ::env(_GRT_RESISTANCE_AWARE)] && "-resistance_aware" ni $args } {
                lappend extra -resistance_aware
            }
            if { [info exists ::env(_GRT_CRITICAL_NETS_PCT)] && "-critical_nets_percentage" ni $args } {
                lappend extra -critical_nets_percentage $::env(_GRT_CRITICAL_NETS_PCT)
            }
        }
        if { [llength $extra] } {
            puts "\[INFO\] grt_extra: global_route $extra"
        }
        return [uplevel 1 [list __grt_extra_orig_global_route {*}$args {*}$extra]]
    }
}
