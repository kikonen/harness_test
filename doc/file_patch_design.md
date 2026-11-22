# file.patch: locating hunks when the diff is imprecise

Design of `lib/tools/file_patch_tool.rb`: how a unified diff is applied to a file
when the model that wrote it is imprecise, and why line numbers and counts are
hints rather than facts. Line-ending handling lives in `doc/file_editing_design.md`.

## What the model is bad at, and what the tool does about it

A model-authored diff routinely has small errors. Each has a specific tolerance:

- **Wrong hunk line numbers.** Hunks are located by searching for their old-side
  lines (context + deletions), starting at the declared position and expanding
  outward (a `SEARCH_WINDOW` band), then a full-file fallback. A small line-number
  error therefore does not fail the patch.
- **Wrong line counts in the `@@` header.** The counts are hints. The hunk body is
  recounted and trusted over the header. When the body is longer than the header
  claims, excess trailing context lines are trimmed (`reconcile_counts`); when it
  is shorter, it is accepted as-is (the body is the more trustworthy source).
- **Extra or wrong context lines.** If the full old-side does not match anywhere,
  matching degrades to progressively shorter old-side patterns: context lines are
  dropped one at a time from the hunk ends (trailing first), NEVER a `-` or `+`
  edit line. The matching new-side context is dropped the same way, so the actual
  edit is never altered.
- **Blank lines inside a hunk.** Treated as context lines with empty content - a
  common quirk where the leading space of a context line is omitted.

A failure reports the first mismatching old-side line so the model can self-correct.

## Order and anchors

Hunks are applied in reverse file order so the line numbers of earlier hunks are
not invalidated by later edits. A pure insertion hunk (no old-side lines) anchors
on a new-side context line so it lands in the right place.

## External-change guard

Before applying, a file read in this session must still match its cached digest; if
the on-disk digest differs, the file changed externally and the patch would apply to
stale content, so it is refused until re-read (the cache lives in the Session). A
successful patch refreshes the cached digest, because the file is now in the exact
state the tool wrote it.

## Why patch over a full rewrite

The model only specifies the changed regions, and context lines are verified, so a
misapplied patch fails loudly instead of silently replacing a whole file.
