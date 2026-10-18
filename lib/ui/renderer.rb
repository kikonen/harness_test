# frozen_string_literal: true

require_relative "palette"

# Renders one output entry to a console line. The PATTERN (the label, and from
# issue #303 on the color) belongs to the renderer, not to the emitter: a
# sender states one role's content and this class decides how the user sees it.
# Design and the type list: doc/output_rendering_design.md.
module UI
  class Renderer
    # type -> label. Labels replace the markers emitters used to bake into the
    # content string (">>> ... <<<", "||| ... |||", the "=" * 80 / "-" * 80
    # rules), so those markers no longer exist anywhere in the buffer.
    LABELS = {
      step_label: "step ",
      plan: "plan:  ",
      interstitial: "say:   ",
      tool_plan: "tools: ",
      response: "model: ",
      warn: "warn:  ",
      error: "error: "
    }.freeze

    # Content is printed as the emitter wrote it. Tool and command lines still
    # own their own shape ("  [file.write] ok"), and :spinner_detail never
    # produces a line at all (the drain loop animates it). Bringing the rest of
    # those prefixes here is the continuation of issue #146.
    VERBATIM = %i[system text stats compact spinner_detail].freeze

    attr_reader :palette

    # palette: a UI::Palette, or nil to render without color (a Task with no
    # harness: specs, a bare console).
    def initialize(palette: nil)
      @palette = palette
    end

    def line(type:, content:)
      type = type.to_sym
      paint(type, labeled(type, content.to_s))
    end

    def labeled?(type)
      type = type.to_sym
      !VERBATIM.include?(type) && LABELS.key?(type)
    end

    private

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
  end
end
