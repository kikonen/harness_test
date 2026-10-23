# TextNormalizer: encoding boundary design

Why every externally-sourced text passes one normalization point
(`lib/text_normalizer.rb`).

---

## Why the boundary exists

Anything the harness takes from OUTSIDE its own process - a shell command's
output, a file read from disk, a diff or a command string the model sent - can
carry bytes that are not valid UTF-8, or be tagged with an encoding that is not
UTF-8. Ruby then fails in two ways:

- String operations over invalid bytes raise `ArgumentError` ("invalid byte
  sequence in UTF-8"): `strip`, `split`, regex match.
- Concatenating a UTF-8 literal with a BINARY string raises
  `Encoding::CompatibilityError` ("incompatible character encodings: UTF-8 and
  BINARY (ASCII-8BIT)") - this is what originally killed `run.command`.

Both fire the moment the malformed text is first touched, and the failure is
often invisible because the handler that reports it fails the same way: the
session save is `JSON.generate`, which raises `JSON::GeneratorError` on the
exact same byte, so the tool error never reaches the console.

## One normalization per read boundary

The harness normalizes ONCE at each read boundary and every downstream consumer
then sees plain, valid UTF-8 and cannot raise: the tokenizer, `String#strip`,
the line truncation, `JSON.generate`, and the console. The boundaries the harness
reads FROM (verified against `lib/` on 2026-10-23, `grep -rn "TextNormalizer.normalize" lib`):
child-process output (`CommandRunner#read_child_in_group`, `GitRunner`), the LLM wire
(`BaseBackend` parsed body, `StreamReader` per line), tool-facing file reads,
model-supplied command text (`CommandAllowlist`, `ShellTokenizer`, `CommandRunner#run`),
tool results entering the chain (`Harness#execute_tool_call`), skill files
(`Skills#read_raw`), a written file's source (`FileText.analyze`), and a prompt file -
`--system-file` (`Harness#read_system_prompt`, issue #342). `harness.md` (the other
half of the prompt, `Harness#build_system_prompt`) is the ONE remaining prompt-file
read that is NOT normalized - issue #341, still open as of this writing.

Why prompt files are on this list at all: the system prompt is the FIRST message of
every chain the harness sends or saves, so an unnormalized read there is not a display
problem but a chain-poisoning one - it survives until `JSON.generate`, which is both
the request body and the session save.

## Return rules

- Already valid UTF-8: returned untouched (no allocation, no frozen-string
  mutation).
- Tagged with a DECLARED encoding: transcoded, trusting the tag.
- BINARY-tagged: a BYTE CONTAINER, not a text encoding, so its bytes are read
  as UTF-8 first (`normalize_bytes`). A naive transcode FROM a BINARY tag maps
  each byte separately and destroys every multi-byte character - a 2-byte
  letter becomes two `?` (issue #268).
- Only bytes that genuinely cannot be represented in UTF-8 become the
  replacement character, so output stays inspectable instead of crashing the
  turn.
