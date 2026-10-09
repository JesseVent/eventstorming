# The strict colour grammar

Source: Alberto Brandolini, *Introducing EventStorming*, ch.12–14 (Process
Modeling) and the figure the book calls "the picture that explains everything".

## Contents

- [The legend](#the-legend)
- [The loop](#the-loop)
- [The two cardinal rules](#the-two-cardinal-rules)
- [Phrasing](#phrasing)
- [Where events come from](#where-events-come-from)
- [Alternative outcomes](#alternative-outcomes)
- [Policies deserve most of your attention](#policies-deserve-most-of-your-attention)
- [Read models](#read-models)
- [The canonical pizza example](#the-canonical-pizza-example)
- [What does not belong on a process model](#what-does-not-belong-on-a-process-model)

## The legend

| Sticky | Colour | `kind` | What it is |
|---|---|---|---|
| **Domain event** | orange | `event` | Something that happened. A state transition, past tense. |
| **Time trigger** | orange | `time` | Time causing an event — a timeout, a deadline, a cron, an end-of-day. Prefix the text `TIME · `. |
| **Command** | blue | `command` | An action, present tense. It can fail or be rejected; completion is not implied. |
| **System** | pink | `system` | Whatever executes the command. "Whatever we can blame." |
| **Policy** | lilac | `policy` | The reactive glue: *whenever [event] then [command]*. |
| **Read model** | green | `read` | The information someone needs in order to take a decision. |
| **Person** | small yellow | `person` | Who decides. User, actor, role, or a named human. |
| **Hotspot** | magenta, tilted | `hotspot` | What could not be settled: a contradiction, a question, a branch parked for later. |

The renderer draws this legend at the top of every board, so a reader can check
an unfamiliar run of stickies against a known-good one without leaving the file.

## The loop

```
person  --decides to issue a-->  COMMAND
COMMAND --invoked on a-------->  SYSTEM
SYSTEM  --produces an-------->   EVENT
EVENT   --activates a-------->   POLICY
POLICY  --issues a---------->    COMMAND      (and round again)

EVENT      --gets translated into one or more-->  READ MODEL
READ MODEL --provides info to----------------->   person
```

Flow is **adjacency**, left to right. A real wall has no arrows; position is the
notation. The renderer draws faint dotted tethers only to off-line stickies,
because a file gets read without a facilitator standing next to it — that is a
concession to the medium, not part of the grammar.

## The two cardinal rules

> "There has to be a Pink System between a Blue Command and an Orange Event,
> there has to be a Lilac Policy between an Orange Event and a Blue Command."

These are the two the validator in `scripts/build_model.py` enforces hardest,
because they are the two that get broken. Both failures feel harmless while you
are drawing:

- **blue → orange.** You know which handler runs, so you skip naming it. But the
  system sticky is where "which of our four services owns this" and "this goes
  through a vendor" live. Skipping it hides the seams.
- **orange → blue.** The reaction seems too obvious to need a note. Brandolini's
  answer: *"there is always a business decision between an event and the
  reaction. Sometimes the underlying decision is too obvious to be noticed; the
  mandatory lilac is just there to force your modeling team to think."*

The full rule table the validator applies:

| A | may only be followed by |
|---|---|
| `read` | `read`, `person` |
| `person` | `command` |
| `command` | `system` |
| `system` | `system`, `event` |
| `event` | `event`, `policy`, `read`, `person` |
| `time` | `policy`, `event` |
| `policy` | `command` |

Plus the mirror: a `command` may only follow a `person` or a `policy`; an `event`
may only follow a `system`, another `event`, or a `time`; a `policy` may only
follow an `event` or a `time`.

Two systems in a row is legal and often right — a command hits your API, which
hits a queue, which hits a vendor. Several events in a row is legal too: one
command can produce several state transitions.

## Phrasing

**Events: verb, past tense.** Greg Young's line, which Brandolini calls the
highest-value-per-character sentence in his professional life. `Order placed`,
`Subscription started`, `Payment declined`. Past tense is what forces you to find
the exact moment something changed, rather than describing a topic.

**Commands: present tense action.** `Order pizzas`, `Charge subscription`.

**Policies: "Whenever … then …".** Do not agonise over the name — Brandolini
suggests leaving it blank and inferring the implementation from the surrounding
stickies, then reading the sentence out loud. The name usually becomes obvious
once the implementation is agreed. Reading it aloud with **always** and
**immediately** inserted is the single best way to find the exception nobody
mentioned.

**Systems: specific names.** Resist "the backend", "the system", "the service".
Different systems have different strengths and pain points; generic ones don't,
which is exactly the information you lose.

## Where events come from

An event never appears from nowhere. It is one of four things:

1. the result of **user interaction**,
2. triggered by an **external system**,
3. triggered by **time**,
4. a **cascading reaction** to another event — and there is no such thing as an
   implicit cascade. Make the policy visible.

## Alternative outcomes

One command can produce several events. Put the happy path **on the line** and
the alternatives **below it**, closest to their sibling. In code this is where
your guard clauses, thrown errors and early returns go:

```json
{"kind": "event", "text": "Subscription started", "under": [
  {"kind": "event", "text": "Subscribe refused\nthe card was declined"},
  {"kind": "event", "text": "Subscribe refused\nthey already have an active plan"}
]}
```

Multiple events are not always alternatives — sometimes they are different
granularities or perspectives on the same moment. That is fine and worth keeping.
Brandolini notes that apparent language inconsistency at one moment is often the
signal of two bounded contexts meeting.

## Policies deserve most of your attention

*"Policies is where people lie."* Not maliciously — a policy shifts from "we call
back within minutes" to "we call back within days" without a meeting or an
announcement. There are rules, there is the interpretation, and there is the
reality.

In a codebase the equivalent is a policy that lives in three places and disagrees
with itself: a retry constant here, a cron interval there, a guard clause that
quietly short-circuits both. Those are the highest-value hotspots on the board.

When a human, not software, performs the reaction, put the person sticky on the
policy.

## Read models

*"Read models are the information that needs to be available to take a given
decision."*

They sit **before the person who decides**, not after the event as a trophy. The
loop closes: an event translates into a read model, the read model informs the
person, the person issues the next command.

Explore them starting from the decision, not from the data. "What does this
person need to know to choose?" — not "what does the endpoint return". If nothing
consumes a read model, it probably does not belong on this board.

## The canonical pizza example

Rendered on every board by the script, from ch.12:

```
MENU PRICES        Customer      Order        iwanthypizza.com   Order placed
OPENING HOURS      (person)      pizzas       (system)           (event)
(read model)                     (command)                        │
                                                                  └── PENDING ORDERS (read model)

Cooking policy                   Prepare pizza     The kitchen      Pizza cooked
Whenever an order is placed,     (command)         (system)         (event)
we start preparing it
(policy)
```

The book's figure trails off after `Prepare pizza …`; the kitchen and its event
complete the run so the example itself satisfies the grammar.

## What does not belong on a process model

**Aggregates.** They are design-level — ch.19, in the "Modeling software systems"
part, not the process-modeling part. Brandolini is explicit that a read model and
an aggregate are different things and that superimposing what you see on screen
onto the internal model is a "vicious temptation". At process level, the slot
between command and event is the pink system.

**Arrows everywhere.** If the board only reads with arrows, the stickies are in
the wrong order.

**Premature precision.** Embrace fuzziness on the first pass. Get the events down,
then sharpen over several rounds. Expect to rewrite event wording repeatedly —
that is the technique working, not failing.
