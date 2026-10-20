# LLM Harness

A small interactive AI coding harness in pure Ruby. Point it at any
OpenAI-compatible model server (Ollama, llama.cpp, vLLM, ...) and chat with
a model that can read, write, patch, search, list files, run git commands
and (with explicit per-run confirmation) execute shell commands - all
scoped to a working directory you choose.

## Features

- **Tool-calling loop** - the model iteratively calls tools until it
  produces a final answer, with loop detection that warns and then forces
  a stop.
- **Fine-grained access control** - every file/directory access by the
  model requires a grant you approve interactively: single file, directory
  (direct children only), or directory tree (recursive). Read and write
  are separate (a write grant implies read) and delete is its own mode.
  Sensitive paths (`.env*`, `.git/`, `.harness/`) are always blocked, except a
  nested one inside a scratch zone (`tmp/scratch/<n>/`, `tmp/keep/<n>/`).
  `.harness/skills/` is the exception it is meant for: a skill is repo content
  the owner chose to keep (see **Project skills** below).
- **Shell execution with confirmation** - the `run.command` tool shows the
  full command before running it and requires an explicit "Allow" every
  single time, unless its prefix is already in the allowlist or the
  consent posture you picked accepts it: AUTO-APPROVE (a model "safe:"
  verdict, `Ctrl+A`) or YOLO (no consent at all, `/yolo`, issue #221). In
  EVERY posture a well-known disaster command (`rm -rf`, `sudo`,
  `git push -f`, `curl | sh`, `format C:`, ...) is refused auto-approval and
  always asks - the denylist is the floor under all three postures.
- **Local shell mode** - a line starting with `!` runs a shell command
  directly, bypassing the model, with its own allowlist
  (`.harness/shell_commands.yml`) (issue #129); its own confirmation dialog
  can be turned off with the `bang_requires_confirmation: false` config key
  (issue #221).
- **Sessions** - the conversation plus the access list is auto-saved to
  `.harness/sessions/<id>/session.json` (its own directory, issue #207) at
  every prompt boundary (before each send and after each reply) and again on
  exit; resume any saved session later, or pick up the newest one with
  `--continue`.
- **Per-session logs** - each session writes its request/tool log to its
  own directory, so concurrent sessions do not interleave (issue #113).
- **Multi-model config** - named model profiles in one YAML file, switch
  between them at runtime with `/model`.
- **Project rules** - a `harness.md` in the working directory is appended
  to the system prompt as project-specific rules (auto-reloaded when it
  changes).
- **Project skills** - a skill is a named markdown procedure the owner wrote down
  once, stored in `.harness/skills/`: either `<name>/SKILL.md` (when the skill
  ships with companion files) or a single `<name>.md`. Optional `---` front
  matter may carry `name:` and `description:`; without it the description is the
  file's first prose line. Skills are NOT injected into the system prompt: only
  names and one-line descriptions are reachable (`/skills`, `skills.list`), and a
  body is loaded on demand (`/skills <name>`, `skills.read(name)`), so defining
  many skills costs no context until one is used. `/help procedures` explains it.

  ```
  .harness/skills/changelog/SKILL.md
  ---
  name: changelog
  description: Regenerate CHANGELOG.md from the merged PR bodies
  ---
  ## Procedure ...
  ```

## Requirements

- Ruby >= 4.0 (see `.ruby-version`)
- An OpenAI-compatible chat completions server with tool calling

## Setup

```bash
cp -a _env .env            # env file (currently just points at the config)
bundle install
```

Which Ruby and git actually run where (CI, Windows, WSL2), and what their
differences mean for reading a test result: `doc/dev_environment.md`.

On first run, a config template is written to the user home config
(`~/.config/harness/config.yml`, issue #260). Edit it to set your model(s),
endpoint and token:

```yaml
models:
  - name: local
    url: http://localhost:11434/v1
    model: qwen2.5-coder:32b
    # token: sk-...
    num_ctx: 65536
    temperature: 0.6
    top_p: 0.95
default_model: local
compact:
  recent_messages: 6        # messages kept verbatim after /compact
  reserved_tokens: 8192     # absolute headroom (tokens) kept free before auto-compact
retry:
  count: 3                  # total attempts for transient errors
  delay: 2                  # base delay (s, exponential backoff)
```

Config lookup order (issue #260): `-c FILE` > `$HARNESS_CONFIG` >
`.harness/config.yml` (in the working directory, a per-project override) >
`~/.config/harness/config.yml` (the user home default). The first existing
file wins; there is no installation-dir tier because `$HARNESS_CONFIG` / `-c`
already covers that case. Every key is optional; missing values fall back to
built-in defaults.

## Usage

```bash
bin/harness                            # interactive, uses default model
bin/harness "fix the off-by-one in lib/foo.rb"
bin/harness -m other                   # pick another configured profile
bin/harness -d /path/to/project        # set the working directory
bin/harness --list-sessions            # list saved sessions and exit
bin/harness -r <id>                    # resume a saved session
bin/harness --continue                 # resume the newest saved session in this workdir
bin/harness --no-auto-save             # disable periodic auto-save at prompt boundaries
bin/harness --system-file my.md        # override the system prompt
bin/harness -v                         # verbose: full prompt + raw response in the log
bin/harness -p basic16                 # output palette: default | basic16 | none
bin/harness --no-color                 # same as -p none
```

`/palette` shows or switches the output palette during a run; the choice is
saved with the session, so a resumed session keeps it.

Rendered output is typed (issue #303 / #146): the step boundary, the reasoning
line, the tool plan and every tool status verdict (`✓` / `✗` / `⚠` / `!` / `=`)
get their own color, and a multi-line command block gets a `  |` gutter.
The two block boundaries - the start of an iteration and the start of the final
answer - are framed by the same 80-column gray rule that names the role
(`------- step 8 -------`, `------- model -------`), and the answer itself is
printed untouched.

`bin/rspec` runs the harness's own test suite (rspec), from any directory.

Type a plain message to send it to the model. Lines starting with `/` are
commands. `/help` lists every command and topic; `/help <command>` shows one
command's accepted forms and `/help <topic>` one topic (keys, consent postures,
multiline input, sessions, ...) - the help text is generated from the command
registry (`doc/command_help_design.md`).
Multiline input: paste a block; the submit key sends it (Enter adds a newline).
Keys: `Ctrl+C` cancel/interrupt, `Ctrl+D` quit (empty prompt), `Ctrl+A`
toggle the command consent mode (MANUAL / AUTO-APPROVE, issue #224),
Up/Down browse history. A line starting with `!` runs a shell command
locally instead of prompting the model (issue #129). `/yolo` [on|off|status]
toggles the YOLO posture: every `run.command` call then runs with no dialog
and no model check (issue #221; the disaster denylist still asks).
`/stream` [on|off|status] toggles streamed LLM responses (issue #28): each part
of an answer is then consumed as it arrives and the spinner line shows the newest
text of it (`[STREAM]` badge). The response the model loop receives is identical
either way; a streamed request is retried only until the first part arrives.
Initial posture: config key `streaming` (or a model profile's own key).

## Regenerating the shell parser

The shell command allowlist is built on a Racc grammar:
`lib/shell_parser.y` is the source, and `lib/shell_parser.rb` is generated
from it (do not edit the `.rb` directly). After changing the grammar,
regenerate with:

```bash
racc -o lib/shell_parser.rb lib/shell_parser.y
```

(racc is already in the Gemfile, so `bundle install` provides it.)

## Commands

| Command | Description |
|---|---|
| `/grant` | Show all current grants (file/dir access + command allowlist) |
| `/clear` | Remove all grants |
| `/retry` | Re-send the chain after a failed request; tool work already done is kept, so the turn resumes from there |
| `/session` | Show a summary of the current session |
| `/session-clear` | Drop all conversation messages |
| `/compact` | Summarize the conversation to free context |
| `/reload` | Force-reload `harness.md` into the system prompt |
| `/save` | Save the session (conversation + access list) now |
| `/sessions` | List saved sessions |
| `/resume <id>` | Restore a saved session: the run is rebuilt under that id (new conversation, grants, log and history file) |
| `/tools` | List available tools |
| `/models` | Show configured models (default and active marked) |
| `/model [name]` | Show or switch the active model |
| `/param [key [value]]` | Show, override or reset a model parameter |
| `/ctx` | Show context usage (tokens, %, headroom, auto-compact status) |
| `/reasoning` | Show the reasoning text of the last response |
| `/skills [name]` | List the project's skills (`.harness/skills/`), or print one skill's body |
| `/yolo [on|off|status]` | Toggle the YOLO shell-consent posture (saved with the session) |
| `/palette [name\|status]` | Show or switch the output palette (saved with the session) |
| `/stream [on|off|status]` | Toggle streamed LLM responses - show each part as it arrives (saved with the session) |
| `/help` | Show command help |
| `/exit` | Quit (auto-saves the session) |

## Tools

The model has access to these tools:

**Files** - `file.read`, `file.write`, `file.patch` (unified diff),
`file.search` (regex grep), `file.list` (glob), `file.info` (metadata),
`file.copy`, `file.rename`, `file.delete` (needs a DELETE grant)

**Directories** - `dir.create`, `dir.delete` (a whole tree, validated up
front and logged path by path; needs one DELETE grant - so `rm -rf` through
`run.command` is never needed)

`git.grep` (search commit diffs for when code was added/removed),
`git.apply` (apply a unified diff; `dry_run` validates it without applying)

**Shell** - `run.command` (full command shown, explicit Allow required
unless the prefix is already allowlisted or the posture you picked accepts it
(AUTO-APPROVE on a "safe:" verdict, or YOLO for everything); timeout-guarded,
output truncated)

**Meta** - `tools.list`, `tools.search`, `time.now`, `ui.notify` (progress
messages to your console), `ui.dialog` (ask the user a question and wait
for the picked option), `ui.note` (one-line note in the model's own
context), `test.echo` (test-only)

**Skills** - `skills.list` (the project's skills: name + one-line description),
`skills.read(name)` (load one skill's body as instructions). Skills live in
`.harness/skills/` and are NOT part of the system prompt.

## Access model

- Grants are tracked per mode: **read**, **write** and **delete** are each
  separate. A write grant implies read on the same path; a read grant
  never implies write, and neither read nor write implies delete.
- Directory grants come in two tiers: *dir only* (direct children) and
  *recursive* (whole tree).
- When the model touches a path you have not granted, you are prompted
  with numbered choices including the intended purpose - no auto-grants.
- File and directory deletes need their own DELETE grant.
- Shell commands ask unless the prefix is allowlisted or the consent posture
  you picked accepts it: AUTO-APPROVE on a "safe:" model verdict (issue #224)
  or YOLO for everything (issue #221). Postures are always the user's choice -
  the model never flips them.
- The active posture is ALWAYS labeled so you can see what a run will do
  before you type anything: the startup banner ("Command consent: MANUAL -
  ..."), the prompt line ("[model (effort)] [MANUAL] >") and the
  spinner line, which also carries the turn's elapsed time after the glyph
  and the posture badge at its end ("⠼ 12s Sending (model / api type)...
  🧠 12% (160K) [YOLO]").
- The disaster denylist overrides every posture AND every stored grant: a
  well-known disaster (`rm -rf`, `mkfs`, `dd of=/dev/`, `sudo`, `git push -f`,
  `curl | sh`, a fork bomb, `format C:`, `diskpart`, `del /s /q`,
  `Remove-Item -Recurse -Force`, ...) always reaches the dialog as a one-off
  Allow, with no "Always allow" option offered (issue #221).
- Sensitive files/dirs (`.env*`, `.git/`, `.harness/`) can never be granted -
  the guard protects the working tree's own git and harness state. A nested one
  inside a scratch zone (`tmp/scratch/<n>/`, `tmp/keep/<n>/`) is exempt, because
  there it is a disposable clone the harness created and the zone is meant to be
  deletable (`doc/sensitive_paths_design.md`).
  `.harness/skills/` is the other exemption: a skill is repo content the owner chose
  to keep, so its files are grantable for read, write and delete like any other
  file. A `.env*` name stays blocked there too, and the rest of `.harness/` stays
  ungrantable.

## Where things live

All harness state lives in `.harness/` inside the working directory:

```
.harness/
  harness_history   # prompt history
  allowed_commands.yml  # run.command prefix allowlist (separate from...)
  shell_commands.yml    # ...the `!` local shell allowlist (issue #129)
  sessions/         # saved sessions (one directory per session, issue #113)
    <id>/           # all of a session's state lives in here (issue #207)
      session.json  # the saved session (conversation + access list)
      harness.log   # that session's request/tool log
      harness_history  # that session's prompt history (issue #119)
  skills/           # the project's own skills (issue #12) - the ONE part of
    <name>/SKILL.md # .harness/ that is git-tracked and grantable
```

`.harness/config.yml` is no longer auto-created there (issue #260): the
template goes to the user home, and a file in the project's `.harness/` is a
deliberate per-project override.

`.gitignore` keeps `.harness/` ignored EXCEPT that skills subtree
(`.harness/*` + `!.harness/skills/`) - a negation under `.harness/**` cannot
re-include anything, because git skips the excluded directory.

## Project layout

```
lib/skills.rb       # the skills loader (.harness/skills) - index + body on demand
harness.rb          # entry point
bin/harness         # launcher (env, rbenv, bundle)
bin/rspec           # test runner (same env hygiene as the launcher)
CHANGELOG.md        # per-issue history (harness.md holds coding rules only)
lib/cli.rb          # option parsing, REPL loop, input handling
lib/harness.rb      # tool loop, tool execution, registry
lib/llm_client.rb   # HTTP, retries, request building
lib/session*.rb     # conversation state, save/resume/compact
lib/file_list.rb    # access grants (read / write / delete, files and dirs)
lib/sensitive_files.rb  # the sensitive-name patterns + the scratch-zone shape
lib/git_runner.rb   # safe git invocation base for the git tools
lib/shell_tokenizer.rb  # StringScanner lexer for shell commands
lib/shell_parser.y  # Racc grammar source (regenerate .rb with racc)
lib/command_handler.rb + lib/commands/*.rb  # one class per /command
lib/command_help.rb + lib/help_topics.rb + lib/help_renderer.rb
                    # /help data (per-command entries, topics) and its renderer
lib/tools/*.rb      # one file per tool
tmp/scratch/<n>/    # transient model scratch (probes, -a copies, dumps); deleted
                    # when its PR merges
analysis/<n>/       # the COMMITTED evidence of issue #<n>: a repro script that runs
                    # from a fresh clone (repro.rb) and/or a measurement script
                    # (measure.sh). Tracked, like doc/.
tmp/keep/<n>/       # measurements an OPEN issue #<n> still quotes that CANNOT be
                    # committed (a real repo clone, a large dump); gitignored, local
                    # to one machine, deleted when that issue closes
local/              # the owner's own working files (sample data, notes): the
                    # model may read them, never writes or deletes there
config/system_prompt.txt                  # built-in system prompt
doc/*.md            # design documents (why a subsystem is shaped as it is)
doc/dev_environment.md  # which Ruby/git runs where (CI vs local), pinned
doc/rubocop_style.md    # which style rules the cops enforce, and why the rest
                        # are off (measured against rubocop 1.92)
doc/sensitive_paths_design.md  # the sensitive-path guard and its scratch-zone
                        # exemption
```
