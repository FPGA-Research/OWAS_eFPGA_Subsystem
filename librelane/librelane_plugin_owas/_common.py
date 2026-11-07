# SPDX-License-Identifier: Apache-2.0
"""Script paths and the base class shared by the plugin's steps."""
import os
from typing import List, Tuple

from librelane.steps.odb import OdbpyStep

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))


def odbpy_script(name: str) -> str:
    """Path of a script run by ``openroad -python`` (scripts/odbpy)."""
    return os.path.join(PLUGIN_DIR, "scripts", "odbpy", name)


def openroad_script(name: str) -> str:
    """Path of a Tcl script run or sourced by ``openroad`` (scripts/openroad)."""
    return os.path.join(PLUGIN_DIR, "scripts", "openroad", name)


class PluginOdbpyStep(OdbpyStep):
    """
    OdbpyStep running ``scripts/odbpy/<script>`` with ``--step-config`` plus
    ``extra_args()``. If ``required_vars`` is not empty and none of them is set,
    the step warns and does nothing.
    """

    script: str = ""
    required_vars: Tuple[str, ...] = ()

    def get_script_path(self) -> str:
        return odbpy_script(self.script)

    def extra_args(self) -> List[str]:
        return []

    def get_command(self) -> List[str]:
        return super().get_command() + ["--step-config", self.config_path] + self.extra_args()

    def run(self, state_in, **kwargs):
        if self.required_vars and not any(self.config[v] for v in self.required_vars):
            verb = "is" if len(self.required_vars) == 1 else "are"
            self.warn(f"{' / '.join(self.required_vars)} {verb} not set; skipping.")
            return {}, {}
        return super().run(state_in, **kwargs)
