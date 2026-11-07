# SPDX-License-Identifier: Apache-2.0
# Entry script for plain OpenROAD.GlobalRouting when GRT_RESISTANCE_AWARE /
# GRT_CRITICAL_NETS_PERCENTAGE is set: installs the global_route wrapper, then runs the
# original LibreLane script unchanged.
source $::env(_GRT_EXTRA_TCL)
source $::env(_GRT_EXTRA_ORIG_SCRIPT)
