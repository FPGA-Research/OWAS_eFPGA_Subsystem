# SPDX-License-Identifier: Apache-2.0
"""
LibreLane plugin for the OWAS eFPGA subsystem backend.

Main feature: placement regions (fences) for OpenROAD. ``Odb.AddPlacementRegions``
creates OpenDB regions + groups (the same objects DEF REGIONS/GROUPS or UPF
``set_domain_area`` create), and the ``Regions.*`` step variants keep the selected
cells inside their region and all other cells outside it through placement,
resizing, CTS and antenna repair.

Also: extra global_route options, repeated hold repair, an improve_placement
seed, PDN stripe-to-macro-ring connections, macro LEF edits (obstructions, PG
pins, pin order) and name shortening. See README.md.

Install: put the folder containing this package on PYTHONPATH (or pip install
it). LibreLane auto-imports any module named ``librelane_plugin_*``.
"""
import os
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Dict, List, Optional, Tuple

from librelane.config import Variable
from librelane.steps import Step
from librelane.steps.odb import OdbpyStep

__dir__ = os.path.dirname(os.path.abspath(__file__))


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
_regions_variable = Variable(
    "PLACEMENT_REGIONS",
    Optional[Dict[str, PlacementRegion]],
    "Placement fences keyed by region name. If unset, the step is skipped.",
    default=None,
)


@Step.factory.register()
class AddPlacementRegions(OdbpyStep):
    """
    Creates (or updates) exclusive placement regions in the OpenDB database
    from ``PLACEMENT_REGIONS``. Safe to run more than once: existing regions
    are reused, and only instances not yet assigned to a group are added, so
    it can be re-run after resizer/CTS steps to absorb newly inserted cells.
    """

    id = "Odb.AddPlacementRegions"
    name = "Add Placement Regions"

    config_vars = [
        _regions_variable,
        Variable(
            "PLACEMENT_REGIONS_STRICT",
            bool,
            "Fail if a pattern matches nothing or a region exceeds its utilization.",
            default=True,
        ),
    ]

    def get_script_path(self) -> str:
        return os.path.join(__dir__, "regions_odb.py")

    def get_command(self) -> List[str]:
        return super().get_command() + ["--step-config", self.config_path]

    def run(self, state_in, **kwargs):
        if not self.config["PLACEMENT_REGIONS"]:
            self.warn("PLACEMENT_REGIONS is not set; skipping.")
            return {}, {}
        return super().run(state_in, **kwargs)


class _AbsorbBeforeDetailedPlacement:
    """
    Runs the step's original script through ``regions_wrap.tcl``, which wraps
    ``detailed_placement`` so cells inserted by the resizer/CTS inside a region
    join that region's group before legalization and get the region's padding,
    and ``global_placement`` so it sees the regions' density blockages (see
    regions_dpl_hook.tcl).
    """

    def prepare_env(self, env, state):
        env = super().prepare_env(env, state)
        env["_REGIONS_HOOK_TCL"] = os.path.join(__dir__, "regions_dpl_hook.tcl")
        env["_REGIONS_HOLD_REPEAT_TCL"] = os.path.join(__dir__, "hold_repeat.tcl")
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
            env["_REGIONS_DPO_TCL"] = os.path.join(__dir__, "improve_placement.tcl")
        return env

    def get_command(self) -> List[str]:
        command = super().get_command()
        command[-1] = os.path.join(__dir__, "regions_wrap.tcl")
        return command


# Read by regions_wrap.tcl (hold_repeat.tcl); exported to the step's env by TclStep.
_hold_repeat_variable = Variable(
    "HOLD_REPAIR_REPEATS",
    Optional[int],
    "Call repair_timing -hold up to this many times per hold repair in the Regions.* "
    "steps, while the hold WNS/TNS still improves (works around OpenROAD dcf3613 "
    "RepairHold stopping after ~2 passes). Unset or <= 1: one call, as in LibreLane.",
    default=None,
)

# Read by hold_repeat.tcl; only the Regions.ResizerTimingPostGRT variant declares it.
_grt_hold_setup_variable = Variable(
    "GRT_HOLD_REPAIR_SETUP_MARGIN",
    Optional[Decimal],
    "Setup margin (ns) for the hold repair in Regions.ResizerTimingPostGRT only. "
    "LibreLane passes GRT_RESIZER_SETUP_SLACK_MARGIN to both the setup and the hold "
    "repair; a lower value here lets hold buffers go on gates with less setup slack "
    "(e.g. logic shared by setup-critical and hold-critical paths). Unset: as LibreLane.",
    default=None,
    units="ns",
)


# Optional extra global_route options (grt_extra.tcl), for every step that runs global routing:
# OpenROAD.GlobalRouting (also inside Odb.DiodesOnPorts), the diode insertion of
# (Regions.)RepairAntennas and the Regions.* post-GRT repair steps. Both unset: nothing changes.
_grt_resistance_aware_variable = Variable(
    "GRT_RESISTANCE_AWARE",
    Optional[bool],
    "Pass -resistance_aware to every global_route call (resistance-aware layer assignment: "
    "long/critical nets on low-R upper layers). Unset/False: as LibreLane.",
    default=None,
)
_grt_critical_nets_variable = Variable(
    "GRT_CRITICAL_NETS_PERCENTAGE",
    Optional[Decimal],
    "Pass -critical_nets_percentage <value> to every global_route call (routing priority for "
    "this percentage of nets with the worst slack). Unset: as LibreLane.",
    default=None,
    units="%",
)
_grt_extra_variables = [_grt_resistance_aware_variable, _grt_critical_nets_variable]


def _grt_extra_env(config, env) -> bool:
    active = False
    if config.get("GRT_RESISTANCE_AWARE"):
        env["_GRT_RESISTANCE_AWARE"] = "1"
        active = True
    pct = config.get("GRT_CRITICAL_NETS_PERCENTAGE")
    if pct is not None:
        env["_GRT_CRITICAL_NETS_PCT"] = str(pct)
        active = True
    if active:
        env["_GRT_EXTRA_TCL"] = os.path.join(__dir__, "grt_extra.tcl")
    return active


def _install_grt_extra():
    from librelane.steps.openroad import (
        GlobalRouting,
        RepairAntennas,
        RepairDesignPostGRT,
        ResizerTimingPostGRT,
        _DiodeInsertion,
    )
    from librelane.steps.odb import DiodesOnPorts

    def add_vars(cls):
        names = {v.name for v in cls.config_vars}
        cls.config_vars = cls.config_vars + [
            v for v in _grt_extra_variables if v.name not in names
        ]

    # Composite steps filter their substeps' config through their own (import-time) list.
    for cls in (GlobalRouting, _DiodeInsertion, RepairDesignPostGRT, ResizerTimingPostGRT,
                DiodesOnPorts, RepairAntennas):
        add_vars(cls)

    # Regions.* variants run their script through regions_wrap.tcl, which sources
    # grt_extra.tcl; plain steps get the env here.
    for cls in (GlobalRouting, RepairDesignPostGRT, ResizerTimingPostGRT):
        orig_prepare_env = cls.prepare_env

        def prepare_env(self, env, state, _orig=orig_prepare_env):
            env = _orig(self, env, state)
            if _grt_extra_env(self.config, env):
                env["_GRT_EXTRA_ORIG_SCRIPT"] = self.get_script_path()
            return env

        cls.prepare_env = prepare_env

    # Plain OpenROAD.GlobalRouting (step and inside Odb.DiodesOnPorts): wrap its script.
    orig_get_command = GlobalRouting.get_command

    def get_command(self, _orig=orig_get_command):
        command = _orig(self)
        if self.config.get("GRT_RESISTANCE_AWARE") or (
            self.config.get("GRT_CRITICAL_NETS_PERCENTAGE") is not None
        ):
            command[-1] = os.path.join(__dir__, "grt_extra_wrap.tcl")
        return command

    GlobalRouting.get_command = get_command


_install_grt_extra()


# Read by improve_placement.tcl; only the Regions.DetailedPlacement variant declares it.
_dpo_seed_variable = Variable(
    "DPL_IMPROVE_PLACEMENT_SEED",
    Optional[int],
    "Run OpenROAD improve_placement (detailed placement optimization: cell swaps/reordering "
    "for lower HPWL) with this random seed once after legalization in "
    "Regions.DetailedPlacement. Rotated fixed macros are hidden behind unrotated proxies "
    "during it (OpenROAD dcf3613 crashes on them), see improve_placement.tcl. Different "
    "seeds give different legal placements. Unset: not run, as in LibreLane.",
    default=None,
)


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
            (_AbsorbBeforeDetailedPlacement, _Base),
            {
                "id": f"Regions.{_name}",
                "name": f"{_Base.name} (Placement Regions)",
                "config_vars": _Base.config_vars
                + [_regions_variable, _hold_repeat_variable]
                + ([_grt_hold_setup_variable] if _name == "ResizerTimingPostGRT" else [])
                + ([_dpo_seed_variable] if _name == "DetailedPlacement" else []),
                "__module__": __name__,
            },
        )
    )


# GRT-stage antenna repair: OpenROAD.RepairAntennas is a CompositeStep around the
# unregistered _DiodeInsertion, so the variant swaps in a wrapped copy of it.
from librelane.steps.openroad import CheckAntennas, RepairAntennas, _DiodeInsertion

_DiodeInsertionWithRegions = Step.factory.register()(
    type(
        "DiodeInsertionWithRegions",
        (_AbsorbBeforeDetailedPlacement, _DiodeInsertion),
        {
            "id": "Regions.DiodeInsertion",
            "name": f"{_DiodeInsertion.name} (Placement Regions)",
            "config_vars": _DiodeInsertion.config_vars + [_regions_variable],
            "__module__": __name__,
        },
    )
)


@Step.factory.register()
class RepairAntennasWithRegions(RepairAntennas):
    id = "Regions.RepairAntennas"
    name = f"{RepairAntennas.name} (Placement Regions)"

    Steps = [_DiodeInsertionWithRegions, CheckAntennas]


@Step.factory.register()
class ConnectMacroRingStripes(OdbpyStep):
    """
    Connects top-level PDN stripes that end at a macro edge to the macro's power
    ring pins just inside that edge (``MACRO_RING_STRIPE_CONNECT``: macro master ->
    options). pdngen trims core-grid stripes at instance boundaries and cannot
    extend them only up to a pin, so the stripe is extended (same layer/width)
    over the same-net ring pin on ``pin_layer``, with landing pads and one via
    per layer pair in between. A connection is skipped if a new shape would
    overlap another net's special wire, another instance's pin/OBS, or the
    macro's own pin of the other net. The macro's own OBS are not checked (its
    abstract LEF may hide free area): the macro must keep those layers free over
    the ring edges. Insert after the PDN, e.g.
    ``"+OpenROAD.GeneratePDN": Odb.ConnectMacroRingStripes``.

    Options per master: ``stripe_layer`` (default Metal4), ``pin_layer``
    (Metal2), ``max_gap`` (µm between stripe end and macro edge, 1.0),
    ``max_depth`` (µm of the pin's far side inside the macro, 6.0), ``nets``
    ("VDD VSS"); all values given as strings.
    """

    id = "Odb.ConnectMacroRingStripes"
    name = "Connect PDN Stripes to Macro Rings"

    config_vars = [
        Variable(
            "MACRO_RING_STRIPE_CONNECT",
            Optional[Dict[str, Dict[str, str]]],
            "Macro master name -> options as strings: stripe_layer, pin_layer, max_gap (µm),"
            + " max_depth (µm), nets (space-separated).",
            default=None,
        ),
    ]

    def get_script_path(self) -> str:
        return os.path.join(__dir__, "connect_ring_stripes.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--step-config",
            self.config_path,
        ]

    def run(self, state_in, **kwargs):
        if not self.config["MACRO_RING_STRIPE_CONNECT"]:
            self.warn("MACRO_RING_STRIPE_CONNECT is not set; skipping.")
            return {}, {}
        return super().run(state_in, **kwargs)


@Step.factory.register()
class RemoveMacroObstructions(OdbpyStep):
    """
    Removes the obstructions (``REMOVE_MACRO_OBSTRUCTIONS``) and the power/ground
    pin shapes (``REMOVE_MACRO_PG_PINS``) on the given layers from macros; keys
    are instance names or master names (all instances of that master). The
    macro LEF from ``MACROS`` is copied without those shapes (written to the
    step dir), read into its own library, and the instances are swapped to that
    master (LEF masters are frozen in OpenDB). Lets the top-level PDN put
    stripes over a macro whose abstract LEF has a full-layer OBS although the
    macro keeps bands of that layer free, or whose own PG stripes lie exactly on
    the top grid rows (pdngen never draws over a macro's pins, so those rows
    would stop short of them). Insert it
    before the PDN, e.g. ``"-Odb.AddPDNObstructions": Odb.RemoveMacroObstructions``;
    keep signal routing off the macro with ``ROUTING_OBSTRUCTIONS``.
    """

    id = "Odb.RemoveMacroObstructions"
    name = "Remove Macro Obstructions"

    config_vars = [
        Variable(
            "REMOVE_MACRO_OBSTRUCTIONS",
            Optional[Dict[str, List[str]]],
            "Macro instance or master name -> layers whose OBS are removed from its master.",
            default=None,
        ),
        Variable(
            "REMOVE_MACRO_PG_PINS",
            Optional[Dict[str, List[str]]],
            "Macro instance or master name -> layers whose power/ground pin shapes are "
            "removed from its master (the shapes stay in the macro's GDS).",
            default=None,
        ),
    ]

    def get_script_path(self) -> str:
        return os.path.join(__dir__, "remove_macro_obs.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--step-config",
            self.config_path,
            "--out-dir",
            self.step_dir,
        ]

    def run(self, state_in, **kwargs):
        if not self.config["REMOVE_MACRO_OBSTRUCTIONS"] and not self.config["REMOVE_MACRO_PG_PINS"]:
            self.warn("REMOVE_MACRO_OBSTRUCTIONS / REMOVE_MACRO_PG_PINS are not set; skipping.")
            return {}, {}
        return super().run(state_in, **kwargs)


@Step.factory.register()
class RestoreMacroMasters(OdbpyStep):
    """
    Swaps the instances of ``REMOVE_MACRO_PG_PINS`` back to their original
    master after the PDN. The stripped copy from Odb.RemoveMacroObstructions has
    the same name as the original; TritonRoute looks masters up by name and
    fails on a copy with fewer PG pin shapes (DRT-0405 "Mismatch in number of
    pins for term <master>/VDD"). The PDN wires stay. Insert it right after the
    PDN, e.g. ``"+Odb.ConnectMacroRingStripes": Odb.RestoreMacroMasters``.
    """

    id = "Odb.RestoreMacroMasters"
    name = "Restore Macro Masters"

    config_vars = [
        Variable(
            "REMOVE_MACRO_PG_PINS",
            Optional[Dict[str, List[str]]],
            "Macro instance or master name -> layers whose power/ground pin shapes are "
            "removed from its master (the shapes stay in the macro's GDS).",
            default=None,
        ),
    ]

    def get_script_path(self) -> str:
        return os.path.join(__dir__, "restore_macro_masters.py")

    def get_command(self) -> List[str]:
        return super().get_command() + ["--step-config", self.config_path]

    def run(self, state_in, **kwargs):
        if not self.config["REMOVE_MACRO_PG_PINS"]:
            self.warn("REMOVE_MACRO_PG_PINS is not set; skipping.")
            return {}, {}
        return super().run(state_in, **kwargs)


@Step.factory.register()
class MacroClockPinFirst(OdbpyStep):
    """
    Makes the given clock output pin the first output pin of a macro master
    (``MACRO_CLOCK_PIN_FIRST``: master -> pin). OpenROAD dcf3613's post-CTS
    LatencyBalancer starts a clock's tree at the root driver's first output pin
    (dbInst::getFirstOutput), not at the driving pin, so a clock generated on a
    multi-output macro pin (LEF pins are often alphabetical) gets no delay
    buffers and its sub-trees stay unbalanced. The
    macro LEF from ``MACROS`` is copied with that PIN block first (written to
    the step dir), read into its own library, and every instance of the master
    is swapped to it (LEF masters are frozen in OpenDB). Geometry is unchanged;
    netgen LVS matches macro pins by name. Insert it before CTS, e.g.
    ``"-OpenROAD.CTS": Odb.MacroClockPinFirst``.
    """

    id = "Odb.MacroClockPinFirst"
    name = "Macro Clock Pin First"

    config_vars = [
        Variable(
            "MACRO_CLOCK_PIN_FIRST",
            Optional[Dict[str, str]],
            "Macro master name -> output pin made its first output pin (a clock root"
            + " for CTS latency balancing).",
            default=None,
        ),
    ]

    def get_script_path(self) -> str:
        return os.path.join(__dir__, "macro_pin_first.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--step-config",
            self.config_path,
            "--out-dir",
            self.step_dir,
        ]

    def run(self, state_in, **kwargs):
        if not self.config["MACRO_CLOCK_PIN_FIRST"]:
            self.warn("MACRO_CLOCK_PIN_FIRST is not set; skipping.")
            return {}, {}
        return super().run(state_in, **kwargs)


# Name shortening: Magic's `save` aborts on instance names longer than ~1000
# characters (SYNTH_AUTONAME driver chains), see shorten_names.py.
from librelane.steps.step import CompositeStep
from librelane.steps.openroad import WriteViews

_max_length_variable = Variable(
    "SHORTEN_NAMES_MAX_LENGTH",
    int,
    "Instance and net names longer than this are cut to their first characters"
    " plus a hash of the full name.",
    default=255,
)


class _ShortenNamesOdb(OdbpyStep):
    id = "Odb.ShortenNamesOdb"
    name = "Shorten Long Names (ODB)"

    config_vars = [_max_length_variable]

    def get_script_path(self) -> str:
        return os.path.join(__dir__, "shorten_names.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--step-config",
            self.config_path,
            "--map-file",
            os.path.join(self.step_dir, "renamed.csv"),
        ]


@Step.factory.register()
class ShortenNames(CompositeStep):
    """
    Renames instances and nets with names longer than
    ``SHORTEN_NAMES_MAX_LENGTH`` (prefix + hash, map in renamed.csv), then
    rewrites all views (netlists, DEF, ODB) so they agree. Insert it before
    Magic.StreamOut, e.g. ``"-OpenROAD.RCX": Odb.ShortenNames``.
    """

    id = "Odb.ShortenNames"
    name = "Shorten Long Names"

    Steps = [_ShortenNamesOdb, WriteViews]
