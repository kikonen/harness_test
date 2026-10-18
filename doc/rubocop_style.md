# Rubocop: which house rules are enforced, and how they were chosen

Why `.rubocop.yml` enables some cops, configures others to a specific style,
and leaves the rest off. Read this before editing the config: a cop that looks
"missing" was measured and rejected on purpose.

Counts were measured with **RuboCop 1.92.0** (ruby 4.0.7 locally, CI pins
ruby-4.0.1) over `lib/**`, `spec/**` and `harness.rb` at the state of the
`feature/issue-302-rubocop` branch. They are a snapshot, not a live number.

---

## The principle

`AllCops: DisabledByDefault: true`, and only the mechanical part of what
`harness.md` states is switched on. A rule every session has to remember is a
rule sessions forget; a rule a cop checks is free. Cops that restate Ruby idiom
rather than a decision of THIS repo stay off - a cop the code fights gets
disabled anyway, and a config full of disabled cops is noise.

Existing violations are baselined in `.rubocop_todo.yml` (per-file `Exclude`
lists): 46 cops, 740 offenses, biggest LineLength 177, HashAlignment 87,
LineEndStringConcatenationIndentation 62, ExtraSpacing 40,
MultilineMethodArgumentLineBreaks 39, FirstMethodArgumentLineBreak 33,
ArgumentAlignment 32. New code is held to the rules; old debt is removed step by
step, each step its own reviewable commit.

## Specs are excluded from formatting rules

The Layout department and each Style cop carry `Exclude: spec/**/*`. Measured:
specs are where nearly every formatting offense lives (1908 of 2136 paren
offenses; 127 of the 175 hash-shorthand ones). Test code's shape follows the
example it describes, so a quote-style or brace-layout rule there buys nothing.

Lint and Naming stay on everywhere: they catch actual mistakes (unused variable,
duplicated branch, shadowed exception), not taste.

## Continuation style: configured, not disabled

`harness.md` says continuation lines get 2 spaces from the line that opened the
call, never aligned under the opening parenthesis. Disabling the six alignment
cops (the first attempt) left that rule unenforced. Instead the shape was pinned
from a probe the owner wrote - two versions of the same `Task.emit` call, one
produced by a model (`not_this`) and one by hand (`want_this`) - by running each
candidate style against ONLY that file and seeing which setting accepts
`want_this` and which flags `not_this`:

```ruby
# not_this - arguments hang under the opening call, hash values table-padded,
# closing brace on its own line.
def not_this
  Task.emit(:spinner_detail, origin: :session_manager,
            content: { message: "Compacting session (#{before} messages to summary)",
                       suffix: -> { @harness.context_indicator_live } })
end

# want_this - short lines, fixed continuation indent, the closing brackets end
# the last argument's line.
def want_this
  Task.emit(
    :spinner_detail,
    origin: :session_manager,
    content: {
      message: "Compacting session (#{before} messages to summary)",
      suffix: -> { @harness.context_indicator_live }
    })
end
```

| Cop | Setting that accepts `want_this` | Alternative measured against the probe |
| --- | --- | --- |
| `ArgumentAlignment` | `with_fixed_indentation` (flagged `not_this`) | `with_first_argument` accepted both - useless as a rule |
| `HashAlignment` | `EnforcedColonStyle: key` | `table` flagged `want_this` itself; table/table 292 and key/table 320 repo-wide |
| `MultilineMethodCallBraceLayout` | `same_line` (the `})` form) | `symmetrical` flagged `want_this`; `new_line` flagged both |
| `MultilineHashBraceLayout` | `symmetrical` (`}` on the line after the last key) | `same_line` keeps `}` glued to the last value |
| `MultilineMethodCallIndentation` | `indented` | `aligned` = 16 repo offenses vs 24 |
| `FirstArgumentIndentation` | `consistent` (3 offenses) | `consistent_relative_to_receiver` = 66, `special_for_inner_method_call` = 39 |
| `First{Array,Hash}ElementIndentation` | `consistent` | 0 offenses - free |

The line-break cops are what actually produce the shape: without
`FirstMethodArgumentLineBreak`, `MultilineMethodArgumentLineBreaks`,
`FirstHashElementLineBreak`, `MultilineHashKeyLineBreaks` and
`FirstArrayElementLineBreak` the inner hash stays inline on one line. With them,
the autocorrector turns `not_this` into `want_this` line for line (verified by
correcting `not_this` and diffing it against `want_this`).

`Layout/HashAlignment` has no `EnforcedStyle` at all (its options are
`EnforcedColonStyle` / `EnforcedHashRocketStyle`) and
`Layout/FirstArrayElementIndentation` does not accept `with_fixed_indentation`.
Writing harness.md's wording into the config as a guess produced three
invalid-config errors; the names in the table are the validated ones.

## Separators (blank lines)

`EmptyLineAfterGuardClause` (25 baselined) and `EmptyLineBetweenDefs` (4) are
enabled: a guard clause glued to what follows it reads as trailing noise on the
line above, which is where a wall of text starts.

`EmptyLinesAround{Class,Block}Body` are pinned to `no_empty_lines` (the repo's
practice: the `empty_lines` style would fire 162 times on ClassBody and 204 on
BlockBody over `lib/` + `harness.rb`).
`EmptyLinesAroundMethodBody` is plain `Enabled: true` - **it does not accept
`EnforcedStyle`**, and rubocop warns on every run and ignores the setting, so a
measurement made with that setting on is meaningless.

There is **no cop for "a blank line before a comment block"**: 161 places in
`lib/` start a comment directly under a code line, and every comment cop rubocop
ships is about indentation, leading space or magic comments.
`EmptyLineAfterComment` is the reverse direction (comment glued to the code
BELOW it). A custom cop was considered and rejected as too much machinery for the
gain, so this remains a harness.md rule checked in review.

## Class structure

`Layout/ClassStructure` with `ExpectedOrder` trimmed to
`module_inclusion, constants, initializer, public_methods, private_methods`:
constants belong at the top of the class, not scattered between its methods
(3 offenses baselined; the default order also demands a public_class_methods
arrangement this repo does not follow, which would make it 12). Its autocorrect
is UNSAFE - a constant read by an earlier method changes meaning - so reordering
is a reviewed edit, never a blind `-a`. The 4th offense, the constant sitting
mid-class in `session_manager.rb`, was moved by the pilot reformat commit.

## Metrics department: off

At the default thresholds it fires **363** times on `lib/`: MethodLength 148,
AbcSize 90, CyclomaticComplexity 55, PerceivedComplexity 43, ClassLength 19
(largest class 401 lines vs a 100 limit), BlockLength 5, ParameterLists 2,
BlockNesting 1.

Class and method size here is a deliberate consequence of the design
(`session_manager.rb`, `command_runner.rb` 609, `command_allowlist.rb` 593) and
is review judgement. Raising the limits to "pass" would only hide the number.

## Parentheses

A call that TAKES arguments wears them (`x = some_method arg1, arg2, arg3` is the
unreadable form); a call that takes none never wears them; `super` stays bare
unless suppressing the forwarding is the point (`super()` is right only when
zero arguments must reach the parent).

Measured, the repo already followed this: all 62 `logger.*` calls parenthesised,
zero bare; zero `super()`; six bare `super`. These cops lock in a habit rather
than fix a defect (1 offense baselined: an optparse `separator ""` in `cli.rb`).
`AllowedMethods` covers the calls Ruby itself writes without parens (`puts`,
`print`, `p`, `warn`, `raise`, `exit`, `sleep`, `yield`, `emit_line`), which is
why the config's `yield` entry never fires.

## Hash values: no `x: x` tautology

`Style/HashSyntax` with `EnforcedStyle: ruby19` (already the repo's practice -
821 offenses against `hash_rockets`) and `EnforcedShorthandSyntax: always`: when
the value IS the variable the key is named after, the repetition is dropped
(`tools: tools` -> `tools:`, `{ saved: saved }` -> `{ saved: }`). 48 sites in
`lib/` were corrected outright, no baseline entry needed.

This is safe because Ruby resolves a bare identifier in that position exactly as
it did before: measured over a scratch file that the shortened form still reaches
a METHOD when no local of that name is in scope, and prefers the local when one
is. The cop only shortens a pair whose value is that bare identifier, so a call
with arguments is left alone.

## Trailing if/unless: review judgement only

A trailing `if` / `unless` carries ONE condition - `something(a, b, c) unless
conda && condb && condc` is unreadable. RuboCop 1.92 has no cop that inspects the
shape of a modifier condition (its only "modifier" cops are access-modifier
indentation), so this cannot be enforced here.

For context: 119 modifier lines in `lib/` have 2+ top-level operands, 12 of them
3+, and only 2 of the 119 exceed 90 chars - the repo already keeps them short.

## Line length: 90 is physical

90 is the width of ONE Emacs buffer in the two-pane setup the code is read in (a
Zenbook: two side-by-side windows fit ~90 columns each), not an abstract limit.
`AllowedPatterns` exempts comment and URL lines. The 177 baselined long lines
are deliberately not reformatted: splitting a long string or a tool description
is often uglier than the long line, so each file is shortened when it is touched
for another reason.

## inherit_mode: merge: [Exclude] is load-bearing

A per-cop `Exclude` in `.rubocop.yml` REPLACES the `Exclude` list the todo file
generates for the same cop - arrays are not merged across `inherit_from` by
default. With the spec scoping in place that silently discarded the whole
baseline (1149 baselined offenses kept firing on a clean tree). Removing
`inherit_mode` makes `.rubocop_todo.yml` inert.

## Line endings, and what autocorrect does to them

`Layout/EndOfLine: lf` is the honest rule even on a Windows checkout: `native`
fires on all 131 inspected files there (native means CRLF) while `lf` is clean,
because the tree is LF (`.gitattributes` `* text=auto eol=lf`, `core.autocrlf
false`).

Corollary: `rubocop -a` WRITES NATIVE ENDINGS, so a correction on this Windows
tree turns files into CRLF on disk even though git normalizes them back to LF on
commit. Convert the touched files back to LF after any `-a` run, or `EndOfLine:
lf` stops meaning anything locally. `-a` also leaves trailing whitespace where it
split an argument list - `Layout/TrailingWhitespace` (already on via the Layout
department, 0 offenses) is what catches that residue.

## Quotes

Double quotes everywhere; the repo's older single-quote habit is dropped. Cost
measured before deciding: 5062 offenses to flip vs 62 for the other direction.
Applied as one mechanical commit over `lib/` + `harness.rb` (989 lines, 81
files); 10 offenses remain baselined (heredocs and strings needing inner
quotes).

## Verifying a reformat commit is layout-only

`ruby -c` and the suite catch breakage, but a stronger check for a pure-style
commit is comparing the PARSED AST of the old and new file. Note its limit,
measured the hard way: `tools: tools` and `tools:` produce **identical** ASTs, so
the comparison is blind to hash-shorthand edits and an "AST identical" verdict
there proves nothing. It is meaningful for changes that move or remove nodes
(indentation, line wrapping, constant ordering - the `session_manager.rb`
reformat was verified that way, 1697 nodes, only the constant moved).
