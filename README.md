# Eventstorming

Turns a codebase into an EventStorming **process model** — a wall of coloured
stickies showing what actually happens in the system, in the order it happens —
and renders it as a single `.excalidraw` file you can open, pan and edit.

It follows Alberto Brandolini's strict colour grammar from *Introducing
EventStorming*, and it **enforces** the grammar rather than trusting it: the
renderer refuses to produce a file that breaks the rules and tells you which
sticky is wrong.

## What you get

One `.excalidraw` file containing:

- a **legend** spelling out what each colour means, drawn as the grammar chain
  itself, so a reader can check any run of stickies without leaving the file
- **Brandolini's pizza example**, rendered in the same notation as a known-good
  reference
- one horizontal **chain per story**, each with a title and a line saying why it
  matters

Colours follow the book:

| Colour | Sticky | Meaning |
|---|---|---|
| 🟧 orange | domain event | something that happened — past tense |
| 🟧 orange, `TIME ·` | time trigger | a timeout, deadline, cron, end-of-period |
| 🟦 blue | command | an action, present tense — it can be rejected |
| 🩷 pink | system | whatever executes the command; "whatever we can blame" |
| 🟪 lilac | policy | *whenever [event] then [command]* |
| 🟩 green | read model | what someone needs to know **before** deciding |
| 🟨 small yellow | person | who decides |
| 🟥 magenta, tilted | hotspot | what could not be settled from the code |

## Why the grammar is enforced

Two rules do most of the work:

> "There has to be a Pink System between a Blue Command and an Orange Event,
> there has to be a Lilac Policy between an Orange Event and a Blue Command."

Both are easy to agree with and easy to break. A blue command wired straight to
an orange event reads fine to whoever drew it — and it has quietly erased the
question of *which* of your services or vendors does the work. An orange event
wired straight to a blue command has skipped a business decision, which is
usually the most contested thing on the board.

So the renderer validates first and draws second. A violation exits non-zero,
renders nothing, and names the slot:

```
GRAMMAR VIOLATIONS — nothing was rendered:
  1 · A customer subscribes: command → event (slot 7→8) — a command may only be followed by ['system']
```

## Install

```bash
git clone https://github.com/JesseVent/eventstorming ~/.claude/skills/eventstorming
```

Needs Python 3 (standard library only) and `jq`. The skill is live in the next
Claude Code session.

## How to use it

Just ask. It triggers on things like:

- "event storm this repo"
- "map the business process in `src/billing` as a diagram"
- "I've inherited this service and I don't understand what actually happens — draw me a domain model"
- "extract the commands, events and policies from this codebase"

Useful things to say along with it:

- **the boundary** — "from a customer subscribing to their first invoice being
  paid". A whole repo is not a process; a good board covers one, or a handful of
  named stories.
- **where to put the file** — otherwise it lands somewhere sensible like
  `docs/domain/process-model.excalidraw`.
- **who it's for** — a board for a stakeholder workshop is worded differently
  from one for the team that maintains the code.

Then open the `.excalidraw` file in [excalidraw.com](https://excalidraw.com), the
VS Code extension, or Obsidian's Excalidraw plugin (or ask for a picture:
`scripts/preview.py` writes a static SVG of the board). Everything is a normal
Excalidraw element, so you can drag stickies around and add your own during a
session.

## Scanning the repo first

The skill runs `scripts/code_analyzer.sh` over the target before it reads any
code. The scanner (Python and JS/TS; needs `jq`) emits the lists a process model
starts from: write routes with their full mounted paths and the roles that
guard them, every way each route can be refused (raises within three calls of
the handler, with the guard they sit under), functions that write to the
database, hand-offs to queues and background tasks, cron and beat schedules,
tables nothing touches, and TODO markers. Nothing lands on the board from it
unread; it tells the agent where to look and gives the final census a number to
reconcile against.

```bash
bash scripts/code_analyzer.sh -s full -o analysis.json /path/to/repo
python3 scripts/test_code_analyzer.py                                  # smoke test
```

## Running the renderer directly

The skill writes a `model.json` and renders it. You can do the same by hand:

```bash
python3 scripts/build_model.py model.json out.excalidraw --root=/path/to/repo   # also writes out.hotspots.md, out.sipoc.md, out.logic-model.md
python3 scripts/build_model.py model.json out.excalidraw --no-reference         # skip legend + pizza
python3 scripts/check_census.py model.json --repo /path/to/repo                 # every write route on the board or documented?
python3 scripts/hotspots_to_issues.py out.hotspots.md [--create]                # one GitHub issue per hotspot (dry run by default)
```

Each chain is rendered inside its own named Excalidraw frame, and a long chain
wraps onto a new row wherever a different person takes over, so a 20-sticky
story stays readable without scrolling sideways.

The SIPOC comes free: `out.sipoc.md` holds a Suppliers / Inputs / Process /
Outputs / Customers table for the whole board (one row per story) and one per
chain, derived from the stickies. Persons and triggers before the first event are
suppliers, read models are inputs, commands are the process, events are outputs,
and whoever acts on an event is a customer. A chain can override any column.

So does a program logic model, `out.logic-model.md`: inputs, activities and
outputs read off the board, hotspots as the assumptions, vendor systems as the
external factors. Outcomes and impact are the one thing code cannot tell you, so
they come from a `logic_model` block in `model.json` or the columns say they are
missing.

Stickies can carry `"src": "path/to/file.py:line"`; the renderer prints it under
the sticky and links it to your editor. The model can carry `left_off`, the write
routes you chose not to draw and why, which the census gate honours.

No dependencies beyond the Python standard library. `model.json` looks like:

```json
{
  "title": "acme-billing — Process Modeling EventStorming",
  "subtitle": "Derived from src/api/subscriptions.ts, not from the README.",
  "chains": [
    {
      "title": "1 · A customer subscribes",
      "blurb": "The only place a Subscription is created.",
      "slots": [
        {"kind": "read",    "text": "PLANS\nprice and billing period"},
        {"kind": "person",  "text": "Customer"},
        {"kind": "command", "text": "Subscribe to a plan"},
        {"kind": "system",  "text": "billing-api\nPOST /subscriptions"},
        {"kind": "event",   "text": "Subscription started", "under": [
          {"kind": "event",   "text": "Subscribe refused\nthe card was declined"},
          {"kind": "read",    "text": "ACCOUNT\ncurrent plan, next charge"},
          {"kind": "hotspot", "text": "Does a declined card retry, or drop them?"}
        ]}
      ]
    }
  ]
}
```

`under` hangs stickies off the line: alternative-outcome events beneath the happy
path, read models the event feeds, and hotspots. Blue and pink may never go there
— if a command is part of the story it belongs on the line with its own system.

Keeping `model.json` in the repo next to the diagram is worth it: the model
becomes reviewable text, and regenerating after a change is an edit and a re-run
rather than dragging boxes.

## What it's good at, and what it isn't

**Good at** surfacing the things documentation never records — every way a
command can be refused, policies that are implemented inconsistently in two
places, cascades nobody wrote down, and the difference between a cron that
actually fires and a TTL that only takes effect on the next request.

**Not** a design-level EventStorming. Aggregates, bounded-context maps and
event-sourcing design belong to a different format (*Introducing EventStorming*
ch.16–21) and are deliberately absent — at process level the slot between command
and event belongs to the pink system.

**Not** a substitute for the workshop. The technique's value is a room full of
people arguing about the lilac stickies. This gives you an accurate, honest
starting wall in minutes instead of an afternoon, so the argument can start
sooner.

## Files

```
eventstorming/
├── SKILL.md                            the workflow
├── README.md                           this file
├── scripts/
│   ├── build_model.py                  validator + renderer + hotspot register, stdlib only
│   ├── code_analyzer.sh                repo scanner: routes, roles, db writes, hand-offs, schedules
│   ├── check_census.py                 gate: every write route on the board or documented as left off
│   ├── sipoc.py                        SIPOC derived from model.json, written beside the board
│   ├── logic_model.py                  program logic model (inputs → activities → outputs; outcomes supplied)
│   ├── preview.py                      static SVG of a board, for a PR or a chat
│   ├── hotspots_to_issues.py           the register as GitHub issues, via gh
│   ├── test_build_model.py             smoke test for the validator, renderer, register and gate
│   └── test_code_analyzer.py           smoke test for the scanner
└── references/
    ├── grammar.md                      the strict grammar, legend, pizza example
    └── deriving-from-code.md           where each colour hides in a codebase
```

## Credit

The notation, the rules and the pizza are Alberto Brandolini's, from
*Introducing EventStorming* (leanpub.com/introducing_eventstorming). This skill
only applies them.
