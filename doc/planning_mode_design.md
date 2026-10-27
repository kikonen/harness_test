# Planning mode (issue #359) - design

Design notes for a proposed *planning mode*: a posture the user turns on so the
model drafts a plan, offers it for iteration, and keeps it on disk - instead of
"rushing to modify code". This is a DESIGN document only; no code is written for
#359 yet. It states the problem, the seams the feature would hook into, the
enforcement options with their costs, and the decisions that must be made before
implementation. Issue #359 stays OPEN until the owner picks a shape.

---

## The problem #359 states

A direct prompt sends the model straight into the tool loop: it reads, then
writes, often before the user has agreed on *what* it is going to change. For a
non-trivial task the user would rather see the intended approach first, correct
it, and only then let the model edit. The issue asks for three things:

1. a mode that makes the model **offer a plan** rather than start editing;
2. a loop to **iterate that plan** with the user until it is agreed;
3. the plan **saved to disk**, so it survives context compaction (the plan must
   not be summarized away with the conversation that produced it).

Point 3 is the load-bearing one and the reason this is not just "ask the model
to plan in prose": a plan that lives only as a message in the chain is exactly
what compaction rewrites.

## The invariant the design must protect

**A plan must live OUTSIDE the message chain, so compaction cannot lose it.**

Both compaction paths replace the chain with a summary:

- `SessionManager#compact_session` (the `/compact` and auto-compact path) calls
  `Session#compact`, which collapses the chain to a summary plus a retained tail.
- `SessionManager#check_inloop_compaction` (mid-turn, from `Harness#call_llm`)
  replaces the whole working chain with a fresh four-message hand-off.

The summary instructions already ask the model to carry "the original goal",
"key decisions" and "the exact next step", so a plan *might* partially survive as
summary prose - but lossily and not guaranteed. The issue wants the plan to
survive **intact**, which is only true if it is stored where neither path
touches it. That rules out "the plan is just a message in the chain".

## The posture pattern this feature follows

The codebase already has a proven shape for a user-side mode that is toggled
live, shown in the prompt/spinner tags, and persisted with the session. The
streaming posture (`/stream`, issue #28) is the template:

- `Harness#stream?` / `stream=` / `toggle_stream` / `stream_mode_label` own the
  posture (a harness posture, NOT conversation state, so `Session#restore`
  never sees it).
- `Commands::StreamCommand` (`/stream [on|off|status]`) toggles it and reports.
- `SessionManager#save_session` writes `data[:stream]`; `Harness#apply_resume_state`
  restores it, so a resumed session keeps the posture.
- `Task.mode_badge` renders one bracket per NON-default posture, and - since
  issue #387 - the SAME builder feeds both the spinner badge and the idle prompt
  line. A `[PLAN]` tag would be added there with no new plumbing.
- `HarnessConfig#streaming_enabled?` + a per-profile tri-state key set the
  initial value; `CLI#setup` resolves it into `options[:stream]`.

A planning posture slots into this exact pattern: `plan?` / `toggle_plan` /
`plan_mode_label`, a `/plan` command, a `data[:plan]` session field, a `[PLAN]`
badge. The plumbing is a known quantity; the open questions are all about
*behavior*, not wiring.

## The open decisions

These are product choices the owner must make; they are recorded here rather than
decided, because the issue is an Idea and the right answer depends on how much
the owner trusts a local model to stay in-lane.

### 1. Enforcement strength (the central fork)

How hard does the mode stop the model from editing?

**A. Hard mode - write/edit tools refused until the plan is approved.**
While planning is on and the plan is unapproved, the mutating tools
(`file.write`, `file.patch`, `file.copy`, `file.rename`, `file.delete`,
`dir.create`, `dir.delete`) return a refusal naming the reason ("planning mode:
approve the plan first"). Read-only tools (`file.read`, `file.search`, `git.*`,
`file.list`, `file.info`) stay open so the model can still investigate to build
the plan. This is a real guarantee and matches the issue's literal "instead of
rushing to modify code".

- Seam: the gate belongs in `Harness#execute_tool_call` (the one place every
  tool call passes through) or in the file tools' own grant check. The YOLO
  posture is the precedent for a posture-driven gate: `Harness` installs
  `@file_list.posture = -> { yolo? }` and `FileList` consults it live, so a
  planning gate can be a second live posture the same way. A tool that refuses
  must push a status line (`Tool.push_status`) so the refusal is visible, and
  the refusal text must tell the model what to do instead (draft the plan), not
  just say "no".
- Cost: it is invasive - it changes tool behavior for a whole class of calls,
  and a model that ignores the mode still cannot edit (which is the point). It
  also needs a crisp definition of "approved" (see decision 4).

**B. Advisory mode - a strong instruction, no tool block.**
While planning is on, the prompt instructs the model to plan first and not edit
until the plan is agreed, but the tools are not blocked. Lightest touch; follows
the posture pattern exactly (the mode is "just" an injected instruction plus a
tag). The model can still edit if it ignores the instruction - it is a nudge, not
a wall.

- Seam: the instruction rides in `SessionManager#build_user_prompt` (or a system
  note) only while the mode is on.
- Cost: no guarantee. For a model that "rushes to modify code" - the exact
  behavior #359 complains about - a nudge may not be enough.

**C. Minimal - a `/plan` command, no persistent mode.**
`/plan <goal>` runs one round that drafts a plan, saves it, and shows it for
iteration. No on/off posture, no `[PLAN]` tag, no tool block. The user invokes
planning explicitly per task.

- Seam: a command that drives an LLM round via `TaskRunner#run_on_task` (the
  shape `/retry` and `/compact` already use).
- Cost: it does not change what a *normal* prompt does, so it does not address
  "the model rushes to modify code" on ordinary turns - it only adds a way to
  plan on demand.

The issue's wording leans toward A, but A is the most invasive; the owner's
choice here decides everything else.

### 2. Where the plan is stored (so it survives compaction)

Given the invariant, the plan must live outside the chain. Options:

- **A session field (`data[:plan]` in `session.json`)**, restored by
  `apply_resume_state`. This is the closest fit: compaction rewrites messages,
  never the posture/state fields, so a plan stored here survives every compaction
  and a resume. It is per-session (a plan belongs to the task in progress), which
  is the right scope. Recommended default.
- **A dedicated file** (e.g. `.harness/sessions/<id>/plan.md`). Survives
  compaction and is human-inspectable, but adds a second store to keep in sync
  with the session and a path to define; the session field already lives in the
  same directory.
- **A memory** (`.harness/memories/`). Rejected for the plan itself: a memory is
  capped at 2000 chars and is *cross-session durable knowledge* (doc/memory_design.md),
  not per-task scratch. A plan is task-scoped and can be longer than a note. A
  memory could hold a *decision about* the plan, but not the working plan.

Whichever is chosen, the plan must be re-surfaced to the model after compaction
(see decision 3), because the chain that carried it is gone.

### 3. How the plan reaches the model

The model must SEE the current plan to iterate on it. Two shapes, with a real
cost each:

- **Inject it while the mode is on** (into `build_user_prompt`, or as a system
  note). Simple, and the user opted into planning mode so the context cost is
  their deliberate choice. But a mid-session change to an injected block rewrites
  a chain message and drops the server's prompt prefix cache - the exact cost
  doc/memory_design.md and doc/compaction_cache_design.md measure for other
  features. Re-injecting after compaction is also what makes "survives
  compaction" actually work: the stored plan is re-shown even though the chain
  that produced it was summarized.
- **A read tool** (`plan.read` / the `/plan` command prints it) so the plan is
  never in the standing prompt. Keeps the prefix cache intact (the memory/skills
  "never injected" rule), but the model only sees the plan when it asks, so the
  mode cannot reliably keep the model anchored to it.

The injection-vs-cache tension is the same one memory_design.md resolved by
choosing "never injected"; a planning mode may deliberately choose the opposite
because the whole point is to keep the plan in front of the model, and the user
turned the mode on knowingly. That trade-off must be stated, not assumed.

### 4. The iteration loop and what "approved" means

The issue wants "offer plan and ask to iterate it". A concrete loop:

1. Model drafts a plan (text, no edits - guaranteed only in hard mode).
2. Harness shows it and asks via `UI::Dialog`: **Approve** / **Iterate** /
   **Cancel**.
3. **Iterate**: the user types feedback (a normal prompt), the model revises the
   stored plan, loop back to 2.
4. **Approve**: the plan is locked and the mode's editing restriction lifts (hard
   mode) or the mode ends (advisory/minimal).
5. **Cancel**: the mode turns off, the plan is kept on disk (or dropped - decide).

"Approved" needs one definition because hard mode gates on it: is approval a
boolean on the posture (`plan_approved?`), or does approving *end* planning mode
so the gate is simply "mode on == not yet approved"? The simplest is the latter:
planning mode is on until the plan is approved, and approval turns the mode off
while leaving the plan stored for reference. That collapses decisions 1 and 4.

### 5. Scope: one active plan, or several named plans

A session most likely has one plan in progress. Multiple named plans (like
memories) add a store, a cap, and naming rules for little gain in v1. Recommend
one active plan per session; a second plan replaces or is refused until the first
is resolved.

## What planning mode is NOT

- **Not a replacement for `harness.md`.** harness.md is the owner's standing
  coding rules injected every turn; a plan is task-scoped and temporary.
- **Not a memory.** A memory is durable cross-session knowledge (doc/memory_design.md);
  a plan is the working approach for the current task and is scoped to the session.
- **Not a transcript or a scratch pad.** It is the agreed approach, not a log of
  what was tried.
- **Not a guarantee in advisory mode.** Only hard mode actually prevents edits.

## Where it would surface (if built)

- `/plan [on|off|status|<goal>]` - toggle the posture, show the current plan, or
  start one.
- `[PLAN]` tag in the prompt line and spinner badge (via `Task.mode_badge`, the
  shared builder from #387), shown only while the mode is on (a tag names a
  non-default posture).
- The startup banner line (the mode is a fact about the run, like consent /
  palette / streaming).
- `session.json` (`data[:plan]`) and a resume that restores it.
- harness.log - the plan drafts and approvals, the way every LLM round is logged.

## Suggested first cut (pending the owner's decision)

If the owner wants the smallest thing that satisfies all three points of the
issue, it is **advisory mode + a session-stored plan + a dialog iteration loop**:
a `/plan` posture following the `/stream` pattern exactly, the plan in
`data[:plan]` so it survives compaction, re-injected while the mode is on, and a
`UI::Dialog` approve/iterate/cancel loop. It adds no tool-behavior change and
reuses every existing seam. Hard mode (the tool gate) can be layered on later as
a separate decision once the loop's shape is proven.

## Deferred / open

- Whether hard mode's gate is a `FileList` posture (like YOLO) or a check in
  `Harness#execute_tool_call`.
- Whether the plan is injected (cache cost) or read on demand (anchor cost).
- Whether approval ends the mode or is a separate flag.
- Whether a plan survives `/session-clear` (it is not conversation state, so it
  arguably should - but that must be decided, not inherited).
- Whether the feature needs a config key for the initial posture (like
  `streaming`) or is session-only (like the palette choice is session-only).
