# SPDX-License-Identifier: Apache-2.0
"""
Name shortening: Magic's ``save`` aborts on instance names longer than ~1000
characters (SYNTH_AUTONAME driver chains), see scripts/odbpy/shorten_names.py.
"""
import os
from typing import List

from librelane.config import Variable
from librelane.steps import Step
from librelane.steps.openroad import WriteViews
from librelane.steps.step import CompositeStep

from ._common import PluginOdbpyStep

max_length_variable = Variable(
    "SHORTEN_NAMES_MAX_LENGTH",
    int,
    "Instance and net names longer than this are cut to their first characters"
    " plus a hash of the full name.",
    default=255,
)


class _ShortenNamesOdb(PluginOdbpyStep):
    id = "Odb.ShortenNamesOdb"
    name = "Shorten Long Names (ODB)"
    script = "shorten_names.py"

    config_vars = [max_length_variable]

    def extra_args(self) -> List[str]:
        return ["--map-file", os.path.join(self.step_dir, "renamed.csv")]


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
