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
  are separate; a write grant implies read. Sensitive paths (`.env*`,
  `.git/`, `.harness/`) are always blocked.
- **Shell execution with confirmation** - the `run.command` tool shows the
  full command before running it and requires an explicit "Allow" every
  single time.
- **Sessions** - the conversation plus the access list is auto-saved to
  `.harness/sessions/` on exit; resume any saved session later.
- **Multi-model config** - named model profiles in one YAML file, switch
  between them at runtime with `/model`.
- **Project rules** - a `harness.md` in the working directory is appended
  to the system prompt as project-specific rules (auto-reloaded when it
  changes).

## Requirements

- Ruby >= 4.0 (see `.ruby-version`)
- An OpenAI-compatible chat completions server with tool calling

## Setup

```bash
cp -a _env .env            # env file (currently just points at the config)
bundle install
```

On first run, a config template is written to `.harness/config.yml` in
your working directory. Edit it to set your model(s), endpoint and token:

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
retry:
  count: 3                  # total attempts for transient errors
  delay: 2                  # base delay (s, exponential backoff)
```

Config lookup order: `-c FILE` > `$HARNESS_CONFIG` > `.harness/config.yml`
(in the working directory) > `~/.config/harness/config.yml`. Every key is
optional; missing values fall back to built-in defaults.

## Usage

```bash
bin/harness                            # interactive, uses default model
bin/harness "fix the off-by-one in lib/foo.rb"
bin/harness -m other                   # pick another configured profile
bin/harness -d /path/to/project        # set the working directory
bin/harness --list-sessions            # list saved sessions and exit
bin/harness -r <id>                    # resume a saved session
bin/harness --system-file my.md        # override the system prompt
bin/harness -v                         # (already on by default) verbose logging
```

`bin/rspec` runs the harness's own test suite (rspec), from any directory.

Type a plain message to send it to the model. Lines starting with `/` are
commands. Multiline input: paste a block, or end a line with `\`.
Keys: `Ctrl+C` cancel/interrupt, `Ctrl+D` quit (empty prompt),
Up/Down browse history.

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
| `/retry` | Re-send the session chain (after a failed request) |
| `/session` | Show a summary of the current session |
| `/session-clear` | Drop all conversation messages |
| `/compact` | Summarize the conversation to free context |
| `/reload` | Force-reload `harness.md` into the system prompt |
| `/save` | Save the session (conversation + access list) now |
| `/sessions` | List saved sessions |
| `/resume <id>` | Restore a saved session |
| `/tools` | List available tools |
| `/models` | Show configured models (default and active marked) |
| `/model [name]` | Show or switch the active model |
| `/help` | Show command help |
| `/exit` | Quit (auto-saves the session) |

## Tools

The model has access to these tools:

**Files** - `file.read`, `file.write`, `file.patch` (unified diff),
`file.search` (regex grep), `file.list` (glob), `file.info` (metadata),
`file.sha`, `file.copy`, `file.rename`, `file.delete` (confirms)

**Directories** - `dir.create`, `dir.delete` (confirms, empty only)

**Git** - `git.status`, `git.diff`, `git.log`, `git.show`,
`git.grep` (search commit diffs for when code was added/removed),
`git.apply` (apply a unified diff)

**Shell** - `run.command` (full command shown, explicit Allow required
every time; timeout-guarded, output truncated)

**Meta** - `tools.list`, `tools.search`, `time.now`, `ui.notify`
(progress messages to your console), `test.echo` (test-only)

## Access model

- Grants are tracked per mode: **read**, **write**, or both. A write
  grant implies read on the same path; a read grant never implies write.
- Directory grants come in two tiers: *dir only* (direct children) and
  *recursive* (whole tree).
- When the model touches a path you have not granted, you are prompted
  with numbered choices including the intended purpose - no auto-grants.
- Destructive operations (file/dir delete, shell commands) always ask.
- Sensitive files/dirs (`.env*`, `.git/`, `.harness/`) can never be
  granted.

## Where things live

All harness state lives in `.harness/` inside the working directory:

```
.harness/
  config.yml        # your configuration (template created on first run)
  harness.log       # request/tool log
  harness_history   # prompt history
  sessions/*.json   # saved sessions (conversation + access list)
```

Ignore it from git with a single `.harness/` entry.

## Project layout

```
harness.rb          # entry point
bin/harness         # launcher (env, rbenv, bundle)
bin/rspec           # test runner (same env hygiene as the launcher)
lib/cli.rb          # option parsing, REPL loop, input handling
lib/harness.rb      # tool loop, tool execution, registry
lib/llm_client.rb   # HTTP, retries, request building
lib/session*.rb     # conversation state, save/resume/compact
lib/file_list.rb    # access grants (read/write, files/dirs)
lib/git_runner.rb   # safe git invocation base for the git tools
lib/shell_tokenizer.rb  # StringScanner lexer for shell commands
lib/shell_parser.y  # Racc grammar source (regenerate .rb with racc)
lib/command_handler.rb + lib/commands/*.rb  # one class per /command
lib/tools/*.rb      # one file per tool
lib/system_prompt.txt                     # built-in system prompt
```
