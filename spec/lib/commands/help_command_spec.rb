# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'command_handler'
require 'commands/help_command'

# issue #323: /help is GENERATED from the dispatch registry. These examples are
# the drift contract: the registry, the per-command HELP entries and README's
# table must cover the same set, or a command exists that no help page mentions.
RSpec.describe Commands::HelpCommand do
  let(:registry) { CommandHandler::COMMANDS }

  def run(args, reg = registry)
    io      = StringIO.new
    console = UI::Console.new(stdout: io, stdin: StringIO.new(''))
    renderer = HelpRenderer.new(registry: reg)
    described_class.new(
      harness: nil,
      file_list: nil,
      options: nil,
      ui: console,
      help_renderer: renderer
    ).handle(args)
    io.string
  end

  describe 'the registry contract' do
    it 'every registered command declares a help entry' do
      missing = registry.reject { |_name, klass| klass.respond_to?(:help) && klass.help }

      expect(missing.keys).to be_empty
    end

    it 'every help entry carries a usage, a summary and a known group' do
      registry.each_value do |klass|
        help = klass.help

        expect(help.usage).not_to be_empty
        expect(help.summary).not_to be_empty
        expect(CommandHelp::GROUPS).to have_key(help.group)
      end
    end

    it 'no command is filed under a group with no commands at all' do
      groups = registry.values.map { |klass| klass.help.group }.uniq

      expect(CommandHelp::GROUPS.keys - groups).to be_empty
    end

    it 'a command needs help: the base class refuses one that declares none' do
      bare = Class.new(Command)

      expect { bare.help }.to raise_error(HarnessError, /declares no HELP/)
    end

    it 'no topic name collides with a command name, and every topic has a body' do
      expect { HelpTopics.validate!(registry.keys) }.not_to raise_error
    end
  end

  describe 'bare /help' do
    it 'lists EVERY registered command (nothing is hand-copied any more)' do
      out = run('')

      expect(registry.keys).to all(satisfy { |name| out.match?(%r{^\s+/#{name}\b}) })
    end

    it 'does not print the prose any more - only the topic index' do
      out = run('')

      expect(out).to include('Topics (read one with /help <topic>):')
      expect(out).not_to include('paste-guarded')
      expect(out).not_to include('Always allow')
      # The dump it replaces was 169 lines (measured from the old heredoc).
      expect(out.lines.size).to be < 100
    end

    it 'labels each group the help entry files the command under' do
      out = run('')

      expect(CommandHelp::GROUPS.values).to all(satisfy { |heading| out.include?(heading) })
    end
  end

  describe '/help <command>' do
    it 'shows one command with all its accepted forms' do
      out = run('param')

      expect(out).to include('/param [key [value]]')
      expect(out).to include('    /param')
      expect(out).to include('    /param <key> default')
      expect(out).not_to include('/yolo')
    end

    it 'knows itself too (/help help)' do
      out = run('help')

      expect(out).to include('/help [command|topic]')
      expect(out).to include('    /help <topic>')
    end
  end

  describe '/help <topic>' do
    it 'prints one topic body instead of the whole dump' do
      out = run('keys')

      expect(out).to include('Keys')
      expect(out).to include('Ctrl+A')
      expect(out).not_to include('Mid-turn steering notes')
    end

    it 'names the topic page the same way from any case' do
      expect(run('KEYS')).to eq(run('keys'))
    end

    it 'a command name wins over a topic name (there is no ambiguity to resolve)' do
      expect(run('session')).to include('/session')
    end
  end

  describe '/help <unknown>' do
    it 'suggests the closest command or topic instead of repeating the usage line' do
      out = run('session2')

      expect(out).to include('Unknown help: /session2')
      expect(out).to include('Did you mean')
    end
  end

  describe 'README table vs the registry (the third copy)' do
    it 'README documents every registered command' do
      documented = readme_command_names

      expect(registry.keys - documented).to eq([])
    end

    it 'README does not document a command the dispatcher does not accept' do
      documented = readme_command_names

      expect(documented - registry.keys).to eq([])
    end
  end

  def readme_command_names
    readme = File.read(File.expand_path('../../../README.md', __dir__))
    readme.scan(/^\| `(\/[a-z-]+)\b/).flatten.map { |cell| cell.delete('/') }
  end
end
