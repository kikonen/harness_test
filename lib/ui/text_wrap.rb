# frozen_string_literal: true

module UI
  # Greedy word wrap, shared by the renderer's :note prose and the dialog's
  # wrapped notes/options so the two never drift. A word wider than the width
  # gets its own line (never split mid-word: a command name or URL is one token).
  module TextWrap
    module_function

    def words(text, width)
      tokens = text.split(/\s+/).reject(&:empty?)
      lines = []
      cur = +""
      tokens.each do |word|
        if cur.empty?
          cur = word
        elsif cur.length + 1 + word.length <= width
          cur << " " << word
        else
          lines << cur
          cur = word
        end
      end
      lines << cur unless cur.empty?
      lines
    end

    # Wrap a single logical line, preserving it verbatim when it already fits
    # (no whitespace is normalised for a line that needs no wrapping). Callers
    # that carry their own newlines split them first and wrap each paragraph.
    def line(text, width)
      text = text.to_s
      return [] if text.empty?
      return [text] if text.length <= width

      words(text, width)
    end

    # Wrap each "\n"-separated paragraph of text and return the indented output
    # lines (continuation carries the same indent, so a wrapped paragraph reads
    # as one block, not several entries).
    def paragraphs(text, width, indent)
      wrapped = text.to_s.split("\n").flat_map { |para| line(para, width) }
      wrapped.map { |seg| "#{indent}#{seg}" }
    end
  end
end
