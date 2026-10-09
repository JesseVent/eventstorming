#!/usr/bin/env python3
"""
hotspots_to_issues.py — one GitHub issue per hotspot in the register build_model.py writes.

    python3 hotspots_to_issues.py docs/domain/process-model.hotspots.md            # dry run: lists what it would create
    python3 hotspots_to_issues.py docs/domain/process-model.hotspots.md --create   # runs `gh issue create`

Run it from inside the target repo so `gh` picks the right remote. Issues get the label
`eventstorming` (created if missing). A hotspot whose title already exists under that
label, open or closed, is skipped, so re-running after a re-render only adds new ones.
"""
import json
import re
import subprocess
import sys

LABEL = "eventstorming"


def parse(text):
    """[(title, body)] from the numbered entries; the `## chain` heading is the context."""
    items, chain, cur = [], None, None
    for line in text.splitlines():
        if line.startswith("## "):
            chain = None if line[3:].lower().startswith("left off") else line[3:].strip()
            cur = None
        elif chain and re.match(r"^\d+\. ", line):
            cur = [re.sub(r"^\d+\. ", "", line).strip(), chain, []]
            items.append(cur)
        elif cur and line.startswith("   - "):
            cur[2].append(line.strip()[2:])
    return [(title[:120], f"**Chain:** {chain}\n" + "".join(f"- {d}\n" for d in details)
             + "\n_From the EventStorming hotspot register; close when the question is settled in code or docs._")
            for title, chain, details in items]


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main(argv):
    if len(argv) < 2:
        print((__doc__ or "").strip())
        return 2
    create = "--create" in argv
    items = parse(open(argv[1]).read())
    existing = set()
    if create:
        subprocess.run(["gh", "label", "create", LABEL, "--color", "E6007E", "--description", "EventStorming hotspot"],
                       capture_output=True)
        existing = {i["title"] for i in json.loads(
            gh("issue", "list", "--label", LABEL, "--state", "all", "--limit", "500", "--json", "title"))}
    made = skipped = 0
    for title, body in items:
        if title in existing:
            skipped += 1
            print(f"  exists:  {title}")
            continue
        if create:
            url = gh("issue", "create", "--title", title, "--body", body, "--label", LABEL).strip()
            print(f"  created: {url}  {title}")
        else:
            print(f"  would create: {title}")
        made += 1
    print(f"{len(items)} hotspots — {made} {'created' if create else 'to create'}, {skipped} already filed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
