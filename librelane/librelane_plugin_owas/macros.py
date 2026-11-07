# SPDX-License-Identifier: Apache-2.0
"""
Macro-related steps: PDN stripes connected to macro rings, macro LEF edits
(obstructions, PG pins, pin order) for the top-level PDN and CTS. The LEF edits
read an edited copy of the macro's LEF from ``MACROS`` into its own library and
recreate the instances with that master (scripts/odbpy/lef_utils.py).
"""
from typing import Dict, List, Optional

from librelane.config import Variable
from librelane.steps import Step

from ._common import PluginOdbpyStep

remove_pg_pins_variable = Variable(
    "REMOVE_MACRO_PG_PINS",
    Optional[Dict[str, List[str]]],
    "Macro instance or master name -> layers whose power/ground pin shapes are "
    "removed from its master (the shapes stay in the macro's GDS).",
    default=None,
)


@Step.factory.register()
class ConnectMacroRingStripes(PluginOdbpyStep):
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
    script = "connect_ring_stripes.py"
    required_vars = ("MACRO_RING_STRIPE_CONNECT",)

    config_vars = [
        Variable(
            "MACRO_RING_STRIPE_CONNECT",
            Optional[Dict[str, Dict[str, str]]],
            "Macro master name -> options as strings: stripe_layer, pin_layer, max_gap (µm),"
            + " max_depth (µm), nets (space-separated).",
            default=None,
        ),
    ]


@Step.factory.register()
class RemoveMacroObstructions(PluginOdbpyStep):
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
    script = "remove_macro_obs.py"
    required_vars = ("REMOVE_MACRO_OBSTRUCTIONS", "REMOVE_MACRO_PG_PINS")

    config_vars = [
        Variable(
            "REMOVE_MACRO_OBSTRUCTIONS",
            Optional[Dict[str, List[str]]],
            "Macro instance or master name -> layers whose OBS are removed from its master.",
            default=None,
        ),
        remove_pg_pins_variable,
    ]

    def extra_args(self) -> List[str]:
        return ["--out-dir", self.step_dir]


@Step.factory.register()
class RestoreMacroMasters(PluginOdbpyStep):
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
    script = "restore_macro_masters.py"
    required_vars = ("REMOVE_MACRO_PG_PINS",)

    config_vars = [remove_pg_pins_variable]


@Step.factory.register()
class MacroClockPinFirst(PluginOdbpyStep):
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
    script = "macro_pin_first.py"
    required_vars = ("MACRO_CLOCK_PIN_FIRST",)

    config_vars = [
        Variable(
            "MACRO_CLOCK_PIN_FIRST",
            Optional[Dict[str, str]],
            "Macro master name -> output pin made its first output pin (a clock root"
            + " for CTS latency balancing).",
            default=None,
        ),
    ]

    def extra_args(self) -> List[str]:
        return ["--out-dir", self.step_dir]
