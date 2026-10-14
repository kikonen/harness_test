# frozen_string_literal: true

# -- TextNormalizer -------------------------------------------------------
#
# Single place for making externally-sourced text safe to use.
#
# WHY (issue #233 / #257): anything the harness takes from OUTSIDE its own
# process - a shell command's output, a file read from disk, a diff or a
# command string the model sent - can carry bytes that are not valid UTF-8,
# or be tagged with an encoding that is not UTF-8. Ruby then fails in two
# ways:
#   * String operations over invalid bytes raise ArgumentError
#     ("invalid byte sequence in UTF-8"): strip, split, regex match.
#   * Concatenating a UTF-8 literal with a BINARY string raises
#     Encoding::CompatibilityError ("incompatible character encodings:
#     UTF-8 and BINARY (ASCII-8BIT)") - this is what killed run.command.
#
# Both fire the moment the malformed text is first touched, and the failure
# is often invisible because the handler that reports it fails the same way:
# the session save is JSON.generate, which raises JSON::GeneratorError on the
# exact same byte, so the tool error never reaches the console.
#
# So the harness normalizes ONCE at each read boundary and every downstream
# consumer then sees plain, valid UTF-8 and cannot raise: the tokenizer,
# String#strip, the line truncation, JSON.generate, and the console.
#
# A string that is already valid UTF-8 is returned untouched (no allocation,
# no frozen-string mutation). Bytes that genuinely belong to another encoding
# are transcoded; only bytes that cannot be represented in UTF-8 are replaced
# with the replacement character, so output stays inspectable instead of
# crashing the turn.
module TextNormalizer
  # Stand-in for a byte that cannot be represented in UTF-8. A printable
  # ASCII char is chosen deliberately: the replacement is what the model
  # sees, and it must not itself break JSON or the console.
  REPLACEMENT = '?'.freeze

  # Returns a valid UTF-8 copy of `text` (never raises).
  def self.normalize(text)
    s = text.to_s
    return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?

    # Tagged with some other encoding (a shell pipe or File.read inherits
    # Encoding.default_external, which on Windows is often a code page):
    # transcode, replacing only what cannot map to UTF-8.
    if s.encoding != Encoding::UTF_8 && s.valid_encoding?
      return s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace,
                     replace: REPLACEMENT)
    end

    # Tagged UTF-8 but byte-invalid, or tagged with another encoding whose
    # bytes are not valid in THAT encoding either: scrub cannot transcode, so
    # treat the bytes as UTF-8 and drop only what cannot be represented.
    s.scrub(REPLACEMENT)
  end

  # Recursively normalizes every String inside a parsed JSON structure
  # (Hash / Array / String). Used where the incoming value is not a single
  # string but a whole parsed object - tool-call arguments and the LLM
  # response - so nothing malformed reaches the message chain.
  def self.normalize_strings(obj)
    case obj
    when String then normalize(obj)
    when Hash   then obj.transform_values { |v| normalize_strings(v) }
    when Array  then obj.map { |v| normalize_strings(v) }
    else obj
    end
  end
end
