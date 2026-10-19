# frozen_string_literal: true

require 'spec_helper'
require 'command'
require 'help_renderer'

RSpec.describe HelpRenderer do
  # A tiny registry stands in for CommandHandler::COMMANDS: the renderer works
  # off ANY registry, which is what makes the drift spec meaningful.
  def stub_command(usage:, summary:, group: :general, forms: [], see_also: [])
    Class.new do
      define_singleton_method(:help) do
        CommandHelp.new(usage:, summary:, group:, forms:, see_also:)
      end
    end
  end

  let(:registry) do
    {
      'demo' => stub_command(
        usage: 'demo [thing]',
        summary: 'A demo command whose summary is long enough to be wrapped ' \
          'into more than one rendered line by the table',
        group: :general,
        forms: ['demo', 'demo <thing>'],
        see_also: %w[other s topic]
      ),
      'other' => stub_command(usage: 'other', summary: 'Other command', group: :access),
      's' => stub_command(usage: 's', summary: 'Short one', group: :access, see_also: [])
    }
  end

  let(:topics) do
    {
      'topic' => HelpTopics::Topic.new(
        name: 'topic',
        title: 'The Topic',
        paragraphs: [
          'A short body.',
          'A body long enough that the renderer has to wrap it, because the ' \
            'data holds wording and the renderer owns the line shape here.'
        ],
        see_also: %w[demo other]
      )
    }
  end

  subject(:renderer) { described_class.new(registry:, topics:) }

  describe '#overview' do
    it 'groups the command table under the GROUPS headings' do
      lines = renderer.overview

      expect(lines).to include('Commands:')
      expect(lines).to include('  Access and consent', '  General')
      # Groups print in GROUPS order, not registry order.
      expect(lines.index('  Access and consent')).to be < lines.index('  General')
    end

    it 'lists every registered command with its usage form' do
      rendered = renderer.overview.join("\n")

      expect(registry.keys).to all(satisfy { |name| rendered.match?(%r{^\s+/#{name}\b}) })
    end

    it 'wraps a long summary under its own column, not under the usage form' do
      lines      = renderer.overview
      row        = lines.find { |line| line.include?('/demo [thing]') }
      continuation = lines[lines.index(row) + 1]
      column   = row.index('A demo')

      expect(row).to match(/\A\s+\/demo \[thing\]\s+A demo/)
      # The continuation lines up with the summary column, not with the usage form.
      expect(continuation).to start_with(' ' * column)
      expect(continuation).not_to include('/')
    end

    it 'aligns every summary to the SAME column across groups' do
      lines = renderer.overview
      starts = ['Other command', 'Short one', 'A demo command'].map do |summary|
        lines.find { |line| line.include?(summary) }.index(summary)
      end

      expect(starts.uniq).to eq([starts.first])
    end

    it 'finishes with the topic index instead of the prose' do
      lines = renderer.overview

      expect(lines).to include('Topics (read one with /help <topic>):')
      expect(lines).to include('  topic  The Topic')
      expect(lines.join("\n")).not_to include('A short body.')
    end

    it 'skips a group no command belongs to' do
      expect(renderer.overview).not_to include('  Model and parameters')
    end
  end

  describe '#command_page' do
    it 'leads with the usage and summary, then every declared form' do
      lines = renderer.command_page('demo')

      expect(lines.first).to start_with('/demo [thing] - A demo command')
      expect(lines).to include('    /demo', '    /demo <thing>')
    end

    it 'names the group and resolves see-also against commands and topics' do
      lines = renderer.command_page('demo').join("\n")

      expect(lines).to include('group: General')
      expect(lines).to include('see also: /other, /s, /help topic')
    end

    it 'a command with no see_also gets no empty refs line' do
      expect(renderer.command_page('other').join("\n")).not_to include('see also:')
    end
  end

  describe '#topic_page' do
    it 'prints the title, the body wrapped, and the see-also commands' do
      lines = renderer.topic_page('topic')

      expect(lines.first).to eq('The Topic')
      expect(lines).to include('  (/help topic)')
      expect(lines.join("\n")).to include('A short body.')
      expect(lines).to include('  see also: /demo, /other')
    end

    it 'every body line carries the topic indent' do
      body = renderer.topic_page('topic').grep(/\S/).drop(2)

      expect(body).to all(start_with('  '))
    end

    it 'wraps to the renderer width' do
      narrow = described_class.new(registry:, topics:, width: 40)

      expect(narrow.topic_page('topic').map(&:length)).to all(be <= 40)
    end
  end

  describe '#unknown_page' do
    it 'suggests the closest command for a mistyped one' do
      out = renderer.unknown_page('demo1').join("\n")

      expect(out).to include('Unknown help: /demo1')
      expect(out).to include('Did you mean /demo?')
    end

    it 'suggests a topic for a mistyped topic name' do
      out = renderer.unknown_page('topci').join("\n")

      expect(out).to include('Or a topic: /help topic?')
    end

    it 'falls back to pointing at /help when nothing is close' do
      out = renderer.unknown_page('zzzzzz').join("\n")

      expect(out).not_to include('Did you mean')
      expect(out).to include('/help on its own lists every command and topic.')
    end
  end

  describe '#command_suggestions' do
    it 'suggests from the registry only (a topic name is not a command)' do
      expect(renderer.command_suggestions('othe')).to eq(['other'])
      expect(renderer.command_suggestions('topic')).to eq([])
    end
  end

  describe 'registry-driven invariants' do
    it 'asks every registered class for its help - a class with none raises' do
      broken = described_class.new(registry: { 'broken' => Class.new(Command) }, topics: {})

      expect { broken.overview }.to raise_error(HarnessError, /declares no HELP/)
    end

    it 'refuses a help entry whose usage is not the registered name' do
      mismatched = stub_command(usage: 'deimo [thing]', summary: 'Wrong slot', group: :general)
      renderer = described_class.new(registry: { 'demo' => mismatched }, topics: {})

      expect { renderer.overview }.to raise_error(HarnessError, /is not \/demo/)
    end
  end
end
