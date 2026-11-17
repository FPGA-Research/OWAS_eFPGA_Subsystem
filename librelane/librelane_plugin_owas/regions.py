# SPDX-License-Identifier: Apache-2.0
"""
Placement regions: ``Odb.AddPlacementRegions`` creates OpenDB regions + groups
(the same objects DEF REGIONS/GROUPS or UPF ``set_domain_area`` create), and the
``Regions.*`` variants of LibreLane's placing/legalizing steps keep the selected
cells inside their region and all other cells outside it.
"""
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Dict, List, Optional, Tuple

from librelane.config import Variable
from librelane.steps import Step
from librelane.steps.openroad import CheckAntennas, RepairAntennas, _DiodeInsertion

# Must extend LibreLane's GRT steps before the variants below copy their variables.
from . import grt  # noqa: F401
from ._common import PluginOdbpyStep, openroad_script


@dataclass
class PlacementRegion:
    """
    One placement fence.

    :param instances: fnmatch-style patterns matched against the (flattened)
        instance names, e.g. ``"u_core.u_alu.*"``.
    :param area: Explicit rectangle ``[llx, lly, urx, ury]`` in µm.
    :param origin: Lower-left corner in µm; used with ``utilization`` to size
        the region automatically when ``area`` is not given.
    :param utilization: Target utilization (%) of the region. With ``origin``
        it sizes the region; with ``area`` it is checked as an upper bound.
    :param aspect_ratio: Height / width for auto-sized regions.
    :param absorb: Also pull in un-grouped cells (e.g. buffers added by the
        resizer or CTS) whose every connection lands inside this region.
    :param gpl_max_density: Max. density (%) global placement may use inside
        the region, applied as a partial placement blockage during
        ``Regions.GlobalPlacement`` only. Lower values spread the region's
        cells like extra GPL padding would.
    :param dpl_padding: Detailed placement padding (sites, split evenly per
        side like ``DPL_CELL_PADDING``) for the region's cells, applied in the
        ``Regions.*`` legalizing steps. Keep it >= ``DPL_CELL_PADDING``: later
        steps check placement with the global padding only.
    :param late_instances: Patterns like ``instances``, but for cells that do
        not exist yet when ``Odb.AddPlacementRegions`` runs (e.g. the resizer's
        ``input*``/``output*`` IO buffers). Matched before each legalization in
        the ``Regions.*`` steps, regardless of the cell's location; never fail.
    :param late_port_margin: Distance (µm). A ``late_instances`` cell on a
        signal net to a top-level port lying more than this outside the region
        stays ungrouped, e.g. the IO buffer of a pin on another die edge, so it
        is legalized next to its pin instead of being pulled into the region.
        Default: off (every match joins).
    :param absorb_margin: Distance (µm). Before each legalization in the
        ``Regions.*`` steps, cells the resizer/CTS inserted (flat names like
        ``hold12``, ``clkbuf_1_0__f_clk``) that sit outside every region but
        within this distance of this one join it if at least one neighbor is in
        it and none is in another group; they are then moved just inside the
        region edge. For regions that end at a macro halo without rows (no
        legal site between the region and the macro's pins), where such cells
        could otherwise only be moved along the macro edge. Default: off.
    """

    instances: List[str] = field(default_factory=list)
    area: Optional[Tuple[Decimal, Decimal, Decimal, Decimal]] = None
    origin: Optional[Tuple[Decimal, Decimal]] = None
    utilization: Optional[Decimal] = None
    aspect_ratio: Decimal = Decimal(1)
    absorb: bool = True
    gpl_max_density: Optional[Decimal] = None
    dpl_padding: Optional[int] = None
    late_instances: List[str] = field(default_factory=list)
    late_port_margin: Optional[Decimal] = None
    absorb_margin: Optional[Decimal] = None


# Shared by every step that reads the regions, so the flow sees one variable.
regions_variable = Variable(
    "PLACEMENT_REGIONS",
    Optional[Dict[str, PlacementRegion]],
    "Placement fences keyed by region name. If unset, the step is skipped.",
    default=None,
)


@Step.factory.register()
class AddPlacementRegions(PluginOdbpyStep):
    """
    Creates (or updates) exclusive placement regions in the OpenDB database
    from ``PLACEMENT_REGIONS``. Safe to run more than once: existing regions
    are reused, and only instances not yet assigned to a group are added, so
    it can be re-run after resizer/CTS steps to absorb newly inserted cells.
    """

    id = "Odb.AddPlacementRegions"
    name = "Add Placement Regions"
    script = "regions_odb.py"
    required_vars = ("PLACEMENT_REGIONS",)

    config_vars = [
        regions_variable,
        Variable(
            "PLACEMENT_REGIONS_STRICT",
            bool,
            "Fail if a pattern matches nothing or a region exceeds its utilization.",
            default=True,
        ),
    ]


# Read by regions_dpl_hook.tcl (via _env.tcl, before the first detailed_placement).
max_displacement_variable = Variable(
    "PLACEMENT_REGIONS_MAX_AVG_DISPLACEMENT",
    Decimal,
    "Stop a Regions.* step with ORD-9310 when a detailed_placement reports a larger "
    "average displacement: dpl reports a legalization that re-placed a whole region "
    "group as success.",
    default=Decimal(50),
    units="µm",
)

# Read by hold_repeat.tcl; passed as _REGIONS_HOLD_REPEATS (see prepare_env).
hold_repeat_variable = Variable(
    "HOLD_REPAIR_REPEATS",
    Optional[int],
    "Call repair_timing -hold up to this many times per hold repair in the Regions.* "
    "steps, while the hold WNS/TNS still improves (works around OpenROAD dcf3613 "
    "RepairHold stopping after ~2 passes). Unset or <= 1: one call, as in LibreLane.",
    default=None,
)

# Read by hold_repeat.tcl; only the Regions.ResizerTimingPostGRT variant declares it.
grt_hold_setup_variable = Variable(
    "GRT_HOLD_REPAIR_SETUP_MARGIN",
    Optional[Decimal],
    "Setup margin (ns) for the hold repair in Regions.ResizerTimingPostGRT only. "
    "LibreLane passes GRT_RESIZER_SETUP_SLACK_MARGIN to both the setup and the hold "
    "repair; a lower value here lets hold buffers go on gates with less setup slack "
    "(e.g. logic shared by setup-critical and hold-critical paths). Unset: as LibreLane.",
    default=None,
    units="ns",
)

# Read by improve_placement.tcl; only the Regions.DetailedPlacement variant declares it.
dpo_seed_variable = Variable(
    "DPL_IMPROVE_PLACEMENT_SEED",
    Optional[int],
    "Run OpenROAD improve_placement (detailed placement optimization: cell swaps/reordering "
    "for lower HPWL) with this random seed once after legalization in "
    "Regions.DetailedPlacement. Rotated fixed macros are hidden behind unrotated proxies "
    "during it (OpenROAD dcf3613 crashes on them), see improve_placement.tcl. Different "
    "seeds give different legal placements. Unset: not run, as in LibreLane.",
    default=None,
)


class _WithRegions:
    """
    Runs the step's original script through ``regions_wrap.tcl``, which wraps
    ``detailed_placement`` so cells inserted by the resizer/CTS inside a region
    join that region's group before legalization and get the region's padding,
    and ``global_placement`` so it sees the regions' density blockages (see
    regions_dpl_hook.tcl).
    """

    def prepare_env(self, env, state):
        env = super().prepare_env(env, state)
        env["_REGIONS_HOOK_TCL"] = openroad_script("regions_dpl_hook.tcl")
        env["_REGIONS_HOLD_REPEAT_TCL"] = openroad_script("hold_repeat.tcl")
        env["_REGIONS_ORIG_SCRIPT"] = self.get_script_path()
        # Config variables reach Tcl only through _env.tcl, which the original script
        # sources (io.tcl) after regions_wrap.tcl has run; "_"-prefixed keys stay in
        # the process env, so pass the value the wrapper needs under such a key.
        repeats = self.config.get("HOLD_REPAIR_REPEATS")
        if repeats is not None and repeats > 1:
            env["_REGIONS_HOLD_REPEATS"] = str(repeats)
        hold_setup = self.config.get("GRT_HOLD_REPAIR_SETUP_MARGIN")
        if hold_setup is not None and self.id == "Regions.ResizerTimingPostGRT":
            env["_REGIONS_HOLD_SETUP_MARGIN"] = str(hold_setup)
        dpo_seed = self.config.get("DPL_IMPROVE_PLACEMENT_SEED")
        if dpo_seed is not None and self.id == "Regions.DetailedPlacement":
            env["_REGIONS_DPO_SEED"] = str(dpo_seed)
            env["_REGIONS_DPO_TCL"] = openroad_script("improve_placement.tcl")
        return env

    def get_command(self) -> List[str]:
        command = super().get_command()
        command[-1] = openroad_script("regions_wrap.tcl")
        return command


# Steps whose scripts place or legalize. Each gets a ``Regions.<Name>`` variant
# to substitute in. Their Classic gating variables (RUN_CTS, ...) are keyed by
# the original IDs and do not apply to the variants.
for _base_id in (
    "OpenROAD.GlobalPlacement",
    "OpenROAD.DetailedPlacement",
    "OpenROAD.RepairDesignPostGPL",
    "OpenROAD.CTS",
    "OpenROAD.ResizerTimingPostCTS",
    "OpenROAD.RepairDesignPostGRT",
    "OpenROAD.ResizerTimingPostGRT",
    # repair_antennas (in drt.tcl's post-DRT antenna loop) is wrapped to take the
    # fences down while it legalizes its diodes; see regions_dpl_hook.tcl
    "OpenROAD.DetailedRouting",
):
    _Base = Step.factory.get(_base_id)
    _name = _base_id.split(".", 1)[1]
    Step.factory.register()(
        type(
            f"{_Base.__name__}WithRegions",
            (_WithRegions, _Base),
            {
                "id": f"Regions.{_name}",
                "name": f"{_Base.name} (Placement Regions)",
                "config_vars": _Base.config_vars
                + [regions_variable, hold_repeat_variable, max_displacement_variable]
                + ([grt_hold_setup_variable] if _name == "ResizerTimingPostGRT" else [])
                + ([dpo_seed_variable] if _name == "DetailedPlacement" else []),
                "__module__": __name__,
            },
        )
    )


# GRT-stage antenna repair: OpenROAD.RepairAntennas is a CompositeStep around the
# unregistered _DiodeInsertion, so the variant swaps in a wrapped copy of it.
_DiodeInsertionWithRegions = Step.factory.register()(
    type(
        "DiodeInsertionWithRegions",
        (_WithRegions, _DiodeInsertion),
        {
            "id": "Regions.DiodeInsertion",
            "name": f"{_DiodeInsertion.name} (Placement Regions)",
            "config_vars": _DiodeInsertion.config_vars + [regions_variable],
            "__module__": __name__,
        },
    )
)


@Step.factory.register()
class RepairAntennasWithRegions(RepairAntennas):
    id = "Regions.RepairAntennas"
    name = f"{RepairAntennas.name} (Placement Regions)"

    Steps = [_DiodeInsertionWithRegions, CheckAntennas]
