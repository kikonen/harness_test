# Planning mode (issue #359) - design

Design notes for a proposed *planning mode*: a posture the user turns on so the
model drafts a plan, offers it for iteration, and keeps it in a durable store -
instead of "rushing to modify code". This is a DESIGN document only; no code is
written for #359 yet. It states the problem, the seams the feature would hook
into, the enforcement options with their costs, and the decisions still open.
Issue #359 stays OPEN until the owner picks a shape.

The owner's design notes (2026-10-27) are folded in below and marked as such;
they settle several early questions and add new requirements (durable store,
mnemonic names, list + search, a `plan.*` tool set, and a link to #286).

---

## The problem #359 states

A direct prompt sends the model straight into the tool loop: it reads, then
writes, often before the user has agreed on *what* it is going to change. For a
non-trivial task the user would rather see the intended approach first, correct
it, and only then let the model edit. The issue asks for three things:

1. a mode that makes the model **offer a plan** rather than start editing;
2. a loop to **iterate that plan** with the user until it is agreed;
3. the plan **saved so it survives context compaction** (the plan must not be
   summarized away with the conversation that produced it).

Point 3 is the load-bearing one and the reason this is not just "ask the model to
plan in prose": a plan that lives only as a message in the chain is exactly what
compaction rewrites.

## The invariant the design must protect

**A plan lives OUTSIDE the message chain, so compaction cannot lose it.**

Both compaction paths replace the chain with a summary:

- `SessionManager#compact_session` (the `/compact` and auto-compact path) calls
  `Session#compact`, which collapses the chain to a summary plus a retained tail.
- `SessionManager#check_inloop_compaction` (mid-turn, from `Harness#call_llm`)
  replaces the whole working chain with a fresh four-message hand-off.

The summary instructions already ask the model to carry "the original goal",
"key decisions" and "the exact next step", so a plan *might* partially survive as
summary prose - but lossily and not guaranteed. The issue wants the plan to
survive **intact**, which is only true if it is stored where neither path touches
it. That rules out "the plan is just a message in the chain".

The owner's first note - "plans need to be stored so that they are not bound to
session" - is the strongest form of this invariant, and it is what the storage
section below follows.

## Storage: a durable plan store, not a session field

(Owner note: plans are not bound to a session; multiple plans persist; they can
be listed and searched.)

The early draft of this doc leaned toward a session field (`data[:plan]` in
`session.json`). The owner's note rejects that, and the rejection is right for a
reason the session field does not satisfy: a session field is *bound to one
session*, so a plan cannot be read back by a later session, listed across
sessions, or shared with a sub-agent. A plan is durable project knowledge about
*how a task is to be done*, and the codebase already has the exact shape for a
durable, model-writable, harness-owned store: **`Memories`** (`lib/memories.rb`,
doc/memory_design.md).

So the plan store mirrors `Memories`:

- A `Plans` class (`lib/plans.rb`) is the ONLY reader and writer of
  `.harness/plans/`, one markdown file per plan. `Harness#plans` hands it to the
  tools and to `/plans`, so what the owner inspects and what the model reads
  cannot drift apart (the same single-reader rule as `Memories` and `Skills`).
- A plan is named by a **NAME, never a path**: the directory comes from
  `Plans::DIR` under the workdir, and `normalize_name` accepts ONE path segment
  (no separator, no `..`, no drive, no leading dot, no `<>|"?*`, no control
  byte), the same rule as `Memories#normalize_name`. A name like
  `../sessions/<id>/session.json` is refused, so the store cannot become a
  general writer inside `.harness/` - which stays ungrantable to the file tools.
- Names are **folded to lowercase** for the same measured platform reason
  (Windows folds case in `File.file?`, ubuntu does not; the fold makes "this
  name exists", the cap, and "one plan per topic" mean the same thing on both).
- Writes need **no FileList grant and no dialog**: a plan call cannot choose a
  path, only a name inside one fixed harness-owned directory - the same consent
  reasoning as a memory write. Writes are still visible: `Harness#execute_tool_call`
  already logs every call (`tool plan.add → ok: saved plan 'brave-curie'`).
- `.harness/plans/` is gitignored with no new rule (`.gitignore` already ignores
  `.harness/*` and re-includes only `.harness/skills/`), so plans are this
  checkout's harness state, exactly like memories, sessions and the log.

This store satisfies "not bound to session" directly: a plan saved in one session
is readable, listable and searchable by any later session in the same workdir,
and survives every compaction because it was never in the chain.

**How this differs from a memory.** A memory is capped at 40 notes / 2000 chars
and is deliberately *not searched* (doc/memory_design.md: 40 notes is small
enough to list). Plans are expected to be longer (a real plan is more than one
fact) and the owner wants search, so the plan store relaxes the memory rules in
two ways: a larger body budget, and a real `plan.search`. It keeps the memory
rules that matter: one reader, name-not-path, no grant, never injected.

## The posture pattern (planning mode itself)

The *mode* - the on/off posture that makes the model plan instead of edit -
follows the streaming posture (`/stream`, issue #28), the proven shape for a
user-side mode that is toggled live, shown in the prompt/spinner tags, and
persisted with the session:

- `Harness#plan?` / `plan=` / `toggle_plan` / `plan_mode_label` own the posture
  (a harness posture, NOT conversation state, so `Session#restore` never sees
  it).
- `Commands::PlanCommand` (`/plan [on|off|status]`) toggles it and reports.
- `Task.mode_badge` renders one bracket per NON-default posture, and - since
  issue #387 - the SAME builder feeds both the spinner badge and the idle prompt
  line. A `[PLAN]` tag is added there with no new plumbing.
- The startup banner names the mode (it is a fact about the run, like consent /
  palette / streaming).

The posture is session state (it is a per-run choice, like `stream` and the
palette), but the *plans themselves* are durable store state. Those are two
different things and the design keeps them separate: **the mode is per-session;
the plans are per-workdir.**

## Active plan: one per agent, pointing into the durable store

(Owner note: "one active plan in session"; and "active per agent", because a plan
can be split into sub-plans run by sub-agents, each with its own session.)

The durable store holds many plans. A session (or a sub-agent's session) has at
most **one active plan**: a pointer (the plan's name) to one entry in the store.
This is what reconciles "not bound to session" (the store) with "one active plan
in session" (the pointer):

- The **store** is durable and shared across sessions in the workdir.
- The **active-plan pointer** is session state: saved in `session.json`
  (`data[:active_plan]`) and restored by `Harness#apply_resume_state`, like the
  streaming posture, so a resumed session picks up where it left off.
- "Active" is what the planning loop iterates and what hard mode gates on (see
  enforcement). A session with no active plan is in planning mode but has not
  drafted one yet.

Because the pointer is per-session and the store is shared, **each agent has its
own active plan** while reading the same store. That is exactly the shape #286
(sub-agents, each its own session/harness) needs: a parent agent's active plan
can reference sub-plans, and each sub-agent sets its own active plan from the
shared store. See "Sub-plans and sub-agents" below.

## Naming: mnemonic names for stored plans

(Owner note: multiple plans persisted "with nice mnemonic name (some gem like
unique_names_generator)".)

A plan needs a name the model can type and a human can read. Two shapes:

**A. A built-in adjective-noun generator (recommended).** A small wordlist
(`ADJECTIVES` x `NOUNS`, Heroku/docker-container style: `brave-curie`,
`quiet-falcon`) in `Plans`, producing a name when the model adds a plan without
one. Zero new dependency, deterministic-enough, and it matches the project's
deliberate dependency policy (the Gemfile justifies every gem in a comment; a
naming nicety does not earn one). Collisions are handled the way `Memories`
handles an existing name: refuse and ask for a different name (or `overwrite`).

**B. The `unique_names_generator` gem** (the owner's suggestion). It is pure Ruby
and small, and it is a well-known adjective+surname generator. The cost is a new
runtime dependency for a convenience the harness can provide in ~30 lines. The
house lean is "no unnecessary deps", so the built-in list is the default
recommendation; the gem is the alternative if the owner wants a larger, curated
name pool than a hand-written list.

Either way the name is a NAME (one segment, folded), and the model may also pass
its own mnemonic name when it adds a plan (the generator is the fallback, not a
mandate).

## The `plan.*` tool set and `/plans`

(Owner note: "should there be 'plan.xxx' tool set?"; "existing saved plans can be
listed"; "model can search plans".)

Yes - a `plan.*` tool set mirroring `memory.*` (which is `memory.list` /
`memory.read` / `memory.add` / `memory.delete`), all rendering through the one
`Plans` object:

- `plan.list` - every stored plan's index line (name + first-line description),
  like `memory.list`.
- `plan.read(name)` - one plan's body as an ordinary tool result.
- `plan.add(name?, text)` - save a plan; a name is generated when omitted.
- `plan.write(name, text)` (or `overwrite: true` on add) - revise a plan; a plan
  is corrected in place, the way a note is.
- `plan.delete(name)` - remove one plan (no DELETE grant: it is the removal of a
  named plan, not a file delete, same as `memory.delete`).
- `plan.search(query)` - substring/keyword match over plan names and bodies,
  returning the matching plans' index lines. No ranking (the same "no relevance
  ranking" honesty as `memory.list`); the model reads what it finds. This is the
  capability memories deliberately omit, added here because the owner asked for
  it and a plan store is expected to outgrow a listable one.

On the owner's side, `/plans [name]` lists the store and prints one plan's body
(the same listing and body `/memory` gives). `/plan [on|off|status]` is the
posture toggle (separate from the store commands, just as `/stream` is separate
from any store).

**Read-on-demand vs injected.** A `plan.*` tool set means a stored plan is read
when asked, not injected into every prompt - the same "never injected" rule
memories and skills follow, and the same prefix-cache protection they exist to
give (doc/memory_design.md, doc/compaction_cache_design.md). The one exception
worth stating: while planning mode is ON, the *active* plan may be injected into
the prompt so the model stays anchored to it - the user turned the mode on
knowingly, so that context cost is a deliberate choice. Whether the active plan
is injected or only read is an open decision (see below).

## Enforcement strength (the central fork - still open)

How hard does the mode stop the model from editing? The owner's notes refine
storage and tools but do not settle this, so it stays the central decision.

**A. Hard mode - write/edit tools refused until the plan is approved.**
While planning is on and the active plan is unapproved, the mutating tools
(`file.write`, `file.patch`, `file.copy`, `file.rename`, `file.delete`,
`dir.create`, `dir.delete`) return a refusal naming the reason ("planning mode:
approve the plan first"). Read-only tools (`file.read`, `file.search`, `git.*`,
`file.list`, `file.info`, and the whole `plan.*` set) stay open so the model can
investigate and draft. This is a real guarantee and matches the issue's literal
"instead of rushing to modify code".

- Seam: the gate belongs in `Harness#execute_tool_call` (the one place every tool
  call passes through). The YOLO posture is the precedent for a posture-driven
  gate: `Harness` installs `@file_list.posture = -> { yolo? }` and `FileList`
  consults it live, so a planning gate can be a second live posture the same way.
  A refusal must push a status line (`Tool.push_status`) so it is visible, and
  its text must tell the model what to do instead (draft the plan), not just
  say "no".
- Cost: invasive - it changes tool behavior for a whole class of calls. It also
  needs a crisp definition of "approved" (see the loop section).

**B. Advisory mode - a strong instruction, no tool block.**
While planning is on, the prompt instructs the model to plan first and not edit
until the plan is agreed, but the tools are not blocked. Lightest touch; follows
the posture pattern exactly. The model can still edit if it ignores the
instruction - a nudge, not a wall.

**C. Minimal - a `/plan` command, no persistent mode.**
`/plan <goal>` runs one round that drafts a plan, saves it, and shows it for
iteration. No on/off posture, no `[PLAN]` tag, no tool block. The owner's notes
(list, search, tool set, active-per-agent) go well beyond this, so C is likely
too small for what the owner now wants; it is kept only as the floor.

The issue's wording leans toward A, but A is the most invasive; the owner's
choice here decides the rest.

## The iteration loop and what "approved" means (still open)

A concrete loop for the active plan:

1. Model drafts a plan (text, no edits - guaranteed only in hard mode) and saves
   it; it becomes the session's active plan.
2. Harness shows it and asks via `UI::Dialog`: **Approve** / **Iterate** /
   **Cancel**.
3. **Iterate**: the user types feedback (a normal prompt), the model revises the
   stored plan, loop back to 2.
4. **Approve**: the plan is locked and the mode's editing restriction lifts (hard
   mode) or the mode ends (advisory).
5. **Cancel**: the mode turns off; the plan stays in the durable store (it is
   durable, so dropping it would contradict the storage decision).

"Approved" needs one definition because hard mode gates on it. The simplest:
planning mode is on until the plan is approved, and approval turns the mode off
while leaving the plan stored. That collapses the enforcement gate to "mode on ==
not yet approved" and avoids a separate `plan_approved?` flag.

## Sub-plans and sub-agents (#286)

(Owner note: when implementing a plan, the model could split it into sub-plans
done by sub-agents; "active per agent"; agents have their own session.)

#286 ("Idea: agent.explore tool") proposes sub-agents that run their own task
loop in their own harness/session and return structured results, so the main
context stays small. Planning mode and #286 compose through the durable store:

- A parent agent's active plan can name sub-plans (steps to be delegated).
- Each sub-agent, having its own session, sets its **own active plan** from the
  shared store - so "active plan" is genuinely per-agent, not global, exactly as
  the owner notes.
- Because the store is shared across sessions in the workdir, a sub-agent can
  `plan.read` the parent's plan and `plan.add` its own sub-plan without any new
  cross-session plumbing - the durability the owner asked for is what makes this
  work.

This is forward-looking: it depends on #286 existing. Planning mode does not need
#286 to be built first, but its storage shape (durable, shared, name-addressed)
is chosen so that #286 can use it later without a redesign. The two issues stay
independent.

## What planning mode is NOT

- **Not a replacement for `harness.md`.** harness.md is the owner's standing
  coding rules injected every turn; a plan is task-scoped and temporary.
- **Not a memory.** A memory is a short durable *fact* (capped, not searched); a
  plan is a longer durable *approach* (searchable). They share a store shape and
  a consent model but are different kinds of knowledge, in different directories.
- **Not a transcript or a scratch pad.** It is the agreed approach, not a log of
  what was tried.
- **Not a guarantee in advisory mode.** Only hard mode actually prevents edits.
- **Not shared across worktrees** (same as memories): the store resolves from the
  working directory, and git gives each linked worktree its own. The cross-checkout
  question is the one doc/memory_design.md defers (issue #365); a plan store
  inherits the same answer and the same open question.

## Where it would surface (if built)

- `/plan [on|off|status]` - toggle the planning posture.
- `/plans [name]` - list the durable store, or print one plan's body.
- `plan.list` / `plan.read` / `plan.add` / `plan.write` / `plan.delete` /
  `plan.search` - the model's side of the store.
- `[PLAN]` tag in the prompt line and spinner badge (via `Task.mode_badge`, the
  shared builder from #387), shown only while the mode is on (a tag names a
  non-default posture).
- The startup banner line (the mode is a fact about the run).
- `session.json` (`data[:active_plan]`) and a resume that restores the pointer.
- harness.log - the plan drafts and approvals, the way every LLM round is logged.

## Suggested first cut (pending the owner's decision)

The smallest thing that satisfies the owner's notes (durable, multiple, named,
listable, searchable, active-per-session) without the invasive tool gate:

1. `Plans` store (`lib/plans.rb`, `.harness/plans/`) mirroring `Memories`:
   one reader/writer, name-not-path, no grant, built-in mnemonic names, a body
   budget, and `plan.search`.
2. `plan.*` tools + `/plans` (list/read/add/write/delete/search).
3. A `/plan` posture following `/stream` exactly, with a `[PLAN]` tag and a
   `data[:active_plan]` session pointer restored on resume.
4. An advisory instruction while the mode is on (no tool block yet), plus the
   approve/iterate/cancel `UI::Dialog` loop on the active plan.

Hard mode (the tool gate) and the #286 sub-plan split are then layered on as
separate decisions once the store and loop are proven. This reuses every existing
seam and adds no tool-behavior change in the first cut.

## Open decisions / deferred

- **Enforcement strength**: hard tool gate vs advisory instruction (the central
  fork; C/minimal now looks too small for the owner's notes).
- **Naming**: built-in wordlist (recommended) vs the `unique_names_generator` gem.
- **Active plan injected vs read-on-demand** while the mode is on (the
  prefix-cache cost memory_design.md resolved as "never injected").
- **Caps**: a plan body budget and a store size cap (memories cap at 40/2000 to
  keep listing affordable; a searchable plan store can be larger but still needs
  *some* cap to avoid unbounded growth).
- **Search depth**: plain substring match (recommended, no ranking) vs anything
  smarter.
- **Whether a plan survives `/session-clear`**: it is not conversation state, so
  arguably it should - but that must be decided, not inherited.
- **Whether the posture needs a config key for its initial value** (like
  `streaming`) or is session-only (like the palette choice).
- **Sub-plan split via #286**: depends on #286; the store is shaped for it but the
  split itself is a later issue.
