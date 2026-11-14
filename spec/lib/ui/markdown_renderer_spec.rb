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

  # issue #475: an answer that quotes a tool call / XML / HTML (text kramdown
  # reads as a raw <element>) used to be DROPPED on the console because
  # kramdown-ansi has no ANSI converter for an unknown html_element. Escaping
  # '<' outside code (never '>') makes the text survive while real markdown
  # - autolinks, blockquotes, code - keeps its meaning.
  describe 'angle-bracket content is NOT dropped (issue #475)' do
    subject(:renderer) { described_class.new(palette: UI::Palette.fetch('default')) }

    it 'keeps a tool-call block whole' do
      out = renderer.render("a\n\n<tool_call>\nclose\n<function=read_file>x</function>\n</tool_call>\nb\n")

      expect(out).to include('<tool_call>')
      expect(out).to include('<function=read_file>x</function>')
      expect(out).to include('close')
      expect(out).to include('a')
      expect(out).to include('b')
    end

    it 'keeps an inline tag AND the text that follows it' do
      out = renderer.render('a <tool_call> x b')

      expect(out).to include('<tool_call>') # the tag itself survives
      expect(out).to include('x b') # and so does the text kramdown used to swallow
    end

    it 'keeps real markdown: autolink, blockquote and inline code with brackets' do
      out = renderer.render("> quote\n\nlink <https://example.com> here\n\n`inline <b>` code\n")

      expect(out).to include('quote')          # blockquote survives ('>' untouched)
      expect(out).to include(']8;;https://example.com') # autolink is still a link
      expect(out).to include('<b>')            # code text is literal, not escaped
      expect(out).to include('here')
    end

    it 'leaves fenced code literal (not escaped)' do
      out = renderer.render("```\n<tool_call>\n<function>x</function>\n```\n")

      expect(out).to include('<tool_call>')
      expect(out).to include('<function>x</function>')
    end
  end

  describe 'angle-bracket content under the none palette (issue #475)' do
    subject(:renderer) { described_class.new(palette: UI::Palette.fetch('none')) }

    it 'keeps a tool-call block and emits no ANSI' do
      out = renderer.render("a\n\n<tool_call>\nclose\n</tool_call>\nb\n")

      expect(out).not_to include("\e[")
      expect(out).to include('<tool_call>')
      expect(out).to include('close')
    end
  end

  # The gem sizes tables from Tins::Terminal.columns (90% of it). We feed it a
  # BASIS from UI::Width: an explicit CHAR count (clamped to the terminal and
  # honored as asked), a PERCENTAGE (taken of the terminal and capped at the
  # reading maximum), or neither (the default percentage, capped). The override
  # must restore the real width afterwards.
  describe 'table width basis' do
    def widest(line)
      line.lines.map { |l| l.gsub(/\e\[[0-9;]*m/, "").rstrip.length }.max
    end

    # Cells long enough that a basis of 80 forces wrapping but a wider basis does
    # not, so the basis is observable in the rendered width.
    let(:table) do
      "| alpha beta gamma delta epsilon zeta eta | theta iota kappa lambda mu nu xi omicron | " \
        "pi rho sigma tau upsilon phi chi |\n| --- | --- | --- |\n" \
        "| one two three four five six seven eight | nine ten eleven twelve thirteen fourteen | " \
        "fifteen sixteen seventeen eighteen |\n"
    end

    before { allow(Tins::Terminal).to receive(:columns).and_return(176) }

    it 'sizes a table to an explicit max_width (and stays within it)' do
      renderer = described_class.new(palette: UI::Palette.fetch('default'), max_width: 120)
      width = widest(renderer.render(table))

      expect(width).to be <= 120
      expect(width).to be > 80 # the extra width is actually used
    end

    # Measured: 80% of 176 would be 140, but a resolved percentage is capped at
    # the reading maximum (UI::Width::MAX_PARAGRAPH_WIDTH = 120), so a wide
    # terminal gets a readable line instead of a 170-column one.
    it 'caps the default percentage at the reading maximum' do
      renderer = described_class.new(palette: UI::Palette.fetch('default'))

      expect(renderer.width).to eq(120)
      expect(widest(renderer.render(table))).to eq(103)
    end

    # A PERCENTAGE is the form that travels to a sink with no column count of its
    # own (a browser, variable-width font), so the renderer keeps it as data.
    it 'keeps a percentage basis as data and resolves it against the terminal' do
      renderer = described_class.new(palette: UI::Palette.fetch('default'), max_width: '85%')

      expect(renderer.max_width).to eq('85%')
      expect(renderer.width).to eq(120) # capped, not 149
    end

    # An explicit CHAR count is exactly what the caller asked for: it is honored
    # past the cap, only clamped to the terminal.
    it 'honors an explicit count past the cap (only clamped to the terminal)' do
      renderer = described_class.new(palette: UI::Palette.fetch('default'), max_width: 140)

      expect(renderer.width).to eq(140)
      expect(widest(renderer.render(table))).to eq(123)
    end

    it 'clamps an explicit max_width to the terminal width' do
      renderer = described_class.new(palette: UI::Palette.fetch('default'), max_width: 200)

      expect(widest(renderer.render(table))).to be <= 176
    end

    it 'restores the detected width after the render (the basis is not global)' do
      pinned = UI::MarkdownRenderer.new(palette: UI::Palette.fetch('default'), max_width: 100)
      widest(pinned.render(table))

      # The next renderer sees the terminal-derived basis again, not 100.
      expect(widest(described_class.new(palette: UI::Palette.fetch('default')).render(table)))
        .to be > 87
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
