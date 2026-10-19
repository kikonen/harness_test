# frozen_string_literal: true

require_relative "palette"

# Renders one output entry to a console line: the PATTERN (label, status
# bracket and glyph, gutter, color) belongs here, never in the emitted string.
# Design and the full type list: doc/output_rendering_design.md.
module UI
  class Renderer
    LABELS = {
      step_label: "step ",
      plan: "plan:  ",
      interstitial: "say:   ",
      tool_plan: "tools: ",
      response: "model: ",
      warn: "warn:  ",
      error: "error: "
    }.freeze

    # The verdict IS the type; the bracket label travels in the event's origin,
    # never in the content. status_info has no glyph: a count or a progress
    # line is not a verdict about an operation.
    STATUS_GLYPHS = {
      status_ok: "✓",
      status_fail: "✗",
      status_warn: "⚠",
      status_note: "!",
      status_same: "=",
      status_info: nil
    }.freeze
    STATUS_TYPES = STATUS_GLYPHS.keys.freeze

    # The emitter still owns these lines' shape. :spinner_detail is listed
    # because the drain loop animates it - it must never produce a line.
    VERBATIM = %i[system text stats compact spinner_detail].freeze

    INDENT      = "  "
    GUTTER      = "#{INDENT}|"
    STATUS_RULE = "#{INDENT}#{"-" * 12}"
    # Fixed width, NOT the terminal width: a boundary that depends on a
    # terminal setting is a boundary that moves.
    STEP_RULE_WIDTH = 80

    attr_reader :palette

    # palette: a UI::Palette, or nil to render without color (a Task with no
    # harness: specs, a bare console).
    def initialize(palette: nil)
      @palette = palette
    end

    # origin: for a status type, the bracket label ("file.read", "access",
    # "run.command"). Ignored by every other type.
    def line(type:, content:, origin: nil)
      type = type.to_sym
      text = content.to_s

      return status_line(type, text, origin) if STATUS_GLYPHS.key?(type)
      return step_line(text) if type == :step_label

      paint(type, labeled(type, text))
    end

    def labeled?(type)
      type = type.to_sym
      return true if STATUS_GLYPHS.key?(type)

      !VERBATIM.include?(type) && LABELS.key?(type)
    end

    private

    # A multi-line message (a pasted multiline script is the everyday case)
    # renders as several lines with a gutter and a closing rule, so its END is
    # visible instead of blurring into the next entry.
    def status_line(type, message, origin)
      glyph = STATUS_GLYPHS[type]
      head  = "#{INDENT}[#{origin.nil? ? "tool" : origin}]"
      lines = message.split("\n")
      lines = [""] if lines.empty?

      out = lines.each_with_index.map do |line, index|
        tail = +""
        tail << " #{glyph}" if index.zero? && glyph
        tail << " #{line}" unless line.empty?
        segment(:marker, index.zero? ? head : GUTTER) + segment(type, tail)
      end
      out << segment(:rule, STATUS_RULE) if lines.size > 1
      out.join("\n")
    end

    def step_line(number)
      label = "#{LABELS[:step_label]}#{number}"
      # The spare is split in two; an odd one (a wider number) gives its extra
      # dash to the right, so the line is always exactly STEP_RULE_WIDTH wide.
      spare = [STEP_RULE_WIDTH - label.length - 2, 2].max
      left  = spare / 2
      segment(:rule, "#{"-" * left} ") +
        segment(:step_label, label) +
        segment(:rule, " #{"-" * (spare - left)}")
    end

    def labeled(type, content)
      return content if VERBATIM.include?(type)

      label = LABELS[type]
      # An entry whose type is in neither list is a MISSING type: render it,
      # but say so loudly, so a new output kind cannot pass unnoticed (#146).
      return "#{content} [untyped:#{type}]" if label.nil?

      "#{label}#{content}"
    end

    def paint(type, text)
      palette.nil? ? text : palette.paint(type, text)
    end

    # One colored RUN, not the whole line: marker and message are different
    # roles. Palette#paint resets every run, so no run bleeds into the next.
    def segment(role, text)
      return "" if text.empty?
      return text if palette.nil?

      palette.paint(role, text)
    end
  end
end
