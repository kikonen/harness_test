# frozen_string_literal: true

require 'spec_helper'
require 'ui/markdown_renderer'

# issue #106: an assistant answer is rendered as markdown through kramdown-ansi,
# with its colored roles SEEDED from the active UI::Palette (no second color
# stack) and a 'none' palette stripping the ANSI entirely.
RSpec.describe UI::MarkdownRenderer do
  def md
    "# Report\n\nSome **bold** and `code` and *em*.\n"
  end

  describe 'with the default palette' do
    subject(:renderer) { described_class.new(palette: UI::Palette.fetch('default')) }

    it 'renders markdown to ANSI (emphasis preserved)' do
      out = renderer.render(md)

      expect(out).to include("\e[")
      # bold and italic survive (the whole point of rendering markdown).
      expect(out).to include("\e[1mbold\e[0m")
      expect(out).to include("\e[3mem\e[0m")
    end

    it 'seeds the header hue from the palette WITHOUT dropping its structure' do
      out = renderer.render(md)

      # The default palette's step_label is cyan ("36"); the header borrows the
      # HUE but keeps the gem's own bold + underline (seeding replaces the
      # default style list, so the hue is appended, not swapped in).
      expect(out).to include("\e[1m\e[4m\e[36mReport\e[0m")
    end

    it 'seeds the inline-code hue from the palette (blue)' do
      out = renderer.render(md)

      # The default palette's plan role is blue ("34"); code borrows it.
      expect(out).to include("\e[34mcode\e[0m")
    end

    it 'renders a table with box-drawing borders' do
      out = renderer.render("| a | b |\n| - | - |\n| 1 | 2 |\n")

      expect(out).to include('┌').or(include('╭'))
      expect(out).to include('│')
    end
  end

  # The gem sizes tables from Tins::Terminal.columns (90% of it); on a wide
  # terminal that is wider than the harness' fixed chrome, so the render caps
  # the width the gem sees. The cap must restore the real width afterwards.
  describe 'width cap' do
    def widest(line)
      line.lines.map { |l| l.gsub(/\e\[[0-9;]*m/, "").rstrip.length }.max
    end

    let(:table) do
      "| alpha beta gamma delta epsilon | zeta eta theta iota kappa | lambda mu nu xi omicron |\n" \
        "| --- | --- | --- |\n" \
        "| one two three four five six | seven eight nine ten | eleven twelve thirteen |\n"
    end

    it 'caps a wide table to the given width' do
      renderer = described_class.new(palette: UI::Palette.fetch('default'), width: 80)

      expect(widest(renderer.render(table))).to be <= 80
    end

    it 'restores the detected width after the render (the cap is not global)' do
      allow(Tins::Terminal).to receive(:columns).and_return(176)
      renderer = described_class.new(palette: UI::Palette.fetch('default'), width: 80)
      renderer.render(table)

      uncapped = described_class.new(palette: UI::Palette.fetch('default'))
      expect(widest(uncapped.render(table))).to be > 80
    end
  end

  describe 'with the none palette (--no-color)' do
    subject(:renderer) { described_class.new(palette: UI::Palette.fetch('none')) }

    it 'emits NO ANSI at all' do
      out = renderer.render(md)

      expect(out).not_to include("\e[")
    end

    it 'keeps the markdown structure as plain text' do
      out = renderer.render(md)

      expect(out).to include('Report')
      expect(out).to include('bold')
    end
  end

  describe 'with no palette (a bare console)' do
    subject(:renderer) { described_class.new(palette: nil) }

    it 'returns the text unchanged (no color to seed, no render)' do
      expect(renderer.render(md)).to eq(md)
    end
  end

  it 'never aborts on a parse failure - returns the raw text' do
    renderer = described_class.new(palette: UI::Palette.fetch('default'))
    allow(Kramdown::ANSI).to receive(:parse).and_raise(StandardError, 'boom')

    expect(renderer.render(md)).to eq(md)
  end

  it 'renders an empty answer as empty' do
    renderer = described_class.new(palette: UI::Palette.fetch('default'))

    expect(renderer.render('')).to eq('')
  end
end
