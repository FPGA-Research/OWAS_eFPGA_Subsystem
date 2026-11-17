# SPDX-License-Identifier: Apache-2.0
# Runs inside `openroad -python`; invoked by Odb.ConnectMacroRingStripes.
#
# Connects top-level PDN stripes that end at a macro edge to the macro's power ring
# pins just inside that edge. pdngen trims core-grid stripes at instance boundaries
# and has no "extend to the pin" option, so this adds, per stripe end that faces a
# same-net ring pin on `pin_layer`:
#   - an extension of the stripe (same layer and width) up to the far side of the pin,
#   - landing pads on every layer between pin_layer and the stripe layer (square, at most
#     the stripe width long along the pin, centred on it),
#   - one via per layer pair (existing block vias, chosen by layer and fit).
# Only stripes running perpendicular to the pin (vertical stripe / horizontal pin, or
# the reverse) are used. A connection is skipped (and reported) if any new shape would
# overlap a shape of another net, another instance's pin/OBS, or the target macro's own
# pin/OBS of the other net on the stripe/pad layers.
import sys

import click
import odb
from reader import click_odb  # LibreLane's scripts/odbpy, on PYTHONPATH


def rect(x0, y0, x1, y1):
    return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def overlaps(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def xform(inst):
    """Macro -> chip coordinates for the DEF orientations (origin = placed bbox lower-left).
    Done by hand: dbTransform.apply is not usable from the Python bindings here."""
    m = inst.getMaster()
    W, H = m.getWidth(), m.getHeight()
    bb = inst.getBBox()
    ox, oy = bb.xMin(), bb.yMin()
    o = inst.getOrient()
    f = {
        "R0": lambda x, y: (x, y),
        "R180": lambda x, y: (W - x, H - y),
        "R90": lambda x, y: (H - y, x),
        "R270": lambda x, y: (y, W - x),
        "MY": lambda x, y: (W - x, y),
        "MX": lambda x, y: (x, H - y),
        "MXR90": lambda x, y: (y, x),
        "MYR90": lambda x, y: (H - y, W - x),
    }[o]

    def apply(x0, y0, x1, y1):
        ax, ay = f(x0, y0)
        bx, by = f(x1, y1)
        return (ox + min(ax, bx), oy + min(ay, by), ox + max(ax, bx), oy + max(ay, by))

    return apply


def inst_shapes(inst, layer_names):
    """(layer, rect, net or None, kind) of the instance's pins and OBS, in chip coordinates."""
    out = []
    xf = xform(inst)
    for it in inst.getITerms():
        net = it.getNet()
        for mpin in it.getMTerm().getMPins():
            for g in mpin.getGeometry():
                ly = g.getTechLayer()
                if ly is None or ly.getName() not in layer_names:
                    continue
                out.append((ly.getName(), xf(g.xMin(), g.yMin(), g.xMax(), g.yMax()),
                            net.getName() if net else None, it.getMTerm().getName()))
    for ob in inst.getMaster().getObstructions():
        ly = ob.getTechLayer()
        if ly is None or ly.getName() not in layer_names:
            continue
        out.append((ly.getName(), xf(ob.xMin(), ob.yMin(), ob.xMax(), ob.yMax()), None, "OBS"))
    return out


def find_via(block, lower, upper, w, h):
    """Smallest-cut block via between two layers whose bottom and top fit w x h."""
    best = None
    for v in block.getVias():
        if v.getBottomLayer() is None or v.getTopLayer() is None:
            continue
        if (v.getBottomLayer().getName(), v.getTopLayer().getName()) != (lower, upper):
            continue
        fits = True
        for b in v.getBoxes():
            ly = b.getTechLayer()
            if ly is None or ly.getType() != "ROUTING":
                continue
            if b.xMax() - b.xMin() > w or b.yMax() - b.yMin() > h:
                fits = False
        if fits:
            cuts = len([b for b in v.getBoxes() if b.getTechLayer().getType() == "CUT"])
            if best is None or cuts > best[0]:
                best = (cuts, v)
    return best[1] if best else None


@click.command()
@click_odb
def main(reader):
    cfg = reader.config.get("MACRO_RING_STRIPE_CONNECT") or {}
    block = reader.block
    tech = reader.db.getTech()
    dbu = block.getDbUnitsPerMicron()
    # pad centers are snapped to the manufacturing grid (DBU)
    grid = tech.getManufacturingGrid() if tech.hasManufacturingGrid() else 1
    total = 0
    skipped = 0

    for master_name, opt in cfg.items():
        stripe_layer = opt.get("stripe_layer", "Metal4")
        pin_layer = opt.get("pin_layer", "Metal2")
        max_gap = int(round(float(opt.get("max_gap", 1.0)) * dbu))
        max_depth = int(round(float(opt.get("max_depth", 6.0)) * dbu))
        nets = str(opt.get("nets", "VDD VSS")).split()

        lo = tech.findLayer(pin_layer).getRoutingLevel()
        hi = tech.findLayer(stripe_layer).getRoutingLevel()
        stack = [tech.findRoutingLayer(i).getName() for i in range(lo, hi + 1)]
        pad_layers = stack[1:-1]

        insts = [i for i in block.getInsts() if i.getMaster().getName() == master_name]
        if not insts:
            print(f"[ERROR] no instance of {master_name}", file=sys.stderr)
            sys.exit(1)

        # all special shapes of all nets on the stack layers, for the conflict check
        sshapes = []
        for net in block.getNets():
            for sw in net.getSWires():
                for b in sw.getWires():
                    if b.isVia():
                        v = b.getBlockVia() or b.getTechVia()
                        vx, vy = b.getViaXY()
                        for vb in v.getBoxes():
                            ly = vb.getTechLayer()
                            if ly and ly.getName() in stack:
                                sshapes.append((ly.getName(), (vx + vb.xMin(), vy + vb.yMin(),
                                                               vx + vb.xMax(), vy + vb.yMax()),
                                                net.getName()))
                    else:
                        ly = b.getTechLayer()
                        if ly and ly.getName() in stack:
                            sshapes.append((ly.getName(), (b.xMin(), b.yMin(), b.xMax(), b.yMax()), net.getName()))

        for inst in insts:
            bb = inst.getBBox()
            ib = (bb.xMin(), bb.yMin(), bb.xMax(), bb.yMax())
            own = inst_shapes(inst, set(stack))
            # other instances near this one (pins and OBS) for the conflict check
            near = (ib[0] - max_depth, ib[1] - max_depth, ib[2] + max_depth, ib[3] + max_depth)
            others = []
            for o in block.getInsts():
                if o.getName() == inst.getName():  # SWIG wrappers are not identical objects
                    continue
                ob = o.getBBox()
                if overlaps(near, (ob.xMin(), ob.yMin(), ob.xMax(), ob.yMax())):
                    others += [s + (o.getName(),) for s in inst_shapes(o, set(stack))]
            pins = [s for s in own if s[0] == pin_layer and s[2] in nets]

            for net_name in nets:
                net = block.findNet(net_name)
                new_sw = None
                for sw in list(net.getSWires()):
                    for b in list(sw.getWires()):
                        if b.isVia() or b.getTechLayer().getName() != stripe_layer:
                            continue
                        s = (b.xMin(), b.yMin(), b.xMax(), b.yMax())
                        vertical = (s[3] - s[1]) > (s[2] - s[0])
                        # stripe end facing the instance edge, stripe within the instance span
                        if vertical:
                            if not (s[0] >= ib[0] and s[2] <= ib[2]):
                                continue
                            if 0 <= ib[1] - s[3] <= max_gap:
                                side = "low"     # stripe below, ends at the bottom edge
                            elif 0 <= s[1] - ib[3] <= max_gap:
                                side = "high"    # stripe above, starts at the top edge
                            else:
                                continue
                        else:
                            if not (s[1] >= ib[1] and s[3] <= ib[3]):
                                continue
                            if 0 <= ib[0] - s[2] <= max_gap:
                                side = "low"
                            elif 0 <= s[0] - ib[2] <= max_gap:
                                side = "high"
                            else:
                                continue
                        # same-net pin crossed by the stripe's extension, within max_depth
                        target = None
                        for (_, p, pnet, _) in pins:
                            if pnet != net_name:
                                continue
                            if vertical:
                                if not (p[0] <= s[0] and p[2] >= s[2]):
                                    continue
                                depth = (p[3] - ib[1]) if side == "low" else (ib[3] - p[1])
                            else:
                                if not (p[1] <= s[1] and p[3] >= s[3]):
                                    continue
                                depth = (p[2] - ib[0]) if side == "low" else (ib[2] - p[0])
                            if 0 < depth <= max_depth and (target is None or depth < target[0]):
                                target = (depth, p)
                        if target is None:
                            continue
                        p = target[1]
                        # The pads are at most as long (along the pin) as the stripe is wide,
                        # centred on the pin. A full-pin pad on a wide ring bar (3 um bar,
                        # 1 um stripe) is a Metal2/Metal3 shape running across the bar, which
                        # detailed placement's check_placement counts as a "blocked layer"
                        # under the macro (DPL-0010/DPL-0033: it marks vertical special
                        # wires on M2/M3 and fails every instance using those layers there).
                        if vertical:
                            ext = rect(s[0], s[3] if side == "low" else p[1],
                                       s[2], p[3] if side == "low" else s[1])
                            half = min(p[3] - p[1], s[2] - s[0]) // 2
                            mid = ((p[1] + p[3]) // 2) // grid * grid
                            pad = rect(s[0], mid - half, s[2], mid + half)
                        else:
                            ext = rect(s[2] if side == "low" else p[0], s[1],
                                       p[2] if side == "low" else s[0], s[3])
                            half = min(p[2] - p[0], s[3] - s[1]) // 2
                            mid = ((p[0] + p[2]) // 2) // grid * grid
                            pad = rect(mid - half, s[1], mid + half, s[3])
                        new = [(stripe_layer, ext)] + [(ly, pad) for ly in pad_layers]
                        bad = []
                        for (ly, r) in new:
                            for (sl, sr, sn) in sshapes:
                                if sl == ly and sn != net_name and overlaps(r, sr):
                                    bad.append(f"{sn} special {ly}")
                            for (ol, orr, on, kind, oname) in others:
                                if ol == ly and on != net_name and overlaps(r, orr):
                                    bad.append(f"{oname} {kind} {ly}")
                            for (ol, orr, on, kind) in own:
                                if ol == ly and on is not None and on != net_name and overlaps(r, orr):
                                    bad.append(f"own pin {kind} {ly}")
                        if bad:
                            skipped += 1
                            print(f"[WARNING] {inst.getName()} {net_name} stripe at "
                                  f"{s[0]/dbu:.2f},{s[1]/dbu:.2f}: skipped ({bad[0]})")
                            continue
                        w, h = pad[2] - pad[0], pad[3] - pad[1]
                        vias = []
                        for a, c in zip(stack[:-1], stack[1:]):
                            v = find_via(block, a, c, w, h)
                            if v is None:
                                print(f"[ERROR] no block via {a}-{c} fitting {w/dbu}x{h/dbu}",
                                      file=sys.stderr)
                                sys.exit(1)
                            vias.append(v)
                        if new_sw is None:
                            new_sw = odb.dbSWire_create(net, "ROUTED")
                        odb.dbSBox_create(new_sw, tech.findLayer(stripe_layer), *ext, "STRIPE")
                        for ly in pad_layers:
                            odb.dbSBox_create(new_sw, tech.findLayer(ly), *pad, "STRIPE")
                        cx, cy = (pad[0] + pad[2]) // 2, (pad[1] + pad[3]) // 2
                        for v in vias:
                            odb.dbSBox_create(new_sw, v, cx, cy, "STRIPE")
                        for (ly, r) in new:
                            sshapes.append((ly, r, net_name))
                        total += 1
                        print(f"[INFO] {inst.getName()} {net_name}: {stripe_layer} stripe at "
                              f"x {s[0]/dbu:.2f}..{s[2]/dbu:.2f} connected to {pin_layer} pin "
                              f"y {p[1]/dbu:.2f}..{p[3]/dbu:.2f} ({side} edge)")
    print(f"[INFO] {total} stripe-to-ring connections added, {skipped} skipped.")


if __name__ == "__main__":
    main()
