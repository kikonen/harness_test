# frozen_string_literal: true

# Single place that makes externally-sourced text valid UTF-8; why the
# boundary exists and the return rules: doc/encoding_design.md
module TextNormalizer
  # Stand-in for a byte that cannot be represented in UTF-8. A printable
  # ASCII char is chosen deliberately: the replacement is what the model
  # sees, and it must not itself break JSON or the console.
  REPLACEMENT = "?".freeze

  # Returns a valid UTF-8 copy of `text` (never raises).
  def self.normalize(text)
    s = text.to_s
    return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?

    # BINARY-tagged: a raw byte buffer (a child pipe), not text yet.
    return normalize_bytes(s) if s.encoding == Encoding::BINARY

    # Tagged with a declared encoding (a code page inherited from
    # Encoding.default_external, or Shift_JIS from a File.read with an
    # explicit encoding option):
    if s.valid_encoding?
      # The tag is trustworthy, so transcode it - a legal character in that
      # code page must survive as the character, not be replaced.
      s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace,
               replace: REPLACEMENT)
    else
      # Byte-invalid even in its own encoding, so there is nothing to
      # transcode - and scrub must be done ON A UTF-8 COPY: scrubbing this
      # string directly would return it still tagged with the code page, and
      # a non-UTF-8 result reintroduces the Encoding::CompatibilityError the
      # #257 read boundary exists to prevent.
      s.dup.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT)
    end
  end

  # A BINARY (ASCII-8BIT) string is a BYTE CONTAINER, not a text encoding -
  # it is what the child-process pipe accumulator holds (issue #257). The
  # ordering here is the whole point (issue #268): #encode from BINARY maps
  # every byte on its own, so a valid UTF-8 multi-byte character is destroyed
  # one byte at a time: 0xC3 0xA4 (a Latin small letter a with diaeresis)
  # came out as two '?' and 0xE2 0x9C 0x93 (a check mark) as three '?', i.e.
  # any non-ASCII text became unreadable. Literal bytes are spelled out in
  # hex so this file stays pure ASCII (a raw byte here would break the
  # harness' own read/patch tools).
  # So: read the bytes as UTF-8 first (output usually already is UTF-8), and
  # only if they are NOT valid UTF-8 fall back to the ambient code page
  # (Windows: the console code page the child actually wrote in), and only
  # then replace what genuinely cannot be mapped.
  def self.normalize_bytes(bytes)
    utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
    return utf8 if utf8.valid_encoding?

    # Not valid UTF-8: try the ambient code page (what the child actually
    # wrote in). BINARY is excluded deliberately - transcoding FROM a BINARY
    # tag is the byte-by-byte mangling this method exists to avoid (#268), so
    # treating it as a real encoding would reintroduce the bug.
    external = Encoding.default_external
    if external != Encoding::UTF_8 && external != Encoding::BINARY
      tagged = bytes.dup.force_encoding(external)
      if tagged.valid_encoding?
        return tagged.encode(Encoding::UTF_8, invalid: :replace,
                            undef: :replace, replace: REPLACEMENT)
      end
    end

    utf8.scrub(REPLACEMENT)
  end
  private_class_method :normalize_bytes

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
