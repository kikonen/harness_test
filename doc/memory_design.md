# Memory: durable notes in .harness/memories

What a memory is for, why nothing of it is in the system prompt, why its writes
need no grant, and what it does NOT do. Issue #10.

---

## The problem a memory solves

A session ends and everything the model learned while working with it goes with
it: which command in this repo is the slow one, why a file must not be renamed,
what the owner decided about a subsystem. The next session in the same project
discovers the same things again, at the cost of the same exploration. `harness.md`
cannot hold them (it is the owner's coding rules, injected into every prompt), and
a skill is a procedure the *owner* wrote, not something the model may append to.

A memory is the third kind of durable project knowledge: **a short note the model
writes itself, that a later session in the same project can read back.**

## The invariant

**A memory is never in the system prompt.** Nothing from `.harness/memories/` is
injected, at startup or after a write. The model learns the feature exists from
the tool descriptions (`memory.list`, `memory.read`, `memory.add`,
`memory.delete`), and learns what was stored by calling `memory.list`.

This is the same rule skills already follow (doc/skills_design.md) for the same
reason: a store the model can append to must not cost context on turns that never
read it. It is also what keeps the server's prompt prefix cache intact - a memory
written mid-session rewrites no chain message, so a note costs nothing until a
session asks for it. The alternative (injecting the whole store, like
`harness.md`) was considered and rejected: every note would then be paid for on
every turn, and a mid-session write would drop the prefix cache (the same cost
issue #238 measured for a different cache-resetting feature).

## One reader, one directory, and a name - never a path

`lib/memories.rb` (`Memories`) is the ONLY reader and writer of the store.
`memory.list`, `memory.read`, `memory.add`, `memory.delete` and `/memory` all
render through the one object `Harness#memories` hands them, so what the owner
inspects and what the model reads cannot drift apart (the same shape as Skills).

The load-bearing rule is that **a memory call names a note NAME, never a path**:

- the directory comes from `Memories::DIR` under the workdir, and
- `normalize_name` accepts ONE path segment (no separator, no `..`, no drive, no
  leading dot, no `<>|"?*`, no control byte), same rule as `Skills#normalize_name`.

A name like `../sessions/<id>/session.json` is therefore refused, and the store
cannot be turned into a general writer inside `.harness/` - which is the point,
because every other `.harness/` path is ungrantable to the file tools
(`SensitiveFiles::SENSITIVE_DIRS`).

Names are also **folded to lowercase**. The store is named by the model, which
cannot see the filesystem's case rules: measured here on Windows, `File.file?` of
`EXACT-NAME.md` matches `exact-name.md`, and CI runs on ubuntu where the same two
names are two files. Without the fold, "this name already exists", the note cap,
and "one note per topic" would each mean something different depending on the
platform, and near-duplicate notes would be invisible to the model. The file's own
case on disk is left alone (a hand-authored `Fact.md` is the owner's, not the
store's to rename) - it is found by its folded name.

## Consent: no grant, and the ordinary tool log line

A memory write asks for **no FileList grant** and no dialog. The owner's decision
(issue #10) and the reason agree: the grant system exists to gate *paths the model
chooses*, and a memory call cannot choose one - only a note name inside one fixed
directory the harness owns. Harness-owned state (session.json, harness.log) has
never asked either.

Writes are not invisible, though: `Harness#execute_tool_call` already logs every
call and its result (`tool memory.add → ok: saved memory 'x' (43 chars)`), so a
memory change is in harness.log the way every other tool change is. The tools do
NOT log a second copy of that fact - a duplicate line is one more thing to keep in
sync, and `dir.delete` logs per-path only because it removes many paths in one
call.

`memory.delete` likewise takes no DELETE grant: it is not a file delete, it is the
removal of one note the model named.

## The caps, and why refusing is the right answer

`MAX_MEMORIES = 40` notes, `MAX_BODY_CHARS = 2000` per note. Over either,
`memory.add` REFUSES rather than truncating or evicting.

- A body over the cap is a subsystem document pretending to be a memory; that
  content belongs in `doc/<topic>.md` (the rule harness.md already states), and a
  silent truncation would store a broken note the model believes is whole.
- An 41st note forces curation: the refusal names the way out (read the narrow
  notes, write one broader one, delete the narrow ones). Without a cap the store
  grows into exactly the always-paid-for context the injection rule exists to
  avoid, just one note at a time.
- A full store still allows **revising** an existing note (`overwrite: true`): the
  cap limits how many notes exist, not how often one may be corrected. Correcting
  a note must stay cheaper than leaving a wrong one, because a later session reads
  a stored note as fact.

A note that already exists is refused unless `overwrite: true` is passed - a note
is never lost by an accidental second `memory.add` of the same shape.

## Read and write boundaries

The file is written with exactly one trailing newline (a text file keeps one) and
read back through `FileText.from_disk` + `TextNormalizer` with the terminator
chomped, so `#body` returns the note's CONTENT - the same length the body cap is
stated in and the number the tools report. A note authored on Windows (CRLF on
disk) reads as LF text and the file on disk keeps its own style, and bytes that
are not valid UTF-8 come back as the `?` stand-in rather than raising (issue #341:
this content goes straight into a message chain, and a byte invalid in UTF-8 would
make the next request body raise).

Text arriving from a tool call is normalized the same way, so a note whose text
carries CRLF or an undecodable byte is stored as clean UTF-8 LF.

## What a memory is NOT

- **Not repo content.** `.gitignore` already ignores `.harness/*` and re-includes
  only `.harness/skills/`, so `.harness/memories/` is ignored with no new rule:
  notes are this checkout's harness state, exactly like sessions and the log.
- **Not session state.** It is never serialized into session.json and a note saved
  under one session id is readable by a harness built under another id in the same
  workdir. Compaction, `/session-clear` and `/resume` cannot touch it.
- **Not memory of the conversation.** It is not a transcript, not a scratch pad,
  and not a place to save file contents (the model can read those itself, cheaper).
  `memory.add`'s description states this so the model does not use it as a cache.
- **Not shared across worktrees.** `Memories` resolves from `Harness`'s working
  directory, and git gives each linked worktree its own. So notes hold over
  *sessions in one workdir* - the issue's "hold over different sessions" half -
  and NOT over another worktree of the same repository. Making them shared would
  mean storing them under `git rev-parse --git-common-dir` (the main checkout's
  `.git`), i.e. writing harness state into the git directory, or a config setting
  naming a shared store; neither was chosen (the owner picked the per-workdir
  store for #10). A project whose worktrees must share notes keeps them in
  `harness.md` or a skill instead - both are repo content and both are shared.
- **Not injected, not searched.** There is no relevance ranking and no keyword
  search: `memory.list` returns every note's index line and the model decides what
  to read. 40 notes is the size at which that is still affordable; if it ever is
  not, the answer is a smaller store or a real search, not a bigger cap.

## Where it surfaces

- `memory.list` - `Memories (2/40), read one with memory.read:` then
  `name - description` per note; an empty store answers with the way to fill it.
- `memory.read(name)` - the note body as an ordinary tool result.
- `memory.add` / `memory.delete` - one status line, plus the harness' tool-call log
  line.
- `/memory [name]` - the same listing and the same body text, on the owner's side.
- harness.log - `tool memory.add → ...` / `tool memory.delete → ...`.
