# frozen_string_literal: true

require 'spec_helper'
require 'ui/renderer'

RSpec.describe UI::Renderer do
  subject(:renderer) { described_class.new }

  describe '#line' do
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

    it 'labels the step with the number the emitter sent' do
      expect(renderer.line(type: :step_label, content: 3)).to eq('step 3')
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
      expect(renderer.line(type: :text, content: '  [file.write] ok')).to eq('  [file.write] ok')
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
      types = described_class::LABELS.keys + described_class::VERBATIM
      lines = types.map { |t| renderer.line(type: t, content: 'body') }

      expect(lines).not_to include(a_string_matching(/>>>/))
      expect(lines).not_to include(a_string_matching(/\|\|\|/))
    end
  end

  describe '#labeled?' do
    it 'is true for a role the renderer patterns' do
      expect(renderer.labeled?(:plan)).to eq(true)
      expect(renderer.labeled?(:response)).to eq(true)
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

    it 'colors the label too, so the label is part of the role presentation' do
      line = painted.line(type: :step_label, content: 3)

      expect(line).to start_with("\e[38;5;240mstep 3")
      expect(line).to end_with("\e[0m")
    end

    it 'leaves a role the palette does not color in the terminal color' do
      expect(painted.line(type: :response, content: 'done')).to eq('model: done')
    end

    it 'colors verbatim roles the palette names (stats and system notes)' do
      expect(painted.line(type: :stats, content: '  [3 iterations]')).to eq(
        "\e[38;5;240m  [3 iterations]\e[0m"
      )
    end

    it 'never bleeds a color past the line it painted' do
      lines = %i[plan error warn step_label].map { |t| painted.line(type: t, content: 'x') }

      expect(lines).to all(end_with("\e[0m"))
      expect(lines.join("\n")).not_to include("\e[0m\e[")
    end
  end
end
