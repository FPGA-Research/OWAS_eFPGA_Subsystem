# SPDX-License-Identifier: Apache-2.0
# Repeated hold repair for the Regions.* steps, sourced by regions_wrap.tcl when
# HOLD_REPAIR_REPEATS > 1 or GRT_HOLD_REPAIR_SETUP_MARGIN is set (passed by the
# plugin as env _REGIONS_HOLD_REPEATS / _REGIONS_HOLD_SETUP_MARGIN).
#
# Works around OpenROAD dcf3613 RepairHold: when a hold buffer is backed out (global
# setup WNS fell below the setup margin), the journal restore resets
# inserted_buffer_count_ to 0, so the pass loop sees "no progress" and stops after
# ~2 passes. Each pass only fixes the worst hold path per endpoint, so endpoints with
# many violating fan-in paths never converge.
#
# Wraps repair_timing: a call with -hold is repeated with the same arguments, up to
# HOLD_REPAIR_REPEATS calls in total, while the hold WNS or TNS still improves.
# Calls without -hold are passed through unchanged.
#
# GRT_HOLD_REPAIR_SETUP_MARGIN (env _REGIONS_HOLD_SETUP_MARGIN, set by the plugin in
# Regions.ResizerTimingPostGRT only) replaces the -setup_margin of the -hold calls.
# LibreLane's rsz_timing_postgrt.tcl passes GRT_RESIZER_SETUP_SLACK_MARGIN to the setup
# and the hold repair (separate calls); a large margin keeps hold buffers off logic shared
# by hold-critical and setup-critical paths.
# Minimum hold WNS/TNS gain (ns) for another repair_timing -hold call.
if { ![info exists ::hold_repeat_min_gain] } {
    set ::hold_repeat_min_gain 0.001
}

if { [info commands repair_timing] ne "" && [info commands __hold_repeat_orig_repair_timing] eq "" } {
    rename repair_timing __hold_repeat_orig_repair_timing
    proc repair_timing { args } {
        if { [lsearch -exact $args -hold] < 0 } {
            return [uplevel 1 [list __hold_repeat_orig_repair_timing {*}$args]]
        }
        if { [info exists ::env(_REGIONS_HOLD_SETUP_MARGIN)] } {
            set j [lsearch -exact $args -setup_margin]
            if { $j >= 0 } {
                lset args [expr {$j + 1}] $::env(_REGIONS_HOLD_SETUP_MARGIN)
            } else {
                lappend args -setup_margin $::env(_REGIONS_HOLD_SETUP_MARGIN)
            }
            puts "\[INFO\] hold_repeat: hold repair with -setup_margin $::env(_REGIONS_HOLD_SETUP_MARGIN)"
        }
        set max_calls 1
        if { [info exists ::env(_REGIONS_HOLD_REPEATS)] } {
            set max_calls $::env(_REGIONS_HOLD_REPEATS)
        }
        set margin 0.0
        set i [lsearch -exact $args -hold_margin]
        if { $i >= 0 } { set margin [lindex $args [expr {$i + 1}]] }
        set rc [uplevel 1 [list __hold_repeat_orig_repair_timing {*}$args]]
        for {set n 2} {$n <= $max_calls} {incr n} {
            set wns [sta::worst_slack -min]
            set tns [sta::total_negative_slack -min]
            puts [format "\[INFO\] hold_repeat: after call %d hold WNS %.4f TNS %.4f setup WNS %.4f" \
                [expr {$n - 1}] $wns $tns [sta::worst_slack -max]]
            if { $wns >= $margin } { break }
            set rc [uplevel 1 [list __hold_repeat_orig_repair_timing {*}$args]]
            set wns2 [sta::worst_slack -min]
            set tns2 [sta::total_negative_slack -min]
            if { $wns2 <= $wns + $::hold_repeat_min_gain && $tns2 <= $tns + $::hold_repeat_min_gain } {
                puts [format "\[INFO\] hold_repeat: call %d no progress (WNS %.4f TNS %.4f), stop" \
                    $n $wns2 $tns2]
                break
            }
        }
        puts [format "\[INFO\] hold_repeat: final hold WNS %.4f TNS %.4f setup WNS %.4f" \
            [sta::worst_slack -min] [sta::total_negative_slack -min] [sta::worst_slack -max]]
        return $rc
    }
}
