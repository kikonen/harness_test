# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'command_handler'
require 'command_runner'

RSpec.describe CommandHandler do
  def make_handler(dir, console)
    # harness: nil is fine for the bang/prompt routing paths (not touched).
    handler = described_class.allocate
    handler.instance_variable_set(:@harness, nil)
    handler.instance_variable_set(:@file_list, FileList.new([], workdir: dir))
    handler.instance_variable_set(:@options, {})
    handler.instance_variable_set(:@exiting, false)
    handler.instance_variable_set(:@ui, console)
    handler
  end

  def drive_bang(dir, *dialog_lines)
    stdin  = StringIO.new(dialog_lines.join("\n"))
    stdout = StringIO.new
    console = UI::Console.new(stdout: stdout, stdin: stdin)
    [make_handler(dir, console), stdout]
  end

  describe '#handle bang syntax (issue #129)' do
    it 'runs an allowed command and prints the result to the console' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'shell_commands.yml'),
                   YAML.dump(['echo']))

        handler, stdout = drive_bang(dir)
        handler.handle('! echo bang')

        expect(stdout.string).to include('exit code: 0')
        expect(stdout.string).to include('bang')
      end
    end

    it 'does NOT auto-approve from the run.command tool list' do
      Dir.mktmpdir do |dir|
        # A grant saved by the MODEL tool must not auto-approve a
        # locally typed command (issue #129).
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'allowed_commands.yml'),
                   YAML.dump(['echo']))

        handler, stdout = drive_bang(dir, '4') # would cancel the dialog
        handler.handle('! echo bang')

        expect(stdout.string).to include('Run shell command:')
        expect(stdout.string).to include('[shell] ✗ denied by user')
      end
    end

    it 'serves the approval dialog in place for unapproved commands' do
      Dir.mktmpdir do |dir|
        handler, stdout = drive_bang(dir, '1') # Allow(1)
        handler.handle('! echo bang')

        expect(stdout.string).to include('Run shell command:')
        expect(stdout.string).not_to include('The model is requesting')
        expect(stdout.string).to include('exit code: 0')
        expect(stdout.string).to include('bang')
      end
    end

    it 'does not run when the user cancels' do
      Dir.mktmpdir do |dir|
        handler, stdout = drive_bang(dir, '4') # Allow(1), grants(2,3), Cancel(4)
        handler.handle('! echo bang')

        expect(stdout.string).not_to include('exit code:')
        expect(stdout.string).to include('[shell] ✗ denied by user')
      end
    end

    it 'shows a usage hint for a bare "!"' do
      Dir.mktmpdir do |dir|
        handler, stdout = drive_bang(dir)
        handler.handle('!')

        expect(stdout.string).to include('usage: ! <command>')
      end
    end

    it 'reports runner errors with an error prefix' do
      Dir.mktmpdir do |dir|
        allow_any_instance_of(CommandRunner).to receive(:run)
                .and_return("error: directory 'missing' does not exist")
        handler, stdout = drive_bang(dir)
        handler.handle('! echo hi')

        expect(stdout.string)
          .to include("[error] directory 'missing' does not exist")
      end
    end

    it 'flattens multiline bang input before executing' do
      Dir.mktmpdir do |dir|
        allow_any_instance_of(CommandRunner).to receive(:run)
                .with('echo a b') { 'exit code: 0 (0.0s)' }
        handler, stdout = drive_bang(dir)
        handler.handle("! echo a\nb")

        expect(stdout.string).to include('exit code: 0')
      end
    end

    it 'routes plain text to a prompt, and "!" lines to the shell' do
      Dir.mktmpdir do |dir|
        stdout = StringIO.new
        handler = make_handler(dir, UI::Console.new(stdout: stdout))

        allow(handler).to receive(:run_direct_prompt) { |_t| :prompted }
        allow(handler).to receive(:run_bang_command) { |_c| :shelled }

        handler.handle('hello there')
        expect(handler).to have_received(:run_direct_prompt).with('hello there')

        handler.handle('! ls -la')
        expect(handler).to have_received(:run_bang_command).with('ls -la')
      end
    end
  end
end
