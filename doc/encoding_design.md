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
the line truncation, `JSON.generate`, and the console.

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
