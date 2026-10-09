#!/usr/bin/env python3
"""
check_census.py — is every write route the scanner found either on the board or
documented as left off?

    python3 check_census.py model.json --analysis analysis.json
    python3 check_census.py model.json --repo /path/to/repo      # runs the scanner first

A route counts as on the board when `METHOD /path` (with `{params}` normalised) appears
in the text of any sticky, which is how the skill names endpoints on pink system
stickies. It counts as documented when model.json lists it under `left_off` with a
`why`. Anything else is printed with its handler and the exit code is 1, so this can
gate a PR.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WRITE_VERBS = {"POST", "PUT", "PATCH", "DELETE"}


def norm(path):
    """`/users/{user_id}/status` and `/users/{id}/status` are the same route."""
    out, depth = [], 0
    for ch in path or "":
        if ch == "{":
            depth += 1
            out.append("{}")
        elif ch == "}":
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return "".join(out).rstrip("/") or "/"


def route_key(method, path):
    return f"{method} {norm(path)}"


def check(model, analysis):
    board_text = " ".join(
        norm_text for ch in model["chains"] for s in ch["slots"]
        for norm_text in [norm(s["text"])] + [norm(u["text"]) for u in (s.get("under") or [])]
    )
    documented = {route_key(*lo["route"].split(" ", 1)) for lo in model.get("left_off") or [] if " " in lo["route"]}
    fns = {fn["i"]: (f["lc"], fn) for f in analysis.get("files", []) for fn in f.get("fns", [])}

    def on_board_text(method, path):
        """`METHOD /path` as a whole: `POST /api/orders` is not satisfied by `DELETE /api/orders/{}`."""
        p = norm(path)
        return bool(p) and re.search(
            r"\b" + method + r"\s+" + re.escape(p) + r"(?![\w/{}\-.])", board_text, re.I) is not None

    on_board, left_off, missing = [], [], []
    for r in analysis.get("routes") or []:
        if r.get("method") not in WRITE_VERBS:
            continue
        path = r.get("full_path") or r.get("path") or ""
        key = route_key(r["method"], path)
        if on_board_text(r["method"], path):
            on_board.append(key)
        elif key in documented:
            left_off.append(key)
        else:
            lc, fn = fns.get(r.get("symbol"), ("?", {}))
            missing.append((key, f"{lc}:{fn.get('ls', '?')}", fn.get("n", "?")))
    return on_board, left_off, missing


def main(argv):
    if len(argv) < 4 or argv[2] not in ("--analysis", "--repo"):
        print((__doc__ or "").strip())
        return 2
    model = json.load(open(argv[1]))
    if argv[2] == "--analysis":
        analysis = json.load(open(argv[3]))
    else:
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
            out = tmp.name
        subprocess.run(["bash", os.path.join(HERE, "code_analyzer.sh"), "-s", "full", "-o", out, argv[3]],
                       check=True, capture_output=True)
        analysis = json.load(open(out))
        os.unlink(out)

    on_board, left_off, missing = check(model, analysis)
    total = len(on_board) + len(left_off) + len(missing)
    print(f"write routes: {total} — on board {len(on_board)}, left off (documented) {len(left_off)}, missing {len(missing)}")
    for key in left_off:
        print(f"  left off: {key}")
    for key, where, name in missing:
        print(f"  MISSING:  {key}  ({name} at {where})")
    if missing:
        print("\nAdd each missing route to a chain, or list it under `left_off` with a `why`.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
