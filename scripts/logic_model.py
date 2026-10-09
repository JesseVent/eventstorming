#!/usr/bin/env python3
"""
logic_model.py — a program logic model (Inputs → Activities → Outputs → Outcomes → Impact,
with Assumptions and External factors) derived from the process model in model.json.
build_model.py writes it beside the board as <stem>.logic-model.md; this is the
standalone form.

    python3 logic_model.py model.json          # markdown to stdout

What the code can say, derived from the chains:
  Inputs       the persons who do the work, the systems used (first line of each pink
               sticky, deduplicated), the read models relied on, the time triggers
  Activities   one per chain, from its title; the chain's commands are the detail
  Outputs      the happy-path events: each is a row written or a message sent, so each
               is countable
  Assumptions  every hotspot. A hotspot is a question the program's logic rests on
               without an answer in the code
  External     systems that are not this program's own API (a pink sticky whose text
               never names a `METHOD /path`): vendors whose availability is outside
               the program's control

What the code cannot say: Outcomes (short, medium, long term) and Impact. Those are the
change the program intends in the people it serves, and no handler records intent.
Supply them in model.json, marking where they came from:

  "logic_model": {
    "outcomes": {"short": ["Clinicians send notes the same day (README)"],
                 "medium": [...], "long": [...]},
    "impact": ["..."],
    "assumptions": ["..."],          # appended to the hotspots
    "external_factors": ["..."]      # appended to the derived vendors
  }

Until they are supplied the columns say so, rather than guess.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sipoc import _first, _uniq, table  # noqa: E402

COLS = ("inputs", "activities", "outputs", "outcomes", "impact")
ROUTE = re.compile(r"\b(GET|POST|PUT|PATCH|DELETE)\s+/")
NOT_IN_CODE = "Not derivable from code — supply `logic_model.{key}` in model.json"


def _stickies(model):
    for ch in model["chains"]:
        for s in ch["slots"]:
            yield ch, s
            for u in s.get("under") or []:
                yield ch, u


def derive(model):
    people, systems, reads, times, outputs, hotspots = [], [], [], [], [], []
    internal = set()
    for ch, s in _stickies(model):
        k, t = s["kind"], _first(s["text"])
        if k == "person":
            people.append(t)
        elif k == "system":
            systems.append(t)
            if ROUTE.search(s["text"]):
                internal.add(t)
        elif k == "read":
            reads.append(t)
        elif k == "time":
            times.append(t if t.upper().startswith("TIME") else "TIME · " + t)
        elif k == "hotspot":
            hotspots.append(" ".join(s["text"].split()))
    for ch in model["chains"]:
        outputs += [_first(s["text"]) for s in ch["slots"] if s["kind"] == "event"]
    supplied = model.get("logic_model") or {}
    outcomes = supplied.get("outcomes") or {}
    inputs = []
    for label, items in (("People", people), ("Systems", systems), ("Information", reads)):
        if items:
            inputs.append(f"{label}: " + ", ".join(_uniq(items)))
    cols = {
        "inputs": inputs + _uniq(times),
        "activities": [re.sub(r"^\d+\s*·\s*", "", ch.get("title", "")) for ch in model["chains"]],
        "outputs": _uniq(outputs),
        "outcomes": [f"Short term: {x}" for x in outcomes.get("short") or []]
                    + [f"Medium term: {x}" for x in outcomes.get("medium") or []]
                    + [f"Long term: {x}" for x in outcomes.get("long") or []]
                    or [NOT_IN_CODE.format(key="outcomes")],
        "impact": list(supplied.get("impact") or []) or [NOT_IN_CODE.format(key="impact")],
    }
    assumptions = _uniq(hotspots + list(supplied.get("assumptions") or []))
    external = _uniq([s for s in systems if s not in internal] + list(supplied.get("external_factors") or []))
    detail = [(ch.get("title", ""),
               [_first(s["text"]) for s in ch["slots"] if s["kind"] == "command"],
               [_first(s["text"]) for s in ch["slots"] if s["kind"] == "event"]) for ch in model["chains"]]
    return cols, assumptions, external, detail


def markdown(model):
    cols, assumptions, external, detail = derive(model)
    lines = [f"# {model.get('title', 'Process model')} — program logic model", "",
             "Inputs, activities and outputs are read off the process model. Outcomes and impact are the "
             "program's intent and are not in the code; they are supplied, with their source, or left blank.", "",
             table(cols, COLS, numbered="activities"), "",
             "## Assumptions", "",
             "Every hotspot on the board is a question the program's logic rests on without an answer in the code.", ""]
    lines += [f"- {a}" for a in assumptions] or ["- none recorded"]
    lines += ["", "## External factors", "",
              "Systems this program depends on and does not control.", ""]
    lines += [f"- {e}" for e in external] or ["- none: every system on the board is this program's own"]
    lines += ["", "## Activities in detail", ""]
    for title, commands, events in detail:
        lines += [f"### {title}", "", "Does: " + "; ".join(commands), "", "Produces: " + "; ".join(events), ""]
    return "\n".join(lines)


def write(model, out_path):
    path = os.path.splitext(out_path)[0] + ".logic-model.md"
    with open(path, "w") as f:
        f.write(markdown(model))
    return path


def main(argv):
    if len(argv) != 2:
        print((__doc__ or "").strip())
        return 2
    print(markdown(json.load(open(argv[1]))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
