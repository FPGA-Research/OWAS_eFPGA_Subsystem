# SPDX-License-Identifier: Apache-2.0
"""
Optional extra global_route options (scripts/openroad/grt_extra.tcl) for every
step that runs global routing: OpenROAD.GlobalRouting (also inside
Odb.DiodesOnPorts), the diode insertion of (Regions.)RepairAntennas and the
Regions.* post-GRT repair steps. Both variables unset: nothing changes.

Importing this module extends LibreLane's own step classes; regions.py imports
it first, so the Regions.* variants inherit the extended variable lists.
"""
from decimal import Decimal
from typing import Optional

from librelane.config import Variable

from ._common import openroad_script

grt_resistance_aware_variable = Variable(
    "GRT_RESISTANCE_AWARE",
    Optional[bool],
    "Pass -resistance_aware to every global_route call (resistance-aware layer assignment: "
    "long/critical nets on low-R upper layers). Unset/False: as LibreLane.",
    default=None,
)
grt_critical_nets_variable = Variable(
    "GRT_CRITICAL_NETS_PERCENTAGE",
    Optional[Decimal],
    "Pass -critical_nets_percentage <value> to every global_route call (routing priority for "
    "this percentage of nets with the worst slack). Unset: as LibreLane.",
    default=None,
    units="%",
)
grt_extra_variables = [grt_resistance_aware_variable, grt_critical_nets_variable]


def grt_extra_env(config, env) -> bool:
    """Puts the options into the step's process env; True if one is set."""
    active = False
    if config.get("GRT_RESISTANCE_AWARE"):
        env["_GRT_RESISTANCE_AWARE"] = "1"
        active = True
    pct = config.get("GRT_CRITICAL_NETS_PERCENTAGE")
    if pct is not None:
        env["_GRT_CRITICAL_NETS_PCT"] = str(pct)
        active = True
    if active:
        env["_GRT_EXTRA_TCL"] = openroad_script("grt_extra.tcl")
    return active


def _install():
    from librelane.steps.odb import DiodesOnPorts
    from librelane.steps.openroad import (
        GlobalRouting,
        RepairAntennas,
        RepairDesignPostGRT,
        ResizerTimingPostGRT,
        _DiodeInsertion,
    )

    def add_vars(cls):
        names = {v.name for v in cls.config_vars}
        cls.config_vars = cls.config_vars + [
            v for v in grt_extra_variables if v.name not in names
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
            if grt_extra_env(self.config, env):
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
            command[-1] = openroad_script("grt_extra_wrap.tcl")
        return command

    GlobalRouting.get_command = get_command


_install()
