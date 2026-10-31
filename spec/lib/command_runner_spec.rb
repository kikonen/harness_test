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
  # palette: the console's palette (nil = paint nothing, issue #388).
  def drive_dialog(lines, palette: nil)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin,
                                               palette:))
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

  # -- Path-shaped commands and DIRECTORY glob grants (issue #417) ----------

  it 'offers a path program and its directory glob as grants' do
    Dir.mktmpdir do |dir|
      out    = drive_dialog(['4']) # Allow(1), 'bin/harness'(2), 'bin/*'(3), Cancel(4)
      result = make_tool_runner(dir).run('bin/harness --version')

      expect(out.string).to include("Always allow 'bin/harness'")
      expect(out.string).to include("Always allow 'bin/*'")
      expect(result).to start_with('error: user denied')
    end
  end

  it 'saves a directory glob and auto-approves every program in it' do
    Dir.mktmpdir do |dir|
      # Allow(1), 'bin/ok.sh'(2), 'bin/ok.sh one'(3), 'bin/*'(4).
      out    = drive_dialog(['4'])
      first  = make_tool_runner(dir).run('bin/ok.sh one')

      yml = File.join(dir, '.harness', 'allowed_commands.yml')
      expect(YAML.safe_load(File.read(yml))).to eq(['bin/*'])
      expect(first).to start_with('exit code:')

      # A fresh runner (fresh allowlist load) auto-approves without a dialog.
      # Nothing typed: had the dialog opened it would hit EOF and cancel.
      out2   = drive_dialog([])
      second = make_tool_runner(dir).run('bin/ok.sh again')
      expect(out2.string).to eq('')
      # It RAN (no dialog). The script does not exist in the tmpdir, so the
      # child answers 127 - the contract under test is that it was not asked for.
      expect(second).to start_with('exit code:')

      # A program in ANOTHER directory is not covered by the stored glob.
      out3 = drive_dialog(['4']) # Allow(1), 'tools/build'(2), 'tools/*'(3), Cancel(4)
      third = make_tool_runner(dir).run('tools/build')
      expect(third).to start_with('error: user denied')
      expect(out3.string).to include("Always allow 'tools/build'")
    end
  end

  it 'states the trust boundary of a glob offer and nothing for an exact prefix' do
    Dir.mktmpdir do |dir|
      out = drive_dialog(['4']) # Allow(1), 'bin/rspec'(2), 'bin/*'(3), Cancel(4)
      make_tool_runner(dir).run('bin/rspec')

      expect(out.string).to include('covers every program in that directory')
      # Only the glob option carries the note: one such line for two offers.
      expect(out.string.scan('covers every program').size).to eq(1)
    end
  end

  it 'asks for a denylisted path verb without offering its directory' do
    Dir.mktmpdir do |dir|
      out    = drive_dialog(['2']) # Allow(1), Cancel(2): no grants offered
      result = make_tool_runner(dir).run('bin/rm -rf /somewhere')

      expect(result).to start_with('error: user denied')
      expect(out.string).to include('DENYLISTED: recursive-force delete')
      expect(out.string).not_to include("Always allow 'bin/*'")
    end
  end

  it 'does not accuse a plain command of being UNSAFE when nothing is grantable' do
    Dir.mktmpdir do |dir|
      out = drive_dialog(['2'])
      # '~/bin/tool' yields no grantable candidate and no danger token: the
      # UNSAFE line used to be inferred from the empty candidate list, so this
      # plain command was accused of carrying shell constructs (issue #417).
      make_tool_runner(dir).run('~/bin/tool')

      expect(out.string).not_to include('UNSAFE')
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
    double('harness', client: client, logger: nil,
           session: double('session', messages: chain),
           tools_payload: [{ type: 'function', function: { name: 'test.echo' } }])
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

    # The fork must carry the SAME tool definitions the live turn sent, or its
    # rendered prompt is a different prompt and re-prefills cold (#246;
    # doc/compaction_cache_design.md). The runner owns the hand-off: it reads
    # Harness#tools_payload and passes it to SafetyCheck.run.
    it 'passes the harness tool payload to the safety check' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: harmless read')
        h = harness_with(client, chain_mid_tool_loop)
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        out = drive_dialog(['1'])
        expect(runner.run('echo hi')).to start_with('exit code: 0')

        expect(client.instance_variable_get(:@calls).first[:tools])
          .to eq(h.tools_payload)
        # The payload is carried, and the verdict still reaches the dialog:
        # carrying tools must not cost the check its answer.
        expect(out.string).to include('MODEL VERDICT (advisory): safe: harmless read')
      end
    end

    # The degraded shape: a harness that cannot report tool definitions (a bang
    # runner built without one). nil is a cache miss, never a wrong verdict -
    # the check still runs and the verdict still reaches the dialog.
    it 'sends no tools and still verdicts when the harness reports none' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: harmless read')
        h = double('harness', client: client, logger: nil,
                   session: double('session', messages: chain_mid_tool_loop))
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        out = drive_dialog(['1'])
        expect(runner.run('echo hi')).to start_with('exit code: 0')

        expect(client.instance_variable_get(:@calls).first[:tools]).to be_nil
        expect(out.string).to include('MODEL VERDICT (advisory): safe: harmless read')
      end
    end

    # The trial contract of issue #382: a DENYLISTED command must still show the
    # model's verdict, so the verdict can be judged against a command the
    # denylist already refuses. The floor is untouched - the command still asks
    # and is not auto-approved; only the note is added.
    it 'shows the verdict on a denylisted command too (MANUAL, issue #382)' do
      Dir.mktmpdir do |dir|
        client = fake_client('1: safe: removes only a scratch dir')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(client, chain_mid_tool_loop))
        out = drive_dialog(['2']) # Allow(1), Cancel(2): no grants offered
        result = runner.run('rm -rf tmp/scratch/x')
        expect(result).to start_with('error: user denied')
        expect(out.string).not_to include('auto-approved')
        expect(out.string).to include('MODEL VERDICT (advisory): safe: removes only a scratch dir')
        expect(out.string).to include('DENYLISTED: recursive-force delete')
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

    # issue #268: the accumulator is BINARY (#257), but a BINARY tag is a
    # byte container, not an encoding - transcoding it byte-by-byte destroyed
    # every multi-byte character, so native non-ASCII command output came out
    # as '?' runs. The bytes are valid UTF-8 and must survive intact.
    it 'keeps multi-byte characters in the child output' do
      Dir.mktmpdir do |dir|
        runner = make_tool_runner(dir)
        # printf writes the UTF-8 bytes of 'a with diaeresis' (C3 A4) and of a
        # 3-byte character, spelled as octal escapes so this SPEC SOURCE
        # stays pure ASCII (a literal here would itself be mangled by the
        # harness' own read/patch boundary).
        output, _status = runner.send(
          :read_child_in_group,
          "printf '\\303\\244\\342\\234\\223'", dir, 10
        )

        expect(output.bytes).to eq([0xC3, 0xA4, 0xE2, 0x9C, 0x93])
        expect(output.encoding).to eq(Encoding::UTF_8)
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

    # issue #344: a line that carries no safe:/dangerous: shape is not a verdict
    # at all, so it cannot reach the auto-approve test - and it is not shown as
    # a MODEL VERDICT either (the dialog would otherwise present a half-sentence
    # as the model's opinion about this command).
    it 'does NOT auto-approve (or even show) an answer that is not a verdict shape' do
      Dir.mktmpdir do |dir|
        client = fake_client('not really safe, just checking')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: auto_approve_harness(client, chain_mid_tool_loop))
        out = drive_dialog(['4'])
        expect(runner.run('echo hi')).to start_with('error: user denied')
        expect(out.string).to include('The model is requesting')
        expect(out.string).not_to include('MODEL VERDICT (advisory)')
      end
    end

    # The consumer-side half of issue #344: the old code mapped an extra model
    # line onto the first command, so 'rm -rf' was reported "safe: syntax check"
    # and AUTO-APPROVE would have run it. An answer that cannot be placed must
    # leave the command verdict-less (the dialog opens), never mislabelled. The
    # command is deliberately NOT denylisted: a denylisted one always asks, so
    # the assertion would prove nothing.
    it 'does NOT auto-approve when the model answer cannot be placed (issue #344)' do
      Dir.mktmpdir do |dir|
        client = fake_client('Here are my verdicts:', 'safe: harmless read')
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: auto_approve_harness(client, chain_mid_tool_loop))
        out = drive_dialog(['4']) # Allow(1), two grants, Cancel(4): the dialog
                                  # MUST open despite the posture and the safe: line
        expect(runner.run('echo hi')).to start_with('error: user denied')
        expect(out.string).to include('The model is requesting')
        expect(out.string).not_to include('auto-approved')
        expect(out.string).not_to include('MODEL VERDICT (advisory)')
      end
    end

    # A dropped verdict is a decision, not a network failure - so it must be
    # recoverable from harness.log (the runner injects the harness logger).
    it 'logs the dropped verdict to harness.log' do
      Dir.mktmpdir do |dir|
        logged = []
        logger = double('logger')
        allow(logger).to receive(:info) { |m| logged << m }
        allow(logger).to receive(:warn) { |m| logged << m }
        client = fake_client('Here are my verdicts:', 'safe: harmless read')
        h = double('harness', client: client, logger: logger,
                   session: double('session', messages: chain_mid_tool_loop),
                   command_safety_auto_approve_effective?: true)
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        drive_dialog(['2'])
        runner.run('echo hi')

        expect(logged.any? { |m| m.include?('safety check:') && m.include?('cannot be placed') })
          .to be true
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

  # The main-thread path renders UI::Renderer's pattern itself, so a bang
  # command looks exactly like a tool one (issue #303 / #146).
  describe 'main-thread status lines use the renderer pattern' do
    it 'indents, brackets and glyphs the line the way the drain loop would' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, auto_approve_all: true)
        runner.run('echo hi')

        expect(out.string).to include('  [shell] ✓ auto-approved (bang consent off): echo hi')
        expect(out.string).to match(/^ {2}\[shell\] ✓ echo hi \(exit 0, [\d.]+s\)/)
      end
    end

    # issue #325: an auto-approved run printed its FULL command in the approval
    # line, so the outcome line names it by handle instead of repeating it.
    it 'prints a long auto-approved command once, then by handle' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, auto_approve_all: true)
        runner.run('echo one two three four five six')

        expect(out.string).to include(
          '[shell] ✓ auto-approved (bang consent off): echo one two three four five six'
        )
        expect(out.string).to match(
          /^ {2}\[shell\] ✓ echo one two three \.\.\. \(exit 0, [\d.]+s\)/
        )
        # The tail tokens appear exactly once: no duplicated command line.
        expect(out.string.scan('four five six').size).to eq(1)
      end
    end

    # A command that reached the consent dialog has no approval line, so its
    # outcome line stays its only trace and keeps the full text.
    it 'keeps the full command in the outcome line of a dialog-approved run' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, '1') # Allow(1), grants(2..), Cancel
        runner.run('echo one two three four five six')

        # The dialog prompt line has no trailing newline, so the status line
        # continues on it - assert the text, not the line start.
        expect(out.string).to include('[shell] ✓ echo one two three four five six (exit 0,')
        expect(out.string).not_to include('echo one two three ...')
      end
    end

    # issue #349: the denylist refusal line prints the FULL command BEFORE the
    # dialog, so a denylisted command the user then allowed is in the same case
    # as an auto-approved one - its outcome line names it by handle.
    it 'shortens the outcome line for a denylisted command allowed from the dialog' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, '1', auto_approve_all: true)
        result = runner.run('rm -rf one two three four five')
        expect(result).to start_with('exit code: 0')
        expect(out.string).to include(
          'denylisted (auto-approval refused in every posture): ' \
          'rm -rf one two three four five'
        )
        # The outcome line is the only place a shortened name could appear, and
        # the full command is never repeated there.
        expect(out.string).to include('[shell] ✓ rm -rf one two ... (exit 0')
        expect(out.string).not_to include('rm -rf one two three four five (exit 0')
      end
    end

    it 'marks only a dropped tail: a command that fits the handle is unchanged' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, auto_approve_all: true)
        runner.run('echo a b c') # exactly HANDLE_TOKENS tokens
        expect(out.string).to match(/^ {2}\[shell\] ✓ echo a b c \(exit 0, [\d.]+s\)/)

        runner.run('echo a b c d') # one token over
        expect(out.string).to match(/^ {2}\[shell\] ✓ echo a b c \.\.\. \(exit 0, [\d.]+s\)/)
      end
    end

    # Every auto-approval entry point passes the flag, not just the posture one:
    # here a stored shell-list grant auto-approves on the main thread.
    it 'shortens the outcome line for an allowlist auto-approval too' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(File.join(dir, '.harness', 'shell_commands.yml'),
                   YAML.dump(['echo one']))
        runner, out = make_main_runner(dir) # no dialog lines: nothing asks
        runner.run('echo one two three four five six')

        expect(out.string).to include('[shell] ✓ auto-approved (allowlist): echo one two')
        expect(out.string).to match(/^ {2}\[shell\] ✓ echo one two three \.\.\. \(exit 0, [\d.]+s\)/)
      end
    end

    it 'reads the harness palette per line, so a mid-session switch is honored' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, auto_approve_all: true,
                                       harness: double('harness',
                                                      output_palette: UI::Palette.fetch('none'),
                                                      logger: nil))
        runner.run('echo one')
        # StringIO#string is the LIVE buffer: copy it before the next run.
        plain = out.string.dup
        runner.instance_variable_set(:@harness,
                                     double('harness', output_palette: UI::Palette.fetch('default'),
                                            logger: nil))
        runner.run('echo two')
        colored = out.string[plain.length..]

        expect(plain).not_to include("\e[")
        expect(colored).to include("\e[32m ✓ echo two")
      end
    end
  end

  # issue #221: the YOLO posture (Harness#yolo? / /yolo). Every run.command
  # skips the consent dialog - including UNSAFE-construct commands the allowlist
  # could never grant - and no model safety check runs for them (issue #238). The
  # disaster denylist is the floor: a denylisted command still gets the dialog even
  # with a stored grant AND YOLO on, and that dialog is the one YOLO case where the
  # check does run and the verdict is shown (issue #382).
  context 'YOLO posture (issue #221)' do
    # A harness stand-in with the YOLO posture ON and a recording logger
    # (the audit trail: every auto-approved run must be logged).
    def yolo_harness
      messages = []
      logger = double('logger')
      allow(logger).to receive(:info) { |m| messages << m }
      allow(logger).to receive(:warn) { |m| messages << m }
      allow(logger).to receive(:debug) { |m| messages << m }
      h = double('harness', yolo?: true, logger: logger)
      [messages, h]
    end

    it 'runs an unapproved command with no dialog (nothing typed)' do
      Dir.mktmpdir do |dir|
        _, h = yolo_harness
        runner = make_tool_runner(dir, {}, harness: h)
        out = drive_dialog([]) # the dialog must NEVER open
        result = runner.run('echo yolo')
        expect(result).to start_with('exit code: 0')
        expect(out.string).not_to include('The model is requesting')
      end
    end

    # The allowlist path could never grant these (no safe prefix to save);
    # YOLO auto-approves them anyway.
    it 'auto-approves a command with UNSAFE constructs' do
      Dir.mktmpdir do |dir|
        _, h = yolo_harness
        runner = make_tool_runner(dir, {}, harness: h)
        drive_dialog([])
        # A redirect: extract_prefix_options returns [] and the allowlist
        # path refuses it - under YOLO it simply runs.
        result = runner.run('echo yolo > tmpfile')
        expect(result).to start_with('exit code: 0')
      end
    end

    it 'skips the model safety check entirely (issue #238: no extra LLM round trip)' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: should never be asked')
        h = double('harness', yolo?: true, logger: nil, client: client,
                   session: double('session', messages: []))
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        drive_dialog([])
        expect(runner.run('echo hi')).to start_with('exit code: 0')
        expect(client.instance_variable_get(:@calls)).to be_empty
      end
    end

    # YOLO auto-approves everything EXCEPT a denylisted command, and the one
    # command that does ask must still carry the verdict (issue #382). This is
    # the only YOLO case where the check runs at all - Harness#precheck_batch_safety
    # skips YOLO, and a non-denylisted command never reaches the check.
    it 'runs the model check for a denylisted command, on its dialog' do
      Dir.mktmpdir do |dir|
        client = fake_client('1: dangerous: recursive force delete')
        h = double('harness', yolo?: true, logger: nil, client: client,
                   session: double('session', messages: chain_mid_tool_loop))
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        out = drive_dialog(['2']) # Allow(1), Cancel(2): no grants offered
        result = runner.run('rm -rf /somewhere')
        expect(result).to start_with('error: user denied')
        expect(client.instance_variable_get(:@calls).size).to eq(1)
        expect(out.string).to include('DENYLISTED: recursive-force delete')
        expect(out.string)
          .to include('MODEL VERDICT (advisory): dangerous: recursive force delete')
      end
    end

    it 'logs every YOLO auto-approval to harness.log (the audit trail)' do
      Dir.mktmpdir do |dir|
        messages, h = yolo_harness
        runner = make_tool_runner(dir, {}, harness: h)
        drive_dialog([])
        runner.run('echo yolo')
        expect(messages.any? { |m| m.include?('auto-approved (YOLO): echo yolo') })
          .to be true
      end
    end

    it 'does NOT cover bang syntax (list: :shell ignores the YOLO posture)' do
      Dir.mktmpdir do |dir|
        _, h = yolo_harness
        # The bang runner keeps asking even while YOLO is on - its consent
        # is controlled by the separate bang_requires_confirmation key.
        # BANG_TITLE + list: :shell - a real bang-path runner, just with
        # the YOLO harness attached (which it must ignore).
        runner, out = make_main_runner(dir, '2', harness: h,
                                       title_fmt: described_class::BANG_TITLE)
        result = runner.run('echo bang')
        expect(out.string).to include('Run shell command:')
        expect(result).to start_with('exit code: 0')
      end
    end

    it 'the disaster denylist overrides a stored allowlist grant AND YOLO' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'rm -rf')
        _, h = yolo_harness
        runner = make_tool_runner(dir, {}, harness: h)
        # Denylist wins: the dialog DOES open (Cancel = option 2 - a
        # denylisted command gets no "Always allow" options).
        out = drive_dialog(['2'])
        result = runner.run('rm -rf /somewhere')
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('DENYLISTED: recursive-force delete')
        expect(out.string).not_to include("Always allow '")
      end
    end

    it 'the disaster denylist overrides the AUTO-APPROVE model verdict' do
      Dir.mktmpdir do |dir|
        client = fake_client('safe: definitely fine')
        h = double('harness', yolo?: false, logger: nil, client: client,
                   session: double('session', messages: chain_mid_tool_loop),
                   command_safety_auto_approve_effective?: true)
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        out = drive_dialog(['2']) # Cancel (Allow=1, Cancel=2: no grants offered)
        result = runner.run('sudo rm something')
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('DENYLISTED: sudo')
      end
    end
    # Same command and posture as above, the other half of it (issue #382): the
    # verdict the posture could not act on is still shown, so it can be judged
    # against a disaster-shaped command.
    it 'shows the AUTO-APPROVE verdict on the denylist dialog it cannot clear' do
      Dir.mktmpdir do |dir|
        client = fake_client('1: dangerous: escalates privileges')
        h = double('harness', yolo?: false, logger: nil, client: client,
                   session: double('session', messages: chain_mid_tool_loop),
                   command_safety_auto_approve_effective?: true)
        runner = make_tool_runner(dir, { command_safety_check: true }, harness: h)
        out = drive_dialog(['2']) # Cancel (Allow=1, Cancel=2: no grants offered)
        result = runner.run('sudo rm something')
        expect(result).to start_with('error: user denied')
        expect(out.string).not_to include('auto-approved')
        expect(out.string).to include('DENYLISTED: sudo')
        expect(out.string)
          .to include('MODEL VERDICT (advisory): dangerous: escalates privileges')
      end
    end

  end

  # issue #221: bang confirmation OFF (config bang_requires_confirmation:
  # false) is passed to the runner as auto_approve_all - a user-typed bang
  # command runs immediately, no dialog. The denylist still gates it.
  context 'bang consent off (issue #221)' do
    it 'runs every bang command without a dialog' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, auto_approve_all: true)
        result = runner.run('echo typed') # nothing typed - no dialog
        expect(result).to start_with('exit code: 0')
        expect(out.string).to include('auto-approved (bang consent off)')
      end
    end

    it 'still asks for a denylisted bang command' do
      Dir.mktmpdir do |dir|
        runner, out = make_main_runner(dir, '2', auto_approve_all: true)
        result = runner.run('rm -rf /somewhere')
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('DENYLISTED')
      end
    end
  end

  # issue #389: command_safety_denylist_safe_approve - the owner's config-only
  # opt-in to let a model "safe:" verdict decide even a DENYLISTED command, so a
  # disaster word inert inside a quoted string stops costing a one-off Allow. The
  # floor stays absolute with the option off; the override fires ONLY on the tool
  # path, ONLY on a real "safe:" verdict, and is logged with the verdict that
  # allowed it. Rationale + the quote-hole measurement: doc/denylist_safe_approve_design.md.
  context 'denylist safe-override (issue #389)' do
    # Denylisted (sudo) but wholly inert: safe to execute under an override.
    let(:inert_denied) { 'echo "sudo rm /data"' }

    # A harness stand-in with a recording logger (the audit trail is the whole
    # point of an override: a denylist match ran with no dialog).
    def override_harness
      logged = []
      logger = double('logger')
      allow(logger).to receive(:info) { |m| logged << m }
      allow(logger).to receive(:warn) { |m| logged << m }
      [logged, double('harness', yolo?: false, logger: logger)]
    end

    # The verdict is INJECTED as a batch pre-check result (options[:safety_verdicts])
    # so no client and no LLM call is involved - this spec is about the firing
    # conditions, not about SafetyCheck.
    def override_options(verdict)
      {
        command_safety_check: true,
        command_safety_denylist_safe_approve: true,
        safety_verdicts: { inert_denied => verdict }
      }
    end

    it 'auto-approves a denylist match on a "safe:" verdict, tool path' do
      Dir.mktmpdir do |dir|
        logged, h = override_harness
        runner = make_tool_runner(dir, override_options('safe: inert quoted data'), harness: h)
        out = drive_dialog([]) # the dialog must NEVER open
        result = runner.run(inert_denied)

        expect(result).to start_with('exit code: 0')
        expect(out.string).not_to include('The model is requesting')
        expect(logged.any? { |m| m.include?('denylist safe-override') }).to be true
        expect(logged.any? { |m| m.include?('command_safety_denylist_safe_approve') }).to be true
        # The log names the verdict that allowed it - the whole audit answer.
        expect(logged.any? { |m| m.include?('safe: inert quoted data') }).to be true
      end
    end

    it 'keeps the floor for a "dangerous:" verdict' do
      Dir.mktmpdir do |dir|
        _, h = override_harness
        runner = make_tool_runner(dir, override_options('dangerous: executes the payload'), harness: h)
        out = drive_dialog(['2']) # Cancel (Allow=1, Cancel=2: no grants offered)
        result = runner.run(inert_denied)
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('DENYLISTED: sudo')
      end
    end

    it 'keeps the floor when there is no verdict' do
      Dir.mktmpdir do |dir|
        logged, h = override_harness
        # A pre-check that produced no verdict for this command: the cached
        # entry is nil, so no client is consulted and the floor stays.
        runner = make_tool_runner(dir, override_options(nil), harness: h)
        out = drive_dialog(['2'])
        result = runner.run(inert_denied)
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('DENYLISTED')
        expect(logged.any? { |m| m.include?('denylist safe-override') }).to be false
      end
    end

    it 'is OFF by default: a safe verdict does not relax the floor' do
      Dir.mktmpdir do |dir|
        _, h = override_harness
        opts = { command_safety_check: true, safety_verdicts: { inert_denied => 'safe: fine' } }
        runner = make_tool_runner(dir, opts, harness: h)
        out = drive_dialog(['2']) # Cancel: no Always-allow offered for a denylist match
        result = runner.run(inert_denied)
        expect(result).to start_with('error: user denied')
        expect(out.string).to include('DENYLISTED: sudo')
      end
    end

    it 'never covers the bang path (list: :shell), even option ON + safe' do
      Dir.mktmpdir do |dir|
        stdin  = StringIO.new('2')
        stdout = StringIO.new
        runner = described_class.new(FileList.new([], workdir: dir),
                                     override_options('safe: fine'),
                                     label: 'shell',
                                     list: :shell,
                                     ui: UI::Console.new(stdout: stdout, stdin: stdin))
        result = runner.run(inert_denied)
        expect(result).to start_with('error: user denied')
        expect(stdout.string).to include('DENYLISTED')
        expect(stdout.string).not_to include('denylist safe-override')
      end
    end
  end

  # issue #388: the dialog note kinds reach the palette. The runner states WHAT
  # each line IS (a Note kind), never a color; the console it serves the dialog
  # on decides the hue. The plain-console contract every other example in this
  # file asserts (no escape bytes) stays untouched - these use a colored drive.
  describe 'dialog note colors (issue #388)' do
    def verdict(kind)
      fake_client("#{kind}: probe verdict")
    end

    it 'paints a dangerous verdict and the DENYLISTED line as alerts' do
      Dir.mktmpdir do |dir|
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(verdict('dangerous'), chain_mid_tool_loop))
        out = drive_dialog(['2'], palette: UI::Palette.new('default'))
        expect(runner.run('sudo rm something')).to start_with('error: user denied')

        # MODEL VERDICT first, DENYLISTED second - both red, as separate runs.
        expect(out.string)
          .to include("\e[31mMODEL VERDICT (advisory): dangerous: probe verdict\e[0m")
        expect(out.string).to include("\e[31mDENYLISTED: sudo - well-known disaster")
      end
    end

    it 'paints a safe verdict green while the deterministic line stays brown' do
      Dir.mktmpdir do |dir|
        runner = make_tool_runner(dir, { command_safety_check: true },
                                  harness: harness_with(verdict('safe'), chain_mid_tool_loop))
        out = drive_dialog(['2'], palette: UI::Palette.new('default'))
        expect(runner.run('echo hi > tmpfile')).to start_with('error: user denied')

        expect(out.string)
          .to include("\e[32mMODEL VERDICT (advisory): safe: probe verdict\e[0m")
        # UNSAFE is a refusal, not the hard floor: brown (dialog_warn).
        expect(out.string).to include(
          "\e[38;5;130mUNSAFE: redirect to file (\"> tmpfile\") cannot be auto-approved\e[0m"
        )
      end
    end

    # The bytes must be the SAME dialog with the palette off: the kind decides a
    # color, so it must not be able to change the text (every other example in
    # this file asserts this plain output).
    it 'a colored drive and a plain drive print the identical text' do
      Dir.mktmpdir do |dir|
        colored = drive_dialog(['2'], palette: UI::Palette.new('default'))
        make_tool_runner(dir).run('sudo rm something')
        plain = drive_dialog(['2'])
        make_tool_runner(dir).run('sudo rm something')

        expect(plain.string).to eq(colored.string.gsub(/\e\[[0-9;]*m/, ""))
      end
    end
  end

  # issue #362: waiting on the child process leaves the task outbox quiet, so the
  # drain loop animates a spinner - and the detail it replays is the LLM request
  # line that already finished, so a long run reads as if the model were still
  # generating. The runner re-points it for the run itself.
  describe 'spinner re-point while a command runs (issue #362)' do
    let(:task) { Task.new }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    def spinner_events
      events = []
      loop do
        m = task.poll(0); break unless m
        events << m if m[:type] == :spinner_detail
      end
      events
    end

    def suffix_harness
      double('harness', logger: nil, tool_wait_suffix: -> { 'ctx 12%' })
    end

    it 'names the run on the spinner while it waits' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'echo')
        runner = make_tool_runner(dir, {}, harness: suffix_harness)
        expect(runner.run('echo hi')).to start_with('exit code: 0')

        events = spinner_events
        expect(events.size).to eq(1)
        expect(events.first[:origin]).to eq('run.command')
        expect(events.first[:content][:message]).to eq('run.command: echo hi')
        expect(events.first[:content][:suffix].call).to eq('ctx 12%')
      end
    end

    # The spinner draws ONE line and appends its own "..." to every message, so
    # the handle arrives without its dropped-tail marker: the line carries one
    # marker, not two. A full command never reaches the spinner.
    it 'shortens a long command to its handle and drops the extra marker' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'echo')
        runner = make_tool_runner(dir, {}, harness: suffix_harness)
        runner.run('echo one two three four five six')

        message = spinner_events.first[:content][:message]
        expect(message).to eq('run.command: echo one two three')
        expect(message).not_to include(' ...')
        expect(message).not_to include('four five six')
      end
    end

    # A runner built without a harness (unit specs, a bare bang call) has no
    # suffix callable to borrow - the re-point must still work.
    it 'announces without a suffix when the harness offers none' do
      Dir.mktmpdir do |dir|
        seed_allowlist(dir, 'echo')
        runner = make_tool_runner(dir) # harness: nil
        runner.run('echo bare')

        expect(spinner_events.first[:content][:suffix]).to be_nil
      end
    end
  end
end
