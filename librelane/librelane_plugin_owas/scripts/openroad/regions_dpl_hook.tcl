# SPDX-License-Identifier: Apache-2.0
# Sourced by regions_wrap.tcl inside OpenROAD steps that place or legalize.
#
# The resizer and CTS never add the cells they insert to a dbGroup, so a buffer
# for fenced logic starts inside the fence as an outsider and detailed_placement
# would push it out of the region. This wraps detailed_placement so such cells
# are first added to the group of the region they sit in, and the region's
# padding is applied. global_placement is wrapped to apply per-region density.
# Cells inserted just outside a region (absorb_margin) can join it too, see
# regions_absorb_near.

# Tunables; set any of them before this file is sourced to override it.
#
# Names of cells OpenROAD's resizer and CTS create (no hierarchy separator).
if { ![info exists ::regions_new_cell_regexp] } {
    set ::regions_new_cell_regexp {^(wire|fanout|hold|delaybuf|clkbuf|clkload|split|rebuffer|load_slew|max_[a-z]+|place|buffer)[0-9_][^.]*$}
}
# Expansion steps when looking for a free side next to overlapped obstacles.
if { ![info exists ::regions_unstick_max_steps] } {
    set ::regions_unstick_max_steps 3
}
# Grouped cells on obstacles named individually before legalization.
if { ![info exists ::regions_report_on_obstacles_max] } {
    set ::regions_report_on_obstacles_max 10
}
# Cells dpl could not place that are listed after a failure.
if { ![info exists ::regions_report_dpl_failures_max] } {
    set ::regions_report_dpl_failures_max 50
}
# Share of a fixed macro's area that must lie inside a region for the region's
# group to get it during global placement; tolerates the macro edge sticking out
# of the core or the site-snapped region. Same value as in regions_odb.py.
if { ![info exists ::regions_lend_min_share] } {
    set ::regions_lend_min_share 0.99
}
# Average displacement limit (um) if PLACEMENT_REGIONS_MAX_AVG_DISPLACEMENT is
# not set, i.e. the hook runs outside the plugin's steps.
if { ![info exists ::regions_default_max_avg_displacement] } {
    set ::regions_default_max_avg_displacement 50.0
}

# Site width, row height and core origin, for snapping to the site/row grid.
proc regions_grid {} {
    set block [ord::get_db_block]
    set site [[lindex [$block getRows] 0] getSite]
    set core [$block getCoreArea]
    return [list [$site getWidth] [$site getHeight] [$core xMin] [$core yMin]]
}

# Bounding box {xMin yMin xMax yMax} of all boxes of `region`.
proc regions_bbox { region } {
    set boxes [$region getBoundaries]
    return [list \
        [tcl::mathfunc::min {*}[lmap b $boxes { $b xMin }]] \
        [tcl::mathfunc::min {*}[lmap b $boxes { $b yMin }]] \
        [tcl::mathfunc::max {*}[lmap b $boxes { $b xMax }]] \
        [tcl::mathfunc::max {*}[lmap b $boxes { $b yMax }]]]
}

# Fixed block instances (macros), in block order.
proc regions_fixed_macros {} {
    set macros [list]
    foreach inst [[ord::get_db_block] getInsts] {
        if { [$inst isFixed] && [[$inst getMaster] isBlock] } {
            lappend macros $inst
        }
    }
    return $macros
}

# 1 if `inst` is a movable core cell in no group.
proc regions_ungrouped_movable { inst } {
    return [expr { [$inst getGroup] eq "NULL" && ![$inst isFixed] && [[$inst getMaster] isCore] }]
}

# Group of the first entry of `boxes` ({group xMin yMin xMax yMax}, see
# regions_absorb) that contains the point (x, y) (half-open), or "".
proc regions_box_group { boxes x y } {
    foreach entry $boxes {
        lassign $entry group x0 y0 x1 y1
        if { $x >= $x0 && $x < $x1 && $y >= $y0 && $y < $y1 } {
            return $group
        }
    }
    return ""
}

# 1 if `inst` has a signal net to a top-level port whose pin center lies more
# than `limit` (DBU, Manhattan) outside every box of `region`.
proc regions_far_port { inst region limit } {
    foreach iterm [$inst getITerms] {
        set net [$iterm getNet]
        if { $net eq "NULL" || [$net getSigType] ne "SIGNAL" } {
            continue
        }
        foreach bterm [$net getBTerms] {
            set bb [$bterm getBBox]
            set px [expr { ([$bb xMin] + [$bb xMax]) / 2 }]
            set py [expr { ([$bb yMin] + [$bb yMax]) / 2 }]
            set best ""
            foreach box [$region getBoundaries] {
                set dx [expr { max([$box xMin] - $px, 0, $px - [$box xMax]) }]
                set dy [expr { max([$box yMin] - $py, 0, $py - [$box yMax]) }]
                set d [expr { $dx + $dy }]
                if { $best eq "" || $d < $best } {
                    set best $d
                }
            }
            if { $best ne "" && $best > $limit } {
                return 1
            }
        }
    }
    return 0
}

# Lower-left corner of `inst`, moved into the core area if the cell sticks out
# of it. repair_design can put a wire buffer with its origin on the core's top
# edge (above the last row); a region reaching the core edge then does not
# contain it (half-open test), the cell stays ungrouped, and dpl fails when the
# only rows within reach belong to that exclusive region (DPL-0036).
proc regions_core_xy { inst } {
    set core [[ord::get_db_block] getCoreArea]
    set b [$inst getBBox]
    set x [expr { max([$core xMin], min([$b xMin], [$core xMax] - [$b getDX])) }]
    set y [expr { max([$core yMin], min([$b yMin], [$core yMax] - [$b getDY])) }]
    return [list $x $y]
}

# 1 if at least one signal-net neighbor of `inst` is in the group named `target`
# and none is in another group; ungrouped neighbors are ignored.
proc regions_neighbors_in { inst target } {
    set ok 0
    foreach iterm [$inst getITerms] {
        set net [$iterm getNet]
        if { $net eq "NULL" || [$net isSpecial] } {
            continue
        }
        set sig [$net getSigType]
        if { $sig eq "POWER" || $sig eq "GROUND" } {
            continue
        }
        foreach other [$net getITerms] {
            set other_inst [$other getInst]
            if { $other_inst eq $inst } {
                continue
            }
            set other_group [$other_inst getGroup]
            if { $other_group eq "NULL" } {
                continue
            }
            if { [$other_group getName] ne $target } {
                return 0
            }
            set ok 1
        }
    }
    return $ok
}

# Adds each {inst group} pair of `candidates` whose cell passes
# regions_neighbors_in to that group, repeated until nothing changes, so chains
# of new cells are absorbed from the grouped end. Returns {absorbed remaining},
# both lists of pairs.
proc regions_absorb_connected { candidates } {
    set absorbed [list]
    set changed 1
    while { $changed } {
        set changed 0
        set remaining [list]
        foreach entry $candidates {
            lassign $entry inst group
            if { [regions_neighbors_in $inst [$group getName]] } {
                $group addInst $inst
                lappend absorbed $entry
                set changed 1
            } else {
                lappend remaining $entry
            }
        }
        set candidates $remaining
    }
    return [list $absorbed $candidates]
}

# Adds every movable, ungrouped core cell located inside a region to that
# region's group if at least one neighbor is in the group and no neighbor is
# in a different group. Ungrouped neighbors are allowed, so buffer chains and
# nets leaving the region are absorbed; port connections are ignored.
proc regions_absorb {} {
    set block [ord::get_db_block]
    set regions [$block getRegions]
    if { [llength $regions] == 0 } {
        return
    }

    # 0. Ungrouped cells matching a region's `late_instances` join it wherever
    #    they are; regions_clamp then pulls them inside. With `late_port_margin`,
    #    a cell on a net to a top-level port more than that distance outside the
    #    region stays ungrouped (an IO buffer for a pin on another edge).
    set dbu [$block getDbUnitsPerMicron]
    array unset port_margin
    foreach {name margin} [regions_setting late_port_margin] {
        set port_margin($name) [expr { round($margin * $dbu) }]
    }
    foreach {name patterns} [regions_setting late_instances] {
        set group [$block findGroup $name]
        if { $group eq "NULL" || [llength $patterns] == 0 } {
            continue
        }
        set count 0
        set kept_out 0
        foreach inst [$block getInsts] {
            if { ![regions_ungrouped_movable $inst] } {
                continue
            }
            foreach pattern $patterns {
                if { [string match $pattern [$inst getName]] } {
                    if { [info exists port_margin($name)]
                         && [regions_far_port $inst [$group getRegion] $port_margin($name)] } {
                        incr kept_out
                        break
                    }
                    $group addInst $inst
                    incr count
                    break
                }
            }
        }
        puts "\[INFO\] Placement regions: $name took $count cell(s) from late_instances."
        if { [info exists port_margin($name)] } {
            puts "\[INFO\] Placement regions: $name left $kept_out late_instances cell(s) ungrouped (port beyond late_port_margin)."
        }
    }

    set boxes [list]
    foreach region $regions {
        foreach group [$region getGroups] {
            foreach box [$region getBoundaries] {
                lappend boxes [list $group [$box xMin] [$box yMin] [$box xMax] [$box yMax]]
            }
        }
    }

    # 1. Ungrouped movable core cells inside a region box.
    set candidates [list]
    foreach inst [$block getInsts] {
        if { ![regions_ungrouped_movable $inst] } {
            continue
        }
        set group [regions_box_group $boxes {*}[regions_core_xy $inst]]
        if { $group ne "" } {
            lappend candidates [list $inst $group]
        }
    }

    # 2. Absorb by connectivity.
    lassign [regions_absorb_connected $candidates] absorbed candidates

    # 3. Cells the resizer/CTS inserted (flat names like wire123, hold45) join
    #    the region they sit in even if their nets also reach another group or
    #    only other ungrouped cells: the tool placed them there on purpose, and
    #    an outsider in a region spanning the whole die height can only leave
    #    sideways, often farther than PL_MAX_DISPLACEMENT_X (DPL-0036).
    #    Unfenced logic (hierarchical names) is still moved out.
    set new_absorbed 0
    set remaining [list]
    foreach entry $candidates {
        lassign $entry inst group
        if { [regexp $::regions_new_cell_regexp [$inst getName]] } {
            $group addInst $inst
            incr new_absorbed
        } else {
            lappend remaining $entry
        }
    }
    set candidates $remaining

    puts "\[INFO\] Placement regions: absorbed [llength $absorbed] new cell(s) by connectivity,\
        $new_absorbed resizer/CTS cell(s) by location;\
        [llength $candidates] outsider(s) inside regions will be moved out."

    regions_absorb_near $boxes
}

# 4. Resizer/CTS cells (flat names) outside every region but within a region's
#    `absorb_margin` (um) join that region if at least one neighbor is in it and
#    none is in another group (ungrouped neighbors are ignored; iterated, so
#    buffer chains are absorbed from the grouped end). regions_clamp then moves
#    them just inside the region edge. Meant for cells the tools put next to a
#    macro pin on the far side of an unplaceable strip, e.g. hold buffers and
#    clock buffers at the pins of a macro whose halo (no rows) separates it from
#    the region: as outsiders dpl could only move them along the macro edge to
#    its end, where they pile up. `boxes` = region boxes from regions_absorb.
proc regions_absorb_near { boxes } {
    set block [ord::get_db_block]
    set dbu [$block getDbUnitsPerMicron]
    set near_boxes [list]
    foreach {name margin} [regions_setting absorb_margin] {
        set region [$block findRegion $name]
        set group [$block findGroup $name]
        if { $region eq "NULL" || $group eq "NULL" } {
            continue
        }
        set m [expr { round(double($margin) * $dbu) }]
        foreach box [$region getBoundaries] {
            lappend near_boxes [list $group [$box xMin] [$box yMin] [$box xMax] [$box yMax] $m]
        }
    }
    if { [llength $near_boxes] == 0 } {
        return
    }

    # Candidates: ungrouped movable resizer/CTS cells outside every region box
    # (same inside test as regions_absorb), each with its nearest region within
    # that region's margin.
    set candidates [list]
    foreach inst [$block getInsts] {
        if { ![regions_ungrouped_movable $inst] } {
            continue
        }
        if { ![regexp $::regions_new_cell_regexp [$inst getName]] } {
            continue
        }
        if { [regions_box_group $boxes {*}[regions_core_xy $inst]] ne "" } {
            continue
        }
        set b [$inst getBBox]
        set best ""
        foreach entry $near_boxes {
            lassign $entry group x0 y0 x1 y1 m
            set dx [expr { max($x0 - [$b xMax], [$b xMin] - $x1, 0) }]
            set dy [expr { max($y0 - [$b yMax], [$b yMin] - $y1, 0) }]
            set d [expr { max($dx, $dy) }]
            if { $d <= $m && ($best eq "" || $d < $best_d) } {
                set best $group
                set best_d $d
            }
        }
        if { $best ne "" } {
            lappend candidates [list $inst $best]
        }
    }

    lassign [regions_absorb_connected $candidates] absorbed candidates
    array set count {}
    foreach entry $absorbed {
        incr count([[lindex $entry 1] getName])
    }

    foreach {name margin} [regions_setting absorb_margin] {
        set n [expr { [info exists count($name)] ? $count($name) : 0 }]
        puts "\[INFO\] Placement regions: $name absorbed $n resizer/CTS cell(s) from\
            outside, within $margin um."
    }
    puts "\[INFO\] Placement regions: [llength $candidates] resizer/CTS cell(s) near a\
        region stay outside (no neighbor in it, or neighbors in another group)."
}

# Moves grouped cells that stick out of their region's bbox (e.g. buffers the
# resizer inserts at the region edge) fully inside it, on the site/row grid.
# Like a cell on a macro at the region edge (see regions_unstick), a cell
# starting outside the region makes dpl's search fail.
proc regions_clamp {} {
    set block [ord::get_db_block]
    lassign [regions_grid] sw rh ox oy

    set moved 0
    foreach region [$block getRegions] {
        lassign [regions_bbox $region] x0 y0 x1 y1
        # Region bbox snapped inwards to the site/row grid.
        set r0 [expr { $ox - (($ox - $x0) / $sw) * $sw }]
        set r1 [expr { $oy - (($oy - $y0) / $rh) * $rh }]
        set r2 [expr { $ox + (($x1 - $ox) / $sw) * $sw }]
        set r3 [expr { $oy + (($y1 - $oy) / $rh) * $rh }]
        foreach group [$region getGroups] {
            foreach inst [$group getInsts] {
                if { [$inst isFixed] } {
                    continue
                }
                set b [$inst getBBox]
                set x [$b xMin]
                set y [$b yMin]
                set nx [expr { max($r0, min($x, $r2 - [$b getDX])) }]
                set ny [expr { max($r1, min($y, $r3 - [$b getDY])) }]
                if { $nx != $x || $ny != $y } {
                    $inst setLocation $nx $ny
                    incr moved
                }
            }
        }
    }
    puts "\[INFO\] Placement regions: moved $moved cell(s) back inside their region."
}

# Boxes no cell may sit on: fixed block instances (macros) and hard placement
# blockages (e.g. strips between stacked macros). Each entry is
# {xMin yMin xMax yMax name}.
proc regions_obstacles {} {
    set block [ord::get_db_block]
    set boxes [list]
    foreach inst [regions_fixed_macros] {
        set b [$inst getBBox]
        lappend boxes [list [$b xMin] [$b yMin] [$b xMax] [$b yMax] [$inst getName]]
    }
    foreach blockage [$block getBlockages] {
        if { [$blockage isSoft] } {
            continue
        }
        set b [$blockage getBBox]
        lappend boxes [list [$b xMin] [$b yMin] [$b xMax] [$b yMax] "placement blockage"]
    }
    return $boxes
}

# Entries of `obstacles` (see regions_obstacles) that the box with lower-left
# corner (x, y) and size w x h overlaps.
proc regions_overlapping { obstacles x y w h } {
    set hits [list]
    foreach o $obstacles {
        lassign $o o0 o1 o2 o3
        if { $x + $w <= $o0 || $x >= $o2 || $y + $h <= $o1 || $y >= $o3 } {
            continue
        }
        lappend hits $o
    }
    return $hits
}

# Moves grouped cells that gpl or the resizer left on a fixed macro or a hard
# placement blockage to the nearest side of it that lies inside their region.
# dpl pushes such cells to the nearest obstacle edge itself, which can be
# outside the region (e.g. a macro flush with the region edge); its search then
# fails for that cell, and one failure makes dpl re-place the whole group from
# the region corners (Opendp::placeGroups2 -> brickPlace2): average
# displacement of hundreds of um, caught by regions_check_displacement.
# A cell can overlap two obstacles at once (e.g. on the gap between two macros
# flush with the same region edge), and a side of one can lie on another. So the
# sides of every obstacle the cell overlaps are candidates, a candidate on
# another obstacle expands into that one's sides (up to
# ::regions_unstick_max_steps steps), and the nearest in-region candidate free
# of all obstacles wins.
proc regions_unstick {} {
    set block [ord::get_db_block]
    set obstacles [regions_obstacles]
    lassign [regions_grid] sw rh ox oy

    set moved 0
    set stuck 0
    foreach region [$block getRegions] {
        lassign [regions_bbox $region] r0 r1 r2 r3
        foreach group [$region getGroups] {
            foreach inst [$group getInsts] {
                if { [$inst isFixed] } {
                    continue
                }
                set b [$inst getBBox]
                set x0 [$b xMin]
                set y0 [$b yMin]
                set w [$b getDX]
                set h [$b getDY]
                if { [llength [regions_overlapping $obstacles $x0 $y0 $w $h]] == 0 } {
                    continue
                }
                set best ""
                set frontier [list [list $x0 $y0]]
                array unset seen
                for { set step 0 } { $step < $::regions_unstick_max_steps && [llength $frontier] > 0 } { incr step } {
                    set next [list]
                    foreach pos $frontier {
                        lassign $pos x y
                        # Left, right, below, above each overlapped obstacle,
                        # snapped outwards to the site/row grid with one site/row
                        # to spare.
                        set sx [expr { $ox + (($x - $ox) / $sw) * $sw }]
                        set sy [expr { $oy + (($y - $oy) / $rh) * $rh }]
                        foreach o [regions_overlapping $obstacles $x $y $w $h] {
                            lassign $o o0 o1 o2 o3
                            foreach {cx cy} [list \
                                [expr { $ox + (($o0 - $w - $ox) / $sw) * $sw - $sw }] $sy \
                                [expr { $ox - (($ox - $o2) / $sw) * $sw + $sw }] $sy \
                                $sx [expr { $oy + (($o1 - $h - $oy) / $rh) * $rh - $rh }] \
                                $sx [expr { $oy - (($oy - $o3) / $rh) * $rh + $rh }]] {
                                if { $cx < $r0 || $cx + $w > $r2 || $cy < $r1 || $cy + $h > $r3
                                     || [info exists seen($cx,$cy)] } {
                                    continue
                                }
                                set seen($cx,$cy) 1
                                if { [llength [regions_overlapping $obstacles $cx $cy $w $h]] > 0 } {
                                    lappend next [list $cx $cy]
                                    continue
                                }
                                set d [expr { abs($cx - $x0) + abs($cy - $y0) }]
                                if { $best eq "" || $d < $best_d } {
                                    set best [list $cx $cy]
                                    set best_d $d
                                }
                            }
                        }
                    }
                    set frontier $next
                }
                if { $best eq "" } {
                    incr stuck
                } else {
                    $inst setLocation {*}$best
                    incr moved
                }
            }
        }
    }
    puts "\[INFO\] Placement regions: moved $moved cell(s) off macros/blockages;\
        $stuck without a free side inside their region."
}

# Warns about grouped cells that still overlap a macro or hard placement
# blockage right before legalization: each can make dpl's search fail and
# trigger the whole-group brick placement (see regions_unstick), so an ORD-9310
# from regions_check_displacement can be traced to them without a debug replay.
proc regions_report_on_obstacles {} {
    set block [ord::get_db_block]
    set dbu [$block getDbUnitsPerMicron]
    set obstacles [regions_obstacles]
    set max $::regions_report_on_obstacles_max
    set count 0
    foreach inst [$block getInsts] {
        if { [$inst isFixed] || [$inst getGroup] eq "NULL" } {
            continue
        }
        set b [$inst getBBox]
        set hits [regions_overlapping $obstacles [$b xMin] [$b yMin] [$b getDX] [$b getDY]]
        if { [llength $hits] == 0 } {
            continue
        }
        incr count
        if { $count <= $max } {
            puts "\[WARNING\] Placement regions: [$inst getName] ([[$inst getGroup] getName])\
                at ([regions_um [$b xMin] $dbu], [regions_um [$b yMin] $dbu]) um is on\
                [join [lmap h $hits { lindex $h 4 }] {, }]; dpl may fail it and brick-place its group."
        }
    }
    if { $count > $max } {
        puts "\[WARNING\] Placement regions: ... [expr { $count - $max }] more grouped cell(s) on macros/blockages."
    }
}

# Returns the region settings (PLACEMENT_REGIONS as a Tcl dict) whose `key`
# is set, as a flat list of name/value pairs.
proc regions_setting { key } {
    if { ![info exists ::env(PLACEMENT_REGIONS)] } {
        return [list]
    }
    set result [list]
    dict for {name settings} $::env(PLACEMENT_REGIONS) {
        if { [dict exists $settings $key] } {
            set value [dict get $settings $key]
            if { $value ne "None" } {
                lappend result $name $value
            }
        }
    }
    return $result
}

# Gives each region's cells its `dpl_padding` (sites, split per side like
# DPL_CELL_PADDING). Instance padding overrides master padding, so masters in
# CELL_PAD_EXCLUDE (taps, fill, ...) are skipped.
proc regions_set_padding {} {
    set block [ord::get_db_block]
    set exclude [list]
    if { [info exists ::env(CELL_PAD_EXCLUDE)] } {
        set exclude $::env(CELL_PAD_EXCLUDE)
    }
    set global_side 0
    if { [info exists ::env(DPL_CELL_PADDING)] } {
        set global_side [expr { $::env(DPL_CELL_PADDING) / 2 }]
    }
    foreach {name padding} [regions_setting dpl_padding] {
        set group [$block findGroup $name]
        if { $group eq "NULL" } {
            continue
        }
        set side [expr { $padding / 2 }]
        if { $side < $global_side } {
            puts "\[WARNING\] Placement regions: $name dpl_padding $padding is below\
                DPL_CELL_PADDING; later steps' check_placement uses the global padding."
        }
        array unset excluded
        set count 0
        foreach inst [$group getInsts] {
            set master [[$inst getMaster] getName]
            if { ![info exists excluded($master)] } {
                set excluded($master) 0
                foreach pattern $exclude {
                    if { [string match $pattern $master] } {
                        set excluded($master) 1
                        break
                    }
                }
            }
            if { $excluded($master) } {
                continue
            }
            dpl::set_padding_inst $inst $side $side
            incr count
        }
        puts "\[INFO\] Placement regions: $name padding $side site(s) per side on $count cell(s)."
    }
}

# Adds a partial placement blockage over each region with `gpl_max_density`.
# Only gpl honors the density; dpl/cts treat any non-soft blockage as fully
# blocked, so the blockages must be destroyed again after global placement.
# gpl subtracts every blockage from every region placer's free area, so the
# other regions see slightly less free area than they have.
proc regions_create_gpl_blockages {} {
    set block [ord::get_db_block]
    set blockages [list]
    foreach {name density} [regions_setting gpl_max_density] {
        set region [$block findRegion $name]
        if { $region eq "NULL" } {
            continue
        }
        foreach box [$region getBoundaries] {
            set blockage [odb::dbBlockage_create $block \
                [$box xMin] [$box yMin] [$box xMax] [$box yMax]]
            $blockage setMaxDensity $density
            lappend blockages $blockage
        }
        puts "\[INFO\] Placement regions: $name global placement max density $density %."
    }
    return $blockages
}

proc regions_um { value dbu } {
    return [format %.2f [expr { double($value) / $dbu }]]
}

# Logs where the cells dpl could not place (DPL-0035 names in `log`) sit, since
# dpl itself only prints their names and the failed step writes no odb. dpl
# errors out before it writes any location back, so these are the positions it
# started from (after regions_absorb/clamp/unstick): location, size, region and
# whether the cell is inside it, the fixed macro it overlaps or the nearest one,
# and its nets.
proc regions_report_dpl_failures { log } {
    set names [lmap {_ name} [regexp -all -inline -line {DPL-0035\]\s+(\S+)} $log] { set name }]
    if { [llength $names] == 0 } {
        return
    }
    set block [ord::get_db_block]
    set dbu [$block getDbUnitsPerMicron]
    set macros [regions_fixed_macros]
    set max_report $::regions_report_dpl_failures_max
    puts "\[INFO\] Placement regions: [llength $names] cell(s) dpl could not place\
        (start positions in um; first $max_report):"
    foreach name [lrange $names 0 [expr { $max_report - 1 }]] {
        set inst [$block findInst $name]
        if { $inst eq "NULL" } {
            puts "\[INFO\]   $name: not found"
            continue
        }
        set b [$inst getBBox]
        set x0 [$b xMin]; set y0 [$b yMin]; set x1 [$b xMax]; set y1 [$b yMax]
        set line "$name ([[$inst getMaster] getName]) at\
            ([regions_um $x0 $dbu], [regions_um $y0 $dbu]) - ([regions_um $x1 $dbu], [regions_um $y1 $dbu])"

        set group [$inst getGroup]
        if { $group eq "NULL" } {
            append line ", ungrouped"
        } else {
            set inside 0
            set region [$group getRegion]
            foreach box [$region getBoundaries] {
                if { $x0 >= [$box xMin] && $x1 <= [$box xMax] && $y0 >= [$box yMin] && $y1 <= [$box yMax] } {
                    set inside 1
                    break
                }
            }
            append line ", region [$group getName] ([expr { $inside ? "inside" : "OUTSIDE" }])"
        }

        set best ""
        foreach macro $macros {
            set m [$macro getBBox]
            set dx [expr { max([$m xMin] - $x1, $x0 - [$m xMax], 0) }]
            set dy [expr { max([$m yMin] - $y1, $y0 - [$m yMax], 0) }]
            set d [expr { max($dx, $dy) }]
            if { $best eq "" || $d < $best_d } {
                set best $macro
                set best_d $d
            }
        }
        if { $best ne "" } {
            if { $best_d == 0 } {
                append line ", ON macro [$best getName]"
            } else {
                append line ", [regions_um $best_d $dbu] from macro [$best getName]"
            }
        }

        set nets [list]
        foreach iterm [$inst getITerms] {
            set net [$iterm getNet]
            if { $net ne "NULL" && ![$net isSpecial] } {
                lappend nets "[[$iterm getMTerm] getName]=[$net getName] ([llength [$net getITerms]] pins)"
            }
        }
        if { [llength $nets] > 0 } {
            append line ", nets [join $nets {, }]"
        }
        puts "\[INFO\]   $line"
    }
}

proc regions_run_detailed_placement {} {
    __regions_orig_detailed_placement {*}$::regions_dpl_args
}

if { [info commands __regions_orig_detailed_placement] eq "" } {
    rename detailed_placement __regions_orig_detailed_placement
    proc detailed_placement { args } {
        regions_absorb
        regions_clamp
        regions_unstick
        regions_report_on_obstacles
        regions_set_padding
        # tee still prints dpl's output; it is only kept to find the failed cells.
        set ::regions_dpl_args $args
        set rc [catch {tee -variable ::regions_dpl_log regions_run_detailed_placement} result options]
        if { $rc } {
            catch { regions_report_dpl_failures $::regions_dpl_log }
        } else {
            regions_check_displacement $::regions_dpl_log
        }
        unset -nocomplain ::regions_dpl_log
        return -options $options $result
    }
}

# Stops the step when legalization moved the cells far on average, e.g. after
# dpl brick-placed a whole group (see regions_unstick). dpl reports that as
# success, and the run would then crawl through GRT/repair_design for hours.
# Limit in um: PLACEMENT_REGIONS_MAX_AVG_DISPLACEMENT.
proc regions_check_displacement { log } {
    if { ![regexp -line {average displacement\s+([0-9.eE+-]+)\s*u} $log -> avg] } {
        return
    }
    set limit $::regions_default_max_avg_displacement
    if { [info exists ::env(PLACEMENT_REGIONS_MAX_AVG_DISPLACEMENT)] } {
        set limit $::env(PLACEMENT_REGIONS_MAX_AVG_DISPLACEMENT)
    }
    if { $avg > $limit } {
        utl::error ORD 9310 "Placement regions: detailed_placement moved cells $avg um on\
            average (limit $limit um): legalization blew up, stopping instead of routing it."
    }
}

# gpl's region placers only block the sites of fixed instances in their own
# group, so they spread the region's cells over any other macro inside it.
# Lends each region's group the fixed macros (nearly) fully inside it; returns
# the group/macro pairs to give back after global placement. They must not stay
# in the group: dpl would try to legalize them (DPL-0017).
proc regions_lend_macros {} {
    set block [ord::get_db_block]
    set lent [list]
    foreach inst [regions_fixed_macros] {
        if { [$inst getGroup] ne "NULL" } {
            continue
        }
        set bbox [$inst getBBox]
        set area [expr { double([$bbox getDX]) * [$bbox getDY] }]
        foreach region [$block getRegions] {
            set inside 0.0
            foreach box [$region getBoundaries] {
                set w [expr { min([$bbox xMax], [$box xMax]) - max([$bbox xMin], [$box xMin]) }]
                set h [expr { min([$bbox yMax], [$box yMax]) - max([$bbox yMin], [$box yMin]) }]
                if { $w > 0 && $h > 0 } {
                    set inside [expr { $inside + double($w) * $h }]
                }
            }
            if { $inside >= $::regions_lend_min_share * $area } {
                set group [lindex [$region getGroups] 0]
                $group addInst $inst
                lappend lent $group $inst
                break
            }
        }
    }
    puts "\[INFO\] Placement regions: [expr { [llength $lent] / 2 }] macro(s) lent to regions for global placement."
    return $lent
}

# repair_antennas legalizes its diodes inside OpenROAD (not through the Tcl
# detailed_placement above), and a diode next to a fenced gate is ungrouped, so
# dpl fails it (DPL-0036). All cells are legal by then, so the fences are taken
# down for the repair and rebuilt unchanged afterwards; the new diodes stay
# ungrouped (the next Regions.* legalization absorbs them like resizer buffers).
proc regions_save_and_drop {} {
    set block [ord::get_db_block]
    set saved [list]
    foreach region [$block getRegions] {
        set boxes [list]
        foreach box [$region getBoundaries] {
            lappend boxes [list [$box xMin] [$box yMin] [$box xMax] [$box yMax]]
        }
        set groups [list]
        foreach group [$region getGroups] {
            set insts [$group getInsts]
            lappend groups [list [$group getName] $insts]
            foreach inst $insts { $group removeInst $inst }
            odb::dbGroup_destroy $group
        }
        lappend saved [list [$region getName] [$region getRegionType] $boxes $groups]
        odb::dbRegion_destroy $region
    }
    puts "\[INFO\] Placement regions: [llength $saved] region(s) removed for antenna repair."
    return $saved
}

proc regions_restore { saved } {
    set block [ord::get_db_block]
    foreach entry $saved {
        lassign $entry name type boxes groups
        set region [odb::dbRegion_create $block $name]
        $region setRegionType $type
        foreach box $boxes {
            odb::dbBox_create $region {*}$box
        }
        foreach g $groups {
            lassign $g group_name insts
            set group [odb::dbGroup_create $region $group_name]
            foreach inst $insts { $group addInst $inst }
        }
    }
    puts "\[INFO\] Placement regions: [llength $saved] region(s) restored after antenna repair."
}

if { [info commands repair_antennas] ne "" && [info commands __regions_orig_repair_antennas] eq "" } {
    rename repair_antennas __regions_orig_repair_antennas
    proc repair_antennas { args } {
        set saved [regions_save_and_drop]
        catch {uplevel 1 [list __regions_orig_repair_antennas {*}$args]} result options
        regions_restore $saved
        return -options $options $result
    }
}

if { [info commands __regions_orig_global_placement] eq "" } {
    rename global_placement __regions_orig_global_placement
    proc global_placement { args } {
        set blockages [regions_create_gpl_blockages]
        set lent [regions_lend_macros]
        catch {uplevel 1 [list __regions_orig_global_placement {*}$args]} result options
        foreach {group inst} $lent {
            $group removeInst $inst
        }
        foreach blockage $blockages {
            odb::dbBlockage_destroy $blockage
        }
        return -options $options $result
    }
}
