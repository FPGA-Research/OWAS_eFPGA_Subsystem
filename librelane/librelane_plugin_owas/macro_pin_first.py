# SPDX-License-Identifier: Apache-2.0
# Runs inside `openroad -python`; invoked by Odb.MacroClockPinFirst.
#
# Makes a macro's clock output pin its first output pin in OpenDB, so the post-CTS
# LatencyBalancer of OpenROAD dcf3613 can see the clock tree of a clock rooted on
# that pin: LatencyBalancer::buildGraph starts from the root driver's
# dbInst::getFirstOutput() instead of the driving pin. LEF pins are often written
# alphabetically, so a clock output pin is rarely first, and a clock generated on
# it gets no delay buffers.
#
# OpenDB keeps a master's pins in LEF order and LEF masters are frozen, so the
# macro's LEF (from MACROS) is copied with the PIN block moved to the front
# (written to the step dir), read into its own library, and every instance of
# the master is recreated with the copy (same name, placement, connections,
# group). Geometry, pins and OBS are unchanged; only the pin order differs.
import os
import re
import sys

import click
from reader import click_odb  # LibreLane's scripts/odbpy, on PYTHONPATH

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from remove_macro_obs import macro_lef, recreate  # noqa: E402


def pin_first(lef_text, pin):
    """Returns the LEF with the PIN `pin` block moved in front of the first PIN."""
    block = re.search(
        rf"^[ \t]*PIN[ \t]+{re.escape(pin)}[ \t]*\n.*?^[ \t]*END[ \t]+{re.escape(pin)}[ \t]*\n",
        lef_text,
        re.M | re.S,
    )
    if block is None:
        return None
    rest = lef_text[: block.start()] + lef_text[block.end() :]
    first = re.search(r"^[ \t]*PIN[ \t]+\S+[ \t]*\n", rest, re.M)
    return rest[: first.start()] + block.group(0) + rest[first.start() :]


def fail(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


@click.command()
@click.option("--out-dir", required=True)
@click_odb
def main(reader, out_dir):
    pins = reader.config.get("MACRO_CLOCK_PIN_FIRST") or {}
    macros = reader.config.get("MACROS") or {}
    db = reader.db
    block = reader.block

    for master_name, pin in pins.items():
        insts = [i for i in block.getInsts() if i.getMaster().getName() == master_name]
        if not insts:
            fail(f"no instance of {master_name}")
        old = insts[0].getMaster()
        mterm = old.findMTerm(pin)
        if mterm is None or mterm.getIoType() != "OUTPUT":
            fail(f"{master_name} has no output pin {pin}")
        first = insts[0].getFirstOutput()
        was = first.getMTerm().getName() if first is not None else None
        if was == pin:
            print(f"[INFO] {master_name}: {pin} is already the first output pin; unchanged.")
            continue

        lef = macro_lef(macros, master_name)
        if lef is None:
            fail(f"no LEF for {master_name} in MACROS")
        text = pin_first(open(lef).read(), pin)
        if text is None:
            fail(f"no PIN {pin} in {lef}")
        out = os.path.join(out_dir, f"{master_name}_{pin}_first.lef")
        with open(out, "w") as f:
            f.write(text)

        # through OpenROAD (not odb.read_lef), so STA knows the new master
        libs_before = {lib.getName() for lib in db.getLibs()}
        reader.add_lef(out)
        new_libs = [lib for lib in db.getLibs() if lib.getName() not in libs_before]
        new = new_libs[0].findMaster(master_name) if new_libs else None
        if new is None:
            fail(f"no master {master_name} in {out}")
        old_pins = sorted(m.getName() for m in old.getMTerms())
        if sorted(m.getName() for m in new.getMTerms()) != old_pins:
            fail(f"{out}: pin set differs from the current {master_name} master")

        for inst in insts:
            name = inst.getName()
            inst = recreate(block, inst, new)
            first = inst.getFirstOutput()
            if first is None or first.getMTerm().getName() != pin:
                fail(f"{name}: first output pin is still not {pin}")
        print(
            f"[INFO] {master_name}: {len(insts)} instance(s) now use {out}"
            f" ({pin} first; first output was {was}, master from {lef})."
        )


if __name__ == "__main__":
    main()
