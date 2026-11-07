# SPDX-License-Identifier: Apache-2.0
# Optional detailed placement optimization (OpenROAD improve_placement, "DPO") after
# legalization in Regions.DetailedPlacement. Enabled by DPL_IMPROVE_PLACEMENT_SEED (the plugin
# passes it as _REGIONS_DPO_SEED); without it this file is not sourced.
#
# improve_placement swaps/reorders cells to reduce HPWL and takes a random seed, so it also
# works as a real placement seed (gpl/dpl/grt have none).
#
# Workaround: OpenROAD dcf3613's DPO mishandles rotated fixed macros (R90/R270/MXR90/MYR90):
# its legalization check then reports overlaps and site errors on a legal placement and it
# crashes ("bad optional access"). Without the rotated macros, or with them replaced by
# blockages of their real footprint, DPO runs clean. So during DPO each rotated macro
# instance gets an unrotated proxy master of its real
# footprint with every pin box at its real position (from the instance's ITerm boxes), placed R0
# at the real lower-left corner. Afterwards the real master, orientation, location and placement
# status are restored and the proxy masters/lib are destroyed, so nothing of it reaches the ODB.

proc regions_dpo_rotated { orient } {
    return [expr { $orient in {R90 R270 MXR90 MYR90} }]
}

proc regions_dpo_fence_outsiders {} {
    set block [ord::get_db_block]
    set count 0
    foreach group [$block getGroups] {
        set region [$group getRegion]
        if { $region eq "NULL" } {
            continue
        }
        set boxes [$region getBoundaries]
        foreach inst [$group getInsts] {
            if { [$inst isFixed] } {
                continue
            }
            set b [$inst getBBox]
            set inside 0
            foreach r $boxes {
                if { [$b xMin] >= [$r xMin] && [$b yMin] >= [$r yMin]
                     && [$b xMax] <= [$r xMax] && [$b yMax] <= [$r yMax] } {
                    set inside 1
                    break
                }
            }
            if { !$inside } {
                incr count
            }
        }
    }
    return $count
}

# Swaps every rotated fixed macro to an unrotated proxy master. The restore state is kept in
# ::regions_dpo_lib / ::regions_dpo_swapped as it is built, so a failure half-way can be undone.
#
# The proxies are read as a LEF library (read_lef -library), not built with odb::dbMaster_create:
# swapMaster calls OpenSTA's swap-master callback, which needs an STA cell for the new master,
# and only read_lef registers new masters with STA (API-created ones segfault there).
proc regions_dpo_swap_in_proxies {} {
    set db [ord::get_db]
    set tech [ord::get_db_tech]
    set block [ord::get_db_block]
    set dbu [$tech getDbUnitsPerMicron]
    set layer [[$tech findRoutingLayer 1] getName]
    set ::regions_dpo_lib NULL
    set ::regions_dpo_swapped [list]
    # pass 1: rotated fixed macros, one proxy per master + orientation (same pin offsets)
    set targets [list]
    array set lef {}
    foreach inst [$block getInsts] {
        if { ![$inst isFixed] || [[$inst getMaster] isCore] } {
            continue
        }
        set orient [$inst getOrient]
        if { ![regions_dpo_rotated $orient] } {
            continue
        }
        set master [$inst getMaster]
        set key "__regions_dpo_[$master getName]_${orient}"
        lappend targets [list $inst $key]
        if { [info exists lef($key)] } {
            continue
        }
        set b [$inst getBBox]
        set x0 [$b xMin]
        set y0 [$b yMin]
        set text "MACRO $key\n  CLASS BLOCK ;\n  ORIGIN 0 0 ;\n"
        append text "  SIZE [expr { double([$b getDX]) / $dbu }] BY [expr { double([$b getDY]) / $dbu }] ;\n"
        foreach mterm [$master getMTerms] {
            set name [$mterm getName]
            set dir [$mterm getIoType]
            if { $dir ni {INPUT OUTPUT INOUT} } {
                set dir INOUT
            }
            set use [$mterm getSigType]
            if { $use ni {SIGNAL POWER GROUND CLOCK ANALOG} } {
                set use SIGNAL
            }
            set ib [[$inst findITerm $name] getBBox]
            if { [$ib xMax] > [$ib xMin] || [$ib yMax] > [$ib yMin] } {
                set rect [list [expr { [$ib xMin] - $x0 }] [expr { [$ib yMin] - $y0 }] \
                    [expr { [$ib xMax] - $x0 }] [expr { [$ib yMax] - $y0 }]]
            } else {
                # pin without shapes: put it at the footprint center
                set cx [expr { [$b getDX] / 2 }]
                set cy [expr { [$b getDY] / 2 }]
                set rect [list $cx $cy [expr { $cx + 1 }] [expr { $cy + 1 }]]
            }
            set um [list]
            foreach v $rect {
                lappend um [expr { double($v) / $dbu }]
            }
            append text "  PIN $name\n    DIRECTION $dir ;\n    USE $use ;\n    PORT\n"
            append text "      LAYER $layer ;\n        RECT [join $um " "] ;\n    END\n  END $name\n"
        }
        append text "END $key\n"
        set lef($key) $text
    }
    if { [llength $targets] == 0 } {
        return
    }
    set fd [file tempfile path __regions_dpo_proxy.lef]
    puts $fd "VERSION 5.8 ;\nBUSBITCHARS \"\[\]\" ;\nDIVIDERCHAR \"/\" ;\n"
    foreach key [array names lef] {
        puts $fd $lef($key)
    }
    puts $fd "END LIBRARY"
    close $fd
    read_lef -library $path
    file delete $path
    # pass 2: a proxy instance takes over the macro's footprint and net connections; the macro
    # itself is parked unrotated outside the die (never deleted, so its attributes stay).
    # swapMaster is not usable: OpenSTA's swap callback compares liberty cells and crashes on
    # a master without one.
    set die [$block getDieArea]
    set park_x [expr { [$die xMax] + 2 * [$die dx] }]
    set n 0
    foreach target $targets {
        lassign $target inst key
        set proxy [$db findMaster $key]
        if { $proxy eq "NULL" } {
            utl::error ORD 9303 "improve_placement workaround: proxy master $key not found after read_lef."
        }
        set ::regions_dpo_lib [$proxy getLib]
        set b [$inst getBBox]
        set x0 [$b xMin]
        set y0 [$b yMin]
        set status [$inst getPlacementStatus]
        set pinst [odb::dbInst_create $block $proxy "__regions_dpo_proxy_[incr n]"]
        set nets [list]
        foreach iterm [$inst getITerms] {
            set net [$iterm getNet]
            if { $net eq "NULL" } {
                continue
            }
            set name [[$iterm getMTerm] getName]
            lappend nets $name $net
            $iterm disconnect
            [$pinst findITerm $name] connect $net
        }
        lappend ::regions_dpo_swapped [list $inst [$inst getOrient] [$inst getLocation] $status $pinst $nets]
        $pinst setOrient R0
        $pinst setLocation $x0 $y0
        $pinst setPlacementStatus FIRM
        $inst setPlacementStatus PLACED
        $inst setOrient R0
        $inst setLocation $park_x [expr { $y0 }]
        $inst setPlacementStatus $status
    }
}

proc regions_dpo_restore {} {
    set lib $::regions_dpo_lib
    foreach entry $::regions_dpo_swapped {
        lassign $entry inst orient location status pinst nets
        foreach iterm [$pinst getITerms] {
            if { [$iterm getNet] ne "NULL" } {
                $iterm disconnect
            }
        }
        odb::dbInst_destroy $pinst
        foreach {name net} $nets {
            [$inst findITerm $name] connect $net
        }
        $inst setPlacementStatus PLACED
        $inst setOrient $orient
        $inst setLocation {*}$location
        $inst setPlacementStatus $status
        if { [$inst getOrient] ne $orient || [$inst getLocation] ne $location } {
            utl::error ORD 9301 "improve_placement workaround: could not restore [$inst getName]."
        }
        foreach {name net} $nets {
            if { [[$inst findITerm $name] getNet] ne $net } {
                utl::error ORD 9304 "improve_placement workaround: [$inst getName]/$name not reconnected."
            }
        }
    }
    if { $lib ne "NULL" } {
        foreach m [$lib getMasters] {
            odb::dbMaster_destroy $m
        }
        odb::dbLib_destroy $lib
    }
    set ::regions_dpo_lib NULL
    set ::regions_dpo_swapped [list]
}

proc regions_improve_placement { seed } {
    set before [regions_dpo_fence_outsiders]
    set rc [catch {
        regions_dpo_swap_in_proxies
        puts "\[INFO\] improve_placement: seed $seed,\
            [llength $::regions_dpo_swapped] rotated macro(s) behind unrotated proxies."
        log_cmd improve_placement -random_seed $seed
    } result options]
    regions_dpo_restore
    if { $rc } {
        return -options $options $result
    }
    set after [regions_dpo_fence_outsiders]
    puts "\[INFO\] improve_placement: region outsiders before $before, after $after."
    if { $after > $before } {
        utl::error ORD 9302 "improve_placement moved [expr { $after - $before }] cell(s) out of their placement regions."
    }
}

# Runs DPO once, right after the step's first successful detailed_placement (the
# Regions wrapper from regions_dpl_hook.tcl is already installed).
if { [info commands __regions_dpo_inner_detailed_placement] eq "" } {
    rename detailed_placement __regions_dpo_inner_detailed_placement
    proc detailed_placement { args } {
        set result [uplevel 1 [list __regions_dpo_inner_detailed_placement {*}$args]]
        if { ![info exists ::regions_dpo_done] } {
            set ::regions_dpo_done 1
            regions_improve_placement $::env(_REGIONS_DPO_SEED)
        }
        return $result
    }
}
