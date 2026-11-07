# SPDX-License-Identifier: Apache-2.0
# Runs inside `openroad -python`; invoked by Odb.RestoreMacroMasters.
#
# Swaps the instances listed in REMOVE_MACRO_PG_PINS back to the macro's original
# master (the one read from MACROS) after the PDN. Odb.RemoveMacroObstructions gave
# them a stripped copy of the master with the same name in its own library; that
# copy only exists for pdngen. TritonRoute looks masters up by name and finds the
# original, so an instance on a copy with fewer PG pin shapes fails with DRT-0405
# ("Mismatch in number of pins for term <master>/VDD"). The PDN wires are block
# special wires and stay as they are.
import os
import sys

import click
import odb
from reader import click_odb  # LibreLane's scripts/odbpy, on PYTHONPATH

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from remove_macro_obs import recreate, targets  # noqa: E402


def original_master(db, master):
    """The other master of the same name: the one not created by
    Odb.RemoveMacroObstructions (whose libraries are named <master>_no*)."""
    name = master.getName()
    found = [
        lib.findMaster(name)
        for lib in db.getLibs()
        if lib.findMaster(name) is not None
        and lib.getName() != master.getLib().getName()
        and not lib.getName().startswith(f"{name}_no")
    ]
    if len(found) != 1:
        print(f"[ERROR] {name}: {len(found)} original master(s) found", file=sys.stderr)
        sys.exit(1)
    return found[0]


@click.command()
@click_odb
def main(reader):
    db = reader.db
    block = reader.block
    keys = list((reader.config.get("REMOVE_MACRO_PG_PINS") or {}).keys())
    for key in keys:
        names = [i.getName() for i in targets(block, key)]
        restored = 0
        for name in names:
            inst = block.findInst(name)
            current = inst.getMaster()
            if not current.getLib().getName().startswith(f"{current.getName()}_no"):
                continue  # already on the original master
            orig = original_master(db, current)
            new = recreate(block, inst, orig)
            if new.getMaster().getLib().getName() != orig.getLib().getName():
                print(f"[ERROR] {name}: not restored", file=sys.stderr)
                sys.exit(1)
            restored += 1
        # TritonRoute reads every master of every library and stops (DRT-0405) when two
        # masters of the same name differ in PG pin count, used or not: drop the stripped
        # libraries of this master once no instance uses them.
        master = block.findInst(names[0]).getMaster()
        used = {i.getMaster().getLib().getName() for i in block.getInsts()}
        for lib in list(db.getLibs()):
            ln = lib.getName()
            if ln.startswith(f"{master.getName()}_no") and lib.findMaster(master.getName()) is not None:
                if ln in used:
                    print(f"[ERROR] library {ln} is still in use", file=sys.stderr)
                    sys.exit(1)
                odb.dbLib.destroy(lib)
                print(f"[INFO] removed stripped library {ln}")
        pins = {
            mt.getName(): len(mt.getMPins())
            for mt in master.getMTerms()
            if mt.getSigType() in ("POWER", "GROUND")
        }
        print(
            f"[INFO] {key}: {restored} of {len(names)} instance(s) back on the original master"
            f" (lib {master.getLib().getName()}, PG pin shapes {pins})."
        )


if __name__ == "__main__":
    main()
