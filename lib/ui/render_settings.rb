# frozen_string_literal: true

require_relative "palette"

# The run's display settings: the one place palette, markdown posture and the
# markdown table-width basis live. The CLI owns one instance and injects it; the
# harness delegates. Rationale: doc/unified_loop_design.md (Step A).
class UI::RenderSettings
  attr_reader :palette

  # Static per run (NOT a live toggle like the palette or markdown posture).
  attr_reader :markdown_max_width

  def initialize(palette: nil, markdown: false, markdown_max_width: nil)
    self.palette = palette
    @markdown = (markdown == true)
    @markdown_max_width = markdown_max_width
  end

  # The single name-check every route hits (CLI flag, config, /palette, resume):
  # UI::Palette.fetch resolves a name and raises on an unknown one.
  def palette=(name)
    @palette = name.is_a?(UI::Palette) ? name : UI::Palette.fetch(name)
  end

  def markdown
    @markdown
  end

  def markdown?
    @markdown
  end

  def markdown=(val)
    @markdown = (val == true)
  end
end
