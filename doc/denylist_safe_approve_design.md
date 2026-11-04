# Denylist-safe approve: the one config-gated exception to the disaster floor

Verified against `lib/command_runner.rb` and `lib/harness_config.rb` on branch
`feature/issue-389-denylist-safe-approve` (ruby 4.0.7, RuboCop 1.92). Issue #389.
Repro: `analysis/389/repro.rb` (exit 1 on master `5d157f8`, exit 0 with the fix).

## The complaint

`CommandAllowlist.disaster?` matches the RAW command text. So a disaster word that
is inert data - the owner's probe carried `"mkfs.ext4"` inside a quoted array
literal - is flagged exactly like a real `mkfs.ext4`, and the flag refuses
auto-approval in every posture, including a stored allowlist grant and YOLO. The
model had already verdict-ed the command `safe: ... strings are inert quoted
data`, and the harness still asked. The complaint is consent fatigue caused by a
denylist FALSE POSITIVE, not by the floor itself.

## Why the fix is NOT a quote-aware denylist

The tempting fix is to make `disaster?` quote-aware: strip quoted spans, then
match. Measured (`analysis/389/repro.rb`, section 1) on both an inert command and
a real payload:

| command | `disaster?` today | quoted spans stripped |
| --- | --- | --- |
| `echo "sudo rm /data"` | true (false positive) | false |
| `ruby -e 'puts "mkfs.ext4 /dev/sda1"'` | true (false positive) | false |
| `sh -c "mkfs.ext4 /dev/sda1"` | true | **false** |
| `bash -c "sudo rm -rf /data"` | true | **false** |
| `ruby -e 'system(%q{mkfs.ext4 /dev/sda1})'` | true | **false** |

The strip silences the false positives AND un-flags every command that actually
EXECUTES the payload it quotes, because a shell payload lives inside quotes. That
is a detection hole in the floor - and `disaster?` also feeds the removal of the
"Always allow" options and the DENYLISTED dialog note, so a stripped match would
silently restore standing grants for a wipe. Therefore:

**`CommandAllowlist.disaster?` DETECTION is never weakened by #389.** Section 1 of
the repro is identical on both trees. The word-based patterns
(`recursive_force_rm?`, `win_recursive_force_delete?`) already skip quoted words;
the regex patterns (`/\bsudo\b/`, `/\bmkfs(\.|\s|$)/`, the git-push `-f` lookahead)
deliberately do not, and stay as they are.

## What the floor does NOT see (issue #392)

`disaster?` is a text gate on the command STRING. Two consequences follow from
the word-based POSIX patterns skipping quoted words, and both are measured in
`analysis/392/repro.rb` (the repro only CLASSIFIES strings, it runs nothing). A
reader must not conclude the floor catches a quoted wipe: it does not.

**A POSIX payload inside a quoted argument is invisible to the floor.** The
word scan reads unquoted words only, so the `rm` never appears as a token:

| command | `disaster?` | why |
| --- | --- | --- |
| `sh -c "rm -fr ~/"` | NOT FLAGGED | `rm` is quoted, skipped; no marker |
| `bash -c "rm -rf /home/kari"` | NOT FLAGGED | same |
| `ruby -e "system(%q{rm -fr ~/})"` | NOT FLAGGED | same |
| `sh -c "mkfs.ext4 /dev/sda1"` | FLAGGED | only because of the `mkfs` REGEX marker, not the payload |
| `bash -c "sudo rm -rf /data"` | FLAGGED | only because of the `sudo` marker, not the `rm` |

So a quoted shell payload is flagged ONLY when it happens to carry a marker word
(`sudo`, `mkfs`) that the regex patterns scan in whole text; strip the marker and
the same shape is unflagged. The Windows side is the deliberate opposite:
`cmd //c "del /q /s C:\*"` and `powershell -Command "Remove-Item -Recurse -Force"`
ARE flagged, because their patterns are whole-segment lookaheads that see inside
the quotes. Both directions are pinned as INTENDED in
`spec/lib/command_allowlist_spec.rb` ("does not flag a quoted message merely
containing rm -rf" / "flags PowerShell Remove-Item ... also inside a quoted
payload"). The asymmetry is a design choice, not a regression.

**The two-step bypass defeats the floor entirely, and no pattern fixes it.**
`file.write`/`file.patch` (WRITE grants, a consent axis the command denylist has
no part in) create a script; then `ruby tmp/evil.rb`, `bash tmp/evil.sh`,
`./tmp/evil`, `ruby -e "system(%q{rm -fr ~/})"` are each `disaster? == false`,
because the wipe lives in the file, not on the command line. `SafetyCheck`
receives only the command string, so the model judges "run a file" and cannot
know what the file does. Worse, a STORED prefix auto-approves these silently: a
`ruby` prefix (what a Ruby-project owner plausibly stores) makes
`allowed?` true for `ruby tmp/evil.rb` and `ruby -e "system(%q{rm -fr ~/})"` -
no dialog, no verdict, no `log_denylist_override` line. This is why #389's
premise holds only while the payload stays on the command line, and why the
text gate cannot be the answer to a filesystem wipe: the real mitigation is
containment (container / read-only mounts / a dedicated user), not more patterns.

## What changed instead: the OUTCOME for a "safe:" verdict

With the key armed, a real model `safe:` verdict may auto-approve a DENYLISTED
match on the tool path. The verdict is the discriminator - it is what separates
the inert literal from the executed payload when text matching cannot:
`sh -c "mkfs.ext4 ..."` comes back `dangerous:`, the inert array comes back
`safe:` (the owner's own session data showed exactly this split).

Firing conditions, all measured in `analysis/389/repro.rb` section 2 and covered
by `spec/lib/command_runner_spec.rb`:

- armed ONLY by config (see below), never by a live switch;
- `command_safety_check` must be on: no check, no verdict, no override;
- fires ONLY on a literal `safe:` verdict (`auto_approve_safe?`, unchanged rule).
  A `dangerous:` verdict or a missing verdict keeps the command fully denylisted -
  dialog, DENYLISTED note, no "Always allow" option;
- `@list == :tool` only. The `!` bang path is consented by the human's own typing
  and has its own key (`bang_requires_confirmation`); the override never covers it;
- `disaster?` still decides WHICH commands are candidates, so a relaxed run is a
  decision about a flagged command, never a command that stopped being flagged;
- every override prints a `warn` status line naming the verdict and writes a
  `harness.log` line naming BOTH the verdict and the option that armed it, so a
  session log can always answer "why did a denylisted command run?".

The ordering inside `run` matters: the disaster branch is checked FIRST (as
before), the override attempt happens inside it, and the batch verdict it consumes
is remembered (`verdict_computed`) because `safety_verdict_for` is one-shot for a
pre-batched verdict - re-reading it would lose the advisory note AND pay for a
second forked LLM call.

## The config shape: one enum, no live toggle

`command_safety_auto_approve` is the single key for both relaxations
(`HarnessConfig::SAFETY_MODES`):

| mode | approve (dialog skipped on `safe:`) | denylist (floor relaxable on `safe:`) |
| --- | --- | --- |
| `manual` (default) | no | no |
| `safe` | yes | no |
| `denylist` | no | yes |
| `safe_denylist` | yes | yes |

A legacy `true`/`false` is read as `safe`/`manual`, so every existing config keeps
working. `command_safety_denylist_safe_approve: true` still works as the denylist
half on its own and is ORed into the mode. An unrecognised value raises
`HarnessError` rather than falling back: a posture that quietly became `manual`
would read as "my relaxation is on", and the reverse would quietly relax the
floor. Both halves are meaningless without `command_safety_check: true`.

`denylist` is orthogonal to the AUTO-APPROVE posture rather than a third posture,
which is why it is NOT part of `command_mode_label` and of the `[MODE]` badge: it
changes what a `safe:` verdict is allowed to DECIDE for a denylisted command, not
how an unflagged command is handled. The startup banner does name it
(`Command consent: MANUAL ...; denylist + "safe:" also runs without asking ...`)
for the same reason it names the floor next to YOLO: a relaxed run must never be
mistaken for a normal one.

It is CONFIG-ONLY, unlike `yolo` and the Ctrl+A mode:

- no slash command and no Ctrl+A path. Ctrl+A toggles one posture between two
  states; a floor relaxation reachable from a keystroke is the failure mode the
  floor exists to prevent;
- no session persistence and no resume restore, so a resumed session cannot be
  more permissive than the config the operator wrote;
- `CommandRunner#denylist_safe_override?` reads `@options` only, so the value
  cannot change mid-run - a relaxed floor cannot appear or disappear inside one
  tool loop (contrast `yolo_active?`, which is read live on purpose).

## The residual risk, stated

The owner can call a real wipe `safe:`. That is the accepted cost: the model is
the only thing able to tell an inert literal from an executed payload, and the
feature is opt-in, tool-path-only, verdict-gated and logged. With the key off -
the default - the floor is absolute exactly as before #389.
