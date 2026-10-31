#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Find text that spills out of a diagram, or collides with other text.

    python scripts/check_diagram_layout.py                     # every week
    python scripts/check_diagram_layout.py week-05-hub-network # one week
    python scripts/check_diagram_layout.py --self-test

Why this exists (2026-10-30)
----------------------------
Jay, looking at the published labs: "ensure they look good. No text coming out
of box and words overlapping." Those are the two defects, and neither is
visible to any check this repo had -- an SVG with text hanging off the canvas
is perfectly well-formed XML, so every structural gate passes it.

It is measured, not estimated. Guessing a string's width from character count
and font-size is wrong often enough to be useless: proportional fonts, bold
runs, and <tspan> all break it. So the SVG is loaded in Chromium and every
text node's real rendered box is read with getBBox(), the same numbers the
browser drew with.

What it reports
---------------
  OVERFLOW  a text box crosses the edge of the viewBox, so it is clipped or
            hanging in space
  OUTSIDE   a text box escapes the panel rect it sits in -- the "coming out of
            the box" case, matched to the smallest rect that contains the
            text's midpoint
  OVERLAP   two text boxes intersect by more than a hair, so the words sit on
            top of each other

A hair is TOLERANCE px. Text that merely touches is not a defect; kerning and
descenders routinely produce a pixel of contact, and flagging that would make
the check noise and therefore ignored.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

LAB = pathlib.Path(__file__).resolve().parent.parent
TOLERANCE = 1.5          # px of horizontal contact that is not a collision

# Vertical tolerance is larger, and the asymmetry is the point. A text node's
# getBBox includes ascender and descender space, so two STACKED lines of one
# wrapped label -- "Azure Monitor" over "workspace" -- report 2-3px of vertical
# box intersection while being perfectly legible. Words genuinely written on
# top of each other share a baseline and intersect by the full glyph height,
# 12-16px here. 5px separates the two cleanly.
#
# Measured: the first run of this check flagged all seven stacked labels in the
# week 11 diagram as overlaps. Every one was typography, not a defect. A check
# that cries wolf on correct output is a check that gets switched off.
TOLERANCE_Y = 5.0
EDGE_SLACK = 0.5         # px a glyph may sit outside the viewBox

ARROW_PAD = 2.0          # px inside a text box before a connector counts as crossing it
ZONE_AREA = 0.15        # a rect bigger than this share of the canvas is a zone, not a box

MEASURE_JS = """
(ZONE_AREA) => {
  const svg = document.querySelector('svg');
  const vb = svg.viewBox.baseVal;
  const texts = [], rects = [];
  for (const t of svg.querySelectorAll('text')) {
    const s = (t.textContent || '').trim();
    if (!s) continue;
    let b;
    try { b = t.getBBox(); } catch (e) { continue; }
    if (!b || b.width === 0) continue;
    texts.push({s, x: b.x, y: b.y, w: b.width, h: b.height});
  }
  for (const r of svg.querySelectorAll('rect')) {
    let b;
    try { b = r.getBBox(); } catch (e) { continue; }
    const fill = (r.getAttribute('fill') || '').toLowerCase();
    // Neither the full-canvas background nor a layout ZONE is a panel.
    // A connector label legitimately sits in the gap between zones and so
    // crosses a zone edge -- week 09's "logs" does exactly that, correctly,
    // and was reported as escaping until this excluded it. A zone here is any
    // rect over ZONE_AREA of the canvas; week 09's band is 20.3%, the content
    // boxes that genuinely clip their text are under 5%.
    if (b.width >= vb.width - 2 && b.height >= vb.height - 2) continue;
    if (b.width * b.height > ZONE_AREA * vb.width * vb.height) continue;
    rects.push({x: b.x, y: b.y, w: b.width, h: b.height, fill});
  }
  // Connectors, sampled along their real geometry.
  //
  // Not bounding boxes: a diagonal arrow's bbox covers a large rectangle it
  // never actually crosses, which would report collisions that are not there.
  // getPointAtLength walks the drawn line itself and works for <line>,
  // <path> and <polyline> alike.
  const arrows = [];
  for (const el of svg.querySelectorAll('line, path, polyline')) {
    if (el.closest('marker') || el.closest('defs')) continue;   // arrowheads
    let len = 0;
    try { len = el.getTotalLength(); } catch (e) { continue; }
    if (!len || len < 2) continue;
    const pts = [];
    const steps = Math.max(8, Math.min(140, Math.round(len / 3)));
    for (let i = 0; i <= steps; i++) {
      const pt = el.getPointAtLength(len * i / steps);
      pts.push({x: pt.x, y: pt.y});
    }
    arrows.push({pts, len});
  }
  return {vb: {x: vb.x, y: vb.y, w: vb.width, h: vb.height}, texts, rects, arrows};
}
"""


def intersect(a, b):
    ox = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
    oy = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
    return ox, oy


def smallest_container(t, rects):
    """The tightest rect containing where the text STARTS.

    Not its midpoint. A text that overflows its panel badly has its midpoint
    outside the panel, so midpoint matching finds no container and silently
    reports nothing -- which is exactly the case this check exists for. Caught
    by the self-test, which is the only reason it is not still wrong.
    """
    mx = t["x"] + min(5.0, t["w"] / 2)
    my = t["y"] + t["h"] / 2
    best = None
    for r in rects:
        if r["x"] <= mx <= r["x"] + r["w"] and r["y"] <= my <= r["y"] + r["h"]:
            if best is None or r["w"] * r["h"] < best["w"] * best["h"]:
                best = r
    return best


def audit(page, svg_path: pathlib.Path):
    page.goto(svg_path.resolve().as_uri())
    page.wait_for_timeout(350)
    data = page.evaluate(MEASURE_JS, ZONE_AREA)
    vb, texts, rects = data["vb"], data["texts"], data["rects"]
    problems = []

    for t in texts:
        label = t["s"][:46]
        if (t["x"] < vb["x"] - EDGE_SLACK
                or t["y"] < vb["y"] - EDGE_SLACK
                or t["x"] + t["w"] > vb["x"] + vb["w"] + EDGE_SLACK
                or t["y"] + t["h"] > vb["y"] + vb["h"] + EDGE_SLACK):
            over = round(max(
                vb["x"] - t["x"],
                vb["y"] - t["y"],
                (t["x"] + t["w"]) - (vb["x"] + vb["w"]),
                (t["y"] + t["h"]) - (vb["y"] + vb["h"])), 1)
            problems.append(("OVERFLOW", f'"{label}" past the canvas edge by {over}px'))
            continue

        box = smallest_container(t, rects)
        if box:
            out = round(max(box["x"] - t["x"],
                            (t["x"] + t["w"]) - (box["x"] + box["w"])), 1)
            if out > TOLERANCE:
                problems.append(("OUTSIDE", f'"{label}" escapes its panel by {out}px'))

    # --- connectors ------------------------------------------------------
    for a in data.get("arrows", []):
        pts = a["pts"]
        off = [p for p in pts
               if p["x"] < vb["x"] - EDGE_SLACK
               or p["y"] < vb["y"] - EDGE_SLACK
               or p["x"] > vb["x"] + vb["w"] + EDGE_SLACK
               or p["y"] > vb["y"] + vb["h"] + EDGE_SLACK]
        if off:
            p0 = off[0]
            problems.append(("ARROW-OFF",
                             f'a connector leaves the canvas near '
                             f'({round(p0["x"])},{round(p0["y"])})'))
            continue

        for t in texts:
            # ignore the first and last few samples: an arrow legitimately
            # starts and ends beside its own label
            inner = pts[2:-2] if len(pts) > 6 else []
            hit = [p for p in inner
                   if t["x"] + ARROW_PAD <= p["x"] <= t["x"] + t["w"] - ARROW_PAD
                   and t["y"] + ARROW_PAD <= p["y"] <= t["y"] + t["h"] - ARROW_PAD]
            if len(hit) >= 2:
                problems.append(("ARROW-THRU",
                                 f'a connector runs through the words '
                                 f'"{t["s"][:34]}"'))
                break

    for i in range(len(texts)):
        for j in range(i + 1, len(texts)):
            ox, oy = intersect(texts[i], texts[j])
            if ox > TOLERANCE and oy > TOLERANCE_Y:
                problems.append((
                    "OVERLAP",
                    f'"{texts[i]["s"][:28]}" over "{texts[j]["s"][:28]}" '
                    f'({round(ox,1)}x{round(oy,1)}px)'))

    return problems, len(texts)


def self_test(page) -> int:
    """Prove the check can fail, on a diagram built to contain each defect."""
    bad = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" '
           'width="200" height="100">'
           '<rect x="0" y="0" width="200" height="100" fill="#fff"/>'
           '<rect x="10" y="10" width="60" height="30" fill="none" stroke="#000"/>'
           '<text x="14" y="30" font-size="12">overflowing the panel badly</text>'
           '<text x="20" y="70" font-size="12">collide</text>'
           '<text x="20" y="70" font-size="12">collide</text>'
           '<text x="150" y="95" font-size="12">off the right edge entirely</text>'
           # a connector that leaves the canvas, and one driven through words
           '<line x1="100" y1="50" x2="260" y2="50" stroke="#000"/>'
           '<text x="20" y="20" font-size="12">speared</text>'
           '<line x1="5" y1="16" x2="90" y2="16" stroke="#000"/>'
           '</svg>')
    tmp = LAB / "scripts" / ".diagram-selftest.svg"
    tmp.write_text(bad, encoding="utf-8")
    try:
        problems, _ = audit(page, tmp)
    finally:
        tmp.unlink(missing_ok=True)
    kinds = {k for k, _ in problems}
    ok = True
    for want in ("OVERFLOW", "OUTSIDE", "OVERLAP", "ARROW-OFF", "ARROW-THRU"):
        hit = want in kinds
        ok &= hit
        print(f"  [{' ok ' if hit else 'FAIL'}] detects {want}")
    if not ok:
        print("\nSELF-TEST FAILED: the check cannot see the defects it exists for.")
        return 1
    print("\nself-test passed: overflow, panel escape, text collision, a connector leaving the canvas, and a connector driven through words are all detected.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("weeks", nargs="*", help="substring of a week folder")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("playwright is required to MEASURE text boxes. Refusing to guess "
              "widths from character counts -- that is wrong often enough to be "
              "useless.")
        return 2

    svgs = sorted(LAB.glob("week-*/docs/blog/diagrams/*.svg"))
    if args.weeks:
        svgs = [s for s in svgs if any(a in str(s) for a in args.weeks)]

    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1400, "height": 900})
        try:
            if args.self_test:
                return self_test(page)

            if not svgs:
                print("NOTHING MATCHED. A check that measured no diagram has not "
                      "passed -- fix the week substring.")
                return 1

            total = 0
            for svg in svgs:
                problems, n = audit(page, svg)
                total += len(problems)
                head = f"{svg.parent.parent.parent.parent.name}/{svg.name}"
                if problems:
                    print(f"\n  {head}  ({n} text nodes)")
                    for kind, msg in problems:
                        print(f"     [{kind}] {msg}")
                else:
                    print(f"  ok  {head}  ({n} text nodes)")
            print(f"\n  {len(svgs)} diagram(s), {total} problem(s).")
            return 1 if total else 0
        finally:
            b.close()


if __name__ == "__main__":
    raise SystemExit(main())
