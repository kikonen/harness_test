# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'command'
require 'job_registry'
require 'commands/ctx_command'
require 'commands/yolo_command'
require 'commands/stream_command'
require 'commands/plan_command'
require 'commands/retry_command'
require 'commands/compact_command'
require 'commands/exit_command'

RSpec.describe Command do
  def build(klass = described_class, ui: UI::Console.new(stdout: StringIO.new), **extra)
    klass.new(file_list: nil, ui: ui, **extra)
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
      expect(Commands::ExitCommand.mid_turn_safe?).to be false
    end

    # /compact no longer opts out: mid-turn it sends a RequestEvent to the live
    # turn instead of starting a nested round (#286 increment 4).
    it 'is true for /compact (it reaches the live turn as a request event)' do
      expect(Commands::CompactCommand.mid_turn_safe?).to be true
    end
  end

  describe '#initialize' do
    it 'exposes everything a command needs to run' do
      file_list = Object.new
      ui = UI::Console.new(stdout: StringIO.new)
      cmd = build(described_class, ui: ui, file_list: file_list)

      expect(cmd.file_list).to equal(file_list)
      expect(cmd.ui).to equal(ui)
    end

    # #286: a command never stores a harness - it reaches the one living on the
    # registry's foreground job. A built-in registry exposes it; none gives nil.
    it 'reaches the Harness through the foreground job, never a stored reference' do
      harness = Object.new
      registry = JobRegistry.new
      registry.add_job(kind: :main, harness:)
      cmd = build(described_class, registry: registry)

      expect(cmd.foreground_harness).to equal(harness)
    end

    # The registry is always present (the dispatcher built it), but a fresh one
    # has NO foreground job yet - that is the only legitimate nil this reaches.
    it 'is nil for a registry with no foreground job yet' do
      expect(build(described_class, registry: JobRegistry.new).foreground_harness).to be_nil
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

  describe 'Reporting inclusion and #submit_turn' do
    # Commands that drive an LLM round (/retry, /compact) share the console
    # reporting mixin; a thin command like /ctx inherits it without using it.
    it 'is included so a command can report a round on a task thread' do
      expect(described_class.include?(Reporting)).to be true
    end

    it 'responds to #submit_turn and #emit_line' do
      cmd = build(described_class)

      expect(cmd).to respond_to(:submit_turn, :emit_line)
    end

    # #286 increment 4c: the round goes to the loop's worker and the JOB comes
    # back for the loop to drain - submit_turn never waits on the turn itself.
    it 'submits its block to the main_loop and returns the job to drain' do
      seen = []
      loop_ = Object.new
      loop_.define_singleton_method(:begin_turn) { |&blk| seen << blk.call(:task); :job }
      cmd = build(described_class, main_loop: loop_)
      returned = nil

      expect(cmd.submit_turn { |task| returned = task }).to eq(:job)

      expect(seen).to eq([:task])
      expect(returned).to eq(:task)
    end
  end
end
