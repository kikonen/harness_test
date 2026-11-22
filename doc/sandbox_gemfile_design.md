# The project Ruby sandbox: `.harness/sandbox/Gemfile`

Why a model-run Ruby script goes through a pinned per-project Gemfile, why the
harness seeds AND offline-locks it but the model manages it, and the `bundle exec` load-path trap
that decides the starter's shape. Issue #340.

---

## The problem

`CommandRunner#run_in_shell` wraps EVERY model command in
`Bundler.with_unbundled_env` (issue #185) so a harness subprocess never inherits
the harness' own bundle. The side effect: a model's bare `ruby script.rb` runs
against the box's AMBIENT user gems - whatever happens to be installed there.
On one box `time_up` resolves; on another it does not. A script's result then
depends on the machine, not on the project. There is no contract to lean on
except Ruby's own stdlib.

## The three paths, measured through the real `sh -c` + unbundled path

1. `ruby script.rb` - ambient user gems. Present only by luck; no guarantee.
2. `bundle exec ruby script.rb` - the WORKDIR's own Gemfile, i.e. the harness
   application's dependencies. Not what a throwaway script wants.
3. `BUNDLE_GEMFILE=<path> bundle exec ruby script.rb` - a curated, pinned set
   that belongs to neither the box nor the app. This is the blessed path.

## The load-path trap (this is what shapes the starter)

`bundle exec` does not merely ADD the Gemfile's gems to the load path - it
ISOLATES it to what the Gemfile declares. Measured against an EMPTY Gemfile,
even `csv`, `rexml`, `logger`, `racc`, and `base64` raise `LoadError`; only the
true Ruby-default `json` survives. A gem installed on the box but not listed in
the Gemfile is a `LoadError` under `bundle exec`.

Consequence: a blessed sandbox **must ship a NON-EMPTY starter**. Seeding an
empty Gemfile would silently break the common format/stdlib-adjacent gems the
model reaches for. The starter therefore lists `csv`, `json`, `rexml`, `logger`,
`racc`, `base64`, and carries the run incantation as a comment so the model sees
it when it opens the file.

## Where the starter comes from: a repo file, not a string in the source

The default is `config/sandbox_gemfile.example.rb` (`SandboxGemfile::STARTER_TEMPLATE_FILE`),
copied verbatim on a fresh seed - the same arrangement `HarnessConfig::TEMPLATE_FILE`
uses for `config/config.example.yml`. It is text in the repo, so changing the default
gem list is an edit of a config file rather than an edit of `lib/`.

It lists `fiddle` and `reline` too: `reline` stopped being a Ruby default gem, and
reline's Windows IO gate requires `fiddle`, so a script that requires anything under
`lib/` (which reaches `UI::Renderer` and `UI::Editor`) needs both. Measured on Ruby
4.0: without them `require "job_registry"` raises `LoadError` under `bundle exec`.

## The default list is a floor, not a starter-only snapshot

`ensure_starter!` writes the template only when no Gemfile exists, so the default would
otherwise be a one-time snapshot: a model that rewrote the sandbox (or a seed made
against an older default) could lose a default gem and only find out mid-script, as a
bare `LoadError`. `ensure_default_gems!` therefore runs on EVERY launch and appends only
the names the sandbox has lost - never rewriting the file, and never touching a version
constraint the model wrote for a gem it keeps declaring. Nothing is ever removed.

Verified against the seeded starter: it resolves offline via
`bundle lock --local`; a model-added gem that is already installed (nokogiri in
the measurement) works; a not-installed gem fails cleanly at `bundle install`
rather than at `require`.

## Harness seeds and offline-locks it, the model manages it

`.harness/` is a SENSITIVE path (`doc/sensitive_paths_design.md`): the model's
file tools cannot write into it. So the scaffold has to be written by the
harness. `SandboxGemfile#ensure_starter!` (lib/sandbox_gemfile.rb) creates the
directory and writes the starter ONLY when no Gemfile is there yet - it never
overwrites a Gemfile the model has since edited - then, for that fresh seed
only, tries to make it a real bundle. A seeded-but-unlocked Gemfile is only a
manifest: `bundle exec` resolves it from locally installed gems, so it works on
this box (every starter gem is present here) but fails on a box missing one with
"Could not find gem ... in locally installed gems" (measured - a gem absent on
the box cannot be resolved offline, and csv/rexml/logger/racc/base64 stop being
Ruby defaults at 3.5, so a clean future box is exactly that case).

So `#lock_seeded?` runs `bundle lock --local` once, in `Bundler.with_unbundled_env`
with stdout/stderr discarded, and keeps the `Gemfile.lock` only if it succeeds.
`--local` is OFFLINE: it never contacts rubygems.org, so it adds no network call
and no download to startup - it only records the versions ALREADY on this box. On
a missing gem it leaves NO partial lock and the method returns false. It runs ONLY
on a fresh seed: every later launch hits the `exist?` early return, so no bundler
is ever spawned again. `ensure_starter!` returns `:existing` / `:seeded_locked` /
`:seeded_unlocked` so Harness can log which happened - a seed that could not lock
is visible at startup instead of surfacing later as a mid-run LoadError.

A bundler failure must never crash harness startup, so any raise in `lock_seeded?`
### "The model manages it" - through bundler and shell, not through the file tools

Measured on this box (Ruby 4.0, `x64-mingw-ucrt`): `Bundler.with_unbundled_env`
removes `BUNDLE_GEMFILE`/`BUNDLE_BIN_PATH`/`RUBYOPT`, but a `run.command` shell is
still a child of the harness process, so it may write into the sandbox - a plain
`File.write(".harness/sandbox/written_by_shell.txt", ...)` from a model command
succeeds, and every `bundle add`/`bundle install` a session has ever run here wrote
its Gemfile and lock there. The block is the FILE TOOLS only: `SensitiveFiles`
matches `.harness` against every path component, so `file.write`/`file.patch` on
`.harness/sandbox/Gemfile` are refused whatever the posture, with no grant offered.

That asymmetry is what the two changes above close. The starter is a repo file the
owner can edit, so the default no longer needs the sandbox to be writable; and the
floor means the model's own bundle edits are safe to keep, because a lost default
comes back on the next launch. A model that wants gems the default does not carry
still adds them the supported way - `bundle add <gem>` (with a version:
`bundle add <gem> --version ">= 1.19"`; the bare positional form silently injects a
garbage declaration) - and `bundle install`.

collapses to false. Installing a gem the box lacks stays the model's own,
consent-gated `bundle install` through `run.command` - the harness never runs a
network install on the model's behalf.

## Why it stays gitignored (unlike skills)

`.gitignore` has `.harness/*` and re-includes only `.harness/skills/`. A
sandbox Gemfile + lock record which gems THIS machine resolved for THIS project
- per-machine state, correctly lost to the next clone, exactly like sessions and
logs. (A skill, by contrast, is repo content the owner chose to keep.) So
`.harness/sandbox/` matching `.harness/*` is the intended behavior, not an
oversight.
