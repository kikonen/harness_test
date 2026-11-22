# Command allowlist: what makes a command auto-approvable

Design of `lib/command_allowlist.rb`: the security model a command must pass
before any prefix can be saved or matched, the disaster denylist, and how the
candidate "Always allow" options are generated.

Adjacent topics live in their own docs and are not repeated here:
- consent postures (MANUAL / AUTO-APPROVE / YOLO) and execution guarantees -> `doc/consent_postures_design.md`
- what a saved prefix actually covers and its scope wording -> `doc/command_grant_scope_design.md`
- the denylist-safe-approve exception -> `doc/denylist_safe_approve_design.md`
- the model safety check -> `doc/safety_check_design.md`

## Two separate lists

User-approved command prefixes persist in `.harness/allowed_commands.yml`
(`run.command` tool, model-driven) or `.harness/shell_commands.yml` (`!` bang
syntax, locally typed). One never auto-approves for the other, so a local
convenience grant cannot authorize a model-initiated command. Format is a
simple YAML array of strings:

```
- ls
- git status
- bundle exec rspec
```

## Security model

A command may be auto-approved only if it decomposes into **simple segments**
joined by shell operators that do not execute hidden code. Tokenization is by
`ShellTokenizer`, parsing by `ShellParser` (Racc); together they replace the
earlier hand-rolled splitting and scanning.

Allowed separators (quote-aware) only control execution order or wire
stdout to stdin:

- `|` pipe
- `&&` and-list
- `||` or-list
- `;` list separator
- `|&` pipe (stdout+stderr)

Each segment must be a simple command: no file redirects (`<`, `>`),
substitutions (`$`, backtick), subshells (`(` `)`), or background (`&`). Those
can read/write files or run arbitrary code, so a segment containing one is
never auto-approved and its prefix is never saved. Quotes are NOT blocked:
they only affect argument splitting, and an operator inside quotes is a
literal character.

## Disaster denylist (the floor)

A command matching `DISASTER_PATTERNS` (or recursive-force rm, `recursive_force_rm?`)
is refused by every auto-approval path - a stored grant, an AUTO-APPROVE verdict,
and YOLO alike - and can only run through an explicit one-off "Allow" (never a
standing grant). The check inspects the raw command, not only the
allowlist-decomposable segments, so it also covers the unsafe constructs YOLO
otherwise auto-approves. Patterns span two forms: per-segment (`DISASTER_PATTERNS`,
`WINDOWS_DISASTER_PATTERNS`) and whole-command (`WHOLE_COMMAND_PATTERNS` - a
construct that crosses a separator, which the tokenizer removes when segmenting).

The recursive-force delete tests match the verb by BASENAME (`verb_token?`), so
`bin/rm -rf /` is the same disaster as `rm -rf /`: a directory grant covers the
program in that directory. A quoted PHRASE is never a verb (`verb_text` returns
nil for it), so a commit message that merely names a path verb stays clean.

## Candidate prefixes and grant scope

Prefix lengths are offered per candidate: one option per prefix length of each
segment (`ruby`, `ruby -c`) plus special shapes (full invocation, run-with-flag,
directory glob), so the user grants exactly as much as they want. What each
shape covers and how its scope is stated in the dialog is covered in
`doc/command_grant_scope_design.md`.

A **directory glob** grant (`bin/*`) is the broadest offer: it auto-approves
every program directly in that directory, including one the model writes there
later. `directory_glob` builds it from a path token, refusing a directory with
an empty, `.` or `..` segment so a glob cannot trust programs outside the shown
directory. `glob_note` states the trust boundary at the moment it is chosen, and
the basename disaster rule is what keeps `bin/*` from standing for `bin/rm -rf /`.

## Reserved words are never grants

POSIX shell reserved words (`for`, `do`, `done`, `if`, ...) are plain words to
the tokenizer but spell no program, so `program_token?` rejects them: a
`for ... do ... done` loop is not exploded into meaningless `done` / `do ruby`
grants. A PATH token whose basename matches one (`bin/done`) is a real
executable checked by `path_program_token?`, so the block is on the bare word.
