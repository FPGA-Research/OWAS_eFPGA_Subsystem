# SPDX-License-Identifier: Apache-2.0
# Runs inside `openroad -python`; invoked by Odb.RemoveMacroObstructions.
#
# Removes all obstructions on the given layers (REMOVE_MACRO_OBSTRUCTIONS) and the
# power/ground pin shapes on the given layers (REMOVE_MACRO_PG_PINS) from macro
# masters. Keys are instance names or master names (a master name applies to all
# its instances). LEF masters are frozen in OpenDB (their shapes cannot be
# deleted), so the macro's LEF (from MACROS) is copied without those shapes, read
# into its own library and the instances are recreated with that master (same
# name, placement and connections). dbInst.swapMaster is not used: its STA
# callback compares the masters' Liberty cells and segfaults for macros without a
# .lib (e.g. black-box macros).
import os
import re
import sys

import click
import odb
from reader import click_odb  # LibreLane's scripts/odbpy, on PYTHONPATH


def strip_pg_pin_layers(lef_text, layers):
    """Returns the LEF without USE POWER/GROUND pin shapes on `layers`, and the
    number removed. Ports left empty are dropped; a pin must keep one port."""
    dropped = 0

    def strip_pin(m):
        nonlocal dropped
        name, body = m.group(1), m.group(2)
        if not re.search(r"^\s*USE\s+(POWER|GROUND)\s*;", body, re.M):
            return m.group(0)
        parts = re.split(r"(^\s*PORT\s*\n.*?^\s*END\s*\n)", body, flags=re.M | re.S)
        out, ports = [], 0
        for part in parts:
            if not re.match(r"\s*PORT\s*\n", part):
                out.append(part)
                continue
            kept, layer, shapes = [], None, 0
            for line in part.splitlines(keepends=True):
                lm = re.match(r"\s*LAYER\s+(\S+)", line)
                if lm:
                    layer = lm.group(1)
                if layer in layers and re.match(r"\s*(LAYER|RECT|POLYGON|VIA)\b", line):
                    dropped += bool(re.match(r"\s*(RECT|POLYGON|VIA)\b", line))
                    continue
                shapes += bool(re.match(r"\s*(RECT|POLYGON|VIA)\b", line))
                kept.append(line)
            if shapes:
                out.append("".join(kept))
                ports += 1
        if not ports:
            print(f"[ERROR] pin {name} would have no shapes left", file=sys.stderr)
            sys.exit(1)
        return f"  PIN {name}\n{''.join(out)}  END {name}\n"

    text = re.sub(r"^  PIN (\S+)\s*\n(.*?)^  END \1\s*\n", strip_pin, lef_text, flags=re.M | re.S)
    return text, dropped


def strip_obs_layers(lef_text, layers):
    """Returns the LEF without OBS shapes on `layers`, and the number removed."""
    head, sep, rest = lef_text.partition("\n  OBS\n")
    if not sep:
        return lef_text, 0
    obs, sep2, tail = rest.partition("\n  END\n")
    kept, dropped, layer = [], 0, None
    for line in obs.splitlines():
        m = re.match(r"\s*LAYER\s+(\S+)", line)
        if m:
            layer = m.group(1)
        if layer in layers:
            if re.match(r"\s*(RECT|POLYGON)", line):
                dropped += 1
            continue
        kept.append(line)
    return head + sep + "\n".join(kept) + sep2 + tail, dropped


def macro_lef(macros, master_name):
    entry = (macros or {}).get(master_name)
    if not entry or not entry.get("lef"):
        return None
    return entry["lef"][0]


def recreate(block, inst, master):
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
        print(f"[ERROR] {name}: connections changed while recreating", file=sys.stderr)
        sys.exit(1)
    return new


def targets(block, key):
    """Instances for a config key: the instance of that name, else all instances of
    the master of that name."""
    inst = block.findInst(key)
    if inst is not None:
        return [inst]
    insts = [i for i in block.getInsts() if i.getMaster().getName() == key]
    if not insts:
        print(f"[ERROR] no instance or master named {key}", file=sys.stderr)
        sys.exit(1)
    return insts


@click.command()
@click.option("--out-dir", required=True)
@click_odb
def main(reader, out_dir):
    obs_cfg = reader.config.get("REMOVE_MACRO_OBSTRUCTIONS") or {}
    pg_cfg = reader.config.get("REMOVE_MACRO_PG_PINS") or {}
    macros = reader.config.get("MACROS") or {}
    db = reader.db
    block = reader.block

    # instance name -> [instance, OBS layers, PG pin layers]
    plan = {}
    for cfg, idx in ((obs_cfg, 1), (pg_cfg, 2)):
        for key, layers in cfg.items():
            for inst in targets(block, key):
                entry = plan.setdefault(inst.getName(), [inst, set(), set()])
                entry[idx] |= set(layers)

    # one stripped master per (master, OBS layers, PG pin layers)
    groups = {}
    for inst, obs_layers, pg_layers in plan.values():
        key = (inst.getMaster().getName(), frozenset(obs_layers), frozenset(pg_layers))
        groups.setdefault(key, []).append(inst)

    for (master_name, obs_layers, pg_layers), insts in groups.items():
        lef = macro_lef(macros, master_name)
        if lef is None:
            print(f"[ERROR] no LEF for {master_name} in MACROS", file=sys.stderr)
            sys.exit(1)

        text, n_obs = strip_obs_layers(open(lef).read(), obs_layers)
        text, n_pg = strip_pg_pin_layers(text, pg_layers)
        tag = "_".join(
            [f"no_{'_'.join(sorted(obs_layers))}"] * bool(obs_layers)
            + [f"nopg_{'_'.join(sorted(pg_layers))}"] * bool(pg_layers)
        )
        stripped = os.path.join(out_dir, f"{master_name}_{tag}.lef")
        with open(stripped, "w") as f:
            f.write(text)

        # through OpenROAD (not odb.read_lef), so STA knows the new master;
        # (STA must know every master an instance is created with)
        libs_before = {lib.getName() for lib in db.getLibs()}
        reader.add_lef(stripped)
        new_libs = [lib for lib in db.getLibs() if lib.getName() not in libs_before]
        new = new_libs[0].findMaster(master_name) if new_libs else None
        if new is None:
            print(f"[ERROR] no master {master_name} in {stripped}", file=sys.stderr)
            sys.exit(1)

        left_obs = [
            b
            for b in new.getObstructions()
            if b.getTechLayer() is not None and b.getTechLayer().getName() in obs_layers
        ]
        left_pg = [
            b
            for mt in new.getMTerms()
            if mt.getSigType() in ("POWER", "GROUND")
            for mp in mt.getMPins()
            for b in mp.getGeometry()
            if b.getTechLayer() is not None and b.getTechLayer().getName() in pg_layers
        ]
        if left_obs or left_pg:
            print(
                f"[ERROR] {master_name}: {len(left_obs)} OBS / {len(left_pg)} PG pin shapes"
                f" left on the removed layers",
                file=sys.stderr,
            )
            sys.exit(1)
        for inst in insts:
            recreate(block, inst, new)
        names = ", ".join(sorted(i.getName() for i in insts)) if len(insts) < 3 else f"{len(insts)} instances"
        print(
            f"[INFO] {master_name} ({names}): removed {n_obs} OBS shape(s) on"
            f" {', '.join(sorted(obs_layers)) or '-'} and {n_pg} PG pin shape(s) on"
            f" {', '.join(sorted(pg_layers)) or '-'}; master now from {stripped}."
        )


if __name__ == "__main__":
    main()
