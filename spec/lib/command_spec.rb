# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'command'
require 'commands/ctx_command'
require 'commands/yolo_command'
require 'commands/stream_command'
require 'commands/plan_command'
require 'commands/retry_command'
require 'commands/compact_command'
require 'commands/exit_command'

RSpec.describe Command do
  def build(klass = described_class, ui: UI::Console.new(stdout: StringIO.new), **extra)
    klass.new(harness: nil, file_list: nil, options: nil, ui: ui, **extra)
  end

  describe '.help' do
    it 'returns the HELP the command class itself declares' do
      expect(Commands::CtxCommand.help).to equal(Commands::CtxCommand::HELP)
    end

    # A base class carries no help of its own: the registry asks each concrete
    # command, so an undeclared HELP must fail loudly, not return nil.
    it 'raises HarnessError when the class declares no HELP' do
      expect { described_class.help }
        .to raise_error(HarnessError, /declares no HELP/)
    end

    # const_defined?(:HELP, false): a subclass inherits its parent's constant
    # but must NOT inherit its help entry, or a new command would show up in
    # /help under another command's text.
    it 'does not inherit a parent HELP' do
      subclass = Class.new(Commands::CtxCommand)

      expect { subclass.help }.to raise_error(HarnessError, /declares no HELP/)
    end

    it 'names the offending class in the message' do
      subclass = Class.new(described_class)
      stub_const('NoHelpCommand', subclass)

      expect { subclass.help }.to raise_error(HarnessError, /NoHelpCommand/)
    end
  end

  describe '.mid_turn_safe?' do
    # The seam that decides whether a command may run from a mid-turn submit
    # (doc/unified_loop_design.md). Default true (edit mode allows all commands);
    # a command opts out when it cannot run safely while a turn is live.
    it 'defaults to true (a command is mid-turn-safe unless it opts out)' do
      subclass = Class.new(described_class)

      expect(subclass.mid_turn_safe?).to be true
    end

    # The posture toggles are pure Harness state writes, so they stay safe.
    it 'is true for a posture toggle (yolo/stream/plan)' do
      expect(Commands::YoloCommand.mid_turn_safe?).to be true
      expect(Commands::StreamCommand.mid_turn_safe?).to be true
      expect(Commands::PlanCommand.mid_turn_safe?).to be true
    end

    # A command that drives an LLM round would start a nested drain loop, and
    # one that rebuilds/ends the run has no live loop to act in: both opt out.
    it 'is false for commands that drive an LLM round or rebuild the run' do
      expect(Commands::RetryCommand.mid_turn_safe?).to be false
      expect(Commands::CompactCommand.mid_turn_safe?).to be false
      expect(Commands::ExitCommand.mid_turn_safe?).to be false
    end
  end

  describe '#initialize' do
    it 'exposes everything a command needs to run' do
      harness = Object.new
      file_list = Object.new
      options = Object.new
      ui = UI::Console.new(stdout: StringIO.new)
      cmd = build(described_class, ui: ui, harness: harness, file_list: file_list, options: options)

      expect(cmd.harness).to equal(harness)
      expect(cmd.file_list).to equal(file_list)
      expect(cmd.options).to equal(options)
      expect(cmd.ui).to equal(ui)
    end

    it 'defaults the CLI-only collaborator to nil' do
      cmd = build(described_class)

      expect(cmd.help_renderer).to be_nil
    end

    it 'accepts a help_renderer (only /help uses it)' do
      renderer = Object.new
      cmd = build(described_class, help_renderer: renderer)

      expect(cmd.help_renderer).to equal(renderer)
    end
  end

  describe 'TaskRunner inclusion' do
    # Commands that drive an LLM round (/retry, /compact) go through the shared
    # task wrapper; a thin command like /ctx must not have to implement it.
    it 'is included so a command can run a round on a task thread' do
      expect(described_class.include?(TaskRunner)).to be true
    end

    it 'responds to #run_on_task and #emit_line' do
      cmd = build(described_class)

      expect(cmd).to respond_to(:run_on_task, :emit_line)
    end
  end
end
