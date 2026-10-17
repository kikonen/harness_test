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

## Refreshing this page

When `.ruby-version`, the workflow's `ruby-version:` or the runner image
changes, re-measure the table and note the date the numbers were taken (the
intro above).
