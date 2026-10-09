#!/usr/bin/env python3
"""
preview.py — a static SVG of a board build_model.py rendered, for readers without Excalidraw
(a PR, a chat, a quick look). Covers the element subset the renderer emits: frames,
rectangles with bound text, labels, arrows. Not a general Excalidraw exporter.

    python3 preview.py board.excalidraw out.svg
    rsvg-convert -w 2400 out.svg -o out.png        # optional raster
"""
import json
import math
import sys
from xml.sax.saxutils import escape

FONT = "Helvetica, Arial, sans-serif"


def _text_lines(el):
    size, lh = el["fontSize"], el.get("lineHeight", 1.25)
    out = []
    for i, line in enumerate(el["text"].split("\n")):
        base = el["y"] + i * size * lh + size * 0.82
        if el.get("containerId") or el.get("textAlign") == "center":
            x, anchor = el["x"] + el["width"] / 2, "middle"
        else:
            x, anchor = el["x"], "start"
        rot = ""
        if el.get("angle"):
            cx, cy = el["x"] + el["width"] / 2, el["y"] + el["height"] / 2
            rot = f' transform="rotate({math.degrees(el["angle"]):.2f} {cx:.1f} {cy:.1f})"'
        out.append(f'<text x="{x:.1f}" y="{base:.1f}" font-size="{size}" font-family="{FONT}" '
                   f'fill="{el["strokeColor"]}" text-anchor="{anchor}"{rot}>{escape(line)}</text>')
    return out


def svg(doc):
    els = [e for e in doc["elements"] if not e.get("isDeleted")]
    xs, ys = [], []
    for e in els:
        if e["type"] == "arrow":
            xs += [e["x"] + p[0] for p in e["points"]]
            ys += [e["y"] + p[1] for p in e["points"]]
        else:
            xs += [e["x"], e["x"] + e["width"]]
            ys += [e["y"], e["y"] + e["height"]]
    m = 60
    x0, y0, x1, y1 = min(xs) - m, min(ys) - m, max(xs) + m, max(ys) + m
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
           f'viewBox="{x0:.0f} {y0:.0f} {x1 - x0:.0f} {y1 - y0:.0f}" width="{x1 - x0:.0f}" height="{y1 - y0:.0f}">',
           '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
           'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#ced4da"/></marker></defs>',
           f'<rect x="{x0:.0f}" y="{y0:.0f}" width="{x1 - x0:.0f}" height="{y1 - y0:.0f}" fill="white"/>']
    for e in els:
        t = e["type"]
        if t == "frame":
            out.append(f'<rect x="{e["x"]:.1f}" y="{e["y"]:.1f}" width="{e["width"]:.1f}" height="{e["height"]:.1f}" '
                       f'fill="none" stroke="#bbbbbb" stroke-width="2" rx="8"/>')
            if e.get("name"):
                out.append(f'<text x="{e["x"]:.1f}" y="{e["y"] - 8:.1f}" font-size="14" font-family="{FONT}" '
                           f'fill="#868e96">{escape(e["name"])}</text>')
        elif t == "rectangle":
            rot = ""
            if e.get("angle"):
                cx, cy = e["x"] + e["width"] / 2, e["y"] + e["height"] / 2
                rot = f' transform="rotate({math.degrees(e["angle"]):.2f} {cx:.1f} {cy:.1f})"'
            rect = (f'<rect x="{e["x"]:.1f}" y="{e["y"]:.1f}" width="{e["width"]:.1f}" height="{e["height"]:.1f}" '
                    f'fill="{e["backgroundColor"]}" stroke="{e["strokeColor"]}" stroke-width="{e["strokeWidth"]}" rx="3"{rot}/>')
            out.append(f'<a xlink:href="{escape(e["link"])}">{rect}</a>' if e.get("link") else rect)
        elif t == "text":
            out += _text_lines(e)
        elif t == "arrow":
            pts = " ".join(f'{e["x"] + p[0]:.1f},{e["y"] + p[1]:.1f}' for p in e["points"])
            dash = ' stroke-dasharray="3,5"' if e.get("strokeStyle") == "dotted" else ""
            head = ' marker-end="url(#arrow)"' if e.get("endArrowhead") == "arrow" else ""
            out.append(f'<polyline points="{pts}" fill="none" stroke="{e["strokeColor"]}" '
                       f'stroke-width="{e["strokeWidth"]}"{dash}{head}/>')
    out.append("</svg>")
    return "\n".join(out)


def main(argv):
    if len(argv) != 3:
        print((__doc__ or "").strip())
        return 2
    with open(argv[2], "w") as f:
        f.write(svg(json.load(open(argv[1]))))
    print(f"wrote {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
