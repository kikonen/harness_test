# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/markdown_command'

# issue #106: /markdown flips the markdown rendering posture. Like /palette it is
# an OUTPUT posture (no spinner badge), changes USER-side harness state only, and
# is saved with the session.
RSpec.describe Commands::MarkdownCommand do
  # Stand-in for Harness exposing the posture surface the command uses.
  def build_harness(markdown: false)
    Class.new do
      attr_writer :markdown

      def initialize(markdown)
        @markdown = markdown
      end

      def markdown?
        @markdown
      end

      def toggle_markdown
        @markdown = !@markdown
        markdown? ? 'MARKDOWN ON' : 'MARKDOWN OFF'
      end
    end.new(markdown)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(harness = build_harness)
    described_class.new(harness: harness, file_list: nil, options: nil, ui: ui)
  end

  describe 'the help entry (issue #323 contract)' do
    it 'declares a HELP entry whose usage starts with its registered name' do
      help = described_class.help

      expect(help.usage).to start_with('markdown')
      expect(help.summary).not_to be_empty
      expect(CommandHelp::GROUPS).to have_key(help.group)
    end

    it 'is grouped as an output posture (like /palette, not /stream)' do
      expect(described_class.help.group).to eq(:output)
    end
  end

  it 'toggles the posture on a bare /markdown and acks the new state' do
    harness = build_harness
    command(harness).handle('')

    expect(harness.markdown?).to be(true)
    expect(io.string).to include('[markdown: ON]')
  end

  it 'toggles back off with a second /markdown' do
    harness = build_harness(markdown: true)
    command(harness).handle('')

    expect(harness.markdown?).to be(false)
    expect(io.string).to include('[markdown: OFF]')
    expect(io.string).to include('shown verbatim')
  end

  it 'sets the posture explicitly with on and off' do
    harness = build_harness
    command(harness).handle('on')
    expect(harness.markdown?).to be(true)

    command(harness).handle('off')
    expect(harness.markdown?).to be(false)
  end

  it 'reports the current posture with status without changing it' do
    harness = build_harness(markdown: true)
    command(harness).handle('status')

    expect(harness.markdown?).to be(true)
    expect(io.string).to include('[markdown: ON]')
  end

  it 'states the palette seeding and the next-turn effect' do
    command(build_harness(markdown: true)).handle('status')

    expect(io.string).to include('seeded from the output palette')
    expect(io.string).to include('Effective from the next turn')
    expect(io.string).to include('Saved with the session')
  end

  it 'shows usage for an argument that is not a posture keyword' do
    command(build_harness).handle('bogus')

    expect(io.string).to include('usage: /markdown')
  end
end
