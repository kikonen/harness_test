---
name: changelog
description: "Regenerate CHANGELOG.md from the merged PR bodies (the #305 procedure)"
---

# Regenerate CHANGELOG.md

A merged PR's body IS its changelog entry. A PR does not touch CHANGELOG.md any
more - not a section, not an entry, not a "Record the #N in CHANGELOG" commit.
CHANGELOG.md is a GENERATED file: rewritten on request from merged PR bodies and
commit subjects, and the regeneration is its own docs-only PR (or one docs commit).

## Procedure

1. List the merged PRs for the window (`mergedAt` is the window key; two merged
   PRs on one day are one window):

   ```
   gh pr list --state merged --limit 200 --json number,title,mergedAt \
     --jq '.[] | "\(.mergedAt[0:10]) #\(.number) \(.title)"' | sort
   ```

   Save the same list as a TSV dataset - `number \t date \t closing-issues \t
   title` - because step 7 checks the written file against it, not against
   memory. `closingIssuesReferences` is the field name for the third column
   (`closesIssues` does not exist in this gh version).

2. Pull the material, only for the window being written:

   ```
   gh pr view <n> --json body -q .body
   gh pr view <n> --json commits --jq '.commits[] | "\(.oid[0:7]) \(.messageHeadline)"'
   ```

   A PR body contains more than the entry (the test plan, the "## Merge" prose,
   text addressed to the reviewer). Condense, do not paste.

3. Condense by a fixed rule. An entry keeps:

   - what changed (the API/behavior, named),
   - the measured numbers that were the point of the change (counts, offense
     counts, suite counts, before -> after),
   - the invariant or gotcha the code cannot state (an ordering constraint, a
     refusal that must stay refused),
   - the spec files that carry the contract, by name.

   It DROPS the subsystem's rationale - that belongs in `doc/<topic>.md`,
   `harness.md` (rules only) and the issue. For such a change the changelog line
   is one sentence plus the doc pointer.

4. Superseded wording is reworded only at the TOP of the file (see the append-only
   rule below): the newest existing date section may be rewritten in place when a
   later PR changes what it described. Older sections are NEVER touched. No
   "(superseded by #N)" annotations.

5. Apply the horizon rule: the file carries one date section per merge date
   (newest first), a bullet per merged PR in the horizon (>= the horizon start the
   header states), and nothing older than the horizon - `git log` and
   `gh pr list --state merged` are the archive. The horizon moves each regeneration.

6. Regeneration is docs-only: it touches no `lib/` or `spec/` file, so rubocop and
   rspec must come out unchanged. Run both and say so in the PR.

7. Run the check, and do not report the file before it passes:

   ```
   ruby .harness/skills/changelog/verify.rb \
     CHANGELOG.md tmp/keep/<n>/merged_prs.tsv <horizon_start> <doc_root>
   ```

   Exit 0 = PASS. The horizon start is the oldest date the header still covers;
   it is read from the dataset, not hard-coded. On a bootstrap (no previous file)
   run it as above: only the shape rules apply. On every later run pass
   `--against <previous CHANGELOG.md>` so the history (append-only) rules apply
   too, and re-run it `--against` the file you just wrote to confirm it is
   idempotent. doc_root is the checkout whose `doc/` the file's pointers resolve
   against (use `.` for the repo root).

## What the check asserts (and why each rule is here)

The check takes the generated CHANGELOG, the PR dataset TSV, the horizon start,
an optional doc_root, and `--against <previous CHANGELOG.md>`. Without
`--against` only the SHAPE rules run (this is the bootstrap run, where a whole-file
rewrite is allowed). With `--against` the HISTORY rules run too. Exit 0 = PASS.

Shape rules (measured on the 906-line origin/master `CHANGELOG.md` with
`--horizon 2026-10-10`: FAIL 62 - 53 horizon PRs MISSING, 1 STALE (#123, merged
2026-10-01), 24 `## Unreleased` sections, 77 lines over 80 cols):

- Sections are `## YYYY-MM-DD` date sections, newest first. There is no
  `## Unreleased` and no `###` subheading: each merged PR is ONE bullet.
- Every horizon PR is the PRIMARY number of exactly one bullet: the number right
  after `- `. A horizon PR that never appears as a bullet primary is MISSING; a PR
  primary on two bullets is DUP. The key is the PR number, not the issue number:
  measured on the 55 horizon PRs, 30 close exactly one issue, 25 close none
  (#333 #329 #322 #320 #287 #266 ...), 0 close two or more. Only the PR number is
  always present, so it is the only key the check can demand.
- A bullet may name a second horizon PR only as a cross-reference, and only when
  that PR has a bullet of its own (e.g. `- #245 ... (follow-up to PR #243)`).
- A bullet may wrap onto continuation lines (indented), but no bullet is longer
  than 5 lines and no line is longer than 80 columns. There are no blank lines
  inside a date section, and no stray prose line: only a bullet or its
  continuation may sit under a date header.
- No PR merged before the horizon start is named (a stale entry survives when the
  horizon moves: measured, #123 in the master file).
- Every `doc/<name>.md` the file points at exists in doc_root, sits next to the
  generated file, or exists as a relative path (the regeneration PR carries its own
  procedure doc, so a pointer to a doc not on master yet is not dangling).

History rules (only with `--against <previous>`; this is what makes regeneration
STABLE rather than a fresh rewrite every run):

- Date sections are unique and newest-first.
- A NEW date section may only be PREPENDED at the top; one inserted below older
  history breaks newest-first and is reported.
- The NEWEST previous date section may be reworded (it may even be split into a
  new section); every OLDER section must be BYTE-IDENTICAL to the previous file.
  A changed older line is REWRITTEN. This is measured: rewording the newest section
  PASSES, rewriting an older one FAILS.
- A previous date section may only disappear once it is OLDER than the horizon;
  dropping one still inside the horizon is REMOVED.

The point: a regeneration is append-only history, not a rewrite. Re-running the
check `--against` the file it just produced must PASS with no changes (measured:
idempotent). What was proven load-bearing is this history gate, not the shape gate
- a fully reworded file still passes the shape rules, which is exactly why the
history rules exist.

## Writing a PR body so it survives as an entry

In this order: what was wrong (with the measurement that proves it), what changed
(named APIs), what was measured, which specs pin it, and that the merge is a rebase
merge. Boilerplate a generator strips ("## Test plan", "## Merge" prose) is fine to
include - it is simply not part of the entry.

## What this is NOT

- Not injected into the system prompt (harness.md holds coding rules only).
- Not a design document: a subsystem's reasoning lives in doc/<topic>.md.
- Not a work log: open work lives in issues; in-flight work appears here only when
  its PR merges.
