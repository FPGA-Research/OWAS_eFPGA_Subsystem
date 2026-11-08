# SPDX-License-Identifier: Apache-2.0
# Runs inside `openroad -python`; invoked by Odb.RemoveMacroObstructions.
#
# Removes all obstructions on the given layers (REMOVE_MACRO_OBSTRUCTIONS) and the
# power/ground pin shapes on the given layers (REMOVE_MACRO_PG_PINS) from macro
# masters. Keys are instance names or master names (a master name applies to all
# its instances). The macro's LEF (from MACROS) is copied without those shapes and
# the instances are recreated with that master, see lef_utils.py.
import os
import re
import sys

import click
from reader import click_odb  # LibreLane's scripts/odbpy, on PYTHONPATH

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lef_utils import fail, macro_lef, read_lef_master, recreate, targets  # noqa: E402


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
            fail(f"pin {name} would have no shapes left")
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


@click.command()
@click.option("--out-dir", required=True)
@click_odb
def main(reader, out_dir):
    obs_cfg = reader.config.get("REMOVE_MACRO_OBSTRUCTIONS") or {}
    pg_cfg = reader.config.get("REMOVE_MACRO_PG_PINS") or {}
    macros = reader.config.get("MACROS") or {}
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
            fail(f"no LEF for {master_name} in MACROS")

        text, n_obs = strip_obs_layers(open(lef).read(), obs_layers)
        text, n_pg = strip_pg_pin_layers(text, pg_layers)
        tag = "_".join(
            [f"no_{'_'.join(sorted(obs_layers))}"] * bool(obs_layers)
            + [f"nopg_{'_'.join(sorted(pg_layers))}"] * bool(pg_layers)
        )
        stripped = os.path.join(out_dir, f"{master_name}_{tag}.lef")
        with open(stripped, "w") as f:
            f.write(text)

        new = read_lef_master(reader, stripped, master_name)

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
            fail(
                f"{master_name}: {len(left_obs)} OBS / {len(left_pg)} PG pin shapes"
                f" left on the removed layers"
            )
        # read the names first: recreate() destroys the instances
        names = ", ".join(sorted(i.getName() for i in insts)) if len(insts) < 3 else f"{len(insts)} instances"
        for inst in insts:
            recreate(block, inst, new)
        print(
            f"[INFO] {master_name} ({names}): removed {n_obs} OBS shape(s) on"
            f" {', '.join(sorted(obs_layers)) or '-'} and {n_pg} PG pin shape(s) on"
            f" {', '.join(sorted(pg_layers)) or '-'}; master now from {stripped}."
        )


if __name__ == "__main__":
    main()
