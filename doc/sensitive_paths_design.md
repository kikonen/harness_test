# The sensitive-path guard, and the scratch zone that exempts it

What the guard is for, where it stops, and why a nested `.git` inside
`tmp/keep/<issue>/` is deletable. Issue #321.

---

## The guard

`SensitiveFiles` (lib/sensitive_files.rb) names two kinds of path a grant can
never cover:

- a BASENAME matching `SENSITIVE_PATTERNS` (`.env*`, so `config/.env.production`
  is blocked too, not only a bare `.env`);
- a path with `.git` or `.harness` as ANY COMPONENT (so `vendor/.git/HEAD` is
  blocked, not just `<workdir>/.git`).

It exists because `.git` and `.harness` are the harness's own footing: the
working tree it is editing and the session/log state it is writing. A model that
could delete either can destroy the run it is running in, and no grant dialog
can be trusted to notice the difference between `repo/.git/config` and
`repo/lib/foo.rb`.

`FileList#sensitive?` (lib/file_list.rb) is the ONE decision point. Every
permission check (`readable?`, `writable?`, `deletable?`, `grant_access`,
`add_file` / `add_dir` / `add_flat_dir`, `rename`) and every tool pre-check
(`dir.create`, `dir.delete`, `file.copy`, `file.delete`, `file.rename`) goes
through it, so the zone rule below applies everywhere at once.

## Why a name-only test was not enough

`SensitiveFiles.sensitive?` has no working directory, so it cannot know WHERE a
`.git` sits. That is why the zone decision lives in `FileList`: it owns
`@workdir`. `FileList#sensitive?` is therefore

```ruby
return false if scratch_zone?(path)
SensitiveFiles.sensitive?(path)
```

- `relative_path(path)` - canonical path relative to the workdir, or `nil`
  outside it (`resolve` has already collapsed any `..`);
- `SensitiveFiles.scratch_zone?(rel)` - `tmp/scratch/<n>/` or `tmp/keep/<n>/`.

## Measured (Windows, Ruby 4.0.7, git 2.56.0)

`tmp/keep/318` - the keep zone of the line-ending issue, which needed REAL repos
to measure git's eol behaviour: 144 entries (93 files, 51 dirs), 3 nested
`.git`, 81 files under them, 280K.

- `dir.delete tmp/keep/318`: refused -
  `contains the sensitive path 'tmp/keep/318/harnessrepo_realfile/.git/COMMIT_EDITMSG'`,
  0 paths deleted, nothing logged.
- The tree walk dir.delete performs blocked 129 of those 144 entries under the
  name-only rule and 0 under the zone rule; one recursive DELETE grant on the
  zone then covers the whole tree.
- The zone is not repo state: `git check-ignore -v` matches BOTH
  `tmp/keep/318/issue_crlf.md` and
  `tmp/keep/318/harnessrepo_realfile/.git/COMMIT_EDITMSG` to `.gitignore:5  tmp/**`,
  and `git ls-files tmp/keep` is empty.

So the standing rule "a keep zone is deleted when its issue closes" was
unexecutable for exactly the measurement the issue was about: the zone the rule
promised to clean could not be cleaned by the tool it named.

## The rule

Inside `tmp/scratch/<n>/` or `tmp/keep/<n>/`, a nested `.git`, `.harness` or
`.env*` is NOT sensitive. The guard protects this project's own state; a
disposable clone the harness itself created under `tmp/` is not that.

Nothing else changes:

- `<n>` is required. `tmp/keep/.git` and `tmp/scratch/.git` - a `.git` in the
  zone LIST, one level up - stay blocked, so the exemption cannot be widened by
  targeting the parent.
- `<n>` is any name, not a number (`tmp/keep/309-316/` is a real zone), but it
  cannot start with `.`: `tmp/keep/318/../.git/config` resolves to
  `<workdir>/.git/config` and stays blocked. That is why the test runs on the
  RESOLVED relative path.
- The zone test is on the workdir-relative path, so a workdir that merely looks
  like a zone segment (`<tmp>/keep` as the workdir) gains no exemption: the
  pattern is anchored at `tmp/`.
- `tmp/keepz/...`, `local/keep/...` and the project's own `.git`, `.harness`,
  `.env*` are untouched. `local/` is the owner's space and stays non-writable,
  so a hypothetical `.git` there is unreachable rather than exempt.
- Grant granularity is unchanged. An exemption makes a path grantable; it does
  not grant anything, and `dir.delete` still needs ONE recursive DELETE grant
  covering the whole tree.

Rejected alternatives: an exemption for delete only (a scratch repo is written
with `git`, not with the harness's file tools, and a half-block leaves a zone
that can be created but never cleaned); forbidding scratch repos under `tmp/`
(that forbids the measurement itself); hand-cleaning the zone (outside the audit
trail, and it reproduces on every future git measurement).

## A keep zone is not repo state - and never was committable

The measurement above shows the zone is invisible to git, and that is the RIGHT
behaviour, not a defect to fix: a keep zone is where a disposable clone lives, and
re-admitting `tmp/keep/` in `.gitignore` would make a scratch zone committable (the
`tmp/keep/318` tree alone was 280K with 81 files under nested `.git` dirs).

What WAS wrong is that the docs promised a keep zone holds "measurements an OPEN
issue still quotes" - evidence that then cannot reach the next session or another
machine (issue #347: `git ls-files tmp` lists only `tmp/.gitkeep`, and
`git log --all -- 'tmp/keep/*'` is empty across the whole history). The split is
now explicit:

- `analysis/<n>/` - TRACKED, like `doc/`: a `repro.rb` / `measure.sh` that runs from
  a fresh clone with no local state. This is what an issue quotes when the
  measurement must be reachable elsewhere.
- `tmp/keep/<n>/` - gitignored, local to one machine, deletable when its issue
  closes: the heavy measurement a clone needs, which must NOT be committed.

## Checked by spec

- `spec/lib/sensitive_files_spec.rb` - the name test (basename patterns, any
  component) and the zone pattern, including the `<n>`-required cases and the
  lookalike directories.
- `spec/lib/sensitive_files_spec.rb` also pins the git half of the rule (issue
  #347): real git in a tmp repo with this project's own `.gitignore`, asserting
  both scratch zones stay out of the repo while `analysis/<n>/` is trackable, and
  that nothing under `analysis/` is left uncommitted. `git add` is the test -
  `git check-ignore -v` prints the matching pattern even when it is a negation,
  so it cannot tell tracked from ignored.
- `spec/lib/file_list_spec.rb` - a zone grant covers a nested `.git`, `.harness`
  and `.env*`; a bare `.git` is still ungrantable (`:blocked`, `grant_access`
  refuses); `..` cannot smuggle a name out of a zone.
- `spec/lib/tools/dir_delete_tool_spec.rb` - a keep zone holding a scratch repo
  is deleted path by path into harness.log, while the zone list's own `.git` and
  the project's `.git` survive the same call.

The zone pattern was also mutation-probed: each weakened variant (no `<n>`
required, everything under `tmp/` exempt, keep-only) is caught by an existing
assertion.
