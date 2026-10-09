# Mining a codebase for the building blocks

Where each colour hides in an implementation, and how to be sure you found it
rather than assumed it.

## Contents

- [The order to work in](#the-order-to-work-in)
- [Finding commands](#finding-commands)
- [Finding systems](#finding-systems)
- [Finding events](#finding-events)
- [Finding refusals](#finding-refusals)
- [Finding policies](#finding-policies)
- [Finding time triggers](#finding-time-triggers)
- [Finding read models](#finding-read-models)
- [Finding people](#finding-people)
- [Finding hotspots](#finding-hotspots)
- [By architecture style](#by-architecture-style)
- [Verification discipline](#verification-discipline)

## The order to work in

Commands first, because they are the easiest to enumerate exhaustively — a
codebase has a finite, findable set of write entry points. Then, for each one,
open the handler and read what it does: that gives you its system, its events,
and its refusals in one pass. Policies fall out of the cascades you find inside
handlers. Read models come last, driven backwards from the decisions.

Enumerating commands exhaustively early also gives you a completeness check: at
the end, every public write entry point should appear on the board exactly once,
and you can say so with a number.

## Finding commands

Blue stickies are the ways the outside world asks the system to change something.

| Stack | Look for |
|---|---|
| HTTP API | `POST` / `PUT` / `PATCH` / `DELETE` routes; anything non-idempotent |
| GraphQL | every `Mutation` field |
| RPC | service methods that write |
| Convex / Firebase | `mutation(...)` / `action(...)` exports; callable functions |
| Rails / Django / Laravel | non-GET controller actions, form handlers |
| Event-driven | message/queue consumers — the message *is* the command |
| CLI | subcommands with side effects |
| Frontend | server actions, form submits, `useMutation` call sites |
| Desktop / mobile | the handler behind a button that changes stored state |

Name them as the user's intention, present tense — `Cancel subscription`, not
`cancelSubscriptionHandler` and not `PATCH /subs/:id`. The technical name belongs
on the pink system sticky underneath it.

Internal functions are usually *not* commands. If nothing outside can invoke it,
it is part of a system's behaviour, not a separate blue sticky. The exception is
a genuinely separate reactive step a policy issues — a scheduled job, a queued
task — which is a command even though only your own code calls it.

## Finding systems

Pink is "whatever we can blame". For each command, at minimum the module or
endpoint that executes it — `billing-api / POST /subscriptions`, or
`payments.ts / chargeCard`. Then every out-of-process thing the handler reaches:

- schedulers and queues (`runAfter`, Sidekiq, Celery, SQS, cron)
- third-party APIs (Stripe, Twilio, Postmark, an internal service)
- engines and libraries doing real work (a rating engine, a solver, a renderer)
- the database, when its behaviour matters — optimistic concurrency, triggers,
  cascade deletes

Chain them when the command genuinely passes through several: `command → API →
scheduler → worker → event` is legal and often the truest picture.

Name them specifically. "The backend" is the failure mode; it erases exactly the
boundaries you drew the board to see.

## Finding events

Orange is what actually changed. Inside the handler, look for:

- rows inserted, and status columns transitioned (`status: 'active' → 'cancelled'`)
- messages published, domain events emitted, webhooks fired
- external state changed (a charge captured, an email sent, a file written)
- derived caches rewritten — if it is meaningful to the domain, it is an event

One command commonly produces several. Put them all on the line in the order they
happen.

Write them past tense, in domain language. `Subscription cancelled`, not
`status set to cancelled` and not `UPDATE subscriptions`. Add a second line for
the detail that a domain expert would want: `Subscription cancelled\naccess runs
to the end of the paid period`.

## Finding refusals

**This is the part that pays for the exercise.** A command can fail or be
rejected, and every rejection is an alternative-outcome event that belongs under
the happy path.

Grep the handler for its guards: `throw`, `raise`, early `return`, validation
failures, permission checks, precondition assertions, unique-constraint probes,
concurrency losers.

Each becomes an event phrased from the domain's point of view, carrying the
reason:

```json
{"kind": "event", "text": "Cancel refused\nthe subscription already ended"}
```

Refusals are almost never written down anywhere else. They are where the real
business rules live, and where a stakeholder reading the board will start
objecting — which is the outcome you want.

## Finding policies

Lilac is *whenever [event] then [command]*. In code it looks like:

- a handler that, after writing, calls another operation ("cascading reaction")
- a scheduler enqueueing a follow-up job
- an event-bus subscription or webhook receiver
- a database trigger
- a retry or dunning loop
- a cron entry reacting to a state, not just to the clock

Whenever you find a command being issued by code rather than by a person, there
is a policy in front of it. Write the sentence, then read it aloud with
**always** and **immediately** inserted. The objections that surface are your
next hotspots.

Watch for policies that are split across files and disagree — a timeout constant
in one place, a retry count in another, a guard that short-circuits both. Those
are the highest-value findings on the board.

## Finding time triggers

TTLs, timeouts, `expires_at`, cron schedules, delayed jobs, billing dates,
end-of-day and end-of-period rollups, "not seen in N days" checks.

Note *how* the deadline is evaluated, because it changes the model: a cron
actually fires; a lazily-evaluated TTL only "fires" on the next read or write,
which means the transition can sit unrealised for a long time. Both are time
triggers; only one has a job you can watch.

## Finding read models

Green is what someone needs in order to decide. Work **backwards from the
decision**, not forwards from the data layer:

> "What does this person need to know before they can issue this command?"

Then find what serves it: the GET endpoint, the query, the projection, the screen.
Name the read model for the decision it informs and list the fields that matter —
`ACCOUNT\ncurrent plan, next charge`, not `GET /account`.

A query nothing on the board consumes is a signal, not an omission: either you
are missing the decision it feeds, or it does not belong in this process.

## Finding people

Who issues each command? Often obvious from auth and routing: an end user, an
admin, an operator, a support agent, another team's service. Start generic and
split only when different people behave differently at the same step.

Where a policy is executed by a human rather than by code, put the person on the
policy.

## Finding hotspots

Magenta is what you could not settle. Genuine candidates:

- documentation that contradicts the implementation
- a rule implemented inconsistently in two places
- a constant with no explanation, or a comment admitting uncertainty
- a branch you deliberately did not explore, so the board records the debt
- a question only a domain expert can answer

Do not pad the board with hotspots to look thorough. Each one should be something
a reader could act on.

## By architecture style

**Layered / MVC.** Commands are controller actions; systems are the service or
module they delegate to; events are what the model layer persists. Watch for
policies hidden in model callbacks (`after_save`, signals) — those are cascading
reactions and they need their lilac.

**Event-driven / CQRS.** The mapping is nearly literal: commands are commands,
events are events, projections are read models. The work is in the policies —
find every subscriber that reacts to an event by issuing a command, and be sure
you have the *implicit* ones: retries, dead-letter handling, sagas.

**Serverless / BaaS (Convex, Firebase, Supabase).** Mutations and actions are
commands; the function module is the system; scheduled functions and triggers are
policies. Be careful with lazily-evaluated state: something can be logically
"expired" long before any code notices.

**Monolith with a job queue.** The queue is a system, and every enqueue inside a
handler is a policy. The job's own handler is a fresh command.

**Frontend-heavy.** Optimistic updates are not events — the event is what the
server durably recorded. The optimistic render belongs to the read model.

## Verification discipline

The single most common way this exercise goes wrong is building the board out of
documentation. READMEs, ADRs and design docs describe intent at the moment they
were written; the code describes behaviour now. When they disagree — and on any
codebase with history they will — the code is the source of truth and the
disagreement is a hotspot.

Practically:

- open the handler for every command you put on the board
- confirm each event against the write that causes it
- confirm each refusal against the guard that throws it
- confirm each constant (thresholds, timeouts, limits) by reading its definition,
  not by trusting a doc that quotes it

While drafting, keep the `file:line` for each sticky next to you. You do not have
to put it on the board, but you should be able to produce it if challenged, and
you should say in your summary which claims you verified and which you inferred.

A smaller board that is true beats a comprehensive one that is confidently wrong.
