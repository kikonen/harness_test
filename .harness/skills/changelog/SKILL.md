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

4. Superseded wording is rewritten IN PLACE, never annotated: when a later issue
   deletes what an earlier entry described, reword the earlier entry to describe
   what the code does NOW (or fold it into the superseding entry). No
   "(superseded by #N)" patches.

5. Apply the window rule and write newest-window-first.

6. Regeneration is docs-only: it touches no `lib/` or `spec/` file, so rubocop and
   rspec must come out unchanged. Run both and say so in the PR.

7. Run the check, and do not report the file before it passes:

   ```
   ruby .harness/skills/changelog/verify.rb \
     CHANGELOG.md tmp/keep/<n>/merged_prs.tsv <horizon_start> .
   ```

   Exit 0 = PASS. The horizon start is the oldest date the header still covers.
   The two full windows are read from the dataset (its two newest `mergedAt`
   dates), so nothing is hard-coded and the check follows the horizon.

## What the check asserts (and why each rule is here)

- Every full-window PR is the number of its own `###` heading.
- Every one-line-window PR is the PRIMARY number of exactly one bullet: the
  number after `- ` (or `### `). A PR primary on two or more lines is reported
  as GROUPED, and a PR folded into another PR's line is reported MISSING (it lost
  its own line). This is the rule a hand-written regeneration breaks most often:
  measured, running this check on PR #337's 302-line file gives 58 fails - 49
  one-line PRs MISSING (49 of 50), 1 full-window PR with no `###` heading (the
  newest window), 6 SHARED multi-PR lines, 1 dangling doc, 1 line over 90 chars.
  The same check on the 951-line origin/master file gives 56 fails, and on the
  regenerated tmp file it PASSES.
- A line may name a second horizon PR only as a CROSS-REFERENCE, and only when
  that PR has a line of its own (e.g. `- #245 ... (follow-up to PR #243)`).
- No PR merged before the horizon start is named (a stale entry survives when the
  horizon moves: measured, one such PR in the 951-line master file).
- Zero `## Unreleased` sections. Measured on master before any regeneration: 25.
- Every `doc/<name>.md` the file points at exists, or sits next to the generated
  file (the regeneration PR carries its own procedure doc, so a pointer to a doc
  that is not on master yet is not a dangling link).
- No line over 90 chars. Measured: PR #337's file had one at 94. The check itself
  is held to 90, because a helper script is ordinary code: `analysis/*.rb` is
  rubocop-covered (gotcha recorded by #347), and `.rubocop.yml` excludes
  `.harness/**/*`, so nothing else would catch it.

## Window rule

- Last two merge windows: full entries, condensed per step 3.
- Older windows: one line per issue/PR (number + title). PRIMARY means the line
  starts with `- #<n>`: a PR may not be folded into a sentence about another one.
- Older still: nothing in the file - `git log` and `gh pr list --state merged` are
  the archive. State where the horizon sits in the header, with the measurement
  behind it; the horizon moves on each regeneration.

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
