# How CHANGELOG.md is produced (issue #305)

Verified against `master` `a0605c0` on 2026-10-20: 118 merged PRs, 348 commits,
**2 merge commits**, both from 2026-09-27 (PR #46 and an early dialog merge) -
i.e. none since the rebase-merge rule, which is what the workflow guarantees
(`git rev-list --count --merges HEAD` = 2, `git rev-list --count HEAD` = 348),
118 PR bodies of 1.2K-12K chars. The old hand-maintained CHANGELOG.md was 916
lines / 24 separate "Unreleased" sections and no roll-up; every merged PR had
also added a "Record the #N ... in CHANGELOG" commit that duplicated its own
PR body.

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
   `harness.md` (rules only) and the issue. Nine such docs already exist
   (`file_editing`, `sensitive_paths`, `rubocop_style`, `command_help`,
   `streaming`, `output_rendering`, `encoding`, `task`, `session_file_cache`);
   the changelog line for such a change is one sentence plus the doc pointer.
4. **Superseded wording is rewritten in place**, never annotated: when a later
   issue deletes what an earlier entry described, the earlier entry is reworded
   to describe what the code does NOW (or folded into the superseding entry).
   The old file needed two inline "(superseded by #280)" patches inside the
   #276 entry; that patch-style accretion is what this rule removes.
5. **Apply the window rule** (below) and write the file newest-window-first.
6. Regeneration is a **docs-only change**: it touches no `lib/` or `spec/`
   file, so `rubocop` and `rspec` must be unchanged by it (measured: they are,
   nothing reads CHANGELOG.md - only README's layout line names the file).

## Window rule

- **Last two merge windows**: full entries, condensed per step 3.
- **Older windows**: one line per issue/PR (number + title), enough to name
  what happened and where to look.
- **Older still**: nothing in the file. `git log` and
  `gh pr list --state merged` are the archive; the header states where the
  file's horizon sits, and the horizon moves when the file is regenerated.

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
