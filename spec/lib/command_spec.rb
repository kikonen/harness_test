# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'command'
require 'commands/ctx_command'

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

    it 'defaults the two CLI-only collaborators to nil' do
      cmd = build(described_class)

      expect(cmd.instance_variable_get(:@on_resume)).to be_nil
      expect(cmd.help_renderer).to be_nil
    end

    it 'accepts an on_resume callable (only /resume uses it)' do
      callable = ->(_id) { :resumed }
      cmd = build(described_class, on_resume: callable)

      expect(cmd.instance_variable_get(:@on_resume)).to equal(callable)
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
