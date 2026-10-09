# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code **skill**, not an application. `SKILL.md` is the skill itself (its
frontmatter `description` is the trigger text); `grammar.md` and
`deriving-from-code.md` are the references it tells the agent to read;
`scripts/build_model.py` is the validator plus Excalidraw renderer; `scripts/sipoc.py`
and `scripts/logic_model.py` derive a SIPOC and a program logic model from the same
model and are called by it (so one render writes `.excalidraw`, `.hotspots.md`,
`.sipoc.md`, `.logic-model.md`).
`scripts/code_analyzer.sh` is a repo scanner (bash wrapper around an embedded
Python AST walker) that enumerates the raw material for a process model: routes,
database writes, queue/background hand-offs, cron and beat schedules, call chains.
Python 3 standard library plus `jq` (the analyzer shells out to it). No package
manager, no lint config. Two test files under `scripts/`, one per executable.

Installed by symlink: `~/.claude/skills/eventstorming` points at this folder, so
edits here are live in the next Claude Code session.

## Commands

```bash
python3 scripts/build_model.py model.json out.excalidraw --root=REPO      # validate, render, write out.hotspots.md + out.sipoc.md
python3 scripts/sipoc.py model.json                                       # the SIPOC alone, markdown to stdout
python3 scripts/logic_model.py model.json                                 # the program logic model alone
python3 scripts/preview.py out.excalidraw out.svg                         # static SVG of a rendered board (rsvg-convert for PNG)
python3 scripts/build_model.py model.json out.excalidraw --no-reference   # skip legend + pizza example
python3 scripts/build_model.py                                            # prints usage, exit 2
python3 scripts/check_census.py model.json --analysis out.json            # exit 1 if a write route is neither drawn nor left_off
python3 scripts/check_census.py model.json --repo REPO                    # same, running the scanner first
python3 scripts/hotspots_to_issues.py out.hotspots.md [--create]          # dry run by default; --create runs gh issue create
```

Exit codes: 0 rendered (prints a sticky census), 1 grammar violation (nothing is
written; each bad slot is named on stderr), 2 usage error. A single bad adjacency
reports twice, once from the "may only be followed by" side and once from the
"may only follow" side.

```bash
bash scripts/code_analyzer.sh -s full -o out.json /path/to/repo   # routes, reactions, time_triggers, per-fn io
bash scripts/code_analyzer.sh -s model -o out.json /path/to/repo  # thin symbol list for an LLM
python3 scripts/test_code_analyzer.py                             # analyzer smoke test, builds its own fixture
```

Analyzer schemas: `full` carries everything the skill needs (`routes[].full_path`,
`routes[].refusals`, `shared_refusals`, `reactions`, `time_triggers`, `absences`,
per-function `io_out` with `database` / `reaction`, `refusals`, `task` on queue
entry points, `sym_calls` to walk a handler down to its writes). `model` drops the
top-level lists. `tool` is `full` plus hashes and import detail.

The check after touching `build_model.py` is `python3 scripts/test_build_model.py`
(validator rules, one message per bad pair, trailing-command and empty-text
checks, TIME prefix on render). The check after touching `code_analyzer.sh` is
`python3 scripts/test_code_analyzer.py`.

## Architecture

`build_model.py` has two independent halves joined by `main()`:

1. **Grammar** (`FOLLOWS`, `PRECEDES`, `UNDER_OK`, `validate()`). Adjacency
   tables encode Brandolini's process-modelling colour rules: pink `system`
   must sit between `command` and `event`; lilac `policy` must sit between
   `event` and `command`. `validate()` walks each chain's `slots` and checks
   every neighbour pair against both tables, then checks `under` lists.
   These tables are the single source of truth; the rule table in `grammar.md`
   ("The two cardinal rules") mirrors them by hand, so change both together.
2. **Rendering** (`STYLE`, `Board`). `Board.sticky` emits one Excalidraw
   rectangle plus a bound text element; `Board.chain` splits the slots into
   rows at each person after the first (`_rows`, pulling preceding read models
   along; `wrap: false` disables), lays each row left to right on a timeline
   (`_row`), vertically centres it, stacks each slot's `under` stickies beneath
   it with a dotted tether, then wraps everything in one named `frame` element
   whose bbox encloses every child. `finish()` back-fills `boundElements` and
   writes the JSON. Flow is adjacency; tethers exist only for off-line stickies.
   `_wrap` breaks a token wider than the sticky (URLs, dotted paths) at
   `/ ? . & = _ -` or by character, so sticky height always fits the text.
   `scripts/preview.py` draws the same element subset as SVG for readers
   without Excalidraw; it is a preview of this renderer's output, not a general
   Excalidraw exporter.

`main()` validates first and renders second. Keep that order: the refusal to
render a wrong model is the point of the tool.

`sipoc.py` (`derive_chain`): suppliers = persons, time triggers and an opening
policy before the first event; inputs = read models before it; process =
commands, each with the next system; outputs = on-line events, read models
under them, alternatives as `or:`; customers = persons after an event plus the
first person. A chain's `sipoc` dict replaces any column except process. The
board table takes chain titles as steps and each chain's last event as output.

`logic_model.py` (`derive`): inputs = persons, systems (first line, deduplicated),
read models, time triggers; activities = chain titles; outputs = on-line events;
assumptions = hotspots plus `logic_model.assumptions`; external factors = systems
whose text never names a `METHOD /path` (vendors) plus `logic_model.external_factors`;
outcomes and impact only from `logic_model`, otherwise a "not derivable" line. Both
scripts share `sipoc.table()` for the column layout.

### model.json shape

```
title, subtitle?, include_reference? (default true), left_off?[], logic_model?, chains[]
  logic_model: outcomes? {short|medium|long: [str]}, impact? [str], assumptions? [str], external_factors? [str]
  left_off: route ("METHOD /path"), why
  chain: title, blurb?, wrap? (default true), sipoc? ({suppliers|inputs|outputs|customers: [str]}), slots[]
    slot: kind, text, width?, src? ("path" or "path:line"), under?[]
```

`src` is relative to `--root`. The renderer prints it under the sticky and sets an
editor link on the rectangle; unresolvable sources warn on stderr but render.
`check_census.py` matches `METHOD /path` text on stickies (normalising `{params}`)
against the scanner's write routes, so pink systems should name endpoints that way.

`kind` is one of `read person command system event time policy hotspot`.
Invariants the validator enforces:

- `hotspot` is never on the line, only in `under`.
- Every slot and every `under` item needs non-empty `text`.
- A chain ends on an `event`. Ending on a command, policy or person means the
  story has no outcome.
- Only `event time read hotspot` may go in `under`; `command` and `system` never.
- An `event` or `time` in `under` may only hang off an `event` or `time` slot
  (alternative outcomes sit under the happy path).
- `time` text gets a `TIME · ` prefix at render time if it lacks one.

The reference section (legend chain + Brandolini's pizza example) is prepended
to every board unless `--no-reference` or `include_reference: false`. The pizza
chain in `PIZZA` must itself pass `validate()`; it is rendered through the same
`chain()` call as user chains.

### code_analyzer.sh

The bash file is a thin CLI wrapper; the real program is the Python heredoc
written to a temp file at run time (`class CodeAnalyzer`). Edit the Python
inside the heredoc, not the bash. Per-file analysis is AST-based for Python and
regex-based for JS/TS, so JS results include false positives from comments and
strings. Mapping to sticky colours, as emitted:

- **Commands**: `routes[]` where `method` is a write verb. `full_path` joins
  `include_router` / `register_blueprint` prefixes across files
  (`resolve_route_prefixes`); `path` is the bare decorator fragment. `roles`
  comes from `Depends(has_permission([...]))` on the router or the handler, and
  from Express middleware such as `requireRole('admin')`; `guards` names other
  auth dependencies. Express routes with inline handlers have `symbol: null`.
- **Events**: functions whose `io_out` contains `database`. ORM and session
  calls are matched after stripping a leading `self.` or `cls.`. Table names
  resolve only when the model class is passed literally; a generic repository
  leaves `db_tables_out` empty.
- **Policies**: `reactions[]` (`background` = BackgroundTasks, `queue` =
  `.delay` / `.apply_async` / `.publish` / bullmq `queue.add`, `async` =
  `create_task`) and functions with `task` set (Celery / shared_task decorators).
  Synchronous cascades are only visible by walking `sym_calls`.
- **Time triggers**: `time_triggers[]` (`beat` from `beat_schedule` dicts,
  `cron` from `crontab()` / node-cron, `scheduler` from APScheduler-style
  calls, `interval` from `setInterval`).
- **Refusals** (alternative-outcome events): per function, `refusals[]` from
  every `raise X(...)` / `abort(...)` (Python, with the nearest enclosing `if`
  test as `when`, `status` from an int or an `HTTP_4xx_` attribute, `msg` from
  the detail even when it is a call) and `throw new X(...)` / `.status(4xx)`
  (JS, nearest named function). `aggregate_refusals` walks each route's
  `sym_calls` to depth 3 and attaches them to `routes[].refusals`; a refusal
  reachable from more than half the routes moves to top-level
  `shared_refusals`. The call graph follows `svc = Cls(...)`, parameters
  annotated with a class, and `self.attr` set in `__init__` (`instance_bindings`,
  `class_bindings`), so service-layer raises reach the route.
- **Hotspots**: `markers[]` (TODO/FIXME/HACK) and `absences`:
  `scheduled_tasks_undefined` (beat task with no function),
  `models_unreferenced` (ORM class never loaded as a name anywhere),
  `models_never_constructed` (never called or passed to an insert; noisy behind
  generic repositories).
- Not detected: early `return` with an error body, guards that silently skip,
  validation in front of the handler. Those stay manual.

## The skill workflow (SKILL.md, in brief)

When event-storming a target codebase: fix the process boundary first; mine
handlers, not READMEs (docs are leads, code is evidence, disagreement is a
hotspot); write one chain per story, not per module; render and let the
validator fail; then report which stickies were verified against code and which
were inferred, plus the census. `deriving-from-code.md` says where each colour
hides per architecture style. Aggregates never go on a process model.
