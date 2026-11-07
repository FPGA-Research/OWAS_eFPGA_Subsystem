# librelane_plugin_owas

LibreLane plugin for the OWAS eFPGA subsystem backend. Its main feature is
placement regions: `Odb.AddPlacementRegions` creates OpenROAD placement fences
(OpenDB `dbRegion` + `dbGroup`, type EXCLUSIVE), and the `Regions.*` step
variants keep them intact through placement, resizing, CTS and antenna repair.
OpenROAD's global placer places each region as its own sub-problem, and the
detailed placer keeps grouped cells inside their region and everything else
outside.

It also adds extra global routing options, repeated hold repair, an
`improve_placement` seed, PDN stripe-to-macro-ring connections, macro LEF edits
(obstructions, PG pins, pin order) and name shortening; see the sections below.

## Install

Put the folder that contains `librelane_plugin_owas/` on `PYTHONPATH`
(LibreLane imports every `librelane_plugin_*` module). Plugins are not supported
in the LibreLane Docker image; use the Nix or pip install.

Importing the plugin also extends some of LibreLane's own steps (see
[Global routing options](#global-routing-options)); with the new variables
unset they behave as before.

## Layout

| Path | Content |
|---|---|
| `__init__.py` | imports the modules below |
| `_common.py` | script paths, `PluginOdbpyStep` base class |
| `grt.py` | global routing options; extends LibreLane's GRT steps |
| `regions.py` | `Odb.AddPlacementRegions`, the `Regions.*` variants and their variables |
| `macros.py` | `Odb.ConnectMacroRingStripes`, `Odb.RemoveMacroObstructions`, `Odb.RestoreMacroMasters`, `Odb.MacroClockPinFirst` |
| `names.py` | `Odb.ShortenNames` |
| `scripts/odbpy/` | scripts run by `openroad -python` (`lef_utils.py`: shared LEF/master helpers) |
| `scripts/openroad/` | Tcl run or sourced by `openroad`; `regions_wrap.tcl` is the entry script of the `Regions.*` variants |

## Configure

```yaml
meta:
  flow: Classic
  substituting_steps:
    # create the fences before the first global placement
    "-OpenROAD.GlobalPlacementSkipIO": "Odb.AddPlacementRegions"
    # steps that place, insert cells or legalize: new cells join their region first
    "OpenROAD.GlobalPlacement": "Regions.GlobalPlacement"
    "OpenROAD.RepairDesignPostGPL": "Regions.RepairDesignPostGPL"
    "OpenROAD.DetailedPlacement": "Regions.DetailedPlacement"
    "OpenROAD.CTS": "Regions.CTS"
    "OpenROAD.ResizerTimingPostCTS": "Regions.ResizerTimingPostCTS"
    # optional, post-GRT repair (always runs once substituted)
    "OpenROAD.RepairDesignPostGRT": "Regions.RepairDesignPostGRT"
    "OpenROAD.ResizerTimingPostGRT": "Regions.ResizerTimingPostGRT"
    # antenna diodes: fences taken down while repair_antennas legalizes them
    "OpenROAD.RepairAntennas": "Regions.RepairAntennas"
    "OpenROAD.DetailedRouting": "Regions.DetailedRouting"

PLACEMENT_REGIONS:
  alu_fence:                       # auto-sized: 55 % utilization, square
    instances: ["u_core.u_alu.*"]
    origin: [50, 50]
    utilization: 55
  fpu_fence:                       # explicit box, fail if > 70 % full
    instances: ["u_core.u_fpu.*"]
    area: [300, 50, 500, 250]
    utilization: 70

PL_TARGET_DENSITY_PCT: 60          # applies to the top level AND every region
```

Fields per region: `instances` (fnmatch patterns on flattened instance names),
`area` [llx lly urx ury] µm, or `origin` [x y] µm + `utilization` %,
`aspect_ratio` (height/width, default 1), `absorb` (default true),
`gpl_max_density` %, `dpl_padding` (sites), `late_instances` (patterns for cells
created after this step, e.g. the resizer's `input*`/`output*` IO buffers; matched
before each legalization in the `Regions.*` steps, never fail), `late_port_margin`
µm (a `late_instances` cell on a net to a top-level port more than this outside
the region stays ungrouped, e.g. the IO buffer of a pin on another die edge;
default off), `absorb_margin` µm (see below; default off).

`PLACEMENT_REGIONS_STRICT` (default true) fails the step when a pattern matches
nothing on first creation or a region is above its `utilization`.

## What it does

1. Matches movable core instances against each region's patterns.
2. Creates the region (snapped to the site/row grid, clipped to the core),
   or reuses it on re-runs.
3. Optionally absorbs un-grouped cells whose every signal connection lands in
   one region (e.g. buffers inserted by `repair_design` or CTS) — iterated so
   buffer chains are absorbed. Cells on nets that reach a top-level port are
   left alone.
4. Prints a per-region utilization table (fixed cells like tap cells are
   subtracted from the free area).

## New cells during repair / CTS

OpenROAD's resizer and CTS never add the cells they insert to a group, and
LibreLane's repair, CTS and timing-repair scripts call `detailed_placement`
in the same step. A buffer for fenced logic would therefore be legalized as an
outsider and pushed out of its region.

The `Regions.*` steps are the LibreLane steps of the same name, run through
`regions_wrap.tcl`: it wraps `detailed_placement` with `regions_absorb`
(`regions_dpl_hook.tcl`) and then sources the original script unchanged. Before
each legalization, every movable ungrouped cell located inside a region joins
that region's group if at least one neighbor is in the group and none is in a
different group. Ungrouped neighbors and port connections are allowed, so
buffer chains, port buffers and nets leaving the region are covered. Cells the
resizer/CTS created (flat names matching `::regions_new_cell_regexp`, a tunable
at the top of `regions_dpl_hook.tcl`; recheck it for another OpenROAD version)
join the region they sit in regardless of their neighbors. Other cells with no neighbor in the region
(e.g. logic gpl dropped there) stay outsiders and are moved out; see
`PL_MAX_DISPLACEMENT_*`.

Cells the resizer/CTS insert just *outside* a region are a second case. If the
region ends at a macro halo without rows, a buffer for a macro pin on that edge
(hold buffers between a fenced flop and the pin, the clock buffer driving the
macro's clock pin) has no legal site near the pin: the region is a fence, so dpl
can only move it along the macro edge, up to the macro's end. With
`absorb_margin` set on a region, resizer/CTS cells outside every region but
within that distance of this one join it if at least one neighbor is in it and
none is in another group (iterated, so chains are absorbed from the grouped
end); they are then moved just inside the region edge. The margin should cover
the halo plus the pin depth inside the macro.

Before legalization the hook also moves grouped cells that stick out of their
region back inside it, and grouped cells left on a macro or hard placement
blockage to the nearest free side of it inside their region (dpl fails such a
cell when the nearest edge is outside the region, and then re-places the whole
group from the region corners). Grouped cells still on an obstacle after that
are reported as warnings.

Variants exist for `GlobalPlacement`, `DetailedPlacement`,
`RepairDesignPostGPL`, `CTS`, `ResizerTimingPostCTS`, `RepairDesignPostGRT`,
`ResizerTimingPostGRT`, `RepairAntennas` and `DetailedRouting`.

`repair_antennas` legalizes its diodes inside OpenROAD, not through the Tcl
`detailed_placement`, so the absorb hook cannot reach them: a diode next to a
fenced gate is ungrouped and dpl fails it (DPL-0036). The hook therefore also
wraps `repair_antennas`: it saves every region (name, type, boxes, group
members), destroys them, runs the repair and rebuilds them unchanged. All cells
are legal by then, so the fences are not needed during the repair. The new
diodes stay ungrouped; the next `Regions.*` legalization absorbs them.
`Regions.RepairAntennas` covers the GRT-stage repair, `Regions.DetailedRouting`
the post-DRT antenna loop (`DRT_ANTENNA_REPAIR_ITERS`). `Odb.DiodesOnPorts`
legalizes with plain `DetailedPlacement` and has no variant.

Classic's `RUN_*` gating variables are keyed by the original step IDs and do
not apply to the variants: substituting `Regions.RepairDesignPostGRT` /
`Regions.ResizerTimingPostGRT` always runs them, even though
`RUN_POST_GRT_DESIGN_REPAIR` / `RUN_POST_GRT_RESIZER_TIMING` are off by default.

## Legalization guard

After every successful `detailed_placement` in a `Regions.*` step, the step
stops with `ORD-9310` if the average displacement dpl reports is above
`PLACEMENT_REGIONS_MAX_AVG_DISPLACEMENT` (µm, default 50). A whole-group
re-placement is reported by dpl as a success, and the run would otherwise spend
hours routing it. When dpl fails, the cells it could not place (`DPL-0035`) are
listed with their start position, region, nearest macro and nets.

For debugging, the process env `REGIONS_DIAG_TCL` names a Tcl file that
`regions_wrap.tcl` sources right after installing the hooks (e.g. to dump
state instead of legalizing). The hooks read their tunables (globals at the
top of `regions_dpl_hook.tcl` and `hold_repeat.tcl`) at call time, so a diag
file can also override them.

## Detailed placement optimization

`DPL_IMPROVE_PLACEMENT_SEED` (int, default unset, declared on
`Regions.DetailedPlacement` only) runs OpenROAD `improve_placement` with that
random seed once after the step's first legalization. It reduces wirelength,
and different seeds give different legal placements (gpl, dpl and grt have no
seed of their own). OpenROAD dcf3613 crashes on rotated fixed macros there, so
`improve_placement.tcl` hides them behind unrotated proxy masters of the same
footprint and pin positions during the run and restores them afterwards. The
step fails if the optimization moves cells out of their region.

## Repeated hold repair

`HOLD_REPAIR_REPEATS` (int, default unset) makes `regions_wrap.tcl` source
`hold_repeat.tcl`, which wraps `repair_timing`: a `-hold` call is repeated with
the same arguments, up to that many calls, while the hold WNS or TNS still
improves (`[INFO] hold_repeat:` lines in the step log). It works around OpenROAD
dcf3613, whose hold repair stops after about two passes when a buffer is backed
out for setup, leaving endpoints with many violating fan-in paths unrepaired.
Only the `Regions.*` variants of `ResizerTimingPostCTS` / `ResizerTimingPostGRT`
call the hold repair.

`GRT_HOLD_REPAIR_SETUP_MARGIN` (ns, default unset, declared on
`Regions.ResizerTimingPostGRT` only) replaces the `-setup_margin` of that step's
hold repair calls (`[INFO] hold_repeat: hold repair with -setup_margin` in the
log). LibreLane passes `GRT_RESIZER_SETUP_SLACK_MARGIN` to both the setup and
the hold repair; the setup repair keeps it. A hold buffer only goes where that
much setup slack remains, so logic shared by hold-critical and setup-critical
paths can stay unrepaired with a large margin.

## Global routing options

`GRT_RESISTANCE_AWARE` (bool) and `GRT_CRITICAL_NETS_PERCENTAGE` (%) add
`-resistance_aware` / `-critical_nets_percentage` to every `global_route` call
(`grt_extra.tcl`) in `OpenROAD.GlobalRouting`, `OpenROAD.RepairAntennas`
(its diode insertion), `Odb.DiodesOnPorts`, `Regions.RepairAntennas`,
`Regions.RepairDesignPostGRT` and `Regions.ResizerTimingPostGRT`. The
plugin also declares them on the plain `OpenROAD.RepairDesignPostGRT` /
`OpenROAD.ResizerTimingPostGRT`, but there they currently have no effect (their
scripts are not wrapped); use the `Regions.*` variants. Both unset: the steps
run as in LibreLane.

## Clock pin first (CTS latency balancing)

`Odb.MacroClockPinFirst` (`MACRO_CLOCK_PIN_FIRST`: macro master -> output pin)
makes that pin the master's first output pin. OpenROAD dcf3613's post-CTS
LatencyBalancer starts a clock's tree at the root driver's first output pin
(`dbInst::getFirstOutput`), not at the driving pin. A clock generated on a pin
of a multi-output macro (macro LEF pins are often alphabetical) therefore gets
no delay buffers ("inserted 0 delay buffers"), and its sub-trees (register
tree, clock-gated tree, macro sinks) stay unbalanced. The step copies the macro
LEF from `MACROS` with that PIN block first (into the step dir), reads it into
its own library and recreates every instance of the master with the copy (same
name, placement, connections, group); geometry is unchanged, netgen LVS matches
macro pins by name. Insert it before CTS: `"-OpenROAD.CTS": Odb.MacroClockPinFirst`.

## Top-level PDN over and up to macros

`Odb.RemoveMacroObstructions` removes, from a macro's master, the obstructions
on the layers in `REMOVE_MACRO_OBSTRUCTIONS` and the power/ground pin shapes on
the layers in `REMOVE_MACRO_PG_PINS` (both: instance or master name -> layers; a
master name covers all its instances). Like `Odb.MacroClockPinFirst` it copies
the LEF from `MACROS` without those shapes into the step dir and recreates the
instances with that master; the GDS is unchanged. pdngen keeps core stripes
away from a macro's obstructions and never draws over a macro's pins (it stops
short of a same-net pin), so this lets the top grid run over a macro whose
abstract LEF blocks a whole layer although the macro keeps bands of it free, or
whose own PG stripes lie exactly on the top grid rows. Insert it before the
PDN, e.g. `"-Odb.AddPDNObstructions": Odb.RemoveMacroObstructions`, and keep
signal routing off the macro on those layers with `ROUTING_OBSTRUCTIONS`.

`Odb.RestoreMacroMasters` swaps the instances of `REMOVE_MACRO_PG_PINS` back to
their original master after the PDN and drops the stripped libraries:
TritonRoute looks masters up by name and fails on a copy with fewer PG pin
shapes (DRT-0405). The PDN wires stay. Insert it right after the PDN, e.g.
`"+Odb.ConnectMacroRingStripes": Odb.RestoreMacroMasters`.

`Odb.ConnectMacroRingStripes` (`MACRO_RING_STRIPE_CONNECT`: macro master ->
options) connects top-level PDN stripes that end at a macro edge to the macro's
power ring pins just inside that edge: pdngen trims core-grid stripes at
instance boundaries and cannot extend them up to a pin. The stripe is extended
(same layer and width) over the same-net ring pin, with landing pads and one
via per layer pair in between. A connection is skipped if a new shape would
overlap another net's special wire, another instance's pin/OBS, or the macro's
own pin of the other net. The macro's own OBS are not checked, so the macro
must keep those layers free over its ring edges. Options per master, all as
strings: `stripe_layer` (default `Metal4`), `pin_layer` (`Metal2`), `max_gap`
(µm between stripe end and macro edge, `1.0`), `max_depth` (µm of the pin's far
side inside the macro, `6.0`), `nets` (`"VDD VSS"`). Insert it after the PDN,
e.g. `"+OpenROAD.GeneratePDN": Odb.ConnectMacroRingStripes`.

## Name shortening

`Odb.ShortenNames` renames instances and nets whose names are longer than
`SHORTEN_NAMES_MAX_LENGTH` (default 255) to their first characters plus a hash
of the full name, writes the map to `renamed.csv` in the step dir and rewrites
all views so they agree. `SYNTH_AUTONAME` can produce names of over 1000
characters, and Magic's `save` aborts on them, so `Magic.StreamOut` writes no
GDS. Port nets are never renamed. Insert it before stream-out, e.g.
`"-OpenROAD.RCX": Odb.ShortenNames`.

## Error codes

The Tcl hooks report their own errors under OpenROAD's `ORD` tool ID, in the
range 9300-9319:

| Code | Meaning |
|---|---|
| ORD-9301 | `improve_placement` workaround could not restore a rotated macro |
| ORD-9302 | `improve_placement` moved cells out of their placement region |
| ORD-9303 | `improve_placement` workaround: proxy master not found after `read_lef` |
| ORD-9304 | `improve_placement` workaround: macro pin not reconnected |
| ORD-9310 | legalization moved cells too far on average (see Legalization guard) |

## Limitations

- OpenROAD treats every region as a hard fence; INCLUSIVE/guide semantics are
  not modelled by gpl or dpl.
- `global_placement -density` is a single value. Per-region utilization comes
  from the region size. gpl raises a region's density automatically if the
  global value is too low for it (GPL-0302).
- gpl is not strict about keeping other cells out of a region. Outsiders that
  end up inside can only be legalized within `PL_MAX_DISPLACEMENT_X/Y`; if the
  region borders macros, the nearest legal rows can be millimetres away.
- Several workarounds target OpenROAD dcf3613 (the version LibreLane
  3.1.0.dev4 ships); recheck them when OpenROAD is updated.
