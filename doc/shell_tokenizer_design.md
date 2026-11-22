# ShellTokenizer design

A StringScanner-based tokenizer for a SAFE SUBSET of POSIX shell. It emits a
flat token stream that ShellParser (a Racc grammar) consumes to build an AST of
pipelines and simple-commands. The tokenizer is NOT responsible for syntax
validation - it only classifies each lexeme.

## Token kinds (symbol values)

- `:word` - a shell word: bare text, single-quoted, double-quoted, or a mix
  (e.g. `foo"bar baz"`). The token's string value preserves the original
  quoting so downstream code can inspect it; ShellParser uses it verbatim for
  prefix matching (quotes do not change what command runs).
- `:pipe` - `|`
- `:and`  - `&&`
- `:or`   - `||`
- `:semi` - `;`
- `:pipe_and` - `|&` (pipe with stderr)
- `:danger` - any construct that must NEVER be auto-approved:
  - `<`, `>`, `>>` (file redirects - EXCEPT to /dev/null, which only discards
    output and is safe, see below)
  - `&>`, `&>>` (combined stdout+stderr redirect; same /dev/null exemption)
  - `&` (background)
  - `$` (substitution / variable expansion)
  - `` ` `` (command substitution)
  - `(`, `)` (subshell / grouping)

  The token's string value holds the offending lexeme so error messages can
  name it.

## Design notes

- fd-to-fd redirects like `2>&1` are NOT dangerous - they only swap
  stderr/stdout within the same process. The tokenizer treats them as a single
  `:word` token (e.g. "2>&1") so that pipelines such as
  `bundle exec rspec 2>&1 | grep x` can be auto-approved.
- Redirects TO /dev/null (`>/dev/null`, `2>/dev/null`, `>>/dev/null`) are NOT
  dangerous either - they only discard output, creating or modifying no file.
  The tokenizer treats them as a single `:word` token (e.g. ">/dev/null",
  "2>/dev/null") so such commands can be auto-approved. Any other redirect
  target is still `:danger`.
- Combined stdout+stderr redirects (`&>`, `&>>`) follow the same rules: safe
  only when targeting /dev/null.
- Operators inside quotes are literal characters, never separators.
- Backslash-escaped operators outside quotes become part of the surrounding
  word (e.g. `echo a\|b` -> one word "a\|b").
- The tokenizer is intentionally conservative: anything it cannot classify
  confidently is emitted as `:danger`, which ShellParser rejects. This errs on
  the safe side.
