# The standing grant on the working directory

Why a run starts with one recursive grant instead of asking per file, why it is
a stored grant and not a posture, and why it reaches `local/` when the posture
does not. Issue #384 (the "grant recursive access to analysis/ itself" report),
resolved by the owner's broader question: "hard to imagine a situation where you
wouldn't just grant access to all files in the project instead of micromanaging
individual files."

---

## The complaint, and what the code already allowed

`FileList` had the capability the issue asked for but never surfaced it. A
recursive grant on a directory covers every file under it (`add_dir` +
`ancestor_granted?` walk up to the workdir), so a grant on the working directory
itself already covers the whole project. Measured on a scratch workdir (the
`grant_workdir:` default seeded):

| path | readable / writable before | after the standing grant |
|---|---|---|
| `lib/foo.rb` | no / no | yes / yes |
| `analysis/246/repro.rb` | no / no | yes / yes |
| `local/notes.md` | no / no | yes / yes |
| `.env`, `.git/config`, `.harness/log` | no / no | **no / no** |
| `../outside.rb` | no / no | **no / no** |

The last two rows are the whole design: the sensitive guard is a NAME rule
(`SensitiveFiles.sensitive?`, consulted before any grant lookup) and the outside
rule is a CONTAINMENT rule (`within_workdir?`), so neither is reachable by a
path grant on an ancestor. "Grant everything in the project" and "keep `.git`
and `.harness` ungrantable" are not in tension - they live at different layers.

## Why a stored grant, not another posture

#274 already shipped a workdir-wide coverage: the YOLO posture
(`FileList#posture_covers?`) auto-covers read/write/delete inside the workdir.
The standing grant is deliberately the OTHER kind:

| | posture coverage (#274) | standing grant (#384) |
|---|---|---|
| stored in `@grants`? | no (never reaches `accessible_paths`) | yes (an ordinary recursive dir grant) |
| visible to `/grant` | as a separate posture line | as "the working directory (recursive)" |
| saved with / restored by a session | no (a resume must not inherit a posture) | yes (it is in the session's access section) |
| removable mid-run | only by `/yolo off` | by `/clear` |
| reaches `local/` | no (`protected_dirs`, #385) | yes (owner's decision, 2026-11-03) |

## Revoking a grant from the CLI

`/clear` is the revocation path, and it is now a FORM command: bare (or
`clear access`) is the file/dir access list - the standing grant included - while
`clear commands`, `clear shell` and `clear hosts` revoke the other consent lists,
which had no revocation path at all before issue #104 (a stored prefix or host
could only be removed by hand-editing its `.yml`). The forms are independent:
the default one has always left the command allowlists untouched (issue #129) and
still does. Revocation is immediate for a run already in progress - see
`CommandAllowlist#reload!` and `WebHostAllowlist#reload!`: both re-read their
file before deciding, because a runner or tool instance lives for a whole run,
and a snapshot taken at start would otherwise keep honouring - or even write
back - a grant the user just revoked.

The reason to keep both: a posture is a live *behaviour* a user flips at the
prompt, so it must never persist into a resumed run's stored grants. A standing
grant is a *property of the project* the owner wrote in their own config, so it
should behave like every other grant - visible, saved, and revocable like any
grant. `#seed_standing_grant` runs BEFORE `Harness#initialize` restores a
session, and `Session#restore` clears the list first, so a resumed run ends with
exactly the grants its session file saved: a `/clear` made before saving is not
silently undone by the resume (the #105 rule that a grant must never reappear
from nowhere).

## Why it covers `local/` when the posture does not

`local/` is the owner's space. The harness.md rule "never write, never delete
there" was always a rule for the MODEL; the code-enforced protection is the
consent dialog itself, and the posture leaves `local/` asking precisely so an
auto-approval never quietly removes that veto (#385).

A standing grant is not an auto-approval - it is the dialog decision made once,
by name, in the owner's own config. When the owner writes `grant_workdir: true`
they have already granted the project including `local/`. So the standing grant
honours the config and covers `local/`; only a run that did NOT declare it
(`grant_workdir: false`) keeps the per-path dialog that protects `local/`. This
is the one place the two workdir-wide mechanisms genuinely differ, and the
reason they are two separate config keys rather than one.

## Why default ON

`#384` is consent fatigue, and the owner's framing was that per-file
micromanagement is the surprising default, not the wanted one. So the key is
`grant_workdir: true` (default; only an explicit `false` opts out, the
`auto_save` / `bang_requires_confirmation` tri-state). Every non-default posture
is named in the startup banner so a run that asks for nothing is never mistaken
for a run that protects nothing:

```
Command consent: MANUAL - unapproved commands ask (/yolo status shows the postures)
File consent: standing grant on C:/work/project - read, write and delete inside the
  project run without asking (.git/.harness/.env* and any path outside it still ask;
  /clear removes the grant, /grant shows it)
```

## Where the change lives (and where it does NOT)

`CLI#build_file_list` seeds it, `CLI#seed_standing_grant` / `#grant_workdir?`
apply the key, `CLIOptions` carries `grant_workdir:` from the config (no CLI
flag - a run that starts with no file consent must not be reachable by a
mistyped flag), `HarnessConfig#grant_workdir?` holds the tri-state, and
`/grant` labels the workdir entry. `FileList` itself is untouched: its
constructor default stays "no standing grant", so every caller that builds a
list directly (specs, tools, library users) is unchanged and no permission-check
method grew a new branch. That is what kept the whole existing FileList/tool
suite green: the new behaviour is one line of seeding at the top of the app, not
a change to the model underneath.

## What the standing grant does NOT change

- The `dir.create` target-first rule (#54): a not-yet-existing directory is
  still offered as its own grant so creating it does not make the parent's
  existing siblings writeable. With the standing grant on, this rarely surfaces
  (the workdir grant already covers it); it still governs paths outside the
  workdir and a run that opted out.
- The two directory tiers (dir-only vs recursive) and the per-mode split stay in
  the model for every path the standing grant does not cover. Simplifying the
  tier model itself is a separate question from ending the per-file dialog; it
  is left open here rather than half-changed.
- The sensitive guard, the scratch-zone and skills exemptions, the outside-the-
  workdir warning, and the disaster denylist (for shell) are all independent of
  this key.
