# frozen_string_literal: true

require_relative "text_normalizer"

# The byte boundary for files the model edits: the line-ending style is decided
# from the bytes ON DISK, never from a text-mode read (which already translated
# them). Design and the measurements: doc/file_editing_design.md.
module FileText
  LF   = "\n"
  CRLF = "\r\n"
  CR   = "\r"

  # text:        content for the model - valid UTF-8, LF separators only
  # separator:   separator the file is written back with
  # trailing_newline: source ended with a separator (kept exactly - a trailing
  #                   blank line is content, not noise)
  # lone_cr:     CR bytes that were not part of a CRLF
  # mixed:       source carried BOTH CRLF and LF separators
  # lossy:       source bytes were not valid UTF-8, so `text` is a scrubbed view
  #              and cannot be written back without changing bytes
  Result = Struct.new(
    :text,
    :separator,
    :trailing_newline,
    :lone_cr,
    :mixed,
    :lossy,
    keyword_init: true)

  def self.from_disk(path)
    analyze(File.binread(path))
  end

  def self.from_text(content)
    analyze(content.to_s)
  end

  # Writes `text` (LF separators) with `separator`, byte for byte: no platform
  # translation, so an LF file stays LF and a CRLF file stays CRLF.
  def self.write(path, text, separator)
    body = separator == LF ? text : text.gsub(LF, separator)
    File.binwrite(path, body)
  end

  def self.dirty?(result)
    result.lone_cr.positive? || result.mixed
  end

  # Names what was already wrong in the source before this tool ran, so a repair
  # is never a silent byte rewrite. `separator` is what the file WILL be written
  # with, which is not always the style the source itself favoured.
  def self.repair_note(result, separator = result.separator)
    parts = []
    parts << "#{result.lone_cr} bare CR" if result.lone_cr.positive?
    parts << "mixed CRLF/LF" if result.mixed
    "#{parts.join(' + ')} normalized to #{separator == CRLF ? 'CRLF' : 'LF'}"
  end

  # Majority wins: CRLF when CRLF is at least as common as bare LF, so a
  # mostly-CRLF file with a couple of stray LFs is repaired in place instead of
  # flipped wholesale by a patch that touched one line. A file with no CRLF at
  # all is LF - that is the case a text-mode read gets wrong.
  def self.analyze(source)
    crlf = source.scan(CRLF).size
    lf   = source.count(LF) - crlf
    lone = source.count(CR) - crlf
    cr_only = crlf.zero? && lf.zero? && lone.positive?
    utf8 = source.dup.force_encoding(Encoding::UTF_8).valid_encoding?

    separator = if cr_only
                  CR
                elsif crlf.zero? && lone.zero?
                  LF
                else
                  crlf >= lf ? CRLF : LF
                end
    text = TextNormalizer.normalize(source).gsub(CRLF, LF)
    # A CR that is not a terminator here is damage: deleting it preserves the
    # file's line COUNT, while treating it as a newline would invent a blank line.
    text = cr_only ? text.gsub(CR, LF) : text.delete(CR)

    Result.new(
      text:,
      separator:,
      trailing_newline: !source.empty? && source.end_with?(separator),
      lone_cr: cr_only ? 0 : lone,
      mixed: crlf.positive? && lf.positive?,
      lossy: !utf8)
  end

  private_class_method :analyze
end
