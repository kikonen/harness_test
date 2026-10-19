# frozen_string_literal: true

require 'spec_helper'
require 'ui/renderer'

RSpec.describe UI::Renderer do
  subject(:renderer) { described_class.new }

  describe '#line (labeled roles)' do
    it 'labels a role with its pattern' do
      expect(renderer.line(type: :plan, content: 'read the tool first')).to eq(
        'plan:  read the tool first'
      )
      expect(renderer.line(type: :interstitial, content: 'checking one more site')).to eq(
        'say:   checking one more site'
      )
      expect(renderer.line(type: :tool_plan, content: 'file.read, file.search')).to eq(
        'tools: file.read, file.search'
      )
    end

    it 'labels the model answer and the two alert roles' do
      expect(renderer.line(type: :response, content: 'done')).to eq('model: done')
      expect(renderer.line(type: :error, content: 'auto-save failed')).to eq(
        'error: auto-save failed'
      )
      expect(renderer.line(type: :warn, content: 'compact skipped')).to eq(
        'warn:  compact skipped'
      )
    end

    it 'renders verbatim types exactly as the emitter wrote them' do
      expect(renderer.line(type: :text, content: 'plain command output')).to eq('plain command output')
      expect(renderer.line(type: :stats, content: '  [3 iterations]')).to eq('  [3 iterations]')
      expect(renderer.line(type: :compact, content: '  [compacting...]')).to eq('  [compacting...]')
      expect(renderer.line(type: :system, content: '  [rules reloaded]')).to eq('  [rules reloaded]')
    end

    it 'announces an unknown type loudly instead of hiding it (issue #146)' do
      expect(renderer.line(type: :brand_new_kind, content: 'text')).to eq('text [untyped:brand_new_kind]')
    end

    it 'accepts a string type (the outbox carries symbols, the buffer is public)' do
      expect(renderer.line(type: 'plan', content: 'x')).to eq('plan:  x')
    end

    it 'never carries the old markers (issue #146)' do
      types = described_class::LABELS.keys + described_class::VERBATIM + described_class::STATUS_TYPES
      lines = types.map { |t| renderer.line(type: t, content: 'body', origin: 'tool') }

      expect(lines).not_to include(a_string_matching(/>>>/))
      expect(lines).not_to include(a_string_matching(/\|\|\|/))
    end
  end

  describe '#line (:step_label) - the iteration boundary' do
    it 'fuses short rules with the number so the step start is visible at a glance' do
      expect(renderer.line(type: :step_label, content: 8)).to eq("#{'-' * 36} step 8 #{'-' * 36}")
    end

    it 'is exactly STEP_RULE_WIDTH wide whatever the number is' do
      widths = [1, 9, 10, 99, 100].map do |n|
        renderer.line(type: :step_label, content: n).length
      end

      expect(widths).to all(eq(described_class::STEP_RULE_WIDTH))
    end

    it 'gives the odd spare dash to the right side (a wider number)' do
      expect(renderer.line(type: :step_label, content: 12)).to eq(
        "#{'-' * 35} step 12 #{'-' * 36}"
      )
    end
  end

  describe '#line (status types) - bracket, glyph and gutter' do
    it 'builds the bracket from the ORIGIN and the glyph from the TYPE' do
      expect(renderer.line(type: :status_ok, origin: 'file.read', content: 'lib/foo.rb')).to eq(
        '  [file.read] ✓ lib/foo.rb'
      )
    end

    it 'colors nothing without a palette but still shapes every verdict' do
      rendered = described_class::STATUS_GLYPHS.map do |type, _glyph|
        renderer.line(type: type, origin: 'file.write', content: 'x')
      end

      expect(rendered).to eq(
        ['  [file.write] ✓ x',
         '  [file.write] ✗ x',
         '  [file.write] ⚠ x',
         '  [file.write] ! x',
         '  [file.write] = x',
         '  [file.write] x']
      )
    end

    it 'renders a verdict with no message as a bare bracket' do
      expect(renderer.line(type: :status_fail, origin: 'access', content: '')).to eq('  [access] ✗')
    end

    it 'a multi-line message gets a gutter on every continuation line' do
      out = renderer.line(type: :status_ok, origin: 'run.command',
                          content: "cd app && ruby -e '\nputs 1\n'\n")

      expect(out.lines.map(&:chomp)).to eq(
        ["  [run.command] ✓ cd app && ruby -e '",
         '  | puts 1',
         "  | '",
         '  ' + ('-' * 12)]
      )
    end

    it 'closes a multi-line entry with a short rule so its end is visible' do
      out = renderer.line(type: :status_info, origin: 'git.diff', content: "a\nb").lines.last.chomp

      expect(out).to eq('  ' + ('-' * 12))
    end

    it 'a single-line entry gets NO gutter and NO rule' do
      out = renderer.line(type: :status_ok, origin: 'file.read', content: 'a').lines

      expect(out.size).to eq(1)
      expect(out.first).not_to include('|')
      expect(out.first).not_to include('--')
    end
  end

  describe '#labeled?' do
    it 'is true for a role the renderer patterns' do
      expect(renderer.labeled?(:plan)).to eq(true)
      expect(renderer.labeled?(:response)).to eq(true)
    end

    it 'is true for the status types (the renderer owns their bracket)' do
      expect(described_class::STATUS_TYPES).to all(satisfy { |t| renderer.labeled?(t) })
    end

    it 'is false for verbatim types and for the spinner' do
      expect(renderer.labeled?(:text)).to eq(false)
      expect(renderer.labeled?(:spinner_detail)).to eq(false)
    end

    it 'is false for an unknown type (there is no pattern to check)' do
      expect(renderer.labeled?(:nope)).to eq(false)
    end
  end

  describe 'with a palette (issue #303)' do
    subject(:painted) do
      described_class.new(palette: UI::Palette.fetch('default'))
    end

    it 'labels and colors the same line' do
      expect(painted.line(type: :plan, content: 'read the tool')).to eq(
        "\e[34mplan:  read the tool\e[0m"
      )
    end

    it 'leaves a role the palette does not color in the terminal color' do
      expect(painted.line(type: :response, content: 'done')).to eq('model: done')
    end

    it 'colors verbatim roles the palette names (stats and system notes)' do
      expect(painted.line(type: :stats, content: '  [3 iterations]')).to eq(
        "\e[38;5;240m  [3 iterations]\e[0m"
      )
    end

    it 'paints the step number in its own hue with gray rules around it' do
      expect(painted.line(type: :step_label, content: 3)).to eq(
        "\e[38;5;240m#{'-' * 36} \e[0m\e[36mstep 3\e[0m\e[38;5;240m #{'-' * 36}\e[0m"
      )
    end

    it 'paints the bracket gray and the message in the verdict color' do
      expect(painted.line(type: :status_fail, origin: 'file.read', content: 'not found')).to eq(
        "\e[38;5;240m  [file.read]\e[0m\e[31m ✗ not found\e[0m"
      )
    end

    it 'gutter and rule are recessive (gray), the message carries the hue' do
      out = painted.line(type: :status_ok, origin: 'run.command', content: "a\nb")

      expect(out).to eq(
        [
          "\e[38;5;240m  [run.command]\e[0m\e[32m ✓ a\e[0m",
          "\e[38;5;240m  |\e[0m\e[32m b\e[0m",
          "\e[38;5;240m  #{'-' * 12}\e[0m"
        ].join("\n")
      )
    end

    it 'leaves a status_info message in the terminal color with a gray bracket' do
      expect(painted.line(type: :status_info, origin: 'tools.list', content: '12 tool(s)')).to eq(
        "\e[38;5;240m  [tools.list]\e[0m 12 tool(s)"
      )
    end

    it 'never bleeds a color past the line it painted' do
      lines = %i[plan error warn step_label status_ok status_fail].map do |t|
        painted.line(type: t, content: 'x', origin: 'tool')
      end

      expect(lines).to all(end_with("\e[0m"))
      expect(lines.join("\n")).not_to include("\e[0m\e[0m")
    end
  end
end
