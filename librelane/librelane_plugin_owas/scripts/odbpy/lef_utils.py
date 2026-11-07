# SPDX-License-Identifier: Apache-2.0
# Helpers shared by the odbpy scripts that give macro instances an edited copy of
# their LEF master (remove_macro_obs.py, macro_pin_first.py, restore_macro_masters.py).
#
# LEF masters are frozen in OpenDB, so an edited master is read from a LEF copy
# into its own library and each instance is recreated with it (same name,
# placement and connections). dbInst.swapMaster is not used: its STA callback
# compares the masters' Liberty cells and segfaults for macros without a .lib
# (e.g. black-box macros).
import sys

import odb


def fail(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def macro_lef(macros, master_name):
    """First LEF of `master_name` in the MACROS config, or None."""
    entry = (macros or {}).get(master_name)
    if not entry or not entry.get("lef"):
        return None
    return entry["lef"][0]


def read_lef_master(reader, lef_path, master_name):
    """Reads `lef_path` into a new library and returns its `master_name` master.
    Goes through OpenROAD (not odb.read_lef), so STA knows the new master: STA
    must know every master an instance is created with."""
    db = reader.db
    libs_before = {lib.getName() for lib in db.getLibs()}
    reader.add_lef(lef_path)
    new_libs = [lib for lib in db.getLibs() if lib.getName() not in libs_before]
    new = new_libs[0].findMaster(master_name) if new_libs else None
    if new is None:
        fail(f"no master {master_name} in {lef_path}")
    return new


def recreate(block, inst, master):
    """Replaces `inst` by an instance of `master` with the same name, location,
    orientation, placement status, halo, group and connections."""
    name = inst.getName()
    x, y = inst.getLocation()
    orient = inst.getOrient()
    status = inst.getPlacementStatus()
    halo = inst.getHalo()
    halo_box = (halo.xMin(), halo.yMin(), halo.xMax(), halo.yMax()) if halo else None
    group = inst.getGroup()
    conns = [
        (it.getMTerm().getName(), it.getNet()) for it in inst.getITerms() if it.getNet()
    ]
    odb.dbInst.destroy(inst)
    new = odb.dbInst.create(block, master, name)
    new.setOrient(orient)
    new.setLocation(x, y)
    new.setPlacementStatus(status)
    if halo_box:
        odb.dbBox.create(new, *halo_box)
    if group:
        group.addInst(new)
    for mterm, net in conns:
        new.findITerm(mterm).connect(net)
    if len([it for it in new.getITerms() if it.getNet()]) != len(conns):
        fail(f"{name}: connections changed while recreating")
    return new


def targets(block, key):
    """Instances for a config key: the instance of that name, else all instances of
    the master of that name."""
    inst = block.findInst(key)
    if inst is not None:
        return [inst]
    insts = [i for i in block.getInsts() if i.getMaster().getName() == key]
    if not insts:
        fail(f"no instance or master named {key}")
    return insts
