#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Render an architecture diagram in the Microsoft reference style.

    python scripts/render_azure_diagram.py week-11-.../docs/blog/diagrams/week-11-architecture.json

Why this exists (2026-10-30)
----------------------------
Jay: diagrams should look like Microsoft's published reference architectures --
official Azure icons, grouping boxes, short edge labels, no prose in the image.
Hand-drawing that per week guarantees drift: the week 11 SVG drawn by hand
carried a VM size that was wrong for days, because a hand-edited diagram has no
source anybody re-reads.

So a diagram is a committed JSON spec rendered to SVG, the same bargain the
terminal cards already make: the artefact can be regenerated and therefore
corrected.

Icon terms, which constrain the renderer
----------------------------------------
Microsoft permits these icons "in architectural diagrams, training materials,
or documentation". The rules that are the renderer's job to honour:

  * "Don't crop, flip, or rotate icons."
  * "Don't distort or change icon shape in any way."
    -> icons are ALWAYS scaled uniformly from their own viewBox. There is no
       code path that writes a non-uniform scale, and none should be added.
  * "In diagrams, we recommend including the product name somewhere close to
    the icon."
    -> a node without a label is a hard error, not a warning.

Icons live unmodified in scripts/diagram-icons/. They are copied from the
official set, never edited.

Spec format
-----------
{
  "title":  "optional heading",
  "width":  1280, "height": 720,
  "groups": [{"id","label","x","y","w","h","style":"vnet|logical","note"}],
  "nodes":  [{"id","icon","label","x","y"}],      # x,y = icon CENTRE
  "edges":  [{"from","to","label","style":"solid|dashed","via":[[x,y],...]}]
}

Coordinates are absolute. That is deliberate: a layout engine would make the
output depend on graph topology, and a diagram that silently re-flows when a
node is added is a diagram nobody can review in a diff.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ICON_DIR = Path(__file__).resolve().parent / "diagram-icons"

ICON_PX = 46          # rendered icon box, uniform
LABEL_DY = 16         # first label baseline below the icon box
LABEL_LH = 14         # label line height
LABEL_MAX = 19        # chars per label line before wrapping

INK = "#1f2933"       # body text
MUTED = "#5b6670"     # edge labels, group notes
EDGE = "#2b3137"      # connector stroke
VNET = "#0078d4"      # the dashed network boundary, Azure blue
GROUP_LINE = "#b9c2cc"
GROUP_FILL = "#ffffff"

FONT = ('font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, '
        'Helvetica, Arial, sans-serif"')


# ---------------------------------------------------------------- icons ----

def load_icon(name: str, uid: str) -> tuple[str, float]:
    """Return (inner svg markup, source viewBox size) with ids namespaced.

    Every icon in the official set carries a <defs> of gradients referenced by
    id. Two instances of the same icon in one diagram would define the same id
    twice and the second would win for both -- so ids are rewritten per
    instance. Found by using two VMs in one draft, where the second took the
    first's gradient.

    Ids are rewritten to SHORT, DETERMINISTIC tokens (`n3i0`), not to a
    prefixed copy of the original. Two reasons, both learned the hard way:

      * the official ids are uuid-shaped, and a prefixed uuid is still
        uuid-shaped. `scripts/secret-sweep.sh` greps the tree for GUIDs and
        failed the whole sweep on a generated diagram. A gate that cries wolf
        on every render is a gate someone starts bypassing.
      * a random per-render id means re-rendering an unchanged spec produces
        a different file. A committed artefact has to be reproducible, or its
        diff tells you nothing.
    """
    path = ICON_DIR / name
    if not path.exists():
        raise SystemExit(
            f"icon not found: {path}\n"
            f"  available: {', '.join(sorted(p.name for p in ICON_DIR.glob('*.svg')))}"
        )
    raw = path.read_text(encoding="utf-8")

    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', raw)
    if not m:
        raise SystemExit(f"{name}: no viewBox, cannot scale without distorting")
    vb_w, vb_h = float(m.group(1)), float(m.group(2))
    if abs(vb_w - vb_h) > 0.01:
        # Not fatal, but the caller assumes a square box; say so rather than
        # silently letting the label drift off-centre.
        print(f"  note: {name} viewBox is {vb_w}x{vb_h}, not square")

    inner = re.sub(r"^.*?<svg[^>]*>", "", raw, count=1, flags=re.S)
    inner = re.sub(r"</svg>\s*$", "", inner, flags=re.S)

    for i, old in enumerate(sorted(set(re.findall(r'id="([^"]+)"', inner)))):
        new = f"{uid}i{i}"
        inner = inner.replace(f'id="{old}"', f'id="{new}"')
        inner = inner.replace(f"url(#{old})", f"url(#{new})")
        inner = inner.replace(f'href="#{old}"', f'href="#{new}"')
    return inner, max(vb_w, vb_h)


def wrap(text: str, width: int = LABEL_MAX) -> list[str]:
    words, lines, cur = text.split(), [], ""
    for w in words:
        trial = f"{cur} {w}".strip()
        if len(trial) <= width:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


# ---------------------------------------------------------------- render ---

def render(spec: dict) -> str:
    W = spec.get("width", 1280)
    H = spec.get("height", 720)
    out: list[str] = []

    alt = spec.get("alt") or spec.get("title", "Architecture diagram")
    out.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
        f'width="{W}" height="{H}" role="img" aria-label="{escape(alt)}">'
    )
    out.append(
        "<!-- Generated by scripts/render_azure_diagram.py from the committed "
        "JSON spec beside this file. Do not hand-edit: regenerate.\n"
        "     Azure icons are official, used unmodified under Microsoft's icon "
        "terms, which permit use in architectural diagrams and documentation. -->"
    )
    out.append(
        '<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" '
        'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{EDGE}"/></marker></defs>'
    )
    out.append(f'<rect x="0" y="0" width="{W}" height="{H}" fill="#ffffff"/>')

    if spec.get("title"):
        out.append(
            f'<text x="28" y="34" {FONT} font-size="15" font-weight="700" '
            f'fill="{INK}">{escape(spec["title"])}</text>'
        )

    # groups first, so connectors and icons sit on top
    for g in spec.get("groups", []):
        style = g.get("style", "logical")
        x, y, w, h = g["x"], g["y"], g["w"], g["h"]
        if style == "vnet":
            out.append(
                f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" '
                f'fill="none" stroke="{VNET}" stroke-width="1.6" '
                f'stroke-dasharray="7 5"/>'
            )
            if g.get("label"):
                out.append(
                    f'<text x="{x + w - 12}" y="{y + h - 12}" {FONT} '
                    f'font-size="12" fill="{VNET}" text-anchor="end">'
                    f'{escape(g["label"])}</text>'
                )
        else:
            out.append(
                f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="4" '
                f'fill="{GROUP_FILL}" stroke="{GROUP_LINE}" stroke-width="1.2"/>'
            )
            if g.get("label"):
                out.append(
                    f'<text x="{x + w / 2}" y="{y + 20}" {FONT} font-size="13" '
                    f'fill="{INK}" text-anchor="middle">{escape(g["label"])}</text>'
                )
        if g.get("note"):
            out.append(
                f'<text x="{x + 10}" y="{y + h - 10}" {FONT} font-size="11" '
                f'fill="{MUTED}">{escape(g["note"])}</text>'
            )

    nodes = {n["id"]: n for n in spec.get("nodes", [])}

    # edges under the icons
    for e in spec.get("edges", []):
        a, b = nodes.get(e["from"]), nodes.get(e["to"])
        if not a or not b:
            raise SystemExit(f"edge references unknown node: {e}")
        pts = [(a["x"], a["y"])] + [tuple(p) for p in e.get("via", [])] + [(b["x"], b["y"])]
        pts = trim_endpoints(pts, a, b)
        d = "M" + " L".join(f"{px},{py}" for px, py in pts)
        dash = ' stroke-dasharray="6 4"' if e.get("style") == "dashed" else ""
        out.append(
            f'<path d="{d}" fill="none" stroke="{EDGE}" stroke-width="1.8"'
            f'{dash} marker-end="url(#arw)"/>'
        )
        if e.get("label"):
            lx, ly = edge_label_pos(pts, e)
            for i, line in enumerate(wrap(e["label"], 22)):
                out.append(
                    f'<text x="{lx}" y="{ly + i * 12}" {FONT} font-size="11" '
                    f'fill="{MUTED}" text-anchor="middle">{escape(line)}</text>'
                )

    # nodes
    for idx, n in enumerate(spec.get("nodes", [])):
        if not n.get("label"):
            raise SystemExit(
                f"node {n.get('id')} has no label. Microsoft's icon guidance is "
                f"to include the product name near the icon, so this is an error."
            )
        inner, vb = load_icon(n["icon"], f"n{idx}")
        s = ICON_PX / vb                      # uniform. never anything else.
        ix, iy = n["x"] - ICON_PX / 2, n["y"] - ICON_PX / 2
        out.append(f'<g transform="translate({ix},{iy}) scale({s:.6f})">{inner}</g>')
        ty = n["y"] + ICON_PX / 2 + LABEL_DY
        for i, line in enumerate(wrap(n["label"])):
            out.append(
                f'<text x="{n["x"]}" y="{ty + i * LABEL_LH}" {FONT} '
                f'font-size="12.5" fill="{INK}" text-anchor="middle">'
                f'{escape(line)}</text>'
            )

    out.append("</svg>")
    return "\n".join(out)


def label_block(node) -> float:
    """Vertical space the node's label occupies below the icon box."""
    lines = len(wrap(node["label"]))
    return LABEL_DY + (lines - 1) * LABEL_LH + 8


def trim_endpoints(pts, a, b):
    """Pull the first and last point back clear of the icon AND its label.

    A node's label hangs below its icon, so any connector that leaves or
    arrives from underneath has to clear the text as well as the glyph.
    Without this, the week 11 draft drew the identity arrow straight through
    the words "Prometheus 3.5.0", and both read arrows began inside the
    "Azure Monitor workspace" caption. Padding by the icon radius alone is
    only correct for horizontal edges.
    """
    def pull(p, q, amount):
        (x1, y1), (x2, y2) = p, q
        dx, dy = x2 - x1, y2 - y1
        dist = (dx * dx + dy * dy) ** 0.5 or 1
        return (round(x1 + dx / dist * amount, 1), round(y1 + dy / dist * amount, 1))

    base = ICON_PX / 2 + 6
    pts = list(pts)

    leaves_downward = pts[1][1] > pts[0][1]
    start_pad = ICON_PX / 2 + label_block(a) if leaves_downward else base

    arrives_from_below = pts[-2][1] > pts[-1][1]
    end_pad = ICON_PX / 2 + label_block(b) if arrives_from_below else base

    pts[0] = pull(pts[0], pts[1], start_pad)
    pts[-1] = pull(pts[-1], pts[-2], end_pad)
    return pts


def edge_label_pos(pts, e):
    if "label_at" in e:
        return tuple(e["label_at"])
    mid = len(pts) // 2
    if len(pts) % 2 == 0:
        (x1, y1), (x2, y2) = pts[mid - 1], pts[mid]
        return ((x1 + x2) / 2, (y1 + y2) / 2 - 8)
    x, y = pts[mid]
    return (x, y - 8)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    spec_path = Path(sys.argv[1])
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    svg = render(spec)
    out_path = spec_path.with_suffix(".svg")
    out_path.write_text(svg, encoding="utf-8", newline="\n")
    print(f"wrote {out_path.name} at {spec.get('width', 1280)}x{spec.get('height', 720)} "
          f"({len(spec.get('nodes', []))} nodes, {len(spec.get('edges', []))} edges)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
