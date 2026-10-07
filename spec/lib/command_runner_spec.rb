# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'command_runner'

RSpec.describe CommandRunner do
  # -- helpers ---------------------------------------------------------------

  def seed_allowlist(dir, *prefixes)
    FileUtils.mkdir_p(File.join(dir, '.harness'))
    File.write(File.join(dir, '.harness', 'allowed_commands.yml'),
               YAML.dump(prefixes))
  end

  # Tool-path mode (no ui:): the dialog is routed via show(ui: nil), which
  # needs a Task - intercept it and serve perform_direct on StringIOS, like
  # run_command_tool_spec does. Returns the captured console output.
  def drive_dialog(lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    stdout
  end

  # Main-thread mode (ui:): no interception needed - the runner serves
  # perform_direct directly on the provided console. Returns [runner, out].
  def make_main_runner(dir, *dialog_lines, **kwargs)
    stdin  = StringIO.new(dialog_lines.join("\n"))
    stdout = StringIO.new
    file_list = FileList.new([], workdir: dir)
    runner = described_class.new(
      file_list, {},
      label: 'shell', ui: UI::Console.new(stdout: stdout), **kwargs)
    [runner, stdout]
  end

  def make_tool_runner(dir, options = {})
    described_class.new(FileList.new([], workdir: dir), options)
  end

  # -- CommandRunner ---------------------------------------------------------

  it 'returns an error for an empty command' do
    Dir.mktmpdir do |dir|
      expect(make_tool_runner(dir).run('   '))
        .to eq("error: 'command' must be a non-empty shell command")
    end
  end

  it 'returns an error for a missing cwd' do
    Dir.mktmpdir do |dir|
      out = make_tool_runner(dir).run('echo hi', cwd: 'no/such/dir')
      expect(out).to start_with("error: directory ")
    end
  end

  it 'runs without a dialog when the prefix is in the allowlist' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'echo hi')

      out = make_tool_runner(dir).run('echo hi')
      expect(out).to start_with('exit code: 0')
      expect(out).to include("hi\n")
    end
  end

  it 'denies when the user cancels the dialog' do
    Dir.mktmpdir do |dir|
      # Options: Allow(1), 'echo'(2), 'echo hi'(3), Cancel(4).
      drive_dialog(['4'])
      out = make_tool_runner(dir).run('echo hi')
      expect(out).to eq('error: user denied executing the command')
    end
  end

  it 'forwards a denial note in the returned error string' do
    Dir.mktmpdir do |dir|
      drive_dialog(['4 too risky, just read the file instead'])
      out = make_tool_runner(dir).run('echo hi')
      expect(out).to eq(
        'error: user denied executing the command ' \
        "(user's note: \"too risky, just read the file instead\")"
      )
    end
  end

  it 'runs the command when the user allows it once' do
    Dir.mktmpdir do |dir|
      drive_dialog(['1'])
      out = make_tool_runner(dir).run('echo hi')
      expect(out).to start_with('exit code: 0')
      expect(out).to include("hi\n")
      # No allowlist file must be created by a one-off Allow.
      expect(File.file?(File.join(dir, '.harness', 'allowed_commands.yml')))
        .to be false
    end
  end

  it 'saves an "Always allow" prefix and auto-approves matching commands' do
    Dir.mktmpdir do |dir|
      drive_dialog(['2']) # Allow(1), 'echo'(2), Cancel(3)
      out1 = make_tool_runner(dir).run('echo hi')
      expect(out1).to start_with('exit code:')

      yml = File.join(dir, '.harness', 'allowed_commands.yml')
      expect(YAML.safe_load(File.read(yml))).to eq(['echo'])

      # A new runner instance (fresh allowlist load) auto-approves now.
      out2 = make_tool_runner(dir).run('echo something else')
      expect(out2).to start_with('exit code:')
    end
  end

  it 'runs without saving when Allow is mixed into a multi-select' do
    Dir.mktmpdir do |dir|
      # "cd C:/work/x && ruby -c f": Allow(1), 'cd C:/work/x'(2),
      # 'ruby'(3), 'ruby -c'(4). Picking Allow + a grant is ambiguous:
      # run now, save nothing.
      drive_dialog(['1 2'])
      out = make_tool_runner(dir).run('cd C:/work/x && ruby -c f')
      # 'cd' fails (no such dir here) - that's fine, the contract under
      # test is: it RAN and nothing was saved.
      expect(out).to start_with('exit code:')

      expect(File.file?(File.join(dir, '.harness', 'allowed_commands.yml')))
        .to be false
    end
  end

  it 'offers no "Always allow" for unsafe constructs and names the construct' do
    Dir.mktmpdir do |dir|
      out = drive_dialog(['2']) # Unsafe: no grantable prefix -> Allow(1), Cancel(2)
      result = make_tool_runner(dir).run('echo hi > tmpfile')

      expect(out.string).not_to include("Always allow '")
      expect(out.string).to include('UNSAFE: redirect to file ("> tmpfile")')
      expect(result).to start_with('error: user denied')
    end
  end

  it 'reports a non-zero exit code' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'false')

      out = make_tool_runner(dir).run('false')
      expect(out).to start_with('exit code: 1')
    end
  end

  it 'returns a timeout error when the command exceeds its limit' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'sleep 120')
      runner = make_tool_runner(dir)
      # Simulate the timeout instead of actually sleeping.
      allow_any_instance_of(described_class).to receive(:run_in_shell)
                .and_raise(Timeout::Error, 'timeout')

      out = runner.run('sleep 120', timeout: 60)
      expect(out).to eq('error: command timed out after 60s')
    end
  end

  it 'honors dry runs without executing' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'echo hi')
      file_list = FileList.new([], workdir: dir)
      runner = described_class.new(file_list, { dry_run: true })
      out = runner.run('echo hi')
      shown = file_list.display_path(dir)
      expect(out).to eq("DRY RUN: would execute 'echo hi' in #{shown}")
    end
  end

  it 'truncates long output to the line limit' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'seq 50')
      runner = make_tool_runner(dir)
      allow_any_instance_of(described_class).to receive(:run_in_shell) do
        stdout = (1..50).map { |i| "line #{i}" }.join("\n") + "\n"
        [stdout, '', Struct.new(:exitstatus).new(0)]
      end

      out = runner.run('seq 50', limit: 10)
      expect(out).to include('line 10')
      expect(out).not_to include('line 11')
      expect(out).to include(
        '(output truncated: 40 more line(s) omitted'
      )
    end
  end

  it 'uses the dialog title from its configuration' do
    Dir.mktmpdir do |dir|
      runner, out = make_main_runner(dir, '4', # Allow(1), grants(2,3), Cancel(4)
                                     title_fmt: described_class::BANG_TITLE)
      runner.run('echo hi')

      expect(out.string).to include('Run shell command:')
      expect(out.string).not_to include('The model is requesting')
    end

    Dir.mktmpdir do |dir|
      out = drive_dialog(['4'])
      make_tool_runner(dir).run('echo hi') # default = tool title
      expect(out.string)
        .to include('The model is requesting to run a shell command:')
    end
  end

  it 'prints status lines to the provided console on the main thread' do
    Dir.mktmpdir do |dir|
      runner, out = make_main_runner(dir, '4') # Allow(1), grants(2,3), Cancel(4)
      runner.run('echo hi')

      expect(out.string).to include('[shell] ✗ denied by user')
    end
  end
end
