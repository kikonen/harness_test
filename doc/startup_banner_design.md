# The startup banner and its replay ordering

Why the startup facts live in their own `StartupBanner` class rather than in
`CLI`, and why the resumed tail is drawn BEFORE the banner. Issue #553 (the
"startup banner vs replay ordering" report) and the owner's follow-up: "that
whole startup banner method is so huge that it could be its own class".

---

## The ordering bug (#553)

On a resumed run the previous exchange used to be redrawn partway through the
banner: after the Model / Working directory / Session lines and before Command
consent / palette / streaming / MCP / tips. The run's own facts wrapped around
the replay block, so reading the startup meant scrolling over the replay to find
the facts.

`StartupBanner#print` fixes the order: the saved tail first, then the banner as
one contiguous block. `resume.replay_on_startup` (config, default on) gates the
automatic redraw; only an explicit false skips it, and `/replay` still shows the
record whatever it says. `resume.replay_entries` still bounds how many lines the
record holds - the two keys are independent.

## Why the display left the CLI

`CLI#run` is the run's owner: it resolves identity, builds the registry, the
SystemSaver, the factory and the command handler, then drives the prompt loop.
The startup facts share none of that machinery - they read settings, the file
list, the foreground Harness and the registry, and write only through the UI. A
68-line `print_startup_banner` plus four display helpers
(`consent_posture_display`, `file_access_display`, `session_log_path_display`,
`print_resume_replay`) sat in the middle of the run mechanics.

`StartupBanner` owns that display. The CLI builds it after `#setup` (so the
foreground Harness it reads exists) and calls `print`. The class takes the
pieces it reads - `ui`, `settings`, `file_list`, `harness`, `registry`,
`resumed` - and holds no run state of its own, so it has nothing to keep in
step with the loop.

What stays in the CLI: `resume_cli_string` (the exit-save path prints it, and
`SaveCommand` has its own copy) and `resumed_run?` (`#setup` uses it to decide
whether to read a session). Those are run mechanics that merely surface in a
line, not startup display.
