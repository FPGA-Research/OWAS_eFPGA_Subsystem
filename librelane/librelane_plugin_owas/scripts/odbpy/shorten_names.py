# SPDX-License-Identifier: Apache-2.0
# Runs inside `openroad -python`; invoked by Odb.ShortenNames.
#
# SYNTH_AUTONAME builds names from the driver chain (..._sg13cmos5l_buf_2_A_X_
# sg13cmos5l_inv_1_A_Y_...), up to ~1400 characters. Magic's `save` aborts on a
# `use <cell> <name>` line longer than ~1024 bytes ("buffer overflow detected"),
# so Magic.StreamOut writes no GDS. Renames every instance and net whose name is
# longer than SHORTEN_NAMES_MAX_LENGTH to its first characters plus a hash of
# the full name: the hierarchical prefix stays, so names remain
# readable and region patterns still match.
import csv
import hashlib
import sys

import click
from reader import click_odb  # LibreLane's scripts/odbpy, on PYTHONPATH


def short_name(name, max_length, exists):
    digest = hashlib.sha1(name.encode()).hexdigest()
    for n in (8, 12, 16, 40):
        prefix = name[: max_length - n - 1]
        # don't cut an escape sequence like `\[` in half
        prefix = prefix.rstrip("\\")
        candidate = f"{prefix}_{digest[:n]}"
        if not exists(candidate):
            return candidate
    raise RuntimeError(f"no unique short name for {name}")


@click.command()
@click.option("--map-file", required=True, help="CSV of the renames (kind, old, new)")
@click_odb
def main(reader, map_file):
    max_length = int(reader.config["SHORTEN_NAMES_MAX_LENGTH"])
    block = reader.block
    rows = []

    for inst in block.getInsts():
        name = inst.getName()
        if len(name) <= max_length:
            continue
        new = short_name(name, max_length, lambda n: block.findInst(n) is not None)
        if not inst.rename(new):
            print(f"[ERROR] could not rename instance {name}", file=sys.stderr)
            sys.exit(1)
        rows.append(("instance", name, new))

    for net in block.getNets():
        name = net.getName()
        # port nets carry the port name; never rename them
        if len(name) <= max_length or net.isSpecial() or len(net.getBTerms()):
            continue
        new = short_name(name, max_length, lambda n: block.findNet(n) is not None)
        if not net.rename(new):
            print(f"[ERROR] could not rename net {name}", file=sys.stderr)
            sys.exit(1)
        rows.append(("net", name, new))

    with open(map_file, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["kind", "old", "new"])
        writer.writerows(rows)

    insts = sum(1 for r in rows if r[0] == "instance")
    print(
        f"[INFO] Shortened {insts} instance and {len(rows) - insts} net name(s)"
        f" longer than {max_length} characters; map in {map_file}."
    )


if __name__ == "__main__":
    main()
