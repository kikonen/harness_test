# The sensitive-path guard, and the two zones that exempt it

What the guard is for and where it stops: why a nested `.git` inside
`tmp/keep/<issue>/` is deletable (#321), and why `.harness/skills` is grantable
while the rest of `.harness/` is not (#12, `doc/skills_design.md`), and why the
owner's own space `local/` is a THIRD kind of region - grantable, but never
covered by a posture (#274).

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
rel = relative_path(path)
return false if SensitiveFiles.scratch_zone?(rel)
return SensitiveFiles.env_named?(path) if SensitiveFiles.skills_zone?(rel)
SensitiveFiles.sensitive?(path)
```

- `relative_path(path)` - canonical path relative to the workdir, or `nil`
  outside it (`resolve` has already collapsed any `..`); both zone tests run on it.
- `SensitiveFiles.scratch_zone?(rel)` - `tmp/scratch/<n>/` or `tmp/keep/<n>/`.
- `SensitiveFiles.skills_zone?(rel)` - the project's own `.harness/skills` subtree
  (issue #12), where only a `.env*` NAME still blocks: `doc/skills_design.md`.
- `SensitiveFiles.sensitive?` is split into `env_named?` / `state_dir?` so the skills
  branch can keep the NAME half of the rule while dropping the `.harness` component
  half.

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

## The owner's space: `local/` (issue #274)

`local/` is a THIRD kind of region, and it is NOT a sensitive path. A human grant
on it is legal - the harness.md rule "local/ is the owner's space (never write,
never delete)" was a rule for the model, and today the human's own dialog is what
enforces it. It is the DEFAULT entry of the posture-exemption list (issue #385):
the YOLO posture covers read, write and delete inside the working directory
without asking (#274), and an auto-approval must not quietly remove the veto the
user kept there. So the posture leaves these dirs asking, exactly as a MANUAL run
does. The list is configurable via `protected_dirs:` in the config; `local` is
what `FileList` applies when the key is absent.

The three regions a posture never covers, and what each one protects:

| region | a human grant may cover it | the posture covers it | why |
|---|---|---|---|
| a sensitive path (`.git`, `.harness`, `.env*`) | no | no | the harness's own footing |
| `local/` | yes | no | the owner's space: the dialog IS the protection |
| outside the workdir | yes, after an explicit "OUTSIDE the working directory - granting access may be a sandbox escape" warning | no | a posture loosens consent INSIDE the sandbox; an escape route stays a decision the user makes by name |

`FileList#protected_space?` checks each protected dir with
`SensitiveFiles.under_dir?(rel, dir)`, the same exact-prefix shape as the two zone
tests, so `local/../analysis` (which `relative_path` has already resolved away) is
not under `local/`, and `analysis/local/` is not either - only the named dir and
its subtree are. An explicit `protected_dirs:` list replaces the default; an
explicit empty list protects nothing.

## What the YOLO posture covers (issue #274)

The owner's complaint was consent fatigue of a specific shape: "constantly stopped
to grant access to analysis/NNN dirs, without any way to grant recursive access to
analysis itself". `FileList` had no notion of a posture at all - YOLO was read only
by `CommandRunner`, so a run that never asked about a `git log` still asked once per
file for `file.read`, `file.search` and `dir.create` (the file tools call `readable?`
on every candidate).

`FileList#posture_covers?` (lib/file_list.rb) is the answer, and its shape is the
contract:

- it is consulted AFTER the sensitive check, so the guard is never loosened;
- it requires `within_workdir?`, so the workdir is the outer bound of the coverage
  (the workdir itself has no relative form, and a `nil` rel is what makes the whole
  tree covered - that is the point of the posture);
- it rejects `protected_space?`, so a protected dir keeps its dialog;
- it is read LIVE through a lambda (`Harness#initialize` wires `-> { yolo? }`), so a
  `/yolo` at the idle prompt or a mid-turn flip applies to the very next tool call,
  and switching it off removes the coverage at once;
- it stores NOTHING in `@grants` and never reaches `#accessible_paths`, because
  consent posture is user-side state and a session saves grants - a resumed session
  must not inherit a standing file grant from a posture;
- it announces once per MODE per session (a status line plus a harness.log line):
  an auto-approval must leave a trace, the same rule YOLO's shell runs follow, but a
  per-access line would bury the log in one line per candidate file.

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
- `spec/lib/sensitive_files_spec.rb` also pins `under_dir?`: the dir and its
  subtree match, a lookalike (`localz`) and a nested name (`lib/local`) do not,
  and a resolved path that escaped it (`local/../analysis`) does not either.
  `spec/lib/file_list_spec.rb` pins the configurable `protected_dirs` list.
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
