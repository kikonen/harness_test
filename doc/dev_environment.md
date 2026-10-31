# Development environments

What each environment actually runs (measured 2026-10-17), and what the
differences mean when reading a test result. This page does not replace
README Setup.

---

## The baseline

`.ruby-version` (`ruby-4.0.1`) is the project baseline, and Ruby itself does
not read it - only rbenv does. A local Ruby that differs from it produces
results that are not comparable with CI's: not worse, just different, so a
number from a run should say which environment produced it.

## Environments

| Environment | Ruby | git |
|---|---|---|
| CI (`ubuntu-24.04`, 24.04.5) | 4.0.1 x86_64-linux | 2.55.0 |
| Windows (MSYS2 / git-bash) | 4.0.7 x64-mingw-ucrt | 2.56.0.windows.2 |
| WSL2 Ubuntu | 4.0.1 x86_64-linux | 2.43.0 |

- CI pins Ruby in the workflow (`ruby-version: ruby-4.0.1`), because
  ruby/setup-ruby does not resolve `file://` here. Bumping `.ruby-version`
  means bumping the workflow in the same commit.
- Windows has no rbenv on PATH, so `bin/harness` and `bin/rspec` run the
  system Ruby (4.0.7) and the pinned baseline is not applied there.
- WSL2 honors `.ruby-version` through rbenv, so its Ruby matches CI's.

## What the asymmetry means

- The git versions differ in BOTH directions: CI's 2.55.0 is newer than
  WSL's 2.43.0 and older than Windows' 2.56.0.windows.2. A failure that
  shows only in CI is plausibly about CI's git rather than about the code,
  so a green local run does not prove a CI-only failure bogus.
- Worked example (issue #292): `git_apply_tool_spec` failed in CI only, on a
  path the example never touched (`Errno::ENOENT .../objects/maintenance.lock`
  during `Dir.mktmpdir` teardown). It was not a phantom - `git commit` spawns
  `git maintenance run --auto --quiet --detach`, whose detached child writes
  that lock after the example has finished. Proven with `GIT_TRACE2`
  (50 maintenance children at baseline, 0 with the fix); not reproducible on
  Windows at all.
- WSL2 is the local environment closest to CI (same Ruby, same OS family, a
  lagging git), so a CI-only failure is reproduced there.
- Windows is the farthest from CI (different Ruby, newest git). Its own
  quirks show up as pending examples rather than failures (symlink specs
  need developer mode).

## Spec-side environment hygiene

Specs run git through a fixed `GIT_ENV`, so the developer's ambient git
config cannot decide a test result, and a spec suppresses the background
children the git under test would otherwise spawn (issue #292:
`maintenance.auto=false` and `gc.auto=0` through `GIT_CONFIG_COUNT` /
`GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` - git's own config env mechanism,
no global config touched).

## Parallel and serial test runs in one script (issue #396)

`bin/rspec` picks the mode by its arguments:

| command | what runs |
|---|---|
| `bin/rspec` | whole suite, one process per core (`parallel_tests`) |
| `bin/rspec spec/lib/task_spec.rb -e "name"` | plain `bundle exec rspec`, exactly as typed |
| `PARALLEL=false bin/rspec` | whole suite, serially |
| `PARALLEL_TEST_PROCESSORS=4 bin/rspec` | whole suite, in 4 processes |

Anything with arguments stays serial on purpose: the gem groups BY FILE, so one
file is FASTER in a single process (measured: `spec/lib/ui/dialog_spec.rb` 2.4s
serial, 3.1s in parallel). Debugging options are the other half of the reason:
the gem claims `-e` as its OWN `-e, --execute COMMAND` flag, so a bare
`-e "name"` makes it try to RUN the example name as a program
(`Errno::ENOENT - colors`); forwarded between its `--` separators it works, but
only after it has already split the suite across processes.
(`--only-failures` needs `config.example_status_persistence_file_path`, which
this repo does not set, so it fails serially too.)

A whole-suite run picks its format by its destination, because a piped one is
read by the `run.command` tool, which keeps the FIRST `limit` lines: a
documentation-format whole-suite run is ~3000 lines, so its own summary would
never reach the model. An interactive TTY gets documentation; a pipe gets
progress (~80 lines), for the parallel and the `PARALLEL=false` run alike. A
run with arguments keeps whatever format was typed (or `.rspec`'s).

The suite is slow because of subprocess/IO waits, not CPU-bound Ruby: six git
tool specs each `git init`+commit a temp repo per example, `task_spec` carries
drain-loop sleeps plus a `sleep 5` hang guard, `external_editor` and
`run_command`/`command_runner` spawn real child processes. Those are wall-clock
waits, so concurrent processes overlap them almost for free.

Measured 2026-10-31 on Windows (ruby 4.0.7, 8 cores), 2251 examples: serial in
the documentation format 1m41s, serial `--format progress` 74s; parallel in the
documentation format 32s (3057 output lines), parallel progress 26s (81 lines),
`bin/rspec` piped 21-29s. The floor is the slowest SINGLE file - grouping is by
file, so `task_spec` (~9s) sets a line no process count goes below. CI stays on
serial `bundle exec rspec`: its runners have 2 cores, the gain is small, and one
serial job reads more cleanly.

The gem balances groups automatically, but its proxy is file SIZE, not time:
time-based grouping needs a recorded per-file runtime log, and for rspec that
log only comes from the `RuntimeLogger` formatter, whose RSpec-2 interface
RSpec 3.13 rejects without the deprecated `rspec-legacy_formatters` gem. Size
already balances to within a couple of seconds here, so that gem is not added.

Parallel runs expose examples that assume a machine-wide namespace. The first
parallel run failed `external_editor_spec`'s "leaves no scratch directory
behind": it globs `Dir.tmpdir` for `harness-editor*`, and a sibling process had
its own live one at that moment. Fixed by giving that example a private temp
root through `TMP`/`TEMP`/`TMPDIR` (all three, because `Dir.tmpdir` prefers
TMP/TEMP on Windows). Any leftover/shared-temp check needs the same treatment.

## Refreshing this page

When `.ruby-version`, the workflow's `ruby-version:` or the runner image
changes, re-measure the table and note the date the numbers were taken (the
intro above).
