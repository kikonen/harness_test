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
    runner = described_class.new(file_list, {},
                                 label: 'shell',
                                 ui: UI::Console.new(stdout: stdout,
                                                     stdin: stdin),
                                 list: :shell, **kwargs)
    [runner, stdout]
  end

  def make_tool_runner(dir, options = {}, harness: nil)
    described_class.new(FileList.new([], workdir: dir), options, harness: harness)
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

  it 'does NOT auto-approve from the local shell (!) list' do
    Dir.mktmpdir do |dir|
      # A grant saved for local bang syntax must not auto-approve a
      # model-initiated run.command (issue #129).
      FileUtils.mkdir_p(File.join(dir, '.harness'))
      File.write(File.join(dir, '.harness', 'shell_commands.yml'),
                 YAML.dump(['echo']))

      drive_dialog(['4']) # must reach the dialog -> cancel it
      out = make_tool_runner(dir).run('echo hi')
      expect(out).to eq('error: user denied executing the command')
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

  it 'saves "Always allow" into the local shell list only' do
    Dir.mktmpdir do |dir|
      runner, out = make_main_runner(dir, '2') # Allow(1), 'echo'(2)
      result = runner.run('echo hi')
      expect(result).to start_with('exit code: 0')

      shell_yml = File.join(dir, '.harness', 'shell_commands.yml')
      tool_yml  = File.join(dir, '.harness', 'allowed_commands.yml')
      expect(YAML.safe_load(File.read(shell_yml))).to eq(['echo'])
      expect(File.file?(tool_yml)).to be false

      # A fresh shell runner auto-approves from the saved grant.
      expect(described_class.new(FileList.new([], workdir: dir), {},
                                 label: 'shell', list: :shell).run('echo x'))
        .to start_with('exit code: 0')
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

  context 'failure tracing (issue #185)' do
    # A harness stand-in whose logger records everything it is told.
    def fake_logger
      messages = []
      logger = double('logger')
      allow(logger).to receive(:warn) { |m| messages << m }
      [messages, logger]
    end

    def harness_with(logger)
      double('harness', logger: logger)
    end

    it 'names the failure when a command exits non-zero without output' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'false')
        _, logger = fake_logger
        runner = described_class.new(FileList.new([], workdir: dir), {},
                                     harness: harness_with(logger))

        out = runner.run('false')
        expect(out).to start_with('exit code: 1')
        expect(out)
          .to include('(the command produced no output - nothing to inspect)')
      end
    end

    it 'logs failed commands (with "(none)" streams) to the session log' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'false')
        messages, logger = fake_logger
        runner = described_class.new(FileList.new([], workdir: dir), {},
                                     harness: harness_with(logger))

        runner.run('false')
        expect(messages.size).to eq(1)
        expect(messages[0]).to start_with('shell command failed:')
        expect(messages[0]).to include('command: false')
        expect(messages[0]).to include('status: exit 1')
        expect(messages[0]).to include("--- output ---\n(none)")
      end
    end

    it 'logs the timed-out command to the session log' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'sleep 120')
        messages, logger = fake_logger
        runner = described_class.new(FileList.new([], workdir: dir), {},
                                     harness: harness_with(logger))
        allow_any_instance_of(described_class).to receive(:run_in_shell)
                  .and_return(['', :timeout])

        runner.run('sleep 120', timeout: 60)
        expect(messages.size).to eq(1)
        expect(messages[0]).to start_with('shell command failed:')
        expect(messages[0]).to include('status: TIMED OUT after 60s')
      end
    end

    it 'does not log successful commands' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'echo')
        messages, logger = fake_logger
        runner = described_class.new(FileList.new([], workdir: dir), {},
                                     harness: harness_with(logger))

        runner.run('echo hi')
        expect(messages).to be_empty
      end
    end
  end

  # issue #224: a fake LLM client that records requests and answers with
  # one scripted verdict block (shared by the safety-check and the
  # auto-approve contexts below).
  def fake_client(*lines)
    client = double('client')
    allow(client).to receive(:chat) do |chain, tools: nil, timeout: nil|
      client.instance_variable_get(:@calls) << { chain: chain, tools: tools }
      { choices: [{ message: { content: lines.join("\n") } }] }
    end
    client.instance_variable_set(:@calls, [])
    client
  end

  def harness_with(client, chain)
    double('harness', client: client, logger: nil, session: double('session', messages: chain))
  end

  # A chain ending on an unresolved assistant tool_calls - the shape the
  # session has at dialog time (SafetyCheck truncates that).
  def chain_mid_tool_loop
    [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'do it' },
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'c1', function: { name: 'run.command', arguments: '{}' } }] }
    ]
  end

  # issue #224: the model's own safety verdict, shown as an advisory note in
  # the consent dialog for an unapproved command. Never auto-approves.
  context 'command safety check (issue #224)' do
    it 'shows the verdict as the first dialog note line (advisory)' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: read-only syntax check')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(client, chain_mid_tool_loop))
        out = drive_dialog(['1'])
        result = runner.run('echo hi')
        expect(result).to start_with('exit code: 0')

        expect(out.string).to include('MODEL VERDICT (advisory): safe: read-only syntax check')
        # The status line goes over the Task outbox in production
        # (no task in this spec); the dialog note is the user-facing artifact.
      end
    end

    it 'keeps the deterministic UNSAFETY note alongside the verdict' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: just writes to tmp/')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(client, chain_mid_tool_loop))
        out = drive_dialog(['2']) # Allow(1), Cancel(2)
        result = runner.run('echo hi > tmpfile')

        expect(out.string).to include('MODEL VERDICT (advisory): safe: just writes to tmp/')
        expect(out.string).to include('UNSAFE: redirect to file ("> tmpfile") cannot be auto-approved')
        expect(result).to start_with('error: user denied')
      end
    end

    it 'is skipped when the option is not enabled (default off)' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe')
        runner = make_tool_runner(dir, {}, harness: harness_with(client, chain_mid_tool_loop))
        out = drive_dialog(['1'])
        result = runner.run('echo hi')
        expect(result).to start_with('exit code: 0')

        expect(out.string).not_to include('MODEL VERDICT')
        expect(client.instance_variable_get(:@calls)).to be_empty
      end
    end

    # issue #240: the allowlist is consulted BEFORE the model check, so an
    # already-allowed command never costs a safety-check call. Same for the
    # bang path (both go through #run).
    it 'does not ask the model for a command already in the allowlist' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'echo')
        client = fake_client('safe: harmless read')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(client, chain_mid_tool_loop))
        out = drive_dialog([]) # no dialog opens - the allowlist already covers it
        result = runner.run('echo hi')

        expect(result).to start_with('exit code: 0')
        expect(client.instance_variable_get(:@calls)).to be_empty
        expect(out.string).not_to include('The model is requesting')
      end
    end

    it 'degrades to the plain dialog when the check call fails' do
      Dir.mktmpdir do |dir|
        client = double('client')
        allow(client).to receive(:chat).and_raise(LLMError, 'offline')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(client, chain_mid_tool_loop))
        out = drive_dialog(['1'])

        expect(out.string).not_to include('MODEL VERDICT')
        expect(runner.run('echo hi')).to start_with('exit code: 0')
      end
    end
  end

  # issue #257: the command string is externally-sourced text (the model's
  # tool-call arguments, parsed from JSON), so a byte that is invalid in
  # UTF-8 used to crash the internal strip / tokenizer. run() normalizes at
  # its entry point, so the bad byte becomes the replacement character and
  # the result is valid UTF-8 that JSON.generate (the session save) can hold.
  describe 'invalid UTF-8 bytes (issue #257)' do
    def bad_byte
      [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)
    end

    it 'does not raise on a model-supplied command carrying an invalid byte' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'echo')
        command = 'echo ' + bad_byte
        expect(command.valid_encoding?).to be false
        # Control: the raw string is what the internal strip used to choke on.
        expect { command.strip }.to raise_error(StandardError)

        runner = make_tool_runner(dir)
        expect { runner.run(command) }.not_to raise_error
        expect(runner.run(command)).to start_with('exit code:')
      end
    end

    it 'normalizes the child output at the read boundary' do
      Dir.mktmpdir do |dir|
        runner = make_tool_runner(dir)
        # printf emits exactly the undecodable byte (no shell quoting of it).
        output, _status = runner.send(:read_child_in_group, "printf 'a\\200b'", dir, 10)
        expect(output.encoding).to eq(Encoding::UTF_8)
        expect(output.valid_encoding?).to be true
        expect(output).to eq('a?b')
        # The point of the fix: this value goes into the session via
        # JSON.generate, which raised on the raw byte.
        expect { JSON.generate({ 'result' => output }) }.not_to raise_error
      end
    end
  end

  # issue #224 follow-up: AUTO-APPROVE mode (live toggle, Ctrl+A). With
  # the posture effective, a verdict of "safe:" skips the consent dialog;
  # "dangerous:" verdicts and missing verdicts still ask.
  context 'auto-approve mode (issue #224 follow-up)' do
    def auto_approve_harness(client, chain)
      double('harness', client: client, logger: nil,
             session: double('session', messages: chain),
             command_safety_auto_approve_effective?: true)
    end

    def manual_harness(client, chain)
      double('harness', client: client, logger: nil,
             session: double('session', messages: chain),
             command_safety_auto_approve_effective?: false)
    end

    it 'skips the dialog for a "safe:" verdict (no user input consumed)' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: harmless read')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: auto_approve_harness(client, chain_mid_tool_loop))
        out = drive_dialog([]) # nothing typed - the dialog must not open
        result = runner.run('echo hi')
        expect(result).to start_with('exit code: 0')
        expect(out.string).not_to include('The model is requesting')
      end
    end

    it 'still opens the dialog for a "dangerous:" verdict' do
      Dir.mktmpdir do |dir|
        client = fake_client('dangerous: deletes the repo')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: auto_approve_harness(client, chain_mid_tool_loop))
        out = drive_dialog(['4']) # Allow(1), Cancel(2) -> deny
        result = runner.run('rm -rf .')
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('dangerous: deletes the repo')
      end
    end

    it 'does NOT auto-approve a malformed verdict that only mentions safe later' do
      Dir.mktmpdir do |dir|
        client = fake_client('not really safe, just checking')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: auto_approve_harness(client, chain_mid_tool_loop))
        out = drive_dialog(['4'])
        expect(runner.run('echo hi')).to start_with('error: user denied')
        expect(out.string).to include('MODEL VERDICT (advisory)')
      end
    end

    it 'still opens the dialog for a "safe:" verdict in MANUAL mode' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: harmless read')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: manual_harness(client, chain_mid_tool_loop))
        out = drive_dialog(['1'])
        result = runner.run('echo hi')
        expect(result).to start_with('exit code: 0')
        expect(out.string).to include('The model is requesting')
      end
    end

    it 'ignores the posture when the safety check is disabled (no verdict)' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: should never be asked')
        runner = make_tool_runner(dir, {},
                                  harness: auto_approve_harness(client, chain_mid_tool_loop))
        out = drive_dialog(['1'])
        result = runner.run('echo hi')
        expect(result).to start_with('exit code: 0')
        expect(client.instance_variable_get(:@calls)).to be_empty
        expect(out.string).to include('The model is requesting')
      end
    end
  end

  it 'returns a timeout error when the command exceeds its limit' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'sleep 120')
      runner = make_tool_runner(dir)
      allow_any_instance_of(described_class).to receive(:run_in_shell)
                .and_return(['', :timeout])

      out = runner.run('sleep 120', timeout: 60)
      expect(out).to eq('error: command timed out after 60s')
    end
  end

  # REAL timeout (no stubbing): proves issue #202 - the runner must ALWAYS
  # return promptly with :timeout and the whole process tree must be dead
  # afterwards, so a hung command can never wedge the harness again. Calls
  # read_child_in_group directly because run() clamps timeout up to 60 s.
  it 'kills the command tree on timeout and returns without hanging' do
    Dir.mktmpdir do |dir|
      runner = make_tool_runner(dir)

      started = Time.now
      _out, status = runner.send(:read_child_in_group, 'sleep 99', dir, 2)
      elapsed = Time.now - started

      expect(status).to eq(:timeout)
      # The tree must be killed, not waited out: well under the 99 s.
      expect(elapsed).to be < 10
    end
  end

  # If the running Ruby rejects the process-group spawn flag (older
  # versions on POSIX), the runner falls back to a plain spawn and the
  # command still runs.
  it 'falls back to a plain spawn when group spawn is unsupported' do
    Dir.mktmpdir do |dir|
      seed_allowlist(dir, 'echo')
      runner, = make_main_runner(dir, '1')

      real_spawn = Process.method(:spawn)
      group_key  = described_class::PGROUP_SPAWN_KEY
      fell_back  = false
      allow(Process).to receive(:spawn).and_wrap_original do |_m, cmd, *args|
        opts = args.last.is_a?(Hash) ? args.last : {}
        if opts.key?(group_key) && !fell_back
          # Reject the grouped attempt like an older Ruby would.
          fell_back = true
          raise ArgumentError, 'wrong exec option symbol: pgroup'
        end
        real_spawn.call(cmd, *args)
      end

      out = runner.run('echo hi')
      expect(out).to start_with('exit code: 0')
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
        [stdout, Struct.new(:exitstatus).new(0)]
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
