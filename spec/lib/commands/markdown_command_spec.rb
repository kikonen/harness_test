# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'commands/markdown_command'
require 'system_settings'

# issue #106: /markdown flips the markdown rendering posture. Like /palette it is
# an OUTPUT posture (no spinner badge), changes USER-side harness state only, and
# is saved with the session.
RSpec.describe Commands::MarkdownCommand do
  # The command talks to SystemSettings directly (#286): use the real one.
  def build_settings(markdown: false)
    SystemSettings.new(markdown: markdown)
  end

  let(:io) { StringIO.new }
  let(:ui) { UI::Console.new(stdout: io) }

  def command(settings = build_settings)
    described_class.new(settings: settings, file_list: nil, ui: ui)
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
    settings = build_settings
    command(settings).handle('')

    expect(settings.markdown?).to be(true)
    expect(io.string).to include('[markdown: ON]')
  end

  it 'toggles back off with a second /markdown' do
    settings = build_settings(markdown: true)
    command(settings).handle('')

    expect(settings.markdown?).to be(false)
    expect(io.string).to include('[markdown: OFF]')
    expect(io.string).to include('shown verbatim')
  end

  it 'sets the posture explicitly with on and off' do
    settings = build_settings
    command(settings).handle('on')
    expect(settings.markdown?).to be(true)

    command(settings).handle('off')
    expect(settings.markdown?).to be(false)
  end

  it 'reports the current posture with status without changing it' do
    settings = build_settings(markdown: true)
    command(settings).handle('status')

    expect(settings.markdown?).to be(true)
    expect(io.string).to include('[markdown: ON]')
  end

  it 'states the palette seeding and the next-turn effect' do
    command(build_settings(markdown: true)).handle('status')

    expect(io.string).to include('seeded from the output palette')
    expect(io.string).to include('Effective from the next turn')
    expect(io.string).to include('Saved with the session')
  end

  it 'shows usage for an argument that is not a posture keyword' do
    command(build_settings).handle('bogus')

    expect(io.string).to include('usage: /markdown')
  end
end
