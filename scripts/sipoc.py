#!/usr/bin/env python3
"""
sipoc.py — a SIPOC (Suppliers, Inputs, Process, Outputs, Customers) derived from the
process model in model.json. build_model.py writes it beside the board as
<stem>.sipoc.md; this is the standalone form.

    python3 sipoc.py model.json            # markdown to stdout

Derivation, per chain:
  Suppliers  persons who act before the first event; time triggers; a policy that opens
             the chain (an external trigger, such as a vendor's webhook)
  Inputs     read models consulted before the first event, and the opening trigger
  Process    the commands in order, each with the system that executes it
  Outputs    the happy-path events, the read models they feed, then the alternative
             outcomes beneath them as "or: ..."
  Customers  persons who act after an event, plus the person who opened the chain (the
             outcome goes back to whoever asked)

A chain may carry "sipoc": {"suppliers": [...], "inputs": [...], "outputs": [...],
"customers": [...]} to replace any derived column; Process always comes from the slots.
The board-level SIPOC at the top takes each chain as one process step and each chain's
final event as its output.
"""
import json
import os
import re
import sys

COLS = ("suppliers", "inputs", "process", "outputs", "customers")


def _first(text):
    return text.split("\n")[0].strip()


def _flat(text):
    return " — ".join(p.strip() for p in text.split("\n") if p.strip())


def _uniq(items):
    out = []
    for x in items:
        if x and x not in out:
            out.append(x)
    return out


def derive_chain(ch):
    slots = ch["slots"]
    sup, inp, proc, out, cus = [], [], [], [], []
    seen_event = False
    for i, s in enumerate(slots):
        k, t = s["kind"], _first(s["text"])
        if k == "person":
            (cus if seen_event else sup).append(t)
        elif k == "time":
            t = t if t.upper().startswith("TIME") else "TIME · " + t
            sup.append(t)
            inp.append(t)
        elif k == "policy" and not seen_event:
            sup.append(t)                       # the chain opens on an external trigger
            inp.append(t)
        elif k == "read":
            (out if seen_event else inp).append(t)
        elif k == "command":
            system = next((_first(x["text"]) for x in slots[i + 1:i + 3] if x["kind"] == "system"), None)
            proc.append(f"{t} — {system}" if system else t)
        elif k == "event":
            seen_event = True
            out.append(t)
            for u in s.get("under") or []:
                if u["kind"] == "read":
                    out.append(_first(u["text"]))
            alts = [_flat(u["text"]) for u in s.get("under") or [] if u["kind"] in ("event", "time")]
            if alts:
                out.append("or: " + "; ".join(alts))
    people = [_first(s["text"]) for s in slots if s["kind"] == "person"]
    derived = {"suppliers": _uniq(sup), "inputs": _uniq(inp), "process": proc,
               "outputs": _uniq(out), "customers": _uniq(cus + people[:1])}
    for key, val in (ch.get("sipoc") or {}).items():
        if key != "process":
            derived[key] = list(val)
    return derived


def derive(model):
    chains = [(ch.get("title", f"chain {i}"), derive_chain(ch)) for i, ch in enumerate(model["chains"])]
    last_events = []
    for ch in model["chains"]:
        events = [_first(s["text"]) for s in ch["slots"] if s["kind"] == "event"]
        if events:
            last_events.append(events[-1])
    board = {
        "suppliers": _uniq(x for _, c in chains for x in c["suppliers"]),
        "inputs": _uniq(x for _, c in chains for x in c["inputs"]),
        "process": [re.sub(r"^\d+\s*·\s*", "", t) for t, _ in chains],
        "outputs": _uniq(last_events),
        "customers": _uniq(x for _, c in chains for x in c["customers"]),
    }
    return board, chains


def table(cols, names=COLS, numbered="process"):
    """Independent column lists as one markdown table; the `numbered` column gets 1. 2. 3."""
    rows = max(len(cols[c]) for c in names) or 1
    head = "| " + " | ".join(c.replace("_", " ").capitalize() for c in names) + " |"
    sep = "|" + "---|" * len(names)
    body = []
    for r in range(rows):
        cells = []
        for c in names:
            v = cols[c][r] if r < len(cols[c]) else ""
            if c == numbered and v:
                v = f"{r + 1}. {v}"
            cells.append(v.replace("|", "\\|"))
        body.append("| " + " | ".join(cells) + " |")
    return "\n".join([head, sep] + body)


def markdown(model):
    board, chains = derive(model)
    lines = [f"# {model.get('title', 'Process model')} — SIPOC", "",
             "Derived from the process model: suppliers and inputs are what sits before the first event, "
             "process is the commands, outputs are the events, customers are who acts on them.", "",
             "## Whole board", "", table(board), ""]
    for title, cols in chains:
        lines += [f"## {title}", "", table(cols), ""]
    return "\n".join(lines)


def write(model, out_path):
    path = os.path.splitext(out_path)[0] + ".sipoc.md"
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
