# frozen_string_literal: true

require "kramdown/ansi"
require "tins/terminal"

require_relative "palette"

# Renders a markdown string (an assistant answer) to ANSI terminal output
# (issue #106) through kramdown-ansi, which PRESERVES inline emphasis
# (bold/italic/inline code) - the whole point of rendering markdown.
#
# COLOR OWNERSHIP: kramdown-ansi colors spans through its own term-ansicolor
# tokens, which would be a second color stack next to UI::Palette. To keep the
# harness' "color lives in the renderer" invariant, the gem's colored roles are
# SEEDED from the active palette's hues (SGR_TO_TOKEN + HUE_SOURCE), so markdown
# colors match the harness' own role colors instead of inventing their own. A
# 'none' palette (or no palette) strips the ANSI entirely, so --no-color stays
# byte-clean.
#
# The renderer is OPT-IN and used for MODEL PROSE only (the :response answer and
# the plan / say lines); tool output (code, logs, diffs) is never rendered - it
# must stay byte-exact.
module UI
  class MarkdownRenderer
    # SGR code -> named term-ansicolor token, for the codes the harness palettes
    # actually use. An unmapped code (an extended 256-color hue) yields no token,
    # so that role keeps the gem's structural default rather than a wrong color.
    SGR_TO_TOKEN = {
      "30" => :black,
      "31" => :red,
      "32" => :green,
      "33" => :yellow,
      "34" => :blue,
      "35" => :magenta,
      "36" => :cyan,
      "90" => :light_black
    }.freeze

    # markdown role -> the harness palette role whose hue it borrows. Structural
    # attributes (bold/underline/italic) stay the gem's defaults; only HUES are
    # seeded, so markdown reads as the same color family as the harness' lines.
    HUE_SOURCE = {
      header: :step_label, # cyan (step_label)
      code: :plan          # blue (plan)
    }.freeze

    # The default table-width basis when no explicit max_width is configured:
    # 80% of the detected terminal columns. The gem then sizes a table at 90% of
    # the basis it is fed, so a table lands a little under the terminal width
    # instead of the old fixed 80 (which wasted the width of a wide terminal).
    AUTO_WIDTH_PERCENT = 80

    # max_width: the column basis for the render (nil = AUTO_WIDTH_PERCENT of the
    # detected terminal). An explicit value is clamped to the terminal width.
    def initialize(palette: nil, max_width: nil)
      @palette   = palette
      @max_width = max_width
    end

    # The markdown -> ANSI render. A parse failure never aborts an answer: the
    # raw text is returned unchanged (a model answer must not crash rendering).
    def render(text)
      text = text.to_s
      return text if @palette.nil?

      styled = with_capped_width { Kramdown::ANSI.parse(text, ansi_styles:) }
      strip? ? Kramdown::ANSI::Width.remove_ansi_escapes(styled) : styled
    rescue StandardError
      text
    end

    private

    # The 'none' palette has no colors at all: emit no ANSI (the gem would still
    # apply its own defaults, so the escape codes are stripped after parsing).
    def strip?
      @palette.respond_to?(:name) && @palette.name == Palette::NONE_NAME
    end

    # kramdown-ansi sizes tables and wraps paragraphs from Tins::Terminal.columns
    # (90% of it). We feed it a BASIS: an explicit max_width (clamped to the
    # terminal) or, by default, 80% of the detected columns. The override wraps
    # only OUR parse and the ensure restores the original method even when the
    # parse raises, so no other Tins::Terminal caller sees it.
    def with_capped_width
      detected = Tins::Terminal.method(:columns)
      columns  = detected.call
      cap      =
        if @max_width
          [columns, @max_width].min
        else
          (columns * AUTO_WIDTH_PERCENT / 100.0).floor
        end
      Tins::Terminal.define_singleton_method(:columns) { cap }
      yield
    ensure
      Tins::Terminal.define_singleton_method(:columns, detected) if detected
    end

    # A seeded role REPLACES the gem's default style list, so the hue is APPENDED
    # to that role's own default (header keeps bold+underline, code keeps its
    # color slot) - seeding a bare token would erase the structure the render is
    # for. An unmapped palette hue yields no seed at all: the gem default stands.
    def ansi_styles
      defaults = Kramdown::ANSI::Styles.new.default_ansi_styles
      styles   = {}
      HUE_SOURCE.each do |md_role, palette_role|
        token = token_for(palette_role)
        next unless token

        styles[md_role] = (Array(defaults[md_role]) + [token]).uniq
      end
      styles
    end

    def token_for(palette_role)
      SGR_TO_TOKEN[@palette.color_for(palette_role)]
    end
  end
end
