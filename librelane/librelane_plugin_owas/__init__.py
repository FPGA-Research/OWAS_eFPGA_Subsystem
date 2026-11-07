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

Modules: grt (global_route options, extends LibreLane's GRT steps), regions
(placement regions and the Regions.* variants), macros (PDN/LEF steps for
macros), names (name shortening). Scripts run by the steps are in
scripts/odbpy (openroad -python) and scripts/openroad (Tcl).
"""
from . import grt, macros, names, regions  # noqa: F401
