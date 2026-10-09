#!/usr/bin/env python3
"""
build_model.py — render an EventStorming process model to an .excalidraw file,
refusing to render one that breaks Brandolini's colour grammar.

    python3 build_model.py model.json out.excalidraw [--no-reference]

The point of this script is the validator. Colour grammar is easy to agree with
and easy to violate: a blue command wired straight to an orange event reads fine
to the author and is wrong. So the grammar is enforced here rather than trusted,
and a violation is a non-zero exit with the offending slot named.

INPUT (model.json)
------------------
{
  "title":    "acme-billing — Process Modeling EventStorming",
  "subtitle": "optional; one or more lines of provenance",
  "chains": [
    {
      "title": "1 · A customer subscribes",
      "blurb": "one line on what this story is and why it matters",
      "slots": [
        {"kind": "read",    "text": "PLANS\\nprice and billing period"},
        {"kind": "person",  "text": "Customer"},
        {"kind": "command", "text": "Subscribe to a plan"},
        {"kind": "system",  "text": "billing-api\\nPOST /subscriptions"},
        {"kind": "event",   "text": "Subscription started",
         "under": [
           {"kind": "event", "text": "Subscribe refused\\nthe card was declined"},
           {"kind": "read",  "text": "ACCOUNT\\ncurrent plan and next charge"},
           {"kind": "hotspot", "text": "Does a failed card retry, or drop them?"}
         ]}
      ]
    }
  ]
}

KINDS
-----
  read     green    a projection someone consults before deciding
  person   yellow   who decides (small sticky)
  command  blue     an action, present tense
  system   pink     whatever executes it — name it specifically
  event    orange   a state transition, PAST tense
  time     orange   a time trigger; prefix the text "TIME · "
  policy   lilac    "Whenever <event> then <command>"
  hotspot  magenta  what could not be settled from the code

`under` hangs a sticky off the line: alternative-outcome events under an event,
read models the event feeds, and hotspots. Blue and pink may never go there —
if a command belongs in the story it belongs on the line, with its own system.

Each chain is rendered inside a named Excalidraw frame, and a long chain wraps
onto a new row at the point a different person decides (the read models that
inform them come along). `"wrap": false` on a chain keeps it on one row.

Beside the board it writes <stem>.hotspots.md (the register), <stem>.sipoc.md
(a SIPOC derived from the chains; see sipoc.py, and the optional per-chain
"sipoc" override) and <stem>.logic-model.md (inputs, activities and outputs
derived; outcomes and impact from the optional top-level "logic_model" block,
since intent is not in the code; see logic_model.py).
"""

import json
import os
import re
import sys

# --------------------------------------------------------------------- grammar
#   "There has to be a Pink System between a Blue Command and an Orange Event,
#    there has to be a Lilac Policy between an Orange Event and a Blue Command."
#                                    — Brandolini, Introducing EventStorming
FOLLOWS = {
    "read":    {"read", "person"},              # read models inform a person
    "person":  {"command"},                     # a person decides to issue a command
    "command": {"system"},                      # PINK between BLUE and ORANGE
    "system":  {"system", "event"},             # a system produces an event
    "event":   {"event", "policy", "read", "person"},
    "time":    {"policy", "event"},             # time triggers, a policy reacts
    "policy":  {"command"},                     # LILAC between ORANGE and BLUE
}
PRECEDES = {
    "command": {"person", "policy"},            # never straight off an event
    "event":   {"system", "event", "time"},     # never straight off a command
    "system":  {"command", "system"},
    "policy":  {"event", "time"},
}
UNDER_OK = {"event", "time", "read", "hotspot"}
KINDS = set(FOLLOWS) | {"hotspot"}


def _a(k):
    return ("an " if k[0] in "aeiou" else "a ") + k


def _src_ok(v):
    """Provenance is `path` or `path:line`, relative to the repo the board describes."""
    return isinstance(v, str) and re.fullmatch(r"[^:\s]+(:\d+)?", v) is not None


def validate(model):
    errs = []
    chains = model.get("chains")
    if not isinstance(chains, list) or not chains:
        return ["model has no 'chains' array"]
    for lo in model.get("left_off") or []:
        if not (isinstance(lo, dict) and isinstance(lo.get("route"), str) and isinstance(lo.get("why"), str)):
            errs.append("left_off entries need 'route' and 'why' strings")
            break
    lm = model.get("logic_model")
    if lm is not None:
        def strs(v):
            return isinstance(v, list) and all(isinstance(x, str) for x in v)
        ok = (isinstance(lm, dict) and set(lm) <= {"outcomes", "impact", "assumptions", "external_factors"}
              and all(strs(lm[k]) for k in ("impact", "assumptions", "external_factors") if k in lm)
              and ("outcomes" not in lm or (isinstance(lm["outcomes"], dict) and set(lm["outcomes"]) <= {"short", "medium", "long"}
                                             and all(strs(v) for v in lm["outcomes"].values()))))
        if not ok:
            errs.append("logic_model may hold outcomes {short|medium|long: [str]}, impact, assumptions, external_factors (lists of strings)")
    for ci, ch in enumerate(chains):
        name = ch.get("title", f"chain {ci}")
        slots = ch.get("slots") or []
        if not slots:
            errs.append(f"{name}: no slots")
            continue
        if "wrap" in ch and not isinstance(ch["wrap"], bool):
            errs.append(f"{name}: 'wrap' must be true or false")
        sp = ch.get("sipoc")
        if sp is not None and not (isinstance(sp, dict) and set(sp) <= {"suppliers", "inputs", "outputs", "customers"}
                                   and all(isinstance(v, list) and all(isinstance(x, str) for x in v) for v in sp.values())):
            errs.append(f"{name}: 'sipoc' may only override suppliers/inputs/outputs/customers, each a list of strings")
        kinds = []
        for si, s in enumerate(slots):
            k = s.get("kind")
            if k not in KINDS:
                errs.append(f"{name}: slot {si} has unknown kind {k!r}")
                kinds.append(None)
                continue
            if k == "hotspot":
                errs.append(f"{name}: slot {si} — a hotspot belongs in 'under', not on the line")
            if not (isinstance(s.get("text"), str) and s["text"].strip()):
                errs.append(f"{name}: slot {si} ({k}) has no text")
            if "src" in s and not _src_ok(s["src"]):
                errs.append(f"{name}: slot {si} has a malformed src {s['src']!r} — use path or path:line")
            kinds.append(k)
        # Adjacency. A hotspot on the line is already reported, so it is skipped here
        # rather than making both its neighbours complain too. One bad pair gets one
        # message: the FOLLOWS rule, or the mirror PRECEDES rule only if FOLLOWS passed.
        line = [(i, k) for i, k in enumerate(kinds) if k != "hotspot"]
        for (i, k), (j, nxt) in zip(line, line[1:]):
            if k is None or nxt is None:
                continue
            if nxt not in FOLLOWS[k]:
                errs.append(
                    f"{name}: {k} → {nxt} (slot {i}→{j}) — "
                    f"{_a(k)} may only be followed by {sorted(FOLLOWS[k])}"
                )
            elif nxt in PRECEDES and k not in PRECEDES[nxt]:
                errs.append(
                    f"{name}: {k} → {nxt} (slot {i}→{j}) — "
                    f"{_a(nxt)} may only follow {sorted(PRECEDES[nxt])}"
                )
        tail = [(i, k) for i, k in line if k]
        if tail and tail[-1][1] != "event":
            i, k = tail[-1]
            errs.append(f"{name}: ends on {_a(k)} (slot {i}) — a story ends on what changed, an event")
        for si, s in enumerate(slots):
            for u in s.get("under") or []:
                uk = u.get("kind")
                if not (isinstance(u.get("text"), str) and u["text"].strip()):
                    errs.append(f"{name}: slot {si} has an off-line {uk!r} with no text")
                if "src" in u and not _src_ok(u["src"]):
                    errs.append(f"{name}: slot {si} has an off-line {uk!r} with a malformed src {u['src']!r}")
                if uk not in UNDER_OK:
                    errs.append(
                        f"{name}: slot {si} has an off-line {uk!r} — "
                        f"only {sorted(UNDER_OK)} may hang off the line"
                    )
                elif uk in ("event", "time") and s.get("kind") not in ("event", "time"):
                    errs.append(
                        f"{name}: slot {si} — an alternative-outcome {uk} hangs off "
                        f"a {s.get('kind')}, not an event"
                    )
    return errs


# ------------------------------------------------------------------- rendering
FONT, LH, CHAR, INK = 1, 1.25, 0.545, "#1e1e1e"
#  kind      : (background, ink, width, min-height, font, tilt)
STYLE = {
    "event":   ("#f5811f", INK,       190, 130, 14, 0.0),
    "time":    ("#f5811f", INK,       190, 130, 14, 0.0),
    "command": ("#2f9be0", INK,       190, 130, 14, 0.0),
    "system":  ("#f9cfe0", INK,       250, 112, 14, 0.0),
    "policy":  ("#dcbcf0", INK,       300, 130, 14, 0.0),
    "read":    ("#8ec63f", INK,       190, 130, 13, 0.0),
    "person":  ("#ffee58", INK,        98, 112, 12, 0.0),
    "hotspot": ("#e6007e", "#ffffff", 200, 118, 13, 0.30),
}
GAP, X0 = 26, 140


class Board:
    def __init__(self, root=None):
        self.els, self.bound, self.n = [], {}, 7000
        self.root = root            # repo the `src` fields are relative to; enables editor links

    def _id(self, p):
        self.n += 1
        return f"{p}-{self.n}"

    def _link(self, src):
        """vscode://file/<abs>:<line> when the source exists under root, else no link."""
        if not (src and self.root):
            return None
        path, _, line = src.partition(":")
        abs_path = os.path.abspath(os.path.join(self.root, path))
        if not os.path.exists(abs_path):
            return None
        return f"vscode://file/{abs_path}" + (f":{line}" if line else "")

    def footnote(self, b):
        """Small grey provenance line under a sticky."""
        if b.get("src"):
            self.label(b["src"], b["x"], b["y"] + b["h"] + 3, 9, "#868e96")

    @staticmethod
    def _wrap(text, font, maxw):
        maxc = max(1, int(maxw / (font * CHAR)))
        out = []
        for para in text.split("\n"):
            words = []
            for w in para.split(" "):
                while len(w) > maxc:                   # a URL or dotted path wider than the sticky
                    cut = max([i for i in range(1, maxc) if w[i - 1] in "/?.&=_-"] or [maxc])
                    words.append(w[:cut])
                    w = w[cut:]
                words.append(w)
            line = ""
            for w in words:
                trial = w if not line else line + " " + w
                if len(trial) <= maxc:
                    line = trial
                else:
                    if line:
                        out.append(line)
                    line = w
            out.append(line)
        return out

    def sticky(self, kind, text, x, y, w=None, src=None):
        bg, ink, dw, minh, font, tilt = STYLE[kind]
        if kind == "time" and not text.upper().startswith("TIME"):
            text = "TIME · " + text          # same colour as an event; the prefix is what tells them apart
        w, pad = w or dw, 9
        lines = self._wrap(text, font, w - 2 * pad)
        th = len(lines) * font * LH
        h = max(minh, th + 2 * pad + 8)
        cid, tid = self._id(kind), self._id("t")
        self.els.append({
            "type": "rectangle", "id": cid, "x": x, "y": y, "width": w, "height": h,
            "angle": tilt, "strokeColor": INK, "backgroundColor": bg, "fillStyle": "solid",
            "strokeWidth": 2, "strokeStyle": "solid", "roughness": 1, "opacity": 100,
            "groupIds": [], "frameId": None, "roundness": None, "seed": self.n * 7 % 900000,
            "version": 1, "versionNonce": self.n * 13 % 900000, "isDeleted": False,
            "boundElements": [{"type": "text", "id": tid}], "updated": 1,
            "link": self._link(src), "locked": False})
        self.els.append({
            "type": "text", "id": tid, "x": x + pad, "y": y + (h - th) / 2,
            "width": w - 2 * pad, "height": th, "angle": tilt, "strokeColor": ink,
            "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 1,
            "strokeStyle": "solid", "roughness": 0, "opacity": 100, "groupIds": [],
            "frameId": None, "roundness": None, "seed": self.n * 11 % 900000, "version": 1,
            "versionNonce": self.n * 17 % 900000, "isDeleted": False, "boundElements": None,
            "updated": 1, "link": None, "locked": False, "fontSize": font,
            "fontFamily": FONT, "text": "\n".join(lines), "textAlign": "center",
            "verticalAlign": "middle", "containerId": cid, "originalText": text,
            "autoResize": False, "lineHeight": LH})
        self.bound[cid] = []
        return {"id": cid, "x": x, "y": y, "w": w, "h": h, "src": src}

    def label(self, text, x, y, size=20, color=INK):
        lines = text.split("\n")
        self.els.append({
            "type": "text", "id": self._id("lbl"), "x": x, "y": y,
            "width": max(len(l) for l in lines) * size * CHAR,
            "height": len(lines) * size * LH, "angle": 0, "strokeColor": color,
            "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 1,
            "strokeStyle": "solid", "roughness": 0, "opacity": 100, "groupIds": [],
            "frameId": None, "roundness": None, "seed": self.n * 3 % 900000, "version": 1,
            "versionNonce": self.n * 5 % 900000, "isDeleted": False, "boundElements": None,
            "updated": 1, "link": None, "locked": False, "fontSize": size,
            "fontFamily": FONT, "text": text, "textAlign": "left", "verticalAlign": "top",
            "containerId": None, "originalText": text, "autoResize": True, "lineHeight": LH})

    def _line(self, x, y, w, h, color, style, head, a=None, b=None):
        aid = self._id("conn")
        self.els.append({
            "type": "arrow", "id": aid, "x": x, "y": y, "width": abs(w), "height": abs(h),
            "angle": 0, "strokeColor": color, "backgroundColor": "transparent",
            "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": style, "roughness": 0,
            "opacity": 100, "groupIds": [], "frameId": None, "roundness": {"type": 2},
            "seed": self.n * 29 % 900000, "version": 1, "versionNonce": self.n * 31 % 900000,
            "isDeleted": False, "boundElements": None, "updated": 1, "link": None,
            "locked": False, "points": [[0, 0], [w, h]], "lastCommittedPoint": None,
            "startBinding": {"elementId": a["id"], "focus": 0, "gap": 4} if a else None,
            "endBinding": {"elementId": b["id"], "focus": 0, "gap": 4} if b else None,
            "startArrowhead": None, "endArrowhead": head, "elbowed": False})
        for e in (a, b):
            if e:
                self.bound.setdefault(e["id"], []).append({"id": aid, "type": "arrow"})

    def tether(self, a, b):
        """Faint dotted line to an off-line sticky. Not notation — a concession to
        reading the board without a facilitator standing next to it."""
        sx, sy = a["x"] + a["w"] / 2, a["y"] + a["h"]
        ex, ey = b["x"] + b["w"] / 2, b["y"]
        self._line(sx, sy, ex - sx, ey - sy, "#adb5bd", "dotted", None, a, b)

    def timeline(self, x, y, w):
        self._line(x, y, w, 0, "#ced4da", "solid", "arrow")

    @staticmethod
    def _bbox(e):
        if e["type"] == "arrow":
            xs = [e["x"] + p[0] for p in e["points"]]
            ys = [e["y"] + p[1] for p in e["points"]]
            return min(xs), min(ys), max(xs), max(ys)
        return e["x"], e["y"], e["x"] + e["width"], e["y"] + e["height"]

    def frame(self, start, name, pad=40):
        """Wrap everything appended since `start` in a named frame, so a chain can be
        selected, collapsed or exported on its own and shows up in Excalidraw's frame list."""
        kids = self.els[start:]
        if not kids:
            return
        boxes = [self._bbox(e) for e in kids]
        x0, y0 = min(b[0] for b in boxes) - pad, min(b[1] for b in boxes) - pad
        x1, y1 = max(b[2] for b in boxes) + pad, max(b[3] for b in boxes) + pad
        fid = self._id("frame")
        for e in kids:
            e["frameId"] = fid
        self.els.insert(start, {
            "type": "frame", "id": fid, "x": x0, "y": y0, "width": x1 - x0, "height": y1 - y0,
            "angle": 0, "strokeColor": "#bbbbbb", "backgroundColor": "transparent", "fillStyle": "solid",
            "strokeWidth": 2, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "groupIds": [],
            "frameId": None, "roundness": None, "seed": self.n * 37 % 900000, "version": 1,
            "versionNonce": self.n * 41 % 900000, "isDeleted": False, "boundElements": [],
            "updated": 1, "link": None, "locked": False, "name": name})

    @staticmethod
    def _rows(slots):
        """Split where a different person decides: a new row starts at each person after the
        first, taking the read models that inform them along. Layout only; the model is one chain."""
        rows, cur = [], []
        for i, s in enumerate(slots):
            if s["kind"] == "person" and i:
                reads = []
                while cur and cur[-1]["kind"] == "read":
                    reads.insert(0, cur.pop())
                if cur:
                    rows.append(cur)
                cur = reads
            cur.append(s)
        rows.append(cur)
        return rows

    def chain(self, title, blurb, slots, y, wrap=True):
        start = len(self.els)
        if title:
            self.label(title, X0, y, 24)
        if blurb:
            self.label(blurb, X0, y + 32, 15, "#495057")
        top = y + (82 if title else 20)
        for row in (self._rows(slots) if wrap else [slots]):
            top = self._row(row, top) + 60
        self.frame(start, (title or "").split("\n")[0] or None)
        return top + 60

    def _row(self, slots, top):
        """One timeline of stickies with their off-line items; returns the lowest y used."""
        made, x = [], X0
        for s in slots:
            b = self.sticky(s["kind"], s["text"], x, top, s.get("width"), s.get("src"))
            made.append((b, s.get("under") or []))
            x += b["w"] + GAP
        maxh = max(b["h"] for b, _ in made)
        for b, _ in made:                              # centre the line vertically
            dy = top + maxh / 2 - b["h"] / 2 - b["y"]
            for e in self.els:
                if e["id"] == b["id"] or e.get("containerId") == b["id"]:
                    e["y"] += dy
            b["y"] += dy
            self.footnote(b)                           # after centring, so it sits under the final position
        self.timeline(X0, top - 24, x - X0 - GAP)
        order = {"command": -1, "system": -1, "event": 0, "time": 0, "read": 1, "hotspot": 2}
        bottom = top + maxh
        for b, unders in made:
            uy = top + maxh + 30
            for u in sorted(unders, key=lambda u: order.get(u["kind"], 0)):
                w = u.get("width") or STYLE[u["kind"]][2]
                ub = self.sticky(u["kind"], u["text"], b["x"] + (b["w"] - w) / 2, uy, w, u.get("src"))
                self.tether(b, ub)
                self.footnote(ub)
                uy += ub["h"] + 22
                bottom = max(bottom, uy)
        return bottom

    def finish(self, path):
        for e in self.els:
            if self.bound.get(e["id"]):
                e["boundElements"] = (e.get("boundElements") or []) + self.bound[e["id"]]
        json.dump({"type": "excalidraw", "version": 2,
                   "source": "https://github.com/anthropics/claude-code",
                   "elements": self.els,
                   "appState": {"gridSize": None, "gridStep": 5, "gridModeEnabled": False,
                                "viewBackgroundColor": "#ffffff"},
                   "files": {}}, open(path, "w"), indent=2)


# -------------------------------------------------------- the reference section
# A legend that spells out the grammar as a chain, and Brandolini's own pizza
# example rendered in the same notation — so anyone opening the board can check
# a strange-looking run of stickies against a known-good one.
LEGEND = [
    {"kind": "read",    "text": "READ MODEL (green)\nwhat someone consults BEFORE deciding — a projection, a screen, a query"},
    {"kind": "person",  "text": "PERSON\n(small yellow)"},
    {"kind": "command", "text": "COMMAND (blue)\nan action, present tense. It can be rejected — completion is not implied"},
    {"kind": "system",  "text": "SYSTEM (pink)\nwhatever executes it. Name it specifically, never 'the system'"},
    {"kind": "event",   "text": "EVENT (orange)\na state transition, PAST tense"},
    {"kind": "policy",  "text": "POLICY (lilac)\n'Whenever <event> then <command>'. There is ALWAYS a business decision here, even when it looks obvious"},
    {"kind": "time",    "text": "TIME (orange)\ntimeouts, deadlines, cron — time is a trigger in its own right"},
]
LEGEND_HOTSPOT = {"kind": "hotspot", "text": "HOTSPOT (magenta) — what could not be settled: a contradiction, a question, a branch deliberately not explored yet."}

PIZZA = [
    {"kind": "read",    "text": "MENU PRICES\nOPENING HOURS"},
    {"kind": "person",  "text": "Customer"},
    {"kind": "command", "text": "Order pizzas"},
    {"kind": "system",  "text": "iwanthypizza.com"},
    {"kind": "event",   "text": "Order placed",
     "under": [{"kind": "read", "text": "PENDING ORDERS"}]},
    {"kind": "policy",  "text": "Cooking policy\nWhenever an order is placed, we start preparing it"},
    {"kind": "command", "text": "Prepare pizza"},
    {"kind": "system",  "text": "The kitchen"},
    {"kind": "event",   "text": "Pizza cooked"},
]


def reference_section(board, y):
    board.label("How to read this board", X0, y, 26)
    board.label(
        "Flow is ADJACENCY, left to right — the dotted tethers are a concession to reading this alone, not part of the notation.\n"
        "The two rules that are easy to break: there is always a PINK SYSTEM between a BLUE COMMAND and an ORANGE EVENT, and always a\n"
        "LILAC POLICY between an ORANGE EVENT and a BLUE COMMAND. No aggregates — those are design-level, not process-level.",
        X0, y + 34, 15, "#495057")
    y += 110
    x = X0
    for item in LEGEND:
        b = board.sticky(item["kind"], item["text"], x, y)
        x += b["w"] + GAP
    hs = board.sticky(LEGEND_HOTSPOT["kind"], LEGEND_HOTSPOT["text"], x, y)
    y += max(b["h"] for b in (hs,)) + 190
    y = board.chain(
        "The canonical example — Brandolini's pizza order",
        "Reproduced from Introducing EventStorming ch.12. The book's figure trails off after 'Prepare pizza'; the kitchen and its event complete the run.",
        PIZZA, y)
    return y + 40


def _all_stickies(model):
    for ch in model["chains"]:
        for s in ch["slots"]:
            yield ch, s, s
            for u in s.get("under") or []:
                yield ch, s, u


def check_sources(model, root):
    """Warn (never fail) when a `src` does not resolve under root."""
    warnings = []
    for _, _, s in _all_stickies(model):
        src = s.get("src")
        if not src:
            continue
        path, _, line = src.partition(":")
        abs_path = os.path.join(root, path)
        if not os.path.exists(abs_path):
            warnings.append(f"{src}: file not found under {root}")
        elif line:
            with open(abs_path, "rb") as f:
                n = sum(1 for _ in f)
            if int(line) > n:
                warnings.append(f"{src}: file has only {n} lines")
    return warnings


def write_register(model, out_path, census):
    """hotspots.md beside the board: the paste-into-the-tracker artefact."""
    reg = os.path.splitext(out_path)[0] + ".hotspots.md"
    lines = [f"# {model.get('title', 'Process model')} — hotspots", "", census, ""]
    n = 0
    for ch in model["chains"]:
        items = [(s, u) for s in ch["slots"] for u in (s.get("under") or []) if u["kind"] == "hotspot"]
        if not items:
            continue
        lines += [f"## {ch.get('title', '')}", ""]
        for s, u in items:
            n += 1
            lines.append(f"{n}. {' '.join(u['text'].split())}")
            lines.append(f"   - under: {s['kind']} · {s['text'].splitlines()[0]}")
            if u.get("src"):
                lines.append(f"   - src: {u['src']}")
            elif s.get("src"):
                lines.append(f"   - src: {s['src']}")
            lines.append("")
    if model.get("left_off"):
        lines += ["## Left off the board", ""]
        lines += [f"- `{lo['route']}`: {lo['why']}" for lo in model["left_off"]] + [""]
    with open(reg, "w") as f:
        f.write("\n".join(lines))
    return reg, n


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    root = next((f.split("=", 1)[1] for f in flags if f.startswith("--root=")), os.getcwd())
    if len(args) != 2:
        print((__doc__ or "").strip().split("INPUT")[0])
        print("usage: build_model.py model.json out.excalidraw [--no-reference] [--root=REPO_DIR]")
        return 2
    model = json.load(open(args[0]))

    errs = validate(model)
    if errs:
        print("GRAMMAR VIOLATIONS — nothing was rendered:", file=sys.stderr)
        for e in errs:
            print("  " + e, file=sys.stderr)
        print("\nSee references/grammar.md. The usual fixes: name the system that "
              "executes the command, or name the policy that reacts to the event.",
              file=sys.stderr)
        return 1

    for w in check_sources(model, root):
        print("src warning: " + w, file=sys.stderr)

    board = Board(root)
    y = 60
    board.label(model.get("title", "Process Modeling EventStorming"), X0, y, 36)
    y += 56
    if model.get("subtitle"):
        sub = model["subtitle"]
        board.label(sub, X0, y, 15, "#495057")
        y += len(sub.split("\n")) * 19 + 40
    if "--no-reference" not in flags and model.get("include_reference", True):
        y = reference_section(board, y)
    for ch in model["chains"]:
        y = board.chain(ch.get("title"), ch.get("blurb"), ch["slots"], y, ch.get("wrap", True))
    board.finish(args[1])

    counts = {}
    for ch in model["chains"]:
        for s in ch["slots"]:
            counts[s["kind"]] = counts.get(s["kind"], 0) + 1
            for u in s.get("under") or []:
                counts[u["kind"]] = counts.get(u["kind"], 0) + 1
    census = (f"grammar OK — {len(model['chains'])} chains, "
              f"{sum(counts.values())} stickies "
              + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    print(census)
    print(f"wrote {args[1]}")
    reg, n = write_register(model, args[1], census)
    print(f"wrote {reg} ({n} hotspots)")
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import sipoc
    import logic_model
    print(f"wrote {sipoc.write(model, args[1])}")
    print(f"wrote {logic_model.write(model, args[1])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
