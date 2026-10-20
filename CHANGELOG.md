# Changelog

Per-issue history of what changed in the harness. This file is NOT injected
into the system prompt - `harness.md` holds only coding rules and guidelines,
so fixed-bug notes and release history belong here (and in the issue/PR).

Issue numbers link to https://github.com/kikonen/harness_test/issues/<n>.
Older history lives in `git log`; this file starts at the 2026-10-10 window.

## Unreleased - a scratch zone's nested .git is deletable (issue #321)

- #317's keep-zone rule ("`tmp/keep/<issue>/` is removed when that issue closes")
  proved unexecutable for git-related measurements: `dir.delete tmp/keep/318`
  refused, because #318 had needed REAL repos to measure git's line-ending
  behaviour and a real repo has a `.git`. Measured on that zone: 144 entries
  (93 files, 51 dirs), 3 nested `.git`, 81 files under them - the tree walk
  named `.../harnessrepo_realfile/.git/COMMIT_EDITMSG`, refused, and deleted 0
  paths. The zone is not repo state: `git check-ignore -v` matches both a plain
  note and that `.git` file to `.gitignore:5  tmp/**`, and `git ls-files
  tmp/keep` is empty.
- The guard protects THIS project's git and harness state, not a disposable
  clone the harness itself created under `tmp/`. Inside `tmp/scratch/<n>/` or
  `tmp/keep/<n>/` a nested `.git`, `.harness` or `.env*` is therefore no longer
  sensitive. `<n>` is required (`tmp/keep/.git` - one level up, in the zone
  LIST - stays blocked, so the exemption cannot be widened by targeting the
  parent) and may be any name (`tmp/keep/309-316/` is a real zone) but never
  starts with `.`; the test runs on the RESOLVED workdir-relative path, so
  `tmp/keep/318/../.git/config` is the project's own `.git` and stays blocked,
  and a workdir that merely looks like a zone segment gains nothing (the pattern
  is anchored at `tmp/`). Grant machinery is untouched: an exemption makes a path
  grantable, and `dir.delete` still needs one recursive DELETE grant over the
  whole tree. Rejected: a delete-only exemption (a scratch repo is written by
  `git`, not by the harness's file tools, and half-blocking leaves a zone that
  can be created but never cleaned), hand-cleaning (outside the audit trail, and
  it reproduces on every future git measurement), forbidding scratch repos under
  `tmp/` (that forbids the measurement itself).
- `FileList#sensitive?` (the instance method - the only one that owns a
  workdir) is the single decision point; the zone-free class-level
  `FileList.sensitive?` delegator is gone (measured: no caller left anywhere,
  every tool pre-check and permission check already went through the instance
  one). `relative_path` replaces the prefix-stripping half of `display_path`,
  because the zone test needs the same relative form. Design and measurements:
  new `doc/sensitive_paths_design.md`.
- Specs: new `spec/lib/sensitive_files_spec.rb` (9: the name test, the zone
  pattern, the `<n>`-required and lookalike cases); 4 in `file_list_spec.rb` (a
  zone grant covers a nested `.git`/`.harness`/`.env*`, a bare `.git` is still
  `:blocked` and `grant_access` still refuses it, `..` cannot smuggle a name out
  of a zone); 3 in `dir_delete_tool_spec.rb` (a keep zone holding a scratch repo
  is deleted path by path into harness.log while the zone list's own `.git` and
  the project's `.git` survive the same call). The zone pattern was
  mutation-probed: dropping the `<n>` requirement, exempting everything under
  `tmp/`, or exempting `keep/` only are each caught by an existing assertion.
- Contract kept honest: the `dir.delete` tool description, harness.md's sensitive
  bullet, README (both mentions, plus the layout list which now names
  `lib/sensitive_files.rb`), the `/help access` topic and
  `config/system_prompt.txt` all state the exemption.

## Unreleased - the command registry is checked against the command classes (issue #327)

- #323's drift spec compared the registry with README and with the HELP entries,
  but every one of those examples ITERATES the registry: a command class written,
  required, and never registered was found by nothing, and the user's symptom was
  `Unknown command: /foo` at runtime. Measured on 2663103: 20 classes, 20 registry
  entries, 20 README rows all agreed - the guard was simply absent.
- Test-only: `spec/lib/commands/help_command_spec.rb` now asserts
  `COMMANDS.values` == the `Commands` subclasses of `Command` (both directions, so
  a class registered twice or a key pointing at a non-command also fails), and
  that every registry key is the first word of its entry's usage form - the check
  `HelpRenderer` already makes when /help renders, now asserted without rendering.
  16 -> 19 examples. `doc/command_help_design.md` lists the two new rules.

## Unreleased - /help from data: registry, entries, topics, renderer (issue #323)

- `HelpCommand#handle` was one 182-line heredoc printing 169 lines (both
  measured): ~35 hand-typed, hand-padded command lines PLUS ~134 lines of prose
  (keys, multiline input, consent postures, sessions) glued into the same page.
  It listed the commands a SECOND time - `CommandHandler::COMMANDS` already IS
  the dispatch registry - and README's table was the third copy. Nothing checked
  the three agreed, and `/palette` is the near-miss this found: its README row was
  missing.
- Help is now four layers with one owner each: the registry (WHICH commands
  exist), a `HELP = CommandHelp.new(usage:, summary:, group:, forms:, see_also:)`
  constant in every command class (WHAT one command is), `lib/help_topics.rb`
  (the prose, as named topics with paragraph bodies) and `lib/help_renderer.rb`
  (HOW it looks). `Command.help` RAISES for a command that declares no `HELP`, so
  a registered command cannot be silently missing from the listing - the same
  "unknown types are loud" rule #146 uses for output.
- What the reader gets: bare `/help` is the grouped table (column width computed
  from the entries, one width for the whole table) + the topic index - 73 lines
  instead of 169; `/help <command>` is one command's forms; `/help <topic>` is one
  topic page; the prose is no longer forced on every `/help`.
- `see_also` names are resolved against BOTH registries (`/name` vs `/help name`),
  and `HelpRenderer#help_entries` refuses a usage that does not start with its
  registered name - the table prints the usage in the command's slot, so a
  mismatch advertises a form the dispatcher rejects.
- Topic names must not collide with command names or `/help session` is
  ambiguous: `HelpTopics.validate!` runs at `CommandHandler` construction (the
  first topic set DID collide on `session`, which is why that topic is
  `conversation`).
- Unknown input now names the closest registered names instead of repeating "type
  /help": `/garnt` says `Did you mean /grant?`, from the same registry the lookup
  just missed. The typo band is `max_distance: 2`, MEASURED over this set - at 3
  an unrelated name qualifies (`helo` -> yolo), at 1 only the nearest survives; a
  prefix counts as exact so `/res` is an abbreviation, not a misspelling.
- README's command table is checked against the registry by spec (a missing row
  AND a row for a command the dispatcher would reject both fail). README's usage
  text is corrected too: `end a line with "\"` described backslash continuation,
  which issue #198 phase 3 REMOVED (`CLI#get_command`: "no backslash continuation").
- New `doc/command_help_design.md` (the layers, what each owns, which rules are
  checked by spec and which are measured); new specs `spec/lib/command_help_spec.rb`
  (11), `spec/lib/help_renderer_spec.rb` (18), `spec/lib/help_topics_spec.rb` (10),
  `spec/lib/commands/help_command_spec.rb` (16, incl. the drift contract); 2 new
  dispatcher examples (unknown-command suggestions) and the startup tips now point
  at `/help input` / `/help notes` instead of "see /help for details".

## Unreleased - output roles, UI::Renderer, and named palettes (issue #303, the #146 renderer work)

- `Harness#print_step_display` emitted ONE type (`:step`) for four roles and
  baked the pattern into every string (`"[step N]"`, `">>> reason <<<"`,
  `"||| content |||"`, `"    -> tools"`). Measured while prototyping the color
  layer: the only way a renderer could color `plan` differently from `tools` was
  to REGEX the markers back out of the content. So the roles are real event
  types now - `:step_label` (the number), `:plan`, `:interstitial`,
  `:tool_plan` - and no marker string exists anywhere in the buffer.
- New `lib/ui/renderer.rb` owns the pattern: labels replace the markers, an
  unknown type renders `content [untyped:name]` loudly (#146 asked for exactly
  this), and `VERBATIM` names the roles whose prefix/indent an emitter still
  owns (`:text`, `:system`, `:stats`, `:compact`) - that list IS the remaining
  scope of #146, written down instead of implied.
- The response block's `"=" * 80` / `"-" * 80` decoration entries are gone:
  three buffer entries became one and the framing moved to the renderer.
- Three compaction / auto-save failures move `:error` -> `:warn`: they cost
  bookkeeping, not the turn, and the alert color on them reads as a broken turn.
- New `lib/ui/palette.rb`: three named palettes (`default` in use, `basic16`
  for a 16-color-only terminal, `none` = plain). `store_and_render` asks the
  renderer for the CONSOLE line and stores the plain role content in the
  OutputBuffer - a color baked into the durable record would be permanent, and
  #146's whole point is re-rendering that record. Asserted directly in
  `spec/lib/task_spec.rb`.
- Colors come from the owner's terminal measurements, not from convention: the
  bright 90-97 band, background colors and bold are unreadable on a light
  background, and 90 (dim) is indistinguishable from 2 (faint) there, so the
  16-color band has NO way to de-emphasize a line. Recessive roles therefore use
  a real dark gray (`38;5;240`) and warnings a brown (`38;5;130`). Full list in
  `doc/output_rendering_design.md`.
- New `/palette` command (`/palette`, `/palette status`, `/palette <name>`):
  switches the palette mid-session and acks with the new label PLUS a sample
  line rendered through the same `UI::Renderer` the drain loop uses, so the
  change is visible without starting a turn. It says plainly that it is
  effective from the NEXT turn - a running `Task` built its renderer already at
  `Task.run`. Validation lives in `Harness#output_palette=`, not in the
  command, so CLI flag, config key, `/palette` and resume all go through one
  name check.
- The palette is saved with the session as its NAME and restored during
  construction (`apply_resume_state`), like `active_model` / `param_overrides` /
  `yolo`: a session the user set to `none` must not come back colored. A stored
  name this build does not have falls back to the default palette instead of
  failing the resume - a name the USER typed is validated strictly, a name read
  from a file only has to be usable.
- The startup banner names the palette for the same reason it names the consent
  posture (issue #221's rule): it is a fact about how this run renders.
- No tty probe: a piped `$stdout.tty?` is false on this setup even though the
  terminal understands SGR (the spinner has printed raw `\e[2K` unconditionally
  since #125), so the switch is explicit - `-p/--palette NAME`, `--no-color`, or
  the config `output_palette:` key, validated at CLI parse time so a typo is
  reported before the model is contacted. `Harness#output_palette` resolves it
  once at construction, never per rendered line.
- Tool and command STATUS lines were the last pattern an emitter owned: 83 call
  sites (measured: 60 in the tools, 9 grant reports, 12 shell-runner lines, 2
  harness notes) wrote the whole line - indent, bracket and glyph - and pushed
  it as `:text`, which is the renderer's VERBATIM list, so coloring `✓`
  differently from `✗` needed regexing the glyph back out of the string. They
  are typed by VERDICT now (`:status_ok` / `:status_fail` / `:status_warn` /
  `:status_note` /
  `:status_same` / `:status_info`, `Tool#status` / `Tool.push_status`), the
  bracket label travels in the event's ORIGIN, and `UI::Renderer` builds the
  line: gray bracket + glyph, message in the verdict's hue. The bang path
  (`! cmd`) renders the same pattern itself, so both callers look identical.
- A multi-line status message (a pasted multiline script is the everyday case)
  is ONE buffer entry rendered as several console lines with a `  |` gutter on
  every continuation line and a short gray rule after the last one: where a
  command block ends became visible instead of blurring into the next entry.
- `:step_label` renders as the number fused with short gray rules, exactly 80
  columns whatever the number is (`-------- step 8 --------`). Bold was
  measured as not perceptible on the owner's terminal, so the boundary is SHAPE
  plus a hue on the number. `Tool.puts` is gone.
- The final answer now gets the SAME boundary: `BOUNDARY_ROLES` is the decision
  written as a list (`:step_label`, `:response`), and a role in it is framed by
  one full-width fused gray rule that NAMES the role
  (`----------- model -----------`), followed by the answer EXACTLY as emitted -
  no label, no indent, so its own paragraphs and indentation survive. The old
  `model: ` prefix is gone; `plan` / `say` / `tools` / `warn` / `error` keep
  their plain labels, because they are lines INSIDE a block and framing them
  too would make the boundary say nothing. `STEP_RULE_WIDTH` became `RULE_WIDTH`
  - there is one width for boundaries now.
- Still emitter-shaped (deliberately, tracked by #146): `:text` command output
  and the bracketed `:system` / `:stats` / `:compact` notes, plus Task's own
  mid-turn acks (`[note] got it - ...`, `[YOLO ON]`), which write straight to
  ui + buffer. `VERBATIM` is the exact list.

## Unreleased - line endings decided from file bytes (issue #318)

- `file.patch` detected a file's line-ending style with
  `content.include?("\r\n")` on content read by `File.read` - which on Windows
  has ALREADY translated every CRLF to LF, so the test was false for a genuine
  CRLF file. A patch touching one line rewrote the whole file with the opposite
  style while reporting `ok: applied 1 hunk(s)`, and `file.write` doubled
  model-supplied CRLF (`"X\r\n"` reached disk as `"X\r\r\n"`).
- Three further defects the same measurements exposed: `file.patch` RAISED
  `ArgumentError: invalid byte sequence in UTF-8` on a cp1252 file (the file was
  left intact, the call died); it DROPPED a trailing blank line
  (`"a\nb\n\n"` -> `"a\r\nB\r\n"`); and a lone CR was AMPLIFIED - a file with 3
  CRs came out with 4, because the old code appended `"\n"` to a line already
  ending in a stray CR, so every patch deepened the damage.
- New `lib/file_text.rb` is the byte boundary both editing tools now go
  through: `binread` so the style is visible at all, majority-decided separator,
  `binwrite` so nothing is translated on the way out. A bare CR is deleted
  (converting it into a newline would invent a blank line and change the file's
  line count); a CR-only file is its own style, not damage. Design and every
  measurement: new `doc/file_editing_design.md`.
- A repair is never silent: the tool result names what the source already
  carried (`1 bare CR normalized to CRLF`, `mixed CRLF/LF normalized to LF`).
  Plain LF text into a CRLF file is the NORMAL path (the model only ever sees LF)
  and carries no note.
- `file.patch` now REFUSES a file whose bytes are not valid UTF-8 instead of
  raising: the model only ever sees the `?`-scrubbed view, so writing it back
  would destroy bytes the harness never read correctly. `file.write` is a
  complete rewrite the model asked for, so it proceeds and says so.
- `Layout/EndOfLine` is set to `Enabled: false` with the reason recorded: the
  default `native` fires on all 83 files of `lib/` + `harness.rb` on a Windows
  checkout (all LF on disk) for an OS-dependent idea of correct, and
  `EnforcedStyle: lf` - which doc/rubocop_style.md previously claimed - would
  flag the CRLF files the tree deliberately allows (`*.bat`, `*.cmd`) and its
  autocorrect would fight `FileText`. The old comment's "131 files" was the
  whole inspected set, not the lib/+harness.rb set the number was about.
- Spec rule that the old spec violated: a line-ending assertion must use
  `binread`/`binwrite`. `file_patch_tool_spec.rb`'s CRLF case PASSED while the
  file on disk was `CR CR LF`, because it asserted with `File.read` - the same
  translation that hides the damage. Now asserted on bytes, plus LF-kept,
  doubled-CR, mixed-majority, trailing-blank, missing-final-newline and
  UTF-8-refusal cases, and a new `file_write_tool_spec.rb` (the tool had none).

## Unreleased - scratch areas split into tmp/scratch, tmp/keep and local/ (issue #317)

- harness.md's single scratch rule ("a scratch subdir is removed when its PR
  merges") was a licence to delete whatever a session found in `tmp/`: it did not
  say WHICH directory it meant, so notes an OPEN issue still quoted were equally
  in scope. The rule now names the zones.
- `tmp/scratch/<issue>/` is transient model work (probe configs, `-a` copies,
  one-run dumps) and keeps the delete-at-merge licence. `tmp/keep/<issue>/` holds
  analysis an open issue still quotes and is removed only when that issue itself
  closes. `local/` is the owner's own space (sample data, notes): the model may
  read it, never writes there and never deletes from it.
- Convention only, no code: nothing in `lib/` references `tmp/` (measured), so
  the grant machinery is untouched. `.gitignore` gains `local/**`;
  `AllCops: Exclude` gains `local/**/*` so the owner's Ruby files are not held to
  this project's style; README's project layout names all three zones. harness.md
  stays at 128 lines - the single bullet is rewritten, not added to.

## Unreleased - rubocop with loosened defaults (issue #302)

- `rubocop` 1.92 in the development group, `.rubocop.yml` from scratch with
  `DisabledByDefault: true` (37 cops named) plus a `.rubocop_todo.yml` baseline
  (46 cops, 740 offenses): the mechanical house rules harness.md states are
  enforced by CI instead of memorized per session. Design and the measured
  numbers behind every choice - why Metrics is off (363), the continuation-style
  probe table, the rules with NO cop behind them: new `doc/rubocop_style.md`.
- Layout and the Style cops skip `spec/**/*` (formatting rules in test code buy
  nothing); Lint and Naming stay on everywhere.
- Continuation style CONFIGURED from a probe file the owner wrote (one
  model-produced version of a call, one hand-written): the line-break cops
  (`FirstMethodArgumentLineBreak`, `MultilineMethodArgumentLineBreaks`,
  `FirstHashElementLineBreak`, `MultilineHashKeyLineBreaks`) plus
  `MultilineHashBraceLayout: symmetrical` make the corrector turn the model's
  shape into the hand-written one line for line. `HashAlignment: key` (no value
  table padding).
- Separators enabled: `EmptyLineAfterGuardClause`, `EmptyLineBetweenDefs`,
  `EmptyLinesAround{Class,Method,Block}Body`. `EmptyLinesAroundMethodBody` does
  NOT accept `EnforcedStyle` (rubocop warns on every run and ignores it) - a
  measurement taken with that setting on is meaningless.
- `Layout/ClassStructure` with `ExpectedOrder` trimmed to constants-first (3
  offenses baselined; the default order would make it 12). Its autocorrect is
  unsafe, so reordering stays a reviewed edit.
- `Style/HashSyntax` with `EnforcedShorthandSyntax: always`: `tools: tools` ->
  `tools:`. 48 sites in `lib/` corrected outright (commit 528cf10).
- Quotes flipped in its own commit (7d1dd32): 989 lines across 81 files (single
  -> double), specs untouched.
- `session_manager.rb` reformatted from the owner's own hand-tuned version
  (blank lines between semantic blocks, the stray constant moved to the
  constants block): 632 -> 725 lines, blank 81 -> 110, comment blocks glued to
  code 16 -> 4, lines over 90 27 -> 11. Suite unchanged throughout (924 examples,
  0 failures).
- `inherit_mode: merge: [Exclude]` is load-bearing: without it an Exclude set in
  `.rubocop.yml` REPLACES the per-cop Exclude lists `.rubocop_todo.yml` generates
  and the whole baseline is silently discarded (1149 baselined offenses were
  firing before this was found).
- CI runs `bundle exec rubocop --format github` after rspec.
- Two rules the config CANNOT express stay review judgement: a trailing
  `if`/`unless` carrying one condition, and a blank line before a comment block
  (161 such places in `lib/`; rubocop ships no cop for either). A custom cop was
  considered and rejected as too much machinery.

## Unreleased - mid-run /resume builds a FRESH Harness (issue #280)

- `/resume <id>` no longer patches the live Harness. `CLI#setup` (issue #282) is
  RUN AGAIN with the resumed id, so the new run is CONSTRUCTED under it: fresh
  Harness, logger, LLM client, HistoryManager, CommandHandler and FileList, and
  `cli.harness` / `cli.history` / `cli.commands` / `cli.file_list` are repointed
  at it. The replaced run's logger is closed after the new one logs the resume.
- `CLI#setup` gains the resume path fully: a `resume_id:` resolves the id through
  `SessionLocator` first (an abbreviated id resolves exactly as `--resume <id>`
  does), reads the saved data, and builds a FileList of its own for the resumed
  run (`build_file_list`) so its grants cannot be shared with the tools of the
  run being replaced (a live FileList is mutable shared state - issue #300).
- `on_resume:` is the wiring: CLI passes `->(id) { setup(resume_id: id) }` to the
  CommandHandler, which forwards it to every command class (`Command` stores it;
  only /resume uses it). A command that has no action says
  `[error] resume is not available in this run` instead of half-resuming, and
  /resume reports through the Harness the ACTION returned - its own `@harness` is
  by definition the session being left behind.
- Delete: `Harness#rebind_logger`, `LLMClient#logger=`, the backend's
  `attr_accessor :logger` (`LLM::BaseBackend` is now `attr_reader` - a resume
  builds a new backend, it never re-points a live one), `HistoryManager#bind_session`
  and `SessionManager#resume_session` with its private `find_session_file` and
  `reset_rules_mtime` (a fresh SessionManager stamps the rules mtime at
  construction, so the reset call was a no-op on this path). Every mid-run
  re-bind API is gone; `SessionManager#restore_session_model` stays public
  because `Harness#apply_resume_state` calls it.
- What a resume restores is now restore of a session FILE (`Session#restore`)
  plus `Harness#apply_resume_state` (model profile, param overrides, YOLO
  posture) - the same code path startup resume uses, so the two cannot drift
  apart the way the mid-run copy of startup behaviour did.
- Fix: the run being replaced used to keep its log open, so anything still
  holding that Logger (a tool object of the old session, a late write) could
  append to a log that is no longer the run's. `setup` closes it after the new
  run has logged the resume, and /resume reports through
  `resumed.session.session_id` - never through a file path.
- New `spec/lib/commands/resume_command_spec.rb` (5 examples: usage line, the
  no-action error, delegation + reporting through the action's Harness, no
  partial resume when the action raises, `resume_cli_string`). `spec/lib/cli_spec.rb`
  gains `mid-run /resume (issue #280)` (2 examples, real saved session with
  grants): the whole run is replaced, grants land on a new FileList, the old
  logdev is closed (a late write cannot append), the fresh client's backend holds
  the fresh logger, and only the two real session dirs exist (no throwaway id).
- `spec/lib/history_manager_spec.rb`: `bind_session` examples replaced by
  "a resumed run gets its OWN manager" (the file is derived from the id at
  construction; nothing re-binds).
- `spec/lib/session_manager_spec.rb`: the mid-run resume examples (the #113 log
  rebind, the #119 history rebind, the #207 abbreviated id, YOLO-resume and the
  param-override restore) are gone with the method they tested - save-side and
  JSON-override examples stay. `spec/lib/harness_spec.rb` loses `rebind_logger`.
- harness.md: the "resolve identity before constructing what derives from it"
  convention (added by #276) is DELETED from the file. It was subsystem history
  - issue numbers, APIs that no longer exist, and an explanation of `val == true`
  - which is exactly what the file's own comment rule forbids; a reader gets the
  rationale from the `SessionLocator` header, `CLI#setup` and this file. The
  consent bullet keeps only the half the code cannot state (consent state is
  never conversation state).

## Unreleased - CLI heavy construction moved into #setup (issue #282)

- `CLI#initialize` kept the basics only (options, UI, FileList, SessionLocator,
  `--list-sessions` exit, idle draft) and the heavy part moved to a new public
  `CLI#setup(resume_id:)`: resolve the id -> read the saved data -> build
  Harness -> HistoryManager -> CommandHandler. `initialize` calls it, so
  `CLI.new.run` is unchanged.
- The point is RE-RUNNABILITY, which issue #280 needs: a mid-run /resume can
  call `setup(resume_id: <id>)` and get a FRESH Harness, history file and
  CommandHandler under that id, instead of mutating the live one. A `setup`
  call with NO resume_id keeps the id the run already owns - a re-run never
  mints a throwaway id (the #123 / #135 symptom) - and a failing setup leaves
  the previous objects in place.
- `cli.session_id` is now exposed (the settled identity, not just the
  Harness's copy of it).
- New specs in `spec/lib/cli_spec.rb` (`#setup`, 4 examples): a second setup
  with a resume id builds a fresh Harness AND repoints `cli.harness` /
  `cli.commands.harness` / the history file; a bad resume id raises before any
  construction and the prior objects survive; re-setup keeps a fresh run's id
  and a --continue run's id.

## Unreleased - development environments documented (issue #295)

- New `doc/dev_environment.md`: what each environment actually runs (Ruby and
  git pinned per platform, measured 2026-10-17) and what the differences mean
  for reading a test result. Environment facts stayed OUT of harness.md - that
  file is injected into every system prompt and holds coding rules only.
- The asymmetry stated plainly: `.ruby-version` is honored by rbenv, not by
  Ruby itself, so on Windows (no rbenv on PATH) `bin/harness` and `bin/rspec`
  run the system Ruby; the baseline is 4.0.1 and Windows runs 4.0.7 for
  technical reasons. CI pins Ruby in the workflow because ruby/setup-ruby does
  not resolve `file://` here, so a `.ruby-version` bump must bump the workflow
  in the same commit.
- Why a green local run does not settle a CI-only failure: the git versions
  differ in both directions (CI 2.55.0, WSL2 2.43.0, Windows 2.56.0), and
  issue #292 - CI-only, real, proven with `GIT_TRACE2` - is the worked
  example. WSL2 is the closest local environment to CI.

## Unreleased - dir.delete deletes a tree and logs every path (issue #290)

- `dir.delete` used to refuse a non-empty directory ("recursive deletion is
  not supported"). In practice that pushed the model to `rm -rf` through
  `run.command`, which is the WORSE route for a destructive operation: the
  shell consent decision replaces the tool's DELETE grant, and the log gets
  the command string only - never the paths that vanished.
- The tool now walks the tree: post-order (children before their directory),
  a symlink INSIDE the tree unlinked as a leaf and never followed. The walk
  happens BEFORE anything is removed, so the whole tree is validated first and
  a refusal deletes nothing at all.
- Safety floor: the tree is refused by name when it contains a sensitive
  subtree (`.git`, `.harness`, `.env*`) instead of silently deleting around
  it; the working directory itself is never deletable; ONE DELETE grant must
  cover the whole tree - a flat grant on a nested tree is refused rather than
  deleting half of it.
- Mandatory audit trail: every removed path is written to the harness log
  (`dir.delete: deleted file tree/sub/b.txt`, ... plus the summary), and only
  the summary line reaches the console, so a 1400-path tree cannot flood the
  terminal or the LLM context. The logger is read live from the harness, so the
  tools built by a mid-run /resume (issue #280 rebuilt them under the fresh
  harness) reach the new session's log. Deleted files also leave the session's
  digest cache (issue #170).
- Fix found by the new specs: the log line named the entry kind AFTER the
  removal, so directories were logged as files.
- New `spec/lib/tools/dir_delete_tool_spec.rb` (14 examples: recursive
  delete, empty dir, symlink leaf, workdir refusal, sensitive-subtree refusal,
  one-dialog-per-call, partial-grant refusal leaving the tree intact, denial
  note forwarding, per-path logging, live logger read, digest-cache drop).
- Contract kept honest: the tool description, `README.md` and harness.md all
  used to promise that recursive deletion does not exist. harness.md now states
  the opposite rule - `rm -rf` through `run.command` is never needed (the
  disaster denylist is untouched: it still forces the shell dialog).
- harness.md scratch rule: loose files in `tmp/` became 180 unattributable
  leftovers, so scratch now gets its own subdir per issue/PR (`tmp/271/`) and
  is deleted when that PR merges.
- Fix found by CI (not locally reproducible): the target path itself may be a
  symlink. `File.directory?` follows it, so a symlinked target reached
  `Dir.rmdir` (`Errno::ENOTDIR`). It is now refused outright and `file.delete`
  is named as the unlink path - following a link would delete a tree outside
  the path the DELETE grant and the audit log describe.

## Unreleased - CI flake: git maintenance raced the spec's tmpdir cleanup (issue #292)

- `git_apply_tool_spec` "rejects a hunk without file headers up front" failed
  intermittently in CI on a path the example never touches:
  `Errno::ENOENT ... /tmp/d.../.git/objects/maintenance.lock`, raised from
  `Dir.mktmpdir`'s teardown. The example's own assertions passed - only the
  cleanup died.
- Cause, measured with `GIT_TRACE2`: `git commit` spawns
  `git maintenance run --auto --quiet --detach` (git's default
  `maintenance.auto`), and that detached child writes
  `.git/objects/maintenance.lock` inside the tmp repo AFTER the example has
  finished, while the cleanup is walking the same tree.
- Fix: the spec's `GIT_ENV` carries `maintenance.auto=false` and `gc.auto=0`
  through git's own config env mechanism (`GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`) - no global git config is
  touched, and `GIT_TRACE2` then shows no maintenance child at all.

## Unreleased - turn elapsed time in the spinner (issue #277)

- The spinner line now shows how long the CURRENT turn has been running, in
  the slot right after the frame glyph so the counter sits at a fixed column
  whatever the message says: "⠼ 12s Sending (qwen / openai)... 🧠 12% (160K)
  [YOLO]". Whole seconds below a minute, minutes past it ("2m 03s").
- The clock is the TURN's, not the wait's: `Task#start` stamps `@started_at`
  and `Task#elapsed_label` formats it. The drain loop rebuilds the spinner
  every time the outbox empties again, so a spinner-owned clock would restart
  on every rebuild; the runner hands the spinner a callable instead, which is
  why `UI::Spinner#elapsed` follows the same live-callable contract as the
  suffix and the badge (nil or a raise renders no segment).

## Unreleased - compact spinner line (issue #271)

- The per-request spinner line was the longest UI line of a turn and its
  numbers were unglanceable:
  "Sending to qwen2.5-coder:32b (ollama /api/chat)... 🧠 ctx 19514/160000 (12%)".
- New format: "Sending (qwen2.5-coder:32b / openai)... 🧠 12% (160K)".
  - `SessionManager#request_spinner_detail`: the recipient moves into
    parentheses after the verb and only the API TYPE is named. The endpoint
    path issue #217 added was the longest part of the line and is already in
    the startup banner and printed by /model, so it left the spinner;
    `target_suffix` became `api_type_label`. `#target_display` (and with it
    /model, /models and the banner) still shows api type + endpoint path.
  - `Harness#context_indicator_live` - the spinner's context segment - now
    leads with the percentage and names the window it is a percentage of,
    rounded to whole thousands by the new `#window_label` (65536 -> 66K,
    160000 -> 160K; a window under 1000 stays exact). The used-token count is
    dropped: the percentage is what the eye tracks frame to frame.
- The compact form is the spinner's ONLY: `#context_indicator` (the modeline
  and the per-turn stats line) and `#context_report` (/ctx) keep the full
  token arithmetic, so /compact's before/after lines stay verbose.

## Unreleased - each LLM request announces its own spinner line (issue #283)

- Fix: after an in-loop compaction the spinner kept saying
  "Compacting session mid-task ..." for the REST of the turn, even though the
  compaction was long done and the model request was running.
- Cause: `send_session` emitted the "Sending to ..." `:spinner_detail` ONCE
  before the whole tool loop, while `Harness#call_llm` iterates many times.
  The compaction re-point won the race and nothing re-pointed it back, because
  the runner replays the last remembered line whenever it rebuilds the spinner.
- Fix shape (the agreed design): a wait that starts says what it is doing.
  New `SessionManager#request_spinner_detail` is the single source of the
  request line (model + ` (api path)` tail + live ctx suffix), and
  `Harness#call_llm` calls it before EVERY `@client.chat` of the loop. There is
  no "clear the spinner" logic anywhere: the next wait overwrites the previous
  one, and `#send_session` no longer emits it at all.
- `target_suffix` keeps the issue #217 target tail and drops it for a client
  without a `#backend` (test doubles), so describing a wait can never break it.
- doc/task_design.md: the spinner-ownership section now states the rule the
  bug was missing - a re-point describes ONE wait; the runner only remembers it
  so a spinner rebuilt INSIDE that wait keeps its message.

## Unreleased - comment rule made enforceable; offenders stripped (issue #281)

- `harness.md` Code Style: the descriptive WWWW rule becomes a hard budget with a
  delete test. A comment may only say what the code cannot (invariant, gotcha,
  ordering constraint, labeled HACK), at most one *why* sentence per method; short
  obvious control flow (getters, setters, label lookups, one-liners) gets NO
  comment; the programming language is never explained (`== true` is a boolean
  check, `!!` a truthiness cast); a comment that restates the line under it is
  fluff and one that names the wrong mechanism (calling `val == true` "coercion")
  is worse than none; issue/bug numbers and design history move out of method
  bodies to CHANGELOG, the issue and the commit message. A comment the user flags
  as useless is stripped by the ASSISTANT, and the same file is audited for the
  same pattern in the same pass.
- `harness.md` Conventions: the "posture flags are coerced to real booleans" line
  was itself the wrong-mechanism kind - it now states what the setters do
  (`val == true`, a strict comparison, so only a literal true turns a posture on).
- Strip: the flagged 10-line comment on the 3-line `Harness#command_mode_label`,
  every comment inside `Harness#initialize` (all of them restated the assignment
  under them), and the same pattern across `lib/harness.rb` and `lib/task.rb`
  (comment lines 292 -> 33 and 279 -> 209; zero issue-number references left in
  either file).
- New rule: design documentation lives in `doc/<topic>.md`, not in a source-file
  header. A long file-level header (the prose explaining a subsystem's
  architecture, protocol or ownership rules) moves to `doc/`; the source keeps at
  most a 3-line header naming the invariant and pointing at the doc. Docs hold
  what a reader needs BEFORE reading the code; comments stay for what a specific
  line cannot say. `README.md` gained the `doc/` line in its project layout.
- Move: four such headers became docs (`doc/task_design.md` 63 header lines,
  `doc/encoding_design.md` 32, `doc/output_buffer_design.md` 30,
  `doc/session_file_cache_design.md` 30); each source file now carries a
  2-3-line pointer instead (`lib/task.rb` 209 -> 149 comment lines). The two
  medium headers that do not warrant a doc file of their own (`lib/ui/spinner.rb`,
  `lib/ui/console.rb`) were trimmed to the same 3-line form: invariant kept,
  history and forward-looking notes dropped. No file-level header of 8+ lines is
  left in `lib/`. harness.md's
  own Encoding convention shrank to the actionable rule plus the pointer, since
  its rationale now lives in `doc/encoding_design.md` and harness.md is injected
  into every system prompt.

## Unreleased - session identity resolved before anything is built (issue #276)

- Refactor: the session id is now settled BEFORE `Harness` is constructed, so
  the log file, the history file and the session directory are all created
  once, under one id. New `SessionLocator` (`lib/session_locator.rb`) is the
  single place that knows WHERE a session lives and WHICH session this run is;
  it needs the workdir and nothing else (constructing it touches no disk).
- `CLI#initialize` order is now: parse options -> resolve the id
  (`--resume <id>` / `--continue` newest / a fresh UUID) -> read the saved data
  -> construct Harness -> bind history to the settled id. `Session` takes its
  id as a parameter (`session_id:`) and `Harness` takes `session_id:` /
  `resume_data:`.
- Delete: `lib/deferred_logger.rb` (the #270 stopgap), the lazy `Harness#logger`
  accessor and the #123 deferral. `Harness#logger` is a real Logger from
  `#initialize` on every path (fresh, `-r`, `--continue`, mid-run `/resume`),
  and the client holds that same Logger, so no consumer can hold a placeholder.
- Trade-off of the eager logger: a fresh run now creates its own
  `.harness/sessions/<id>/` at startup (its log file), where the #123 deferral
  created it only on the first log line. The deferral existed to protect the
  RESUMED case (no dir for an id the run threw away) and that case is now
  correct by construction; the log file of the id a run actually owns is not
  throwaway state.
- `rebind_logger` survives ONLY as the mid-run `/resume` case (identity changes
  while everything is already running); startup resume no longer rebinds
  anything, and `SessionManager#resume_session` is now the mid-run path alone.
  (Superseded by issue #280 above: the mid-run case re-runs `CLI#setup` instead,
  so `rebind_logger`, `client.logger=` and `history.bind_session` no longer exist
  anywhere and `SessionManager#resume_session` is gone - nothing rebinds on any
  path.)
- Startup resume also applies the session's harness-side state (model profile,
  param overrides, YOLO posture) during construction via
  `Harness#apply_resume_state`, so a `--resume` run no longer silently drops
  the posture and overrides the mid-run `/resume` used to restore.
- A session file whose stored `session_id` is not the directory name it lives
  under is now refused (it would split the run's state across two dirs), and a
  typo'd `--resume` id raises BEFORE any session directory is created.
- `--list-sessions` lists through `SessionLocator` (it used to construct a whole
  Harness - client, logger, tool registry - just to read a few JSON files, and
  minted a fresh random id on the way). `CommandHandler#list_sessions` is gone.
- Fix found while testing the real CLI: mid-run `/resume` printed
  `File.basename(path, '.json')`, which has never been the id since the #207
  layout moved the JSON to `<sessions>/<id>/session.json`.
- harness.md: the "a deferred value must be resolved lazily" rule (which
  advertised `DeferredLogger` as a reusable pattern) is replaced by the
  ordering rule - resolve identity before constructing what derives from it.
  Issues #113 / #119 / #123 / #135 / #270 were five symptoms of this one bug.
  (The ordering rule itself was later deleted from harness.md by #280 - see the
  entry at the top of this file.)

## Unreleased - first prompt no longer dies on a nil logger (issue #270)

- Fix: with `auto_save: false` (and verbose off), the FIRST prompt of a run
  ended in `[task error] NoMethodError: undefined method 'info' for nil`.
- Cause (stopgap; superseded by #276 above): `Harness#initialize` passed the
  deliberately-deferred logger (nil
  until first use, issue #123) straight into `LLMClient`, and the backend logs
  unconditionally on the first attempt of every request. The lazy `Harness#logger`
  accessor and its client rebind could never help: the crash happened before
  anything had asked for the logger, so the rebind never ran.
- New `DeferredLogger` (`lib/deferred_logger.rb`, DELETED by #276): what such a
  consumer got
  instead of the nil. It resolves the source's `#logger` at CALL time, so it can
  never hold a nil and never pins a logger the owner is about to replace. The
  deferral itself (#123: no throwaway log dir for a fresh id) is unchanged.
- The rule this taught (superseded by the ordering rule in harness.md): a
  deferred value is only correct if RESOLVING it is
  deferred too - a nil placeholder is a snapshot of "not yet", not a deferred
  value.

## Unreleased - TextNormalizer preserves multi-byte text (issue #268)

- Fix: command output lost every non-ASCII character. The child pipe
  accumulator is BINARY (the #257 design), and `String#encode` FROM a BINARY
  tag maps each byte separately, so a valid UTF-8 character was destroyed one
  byte at a time - a 2-byte letter became two '?' and a 3-byte glyph became
  three. A native Finnish `wc -c` total line arrived as `yhteens??`, i.e.
  command output with non-ASCII text was simply unreadable.
- `normalize` now treats a BINARY tag as a BYTE CONTAINER rather than a text
  encoding: read the bytes as UTF-8 first, fall back to the ambient code page
  only when they are not valid UTF-8, and only then replace what genuinely
  cannot be mapped. The fallback refuses BINARY as `default_external`.
- Fix: a string byte-invalid in its OWN declared code page was returned still
  tagged with that code page (scrub in place), re-introducing the
  Encoding::CompatibilityError the #257 boundary exists to prevent. scrub now
  runs on a UTF-8 copy, so the return type is always valid UTF-8.

## Unreleased - YOLO consent posture (PR #266, issues #221 / #254)

- YOLO posture: `/yolo [on|off|status]` skips the `run.command` consent
  dialog (and the model safety check) for every command. Initial posture
  from the config `yolo:` key; the state is saved with the session, so a
  resume keeps it. Mid-turn steering note `/yolo` flips it live.
- Disaster denylist (`CommandAllowlist.disaster?`) is the floor under EVERY
  posture and every stored allowlist grant: `rm -rf`, `mkfs`, `dd of=/dev/`,
  fork bombs, `sudo`, `git push -f`, `curl | sh`, `format C:`, `diskpart`,
  `del /s /q`, `takeown`, `icacls`, `Remove-Item -Recurse -Force`, ... keep
  the dialog, with no "Always allow" option (one-off Allow only). Every
  auto-approved run prints a status line and is logged.
- Bang syntax (`! cmd`) is governed by the new `bang_requires_confirmation:`
  config key (default true), NOT by YOLO - a human-typed command is already
  consent. The denylist still applies.
- Allowlist regex bugs found by the new specs and fixed: bare `takeown` was
  not matched, `ircacls?` typo, bogus `rdel` plus duplicate `erase` entries,
  and `disaster_label` returning an empty label on zero-width lookahead
  matches.
- `Task#yolo_note_action` returned `nil` for a bare `/yolo` (unmatched
  optional group), so the gesture silently fell through into the
  conversation chain; `on` / `off` forms were ignored. Now returns
  `:toggle` / `:on` / `:off`.
- Review fixes: the spinner keeps its real message instead of resetting to
  the bare "Working..." default when the drain loop rebuilds it; the consent
  posture is always labeled (`Harness#command_mode_label` no longer returns
  nil for a real harness) in the startup banner, the prompt modeline and the
  spinner badge at the END of the spinner line; the tag is the bare bracketed
  label (`[YOLO]`), a `cmd:` prefix inside the brackets being noise.
- harness.md de-bloat: the file is injected into every system prompt, so it
  holds coding rules only. Tunable Constants and the Pending / Deferred
  sections were dropped (constants live in the code, deferred work in open
  issues #244 / #254 / #183 / #267), as were the self-descriptive notes about
  how harness.md itself is loaded - the model does not need them to code.
- Code Style now states the WWWW comment rule (What / Why / When / Who / *,
  the star being what the code cannot tell the reader): lead with *why*,
  document *what* only where a complex algorithm hides it, say each thing
  once. It replaces the bare "comments explain why, not what" line.
- Follow-up: issue #267 for the mid-turn gesture-dispatch refactor (remove
  the labeled `/yolo` HACK in `Task#commit_note`).

## 2026-10-15

- #260: the user home config (`~/.config/harness/config.yml`) is the default
  location; `.harness/config.yml` is a per-project override. Lookup order
  `-c` > `$HARNESS_CONFIG` > working dir > user home; the installation-dir
  tier is gone.
- #262: removed the obsolete dry-run mode.
- #264: docs sync - README / harness.md corrected against the actual code.
- #257: externally-sourced text (shell output, file reads, tool-call
  arguments, git output, LLM bodies) is normalized once at each read boundary
  by `TextNormalizer`, so invalid bytes cannot break JSON generation or the
  console.

## 2026-10-14

- #253: `/compact` runs on a Task thread (its output and dialogs follow the
  single-thread I/O rule).
- #249: the consent dialog offers the short prefix alongside the full
  invocation when saving an "always allow" grant.
- #241: allowlisted commands never reach the model safety check (the batch
  precheck skips exactly what the runner auto-approves).
- #240: spec locks the allowlist check ahead of the model safety check.
- LLM log now records per-attempt request/response stats.
- Fix: `require_relative` for `ui` in `command.rb` (the runtime bootstrap was
  broken).

## 2026-10-13

- #235: `/retry` re-sends on a Task thread; the shared `TaskRunner` wrapper
  (Task.run + `[task error]` line) extracted for `/retry` and `/compact`.
- #224: model self-check for unapproved shell commands (advisory verdict in
  the consent dialog), plus the Ctrl+A AUTO-APPROVE toggle and the spinner's
  live mode badge.
- #223: the system prompt is a file reference read on demand, so `/reload`
  picks up edits without a restart.
- #226: elapsed time formatted with minutes for long turns;
  `max_tool_iterations` configurable.

## 2026-10-12

- #219: session-level model parameter overrides (`/param`), unified with
  `/model` param listing; overridden lines show the config value.
- #216: the live context estimate is anchored to the server-reported
  prompt-token count instead of drifting from a rough estimate.

## 2026-10-11

- #217: the active backend target (API type + endpoint path) is surfaced in
  the banner and the spinner.
- #215: the config owns LLM sampling parameters; per-backend wire shapes; an
  unset key is not sent.
- #197: the LLM client is split per backend API type (`openai` / `ollama`) so
  `num_ctx` is honoured.
- #207: session JSON moves into the session directory
  (`.harness/sessions/<id>/session.json`).
- #208: a failed request resumes mid-loop (the working chain IS the session),
  so `/retry` continues from exactly where it stopped, including tool work.
- #198 phases 3-4: idle prompt and steering notes through the multiline
  `UI::Editor` (Enter inserts a newline, the submit key sends the whole
  buffer, Esc keeps a draft), plus CSI Ctrl+Enter bound as a portable submit
  key for remote terminals.
- #202: `run.command` owns the child process group so a timeout can never
  wedge the harness; CI fixes for the platform-specific spawn key and
  `Reline::Windows`.

## 2026-10-10

- #198 phases 1-2: mid-turn steering without a reader thread (keypress peek +
  Reline note editor), dialog choice lines through the same editor, stuck
  grant dialogs fixed (a channel can never be left open with a dead reader).
- Steering note contract documented and specced: one note in flight, the
  latest line wins.
- Workflow rule added: never commit to `master` directly - branch, PR, rebase.
