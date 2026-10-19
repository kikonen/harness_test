# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'command_handler'
require 'command_runner'

RSpec.describe CommandHandler do
  def make_handler(dir, console)
    # harness: nil is fine for the bang/prompt routing paths (not touched).
    described_class.new(
      harness: nil,
      file_list: FileList.new([], workdir: dir),
      options: {},
      ui: console
    )
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

    # issue #221: the bang consent switch. bang_requires_confirmation is
    # the DEFAULT (today's dialog behavior); only an explicit false drops
    # it, and it reaches the runner as auto_approve_all. YOLO is NOT
    # consulted here - the bang path has its own key (the user's own
    # typing is already the consent).
    describe 'bang confirmation option (issue #221)' do
      def handler_with_options(dir, options)
        handler = make_handler(dir, UI::Console.new(stdout: StringIO.new))
        handler.instance_variable_set(:@options, options)
        handler
      end

      def captured_auto_approve(handler, line)
        captured = nil
        allow(CommandRunner).to receive(:new).and_wrap_original do |m, *args, **kwargs|
          captured = kwargs[:auto_approve_all]
          m.call(*args, **kwargs)
        end
        allow_any_instance_of(CommandRunner).to receive(:run)
                .and_return('exit code: 0 (0.0s)')
        handler.handle(line)
        captured
      end

      it 'passes auto_approve_all: false by default (keep the dialog)' do
        Dir.mktmpdir do |dir|
          handler = handler_with_options(dir, {}) # key absent -> dialog kept
          expect(captured_auto_approve(handler, '! echo x')).to be(false)
        end
      end

      it 'passes auto_approve_all: true only when bang confirmation is turned off' do
        Dir.mktmpdir do |dir|
          handler = handler_with_options(dir, { bang_requires_confirmation: false })
          expect(captured_auto_approve(handler, '! echo x')).to be(true)
        end
      end
    end
  end

  # issue #323: an unregistered name gets its suggestion from the SAME registry
  # the dispatch just missed (the old message only said "type /help").
  describe '#handle unknown command (issue #323)' do
    def drive_command(dir, line)
      stdout = StringIO.new
      handler = make_handler(dir, UI::Console.new(stdout: stdout, stdin: StringIO.new('')))
      handler.handle(line)
      stdout.string
    end

    it 'suggests the closest registered command for a typo' do
      Dir.mktmpdir do |dir|
        out = drive_command(dir, '/garnt')

        expect(out).to include('Unknown command: /garnt')
        expect(out).to include('Did you mean /grant?')
      end
    end

    it 'falls back to pointing at /help when nothing is close' do
      Dir.mktmpdir do |dir|
        out = drive_command(dir, '/xyzzy')

        expect(out).to include('Unknown command: /xyzzy')
        expect(out).not_to include('Did you mean')
        expect(out).to include('/help')
      end
    end
  end
end
