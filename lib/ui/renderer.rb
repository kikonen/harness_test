# frozen_string_literal: true

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

    def line(type:, content:)
      type = type.to_sym
      return content.to_s if VERBATIM.include?(type)

      label = LABELS[type]
      # An entry whose type is in neither list is a MISSING type: render it,
      # but say so loudly, so a new output kind cannot pass unnoticed (#146).
      return "#{content} [untyped:#{type}]" if label.nil?

      "#{label}#{content}"
    end

    def labeled?(type)
      type = type.to_sym
      !VERBATIM.include?(type) && LABELS.key?(type)
    end
  end
end
