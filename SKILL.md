---
name: eventstorming
description: Derive an EventStorming process model from a codebase and render it as an .excalidraw file, following Alberto Brandolini's strict colour grammar (person → command → system → event → policy → command, with read models feeding the decision). Use this whenever someone wants to event-storm a project, map a domain or business process from code, produce a process model or domain model as a diagram, understand "what actually happens" in an unfamiliar system, or asks for the commands, events, policies or read models to be extracted from an implementation (a request for aggregates or bounded contexts gets the process model first; design-level EventStorming is out of scope). Also use it when someone mentions EventStorming, event storming, domain-driven design process modelling, or wants a whiteboard-style domain map they can open and edit — even if they don't name the notation.
---

# EventStorming a codebase

You are turning an implementation into a **process model**: a wall of coloured
stickies that says what actually happens in a system, in the order it happens,
in language a non-programmer could follow.

The output is one `.excalidraw` file, rendered by `scripts/build_model.py`, which
**refuses to render a model that breaks the grammar**. (`scripts/` and
`references/` paths in this file are relative to this skill's own directory, not
to the repo being modelled.) That refusal is the point.
The colour rules are easy to nod along to and easy to violate — a blue command
wired straight to an orange event looks fine to whoever drew it and is wrong.

## The two rules everything else hangs off

> "There has to be a Pink System between a Blue Command and an Orange Event,
> there has to be a Lilac Policy between an Orange Event and a Blue Command."
> — Brandolini, *Introducing EventStorming*

The full loop:

```
person  --decides to issue a-->  COMMAND  --invoked on a-->  SYSTEM
        --produces an-->  EVENT  --activates a-->  POLICY  --issues a-->  COMMAND
EVENT   --gets translated into one or more-->  READ MODEL  --provides info to-->  person
```

Read `references/grammar.md` before writing any stickies. It carries the phrasing
rules, the legend, the worked pizza example, and the mistakes that are worth
naming out loud.

**Do not put aggregates on a process model.** Aggregates are design-level
(*Introducing EventStorming* ch.19). At process level the slot between command and
event belongs to the pink system.

## Workflow

### 1. Set the boundary before mining anything

Ask, or decide and state: which process, from which trigger, to which outcome?
A whole repo is not a process. "From a customer subscribing to their first
invoice being paid" is. If the codebase clearly holds several processes, say so
and either pick one or plan a chain per story.

### 2. Enumerate with the scanner, then mine the code, not the docs

Run the scanner before reading anything (Python and JS/TS; needs `jq`):

```bash
bash scripts/code_analyzer.sh -s full -o /tmp/analysis.json /path/to/repo
```

It is a deterministic first pass, not a card generator. Nothing goes on the
board unread; the scanner says where to read and gives the census a number.

- **Commands**: `routes[]` with a write verb (`POST PUT PATCH DELETE`). Use
  `full_path` when present (router prefixes joined); `path` is the bare
  decorator fragment. Count them now: the census in step 5 reconciles against
  this number.
- **Events**: from each write handler, follow `sym_calls` until a function whose
  `io_out` contains `database`. Read that function for the actual state change
  and its wording. `db_tables_out` is filled only when the model class is passed
  literally; a generic repository leaves it empty, so read the model too.
- **Systems**: the same walk names the modules the command passes through.
  Functions with `api` in `io_in` or `io_out` are outbound vendor calls.
- **Policies**: `reactions[]` lists every hand-off to a background task, a queue
  or the event loop, with the function it fires. Functions with `task` set are
  the entry points those hand-offs land on. Synchronous cascades are not listed;
  they are the extra calls in `sym_calls` after the write.
- **Time triggers**: `time_triggers[]` (celery beat, cron, scheduler jobs,
  `setInterval`). A beat entry whose `task` matches no `task` function is a
  hotspot: a scheduled job that cannot run.
- **Refusals**: `routes[].refusals`, every raise or abort within three calls of
  the handler, with `when` (the guard it sits under), `status`, `msg`, and
  `fn` plus `file:ls`. Each one is an alternative-outcome event under the
  happy-path event. Helpers that every route reaches are listed once in
  `shared_refusals` instead. The list says where a refusal is, not what the
  person sees: read the guard before wording the sticky.
- **Absences**: `absences.scheduled_tasks_undefined` (a beat entry with no
  task function), `absences.models_unreferenced` (a table nothing in the repo
  touches) and `absences.models_never_constructed` (noisy behind a generic
  repository; a lead, not a finding). Each is a hotspot until the code says
  otherwise.
- **Hotspots**: `markers[]` (TODO, FIXME, HACK), plus everything above that
  the code cannot settle.

For a repo in any other language, skip the scanner and write the list of write
entry points by hand, with `file:line`, before mining, so the census still has a
number to reconcile.

`references/deriving-from-code.md` is the playbook for the reading: where each
colour hides, per architecture style.

Treat READMEs, design docs and ADRs as **leads, not evidence**. They drift, and a
process model built on drifted prose is confidently wrong in a way nobody catches.
Open the handler and read what it does. When a doc and the code disagree, the code
wins and the disagreement is worth a hotspot.

What pays for the exercise, and what docs never record, is **every way a command
can be refused.** A command does not imply completion. The scanner lists the
raises it can see; it cannot see an early `return` with an error body, a guard
that silently does nothing, or a validation layer in front of the handler. Read
the handler anyway. Together the refusals are usually the most informative part
of the board.

### 3. Write `model.json`

One chain per **story**, not per module. A story runs from what someone wanted to
what actually changed. Give each a title and a one-line blurb saying why it
matters. Write the file next to where the diagram will live (for example
`docs/domain/model.json`), so a later change is an edit and a re-run.

```json
{
  "title": "acme-billing — Process Modeling EventStorming",
  "subtitle": "Derived from src/api/subscriptions.ts and src/jobs/dunning.ts, not from the README.",
  "chains": [
    {
      "title": "1 · A customer subscribes",
      "blurb": "The only place a Subscription is created.",
      "slots": [
        {"kind": "read",    "text": "PLANS\nprice and billing period"},
        {"kind": "person",  "text": "Customer"},
        {"kind": "command", "text": "Subscribe to a plan"},
        {"kind": "system",  "text": "billing-api\nPOST /subscriptions"},
        {"kind": "system",  "text": "Stripe\ncharge the saved card"},
        {"kind": "event",   "text": "Subscription started", "under": [
          {"kind": "event",   "text": "Subscribe refused\nthe card was declined"},
          {"kind": "read",    "text": "ACCOUNT\ncurrent plan, next charge"},
          {"kind": "hotspot", "text": "Does a declined card retry, or drop them?"}
        ]},
        {"kind": "policy",  "text": "Whenever a subscription starts, send the welcome pack"},
        {"kind": "command", "text": "Send welcome pack"},
        {"kind": "system",  "text": "Postmark"},
        {"kind": "event",   "text": "Welcome pack sent"}
      ]
    }
  ]
}
```

`under` hangs stickies off the line — alternative-outcome events under an event
(happy path stays on the line, alternatives below it), read models the event
feeds, and hotspots. Blue and pink may never go there: if a command is part of
the story it belongs on the line with its own system.

Two more fields keep the board honest:

- `"src": "app/billing/service.py:146"` on any sticky: where the claim comes
  from. Put it on every hotspot and every system at least. The renderer prints
  it under the sticky and links it to the editor; the register and the census
  gate use it.
- `"left_off": [{"route": "PATCH /api/x/{id}", "why": "edit variant of the create"}]`
  at the top level: write routes you chose not to draw. Name pink systems as
  `METHOD /path` so the gate can see them.
- `"sipoc": {"customers": ["Clinician", "Their client"]}` on a chain, only when
  the derived SIPOC column is wrong (see step 4). Any of `suppliers`, `inputs`,
  `outputs`, `customers`; `process` always comes from the commands.
- `"logic_model": {"outcomes": {"short": [...], "medium": [...], "long": [...]},
  "impact": [...], "assumptions": [...], "external_factors": [...]}` at the top
  level, for the program logic model (step 4). Outcomes and impact are intent,
  not code: take them from the README, a pitch or the person asking, and say so
  in the text (`"... (README)"`). Never invent them. Leave the block out and the
  columns say they are not derivable.

### 4. Render, and let it fail

```bash
python3 scripts/build_model.py docs/domain/model.json docs/domain/process-model.excalidraw --root=.
```

On success it prints the sticky census and writes `process-model.hotspots.md`
beside the board: every hotspot, numbered, with its source and the left-off
routes. That file is what goes into the tracker or the channel. `--root` is the
repo the `src` fields are relative to; a `src` that does not resolve is a
warning, not a failure.

It also writes `process-model.sipoc.md`: a SIPOC (Suppliers, Inputs, Process,
Outputs, Customers) derived from the chains, one table for the whole board with
each chain as a process step, then one per chain. Suppliers are the persons and
triggers before the first event, inputs the read models they consult, process
the commands with their systems, outputs the events with alternatives as
`or:`, customers the persons who act after an event plus whoever asked. Read it
once; where a column is wrong, fix the model if the model is wrong, otherwise
add the `sipoc` override on that chain.

And `process-model.logic-model.md`: a program logic model. Inputs (people,
systems, information, time triggers), activities (one per chain) and outputs
(the happy-path events, each a countable row or message) come from the board;
every hotspot becomes an assumption; every system that is not this program's
own API becomes an external factor. Outcomes and impact come only from the
`logic_model` block, because intent is not in the code.

Each chain lands in its own named Excalidraw frame, and a long chain wraps onto
a new row wherever a different person decides (their read models come along).
That is layout, not a split in the model; `"wrap": false` on a chain keeps one
row. On a violation it renders nothing and names the slot:

```
GRAMMAR VIOLATIONS — nothing was rendered:
  1 · A customer subscribes: command → event (slot 7→8) — a command may only be followed by ['system']
```

Fix the model, not the validator. The two fixes that resolve almost everything:

- **blue → orange**: name the thing that executes the command. A handler, a
  module, a queue, a third-party API. If you genuinely can't name it you have
  found something worth a hotspot, not a shortcut.
- **orange → blue**: name the policy. "Whenever X then Y." Say it out loud — if
  it sounds stupid when spoken, the model is telling you something. Brandolini's
  trick is to reread it with the words **always** and **immediately** inserted
  and watch what objections surface.

### 5. Verify before you hand it over

Say plainly which claims you verified against code and which you inferred. If
you took anything from a doc without confirming it, either confirm it or make it
a hotspot. A board full of unverified assertions in confident past tense is worse
than a smaller honest one.

Then run the gate and report what it says:

```bash
python3 scripts/check_census.py docs/domain/model.json --analysis /tmp/analysis.json
```

It lists every write route as on the board, left off (documented), or missing,
and exits 1 on missing. Fix the model until it exits 0, then report the census
— chains, stickies by colour, routes on the board against routes found — and
where the files are, including the hotspot register, the SIPOC and the logic
model.

When someone asks to *see* the board, or the reader has no Excalidraw, render a
static picture and open or send it rather than describing it:

```bash
python3 scripts/preview.py docs/domain/process-model.excalidraw docs/domain/process-model.svg
rsvg-convert -w 2400 docs/domain/process-model.svg -o /tmp/board.png   # if a raster is needed
```

Look at the picture yourself before handing it over; a sticky whose text
overflows or a frame that clips is visible there and not in the census.

If the hotspots should become tickets, `scripts/hotspots_to_issues.py
docs/domain/process-model.hotspots.md` lists what it would file; add
`--create` only when asked, from inside the target repo, and say how many it
made.

## Things that quietly go wrong

**Generic systems.** "The backend" tells you nothing and hides exactly the
differences that make one path fragile and another fine. Name the module, the
endpoint, the vendor. Where several systems would clutter the board, pick a
representative and leave a hotspot for the rest.

**Read models drawn as outputs.** A read model is the information someone needs
**in order to decide** — it sits before the person, not after the event as a
trophy. If nothing consumes it, it may not belong on this board at all.

**Silent refusals.** If every command on your board succeeds, you have modelled
the brochure, not the system.

**Past tense.** Events are state transitions: `Subscription started`, not
`Start subscription` or `Subscription`. Commands are the opposite: present-tense
actions. This is not pedantry — it is what forces you to find the exact moment
something changed.

**One chain per module.** A module is not a story. Split by what someone was
trying to do.

**Fuzziness is allowed early.** Brandolini is explicit that precision too early
kills the conversation. First pass: get the events down. Then sharpen.
