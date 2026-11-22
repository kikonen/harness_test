# Consent postures and shell-command execution guarantees

Design of the consent model and execution mechanics in `lib/command_runner.rb`.
Verified against `lib/command_runner.rb` during the comment-briefening pass.

Adjacent topics live in their own docs and are not repeated here:
- the model safety check and how a verdict is bound -> `doc/safety_check_design.md`
- the denylist-safe-approve exception -> `doc/denylist_safe_approve_design.md`
- what an "Always allow" prefix actually saves -> `doc/command_grant_scope_design.md`
- the standing working-directory grant -> `doc/standing_grant_design.md`

## Two callers, one runner

`CommandRunner` serves both shell-execution callers:

- `Tools::RunCommandTool` - model-driven, runs on a Task thread. The consent
  dialog is routed to the main thread (`ui: nil`), status lines go over the
  task's event queue, and the formatted result string returns to the model.
- `CommandHandler` bang syntax (`! cmd`) - user-typed, runs on the main thread;
  the dialog is served in place on the console.

The allowlist is separate per caller: the tool writes
`.harness/allowed_commands.yml`, bang syntax writes `.harness/shell_commands.yml`;
one never auto-approves for the other.

## Consent postures

How much manual approval an unapproved command needs. The user chooses the
posture (config initial value + the live `/yolo` switch); the model never does.

- **MANUAL** - default. Every unapproved command gets the dialog.
- **AUTO-APPROVE** - commands the model verdicts `safe:` skip the dialog.
  Config-derived, no live toggle.
- **YOLO** (`/yolo`) - every `run.command` call skips the dialog and the model
  check (the check costs a forked LLM round trip and trashes the local KV
  cache). Every such run is status-lined and logged, so nothing is invisible.
  YOLO covers only the model-driven tool path; the bang list is untouched
  because the human already typed the command.

For bang syntax the equivalent knob is `bang_requires_confirmation`: when OFF,
a user-typed command runs without a dialog.

The disaster denylist is the floor under every posture (checked first, so no
later shortcut skips it); its one exception is documented in
`doc/denylist_safe_approve_design.md`.

## Execution guarantees

- Commands run under a timeout (default 60s, cap 300s). The child runs in its
  own process group (`:new_pgroup` on Windows, `:pgroup` on POSIX; same effect:
  pgid == pid); on timeout the whole tree is killed (taskkill /T on Windows, a
  group signal elsewhere), so a hung command can never hold the harness' streams
  open. A `waiter.join` after the kill cannot hang because the tree is gone.
- Output is truncated to a line limit (default 500, max 5000) AND the result
  byte budget (`OutputBudget`). A line count is not a size limit; a result
  bigger than the context window is what makes the backend refuse the whole
  request. The bang path prints it as-is.
- The child's stderr is merged into stdout (2>&1): one stream is enough for the
  LLM context path. Pipe chunks are read into a BINARY accumulator and
  normalized once at the end (see `doc/encoding_design.md`).
