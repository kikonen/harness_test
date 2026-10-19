# /help as data: the registry, the entries, the renderer

Why the help text is split into three layers and what each one owns.
Issue #323 (the "command help logic is starting to be klunky" report).

---

## Before: one dump that had to be maintained three times

`HelpCommand#handle` was a single 182-line heredoc that printed 169 lines
(measured by running the real command before the change). Inside it:

- ~35 hand-typed command lines with hand-padded columns, listing the commands a
  second time - `CommandHandler::COMMANDS` already IS the dispatch registry, and
  nothing checked that the two agreed;
- ~134 lines of prose (keys, multiline input, consent postures, sessions) glued
  to the listing, so one page was the only page, and reading `/param`'s forms
  meant scrolling the whole dump;
- a third copy in `README.md`'s command table.

Adding a command therefore meant editing three places, and forgetting one was
invisible: the harness happily dispatched a command no help page mentioned.
`/palette` is exactly that near-miss - the README row for it was missing when
this issue started.

## After: three layers, one owner each

| layer | file | owns |
| --- | --- | --- |
| registry | `lib/command_handler.rb` | WHICH commands exist (`COMMANDS`) |
| entry data | each `lib/commands/<name>_command.rb` | WHAT one command is: usage form, accepted forms, one-line summary, group, see-also |
| topic data | `lib/help_topics.rb` | the prose: named topics with paragraph bodies |
| rendering | `lib/help_renderer.rb` | HOW it looks: grouping, column width, wrapping, the see-also resolution, the "did you mean" list |

`Command.help` (on the shared base) reads the class's own `HELP` constant, and
**raises if a command declares none**. That is the whole anti-drift mechanism:
`/help` builds its table by asking the registry's classes for their entries, so a
registered command without help cannot be silently skipped - it fails loudly, the
same principle #146 applied to unknown output types.

`HelpRenderer` takes the registry as a parameter and returns LINES; it prints
nothing. The command that owns the console decides how they land - the same
data-then-render split the output layer uses.

## What the reader gets

- bare `/help`: the command table grouped by kind (one column width computed from
  the entries, not hand-padded) + the topic index. 73 lines instead of 169.
- `/help <command>`: that command's summary and every accepted form.
- `/help <topic>`: one prose topic on its own. The bodies are plain paragraphs;
  the renderer wraps them to `DEFAULT_WIDTH` (78), so the wording is data and
  the line shape is a rendering decision.
- `/help <unknown>` and `/<unknown>`: the closest registered names, from the same
  registry the lookup just missed.
- An entry's `see_also` is resolved against BOTH registries: a command becomes
  `/name`, a topic becomes `/help name`.

## Rules that are checked, not remembered

`spec/lib/commands/help_command_spec.rb` is the drift contract:

- every registered class answers `help`, and every entry has a usage, a summary
  and a group `CommandHelp::GROUPS` actually names (so no group is empty);
- bare `/help` contains every registered command;
- README's table covers exactly the registry - neither a missing row nor a row
  for a command the dispatcher would reject;
- `CommandHandler::COMMANDS.values` is EXACTLY the set of `Commands` classes that
  subclass `Command` (issue #327). The examples above iterate the registry, so
  they can find a missing `HELP` but never a command class that was written,
  required, and never registered - the failure that reaches the user as
  `Unknown command: /foo`. Checking the set both ways also catches a class
  registered twice, and a key pointing at something that is not a command;
- no topic name collides with a command name. `HelpTopics.validate!` runs that
  at `CommandHandler` construction too: the collision is what would make
  `/help session` ambiguous (the first topic set did collide on `session`, which
  is why the prose topic is `conversation`).

`HelpRenderer#help_entries` additionally refuses an entry whose usage does not
start with its registered name: the table prints the usage form in the command's
slot, so a mismatched one would advertise a form the dispatcher does not accept -
the spec asserts the same thing for every entry, without running the renderer.

## The typo band is measured

`CommandHelp.suggestions` is a plain Levenshtein ranking with `max_distance: 2`,
measured over this command set: at 3 an unrelated name qualifies (`helo` ->
`yolo`), at 1 only the single nearest survives. A prefix counts as exact, so
`/res` is treated as an abbreviation of `/resume`, not as a misspelling.

## Not in this issue

`/help` still has no paging: a topic page prints to the console in one go. A TUI
(#146) is the natural owner of scrolling, and `HelpRenderer` returning lines
instead of printing is what keeps that door open.
