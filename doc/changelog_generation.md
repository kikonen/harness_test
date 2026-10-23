# How CHANGELOG.md is produced (issue #305)

Verified against `master` `a421270` on 2026-10-24: 126 merged PRs, 364 commits,
**2 merge commits** (unchanged: both predate the rebase-merge rule; the 13 PRs
merged since left no merge commit behind)
(`git rev-list --count --merges origin/master` = 2, `git rev-list --count
origin/master` = 364); 62 of those PRs are in the file's horizon (merged on or
after 2026-10-10), 64 are older than it. PR bodies run 1.2K-12K chars. The old
hand-maintained CHANGELOG.md was 951 lines with 25 separate "Unreleased"
sections and no roll-up (measured on master before the first regeneration); at
the time issue #305 was filed it was 466 lines / 13 such sections. Every merged
PR had also added a "Record the #N ... in CHANGELOG" commit that duplicated its
own PR body.

## The rule

**A merged PR's body IS its changelog entry.** A PR does not touch
CHANGELOG.md any more - not a section, not an entry, not a fix-up commit.
CHANGELOG.md is a GENERATED file: it is rewritten, on request, from the merged
PR bodies and commit subjects, and the regeneration is its own small docs-only
PR (or a docs commit of one).

Why the PR body is enough (measured, not assumed):

- Every one of the 24 hand-written sections maps 1:1 to a merged PR - the only
  split was #28 (two sections from the single PR #329, step 1 / step 2).
- Those PR bodies are LONGER than the sections derived from them (PR #322 body:
  12 106 chars vs its 86-line section), so nothing was being gained by hand-
  copying them into the file.
- Rebase merges leave no merge commit, so each PR's own commit subjects are
  reachable on master, and `gh pr view <n> --json commits` lists them.

So the maintenance cost drops from "write an entry per PR + a docs commit per
PR + roll the section up later" to "write one body you already had to write".

## Procedure (when the owner asks for the changelog to be updated)

1. **List the merged PRs** for the window:

   ```
   gh pr list --state merged --limit 200 --json number,title,mergedAt \
     --jq '.[] | "\(.mergedAt[0:10]) #\(.number) \(.title)"' | sort
   ```

   `mergedAt` is the window key. Two merged PRs on one day are one window.
2. **Pull the material** per PR (and only for the window being written):

   ```
   gh pr view <n> --json body -q .body                 # the entry, raw
   gh pr view <n> --json commits --jq '.commits[] | "\(.oid[0:7]) \(.messageHeadline)"'
   ```

   A PR body contains more than the entry: the test plan, the "## Merge"
   section, prose addressed to the reviewer. **Condense, do not paste.**
3. **Condense by a fixed rule**: an entry keeps
   - what changed (the API/behavior, named),
   - the measured numbers that were the point of the change (counts, offense
     counts, suite counts, before -> after),
   - the invariant or gotcha the code cannot state (an ordering constraint, a
     refusal that must stay refused),
   - the spec files that carry the contract, by name.

   It DROPS the subsystem's rationale - that belongs in `doc/<topic>.md`,
   `harness.md` (rules only) and the issue. Measured: fourteen such docs on master
   (see `ls doc/`), thirteen of them pointed at from CHANGELOG.md, so every pointer
   in that file resolves; the changelog line for such a change is one sentence plus
   the doc pointer. A pointer to a doc that does not exist yet is a bug the
   regeneration check catches.
4. **Superseded wording is rewritten in place**, never annotated: when a later
   issue deletes what an earlier entry described, the earlier entry is reworded
   to describe what the code does NOW (or folded into the superseding entry).
   The old file needed two inline "(superseded by #280)" patches inside the
   #276 entry; that patch-style accretion is what this rule removes.
5. **Apply the window rule** (below) and write the file newest-window-first.
6. Regeneration is a **docs-only change**: it touches no `lib/` or `spec/`
   file, so `rubocop` and `rspec` must be unchanged by it (measured: they are,
   nothing reads CHANGELOG.md - only README's layout line names the file).

## The lag rule (why the check does not demand total coverage)

A regeneration run cannot bullet its own PR (the number exists only once the PR is
opened) nor any PR merged after the dataset it read, so the file is ALWAYS behind
the merged-PR list. Before this rule that gap was an unmeasured gotcha written
inside one bullet (#350: "the NEXT run absorbs it") and the check simply reported
those PRs as MISSING on every run - PASS was only reachable with a dataset frozen
at the file's own writing time.

The file's header now states the count it was written against (`59 in the horizon`)
and the check compares it to the dataset. The newest `horizon.size - declared` PRs,
newest-first, are the LAG: they are printed whether or not they are tolerated (a
silent pass would hide exactly the fact this rule exists to keep visible), and they
are the ONLY uncovered PRs the check accepts. `--strict` turns them back into
`MISSING`, which is what an archival audit run wants.

Measured on a `gh pr list --state merged` dataset through 2026-10-23 (126 merged
PRs; horizon start 2026-10-10 -> 62 horizon PRs; the file's header declares 59),
against master `a421270`: the file PASSES with `lag: 3 newest ... #356 #354 #353`,
`--strict` FAILS (3), a header with no count FAILS (5: `HEADER has no horizon count`
plus the four uncovered bullets), a header claiming 999 FAILS (5: `stale claim` plus
the same four). Deleting a MID-history bullet - #205, merged 2026-10-10, inside the
horizon - FAILS (1) `MISSING #205` while the same 3-PR lag is printed: the
tolerance covers the newest merges and nothing else, so the append-only rule still
catches a hole in the middle of history.

## Window rule

- **Last two merge windows**: full entries, condensed per step 3.
- **Older windows**: one line per issue/PR (number + title), enough to name
  what happened and where to look.
- **Older still**: nothing in the file. `git log` and
  `gh pr list --state merged` are the archive; the header states where the
  file's horizon sits (with its own count, which is the lag rule's anchor), and the
  horizon moves when the file is regenerated.

## Writing a PR body so it survives as an entry

The body needs, in this order: what was wrong (with the measurement that proves
it), what changed (named APIs), what was measured, which specs pin it, and a
statement that the merge is a rebase merge. Boilerplate a generator must strip
("## Test plan", "## Merge" prose) is fine to include - it is simply not part
of the entry.

## What this file is NOT

- Not injected into the system prompt (`harness.md` holds coding rules only;
  the header of CHANGELOG.md says the same thing).
- Not a design document: a subsystem's reasoning lives in `doc/<topic>.md`.
- Not a work log: open work lives in issues, and in-flight work is not written
  here at all - it appears when its PR merges.
