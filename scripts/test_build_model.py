#!/usr/bin/env python3
"""Smoke test for build_model.py's grammar validator and renderer.

    python3 scripts/test_build_model.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True   # keep __pycache__ out of the skill directory
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_model as bm  # noqa: E402


def chain(*kinds, under=None):
    slots = [{"kind": k, "text": k.upper()} for k in kinds]
    if under:
        idx, items = under
        slots[idx]["under"] = items
    return {"title": "t", "chains": [{"title": "story", "slots": slots}]}


def errors(model):
    return bm.validate(model)


def main():
    # The documented happy path validates and renders.
    ok = chain("read", "person", "command", "system", "event", "policy", "command", "system", "event",
               under=(4, [{"kind": "event", "text": "refused"}, {"kind": "hotspot", "text": "why?"}]))
    assert errors(ok) == [], errors(ok)

    # One bad adjacency gives one message, not one per side.
    e = errors(chain("person", "command", "event"))
    assert len(e) == 1 and "command → event" in e[0], e

    # A hotspot on the line is one error, not three.
    e = errors(chain("person", "command", "system", "event", "hotspot", "policy", "command", "system", "event"))
    assert len(e) == 1 and "hotspot" in e[0], e

    # A story has to end on what changed.
    e = errors(chain("person", "command"))
    assert len(e) == 1 and "ends on a command" in e[0], e

    # Empty text is caught before the renderer would crash on it.
    bad = chain("person", "command", "system", "event")
    bad["chains"][0]["slots"][0]["text"] = ""
    assert any("no text" in x for x in errors(bad)), errors(bad)

    # Rendering: the TIME prefix is added when missing, and the file is valid Excalidraw JSON.
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out.excalidraw"
        board = bm.Board()
        board.chain("story", None, [{"kind": "time", "text": "end of month"},
                                    {"kind": "policy", "text": "whenever"},
                                    {"kind": "command", "text": "bill"},
                                    {"kind": "system", "text": "billing"},
                                    {"kind": "event", "text": "billed"}], 0)
        board.finish(out)
        data = json.load(open(out))
        texts = [el["text"] for el in data["elements"] if el["type"] == "text"]
        assert any(t.startswith("TIME · end of month") for t in texts), texts
        assert data["type"] == "excalidraw" and len(data["elements"]) > 10

    # Provenance: malformed src and left_off are validation errors.
    bad = chain("person", "command", "system", "event")
    bad["chains"][0]["slots"][2]["src"] = "app/x.py:12:3"
    assert any("malformed src" in x for x in errors(bad)), errors(bad)
    lo = chain("person", "command", "system", "event")
    lo["left_off"] = [{"route": "PATCH /x"}]
    assert any("left_off" in x for x in errors(lo)), errors(lo)

    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "svc.py").write_text("a\nb\nc\n")
        # A good src renders a footnote and an editor link; a line past EOF warns.
        board = bm.Board(tmp)
        board.chain("t", None, [{"kind": "person", "text": "P"}, {"kind": "command", "text": "C"},
                                {"kind": "system", "text": "S", "src": "svc.py:2"}, {"kind": "event", "text": "E"}], 0)
        texts = [el["text"] for el in board.els if el["type"] == "text"]
        assert "svc.py:2" in texts, texts
        links = [el["link"] for el in board.els if el["type"] == "rectangle" and el.get("link")]
        assert links == [f"vscode://file/{os.path.abspath(tmp)}/svc.py:2"], links
        assert bm.check_sources({"chains": [{"slots": [{"kind": "system", "text": "S", "src": "svc.py:9"}]}]}, tmp)
        assert not bm.check_sources({"chains": [{"slots": [{"kind": "system", "text": "S", "src": "svc.py:3"}]}]}, tmp)

        # The hotspot register lists hotspots with their source and the documented left-off routes.
        model = chain("person", "command", "system", "event",
                      under=(3, [{"kind": "hotspot", "text": "why?", "src": "svc.py:1"}]))
        model["left_off"] = [{"route": "PATCH /x", "why": "edit variant"}]
        reg, n = bm.write_register(model, str(Path(tmp) / "b.excalidraw"), "census line")
        body = Path(reg).read_text()
        assert n == 1 and "1. why?" in body and "src: svc.py:1" in body and "`PATCH /x`: edit variant" in body, body

    # Frames: every chain is one named frame that encloses all of its elements.
    board = bm.Board()
    two = [{"kind": "person", "text": "Customer"}, {"kind": "command", "text": "Order"},
           {"kind": "system", "text": "shop"}, {"kind": "event", "text": "Ordered",
                                                "under": [{"kind": "hotspot", "text": "?"}]},
           {"kind": "read", "text": "QUEUE"}, {"kind": "person", "text": "Cook"},
           {"kind": "command", "text": "Cook"}, {"kind": "system", "text": "kitchen"}, {"kind": "event", "text": "Cooked"}]
    board.chain("1 · Pizza", "why", two, 0)
    frames = [e for e in board.els if e["type"] == "frame"]
    assert len(frames) == 1 and frames[0]["name"] == "1 · Pizza", frames
    kids = [e for e in board.els if e["type"] != "frame"]
    assert all(e["frameId"] == frames[0]["id"] for e in kids)
    f = frames[0]
    for e in kids:
        x0, y0, x1, y1 = bm.Board._bbox(e)
        assert f["x"] <= x0 and f["y"] <= y0 and x1 <= f["x"] + f["width"] and y1 <= f["y"] + f["height"], e["id"]
    # Wrapping: a second person starts a new row (two timelines), and pulls its read model along.
    timelines = [e for e in board.els if e["type"] == "arrow" and e["endArrowhead"] == "arrow"]
    assert len(timelines) == 2, len(timelines)
    assert [[s["kind"] for s in r] for r in bm.Board._rows(two)] == [
        ["person", "command", "system", "event"], ["read", "person", "command", "system", "event"]]
    board = bm.Board()
    board.chain("1 · Pizza", None, two, 0, wrap=False)
    assert sum(1 for e in board.els if e["type"] == "arrow" and e["endArrowhead"] == "arrow") == 1
    assert any("'wrap'" in x for x in errors({"chains": [{"title": "t", "wrap": "no", "slots": two}]}))

    # Issues: the register parses into one (title, body) per hotspot, left-off routes excluded.
    import hotspots_to_issues as hi
    reg = "# t — hotspots\n\ncensus\n\n## 1 · Pizza\n\n1. Does a cold pizza get remade?\n   - under: event · Cooked\n   - src: k.py:3\n\n## Left off the board\n\n- `PATCH /x`: edit\n"
    parsed = hi.parse(reg)
    assert len(parsed) == 1 and parsed[0][0] == "Does a cold pizza get remade?" and "- src: k.py:3" in parsed[0][1], parsed

    # SIPOC: suppliers before the first event, inputs are reads, process is the commands with
    # their systems, outputs are events plus alternatives, customers act after an event (plus the asker).
    import sipoc
    pizza = {"title": "p", "chains": [{"title": "1 · Pizza", "slots": [
        {"kind": "read", "text": "MENU"}, {"kind": "person", "text": "Customer"},
        {"kind": "command", "text": "Order pizzas"}, {"kind": "system", "text": "iwantmypizza.com"},
        {"kind": "event", "text": "Order placed", "under": [{"kind": "read", "text": "PENDING ORDERS"},
                                                           {"kind": "event", "text": "Order refused\ncard declined"}]},
        {"kind": "person", "text": "Cook"}, {"kind": "command", "text": "Prepare pizza"},
        {"kind": "system", "text": "The kitchen"}, {"kind": "event", "text": "Pizza cooked"}]}]}
    c = sipoc.derive_chain(pizza["chains"][0])
    assert c["suppliers"] == ["Customer"] and c["inputs"] == ["MENU"], c
    assert c["process"] == ["Order pizzas — iwantmypizza.com", "Prepare pizza — The kitchen"], c
    assert c["outputs"] == ["Order placed", "PENDING ORDERS", "or: Order refused — card declined", "Pizza cooked"], c
    assert c["customers"] == ["Cook", "Customer"], c
    pizza["chains"][0]["sipoc"] = {"customers": ["Hungry customer"]}
    assert sipoc.derive_chain(pizza["chains"][0])["customers"] == ["Hungry customer"]
    board, _ = sipoc.derive(pizza)
    assert board["process"] == ["Pizza"] and board["outputs"] == ["Pizza cooked"], board
    assert "| Suppliers | Inputs | Process | Outputs | Customers |" in sipoc.markdown(pizza)
    assert errors(pizza) == [], errors(pizza)
    pizza["chains"][0]["sipoc"] = {"process": ["no"]}
    assert any("'sipoc'" in x for x in errors(pizza)), errors(pizza)
    del pizza["chains"][0]["sipoc"]

    # Logic model: inputs/activities/outputs from the chains, hotspots as assumptions, vendors as
    # external factors; outcomes and impact only when supplied, otherwise say so.
    import logic_model as lm
    pizza["chains"][0]["slots"][3]["text"] = "iwantmypizza.com\nPOST /orders"
    pizza["chains"][0]["slots"][4]["under"].append({"kind": "hotspot", "text": "Who pays for a refused order?"})
    cols, assumptions, external, detail = lm.derive(pizza)
    assert cols["inputs"] == ["People: Customer, Cook", "Systems: iwantmypizza.com, The kitchen",
                              "Information: MENU, PENDING ORDERS"], cols["inputs"]
    assert cols["activities"] == ["Pizza"] and cols["outputs"] == ["Order placed", "Pizza cooked"], cols
    assert cols["outcomes"][0].startswith("Not derivable") and cols["impact"][0].startswith("Not derivable"), cols
    assert assumptions == ["Who pays for a refused order?"] and external == ["The kitchen"], (assumptions, external)
    assert detail == [("1 · Pizza", ["Order pizzas", "Prepare pizza"], ["Order placed", "Pizza cooked"])], detail
    pizza["logic_model"] = {"outcomes": {"short": ["Fed (README)"]}, "impact": ["Repeat custom"],
                            "external_factors": ["Flour supply"]}
    cols, _, external, _ = lm.derive(pizza)
    assert cols["outcomes"] == ["Short term: Fed (README)"] and cols["impact"] == ["Repeat custom"], cols
    assert external == ["The kitchen", "Flour supply"], external
    assert "| Inputs | Activities | Outputs | Outcomes | Impact |" in lm.markdown(pizza)
    assert errors(pizza) == [], errors(pizza)
    pizza["logic_model"] = {"outcomes": {"soon": ["x"]}}
    assert any("logic_model" in x for x in errors(pizza)), errors(pizza)
    del pizza["logic_model"]

    # Census gate: on board by whole-path match, documented by left_off, otherwise missing.
    import check_census as cc
    analysis = {"files": [{"lc": "r.py", "fns": [{"i": "f1_fn0", "n": "h", "ls": 3}]}],
                "routes": [{"method": "POST", "full_path": "/api/orders", "symbol": "f1_fn0"},
                           {"method": "PATCH", "full_path": "/api/orders/{order_id}", "symbol": "f1_fn0"},
                           {"method": "DELETE", "full_path": "/api/orders/{order_id}", "symbol": "f1_fn0"},
                           {"method": "GET", "full_path": "/api/orders", "symbol": "f1_fn0"}]}
    model = chain("person", "command", "system", "event")
    model["chains"][0]["slots"][2]["text"] = "api\nPOST /api/orders"
    model["left_off"] = [{"route": "PATCH /api/orders/{id}", "why": "edit"}]
    on, left, missing = cc.check(model, analysis)
    assert on == ["POST /api/orders"], on
    assert left == ["PATCH /api/orders/{}"], left
    assert [m[0] for m in missing] == ["DELETE /api/orders/{}"] and missing[0][1] == "r.py:3", missing
    print("ok: validator, renderer, provenance, register, frames, wrap, issues, sipoc, logic model, census gate")


if __name__ == "__main__":
    sys.exit(main())
