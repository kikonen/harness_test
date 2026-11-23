# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness do
  include HarnessSpecSupport

  describe '#precheck_batch_safety (issue #224)' do
    def run_command_calls(*commands)
      commands.each_with_index.map do |c, i|
        { id: "c#{i + 1}",
          function: { name: 'run.command',
                      arguments: JSON.dump(command: c) } }
      end
    end

    let(:harness) { build_harness(command_safety_check: true) }

    # YOLO's auto-approval branch in CommandRunner#run returns before
    # safety_verdict_for is reached, so batch verdicts produced here can only be
    # thrown away - a forked LLM round trip paid for nothing, on the prefix the
    # batch's own request just filled (#238). The skip must be logged, or a
    # session that stopped pre-checking has nothing to explain it.
    it 'is skipped in the YOLO posture, with the reason logged' do
      on = build_harness(command_safety_check: true, yolo: true)
      client = instance_double('client')
      allow(client).to receive(:chat)
      on.instance_variable_set(:@client, client)
      on.session.add_user('go')

      expect(on.precheck_batch_safety(run_command_calls('echo a', 'echo b')))
        .to be_nil
      expect(on.settings.safety_verdicts).to be_nil
      expect(client).not_to have_received(:chat)
      expect(File.read(on.session_log_path))
        .to include('safety pre-check skipped (YOLO consumes no verdicts)')
    end

    it 'is a no-op when the option is disabled' do
      off = build_harness(command_safety_check: false)
      expect(off.precheck_batch_safety(run_command_calls('a', 'b')))
        .to be_nil
    end

    it 'is a no-op for a batch with fewer than two run.command calls' do
      expect(harness.precheck_batch_safety(run_command_calls('echo hi')))
        .to be_nil
      expect(harness.settings.safety_verdicts).to be_nil
    end

    it 'caches {command => verdict} in options when the batch has two or more' do
      client = instance_double('client')
      allow(client).to receive(:chat)
        .and_return({ choices: [{ message: { content:
          "safe: syntax check\nsafe: writes to tmp only" } }], usage: {} })
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      verdicts = harness.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'))

      expect(verdicts).to eq('ruby -c lib/a.rb' => 'safe: syntax check',
                             'bundle exec rspec' => 'safe: writes to tmp only')
      expect(harness.settings.safety_verdicts).to eq(verdicts)
    end

    # issue #344: the batch consumer binds by the number the model wrote, so an
    # out-of-order answer is still correct - and an answer that cannot be placed
    # caches NO verdicts (the runner then opens the dialog) instead of a shifted
    # set. The drop itself goes to harness.log.
    it 'binds batch verdicts by number, and caches none when the answer cannot be placed' do
      numbered = instance_double('client')
      allow(numbered).to receive(:chat).and_return({ choices: [{ message: { content:
        "2: dangerous: drops the table\n1: safe: syntax check" } }], usage: {} })
      harness.instance_variable_set(:@client, numbered)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(run_command_calls('ruby -c a.rb', 'DROP TABLE x')))
        .to eq('ruby -c a.rb' => 'safe: syntax check', 'DROP TABLE x' => 'dangerous: drops the table')

      shifted = instance_double('client')
      allow(shifted).to receive(:chat).and_return({ choices: [{ message: { content:
        "Here are my verdicts:\nsafe: syntax check\ndangerous: drops the table" } }], usage: {} })
      harness.instance_variable_set(:@client, shifted)

      expect(harness.precheck_batch_safety(run_command_calls('ruby -c a.rb', 'DROP TABLE x')))
        .to eq('ruby -c a.rb' => nil, 'DROP TABLE x' => nil)
      expect(File.read(harness.session_log_path))
        .to include('safety check: line "Here are my verdicts:" carries no ' \
                    'safe:/dangerous: shape; 2 unnumbered verdict line(s) cannot be placed')
    end

    it 'sends one check request with the live tool payload, forked from the chain' do
      client = instance_double('client')
      captured = []
      allow(client).to receive(:chat) do |chain, tools: nil, timeout: nil|
        captured << { chain: chain, tools: tools, timeout: timeout }
        { choices: [{ message: { content: "safe\nsafe" } }], usage: {} }
      end
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      harness.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'))

      expect(captured.size).to eq(1)
      # #246: the fork carries the SAME tool definitions the live turn sends
      # (Harness#tools_payload -> the live turn's own payload), because a chat
      # template renders them into the prompt - omitting them makes the fork a
      # different prompt, not a longer one. doc/compaction_cache_design.md.
      expect(captured[0][:tools]).to eq(harness.tools_payload)
      expect(captured[0][:tools]).not_to be_empty
      expect(captured[0][:timeout]).to eq(SafetyCheck::DEFAULT_TIMEOUT)
      forked = captured[0][:chain]
      expect(forked.map { |m| m[:role] }).to eq(%w[system user user])
      expect(forked.last[:content]).to include('1. ruby -c lib/a.rb')
      expect(forked.last[:content]).to include('2. bundle exec rspec')
    end

    it 'returns nil (no verdicts) when the check call fails' do
      client = instance_double('client')
      allow(client).to receive(:chat).and_raise(LLMError, 'offline')
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(
               run_command_calls('a', 'b'))).to be_nil
      expect(harness.settings.safety_verdicts).to be_nil
    end

    # issue #241: allowlisted commands never reach a consent dialog (the
    # runner auto-approves them), so the model must not be asked about
    # them - only the unapproved commands are checked.
    def allowlist(*prefixes)
      FileUtils.mkdir_p(File.join(workdir, '.harness'))
      File.write(File.join(workdir, '.harness', 'allowed_commands.yml'),
                 YAML.dump(prefixes))
    end

    it 'skips allowlisted commands - only the unapproved ones are checked' do
      allowlist('ruby')
      client = instance_double('client')
      captured = []
      allow(client).to receive(:chat) do |chain, **|
        captured << chain
        { choices: [{ message: { content: "safe: tests\nsafe: git only" } }], usage: {} }
      end
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      verdicts = harness.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec', 'git status'))

      expect(verdicts).to eq('bundle exec rspec' => 'safe: tests',
                             'git status' => 'safe: git only')
      expect(captured.size).to eq(1)
      expect(captured.first.last[:content]).to include('1. bundle exec rspec')
      expect(captured.first.last[:content]).to include('2. git status')
      expect(captured.first.last[:content]).not_to include('ruby -c lib/a.rb')
    end

    it 'makes no model call when every command in the batch is allowlisted' do
      allowlist('ruby', 'bundle exec rspec')
      client = instance_double('client')
      allow(client).to receive(:chat)
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(
               run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'))).to be_nil
      expect(client).not_to have_received(:chat)
    end

    it 'makes no batch call when only one command is left after filtering' do
      allowlist('ruby')
      client = instance_double('client')
      allow(client).to receive(:chat)
      harness.instance_variable_set(:@client, client)
      harness.session.add_user('go')

      expect(harness.precheck_batch_safety(
               run_command_calls('ruby -c lib/a.rb', 'ruby -c lib/b.rb',
                                 'bundle exec rspec'))).to be_nil
      expect(client).not_to have_received(:chat)
    end

    # issue #332's candidate: a run.command whose arguments were cut mid-JSON
    # used to parse to {}, so the command vanished and a batch of two truncated
    # calls was safety pre-checked as ZERO commands. The skip must be visible.
    it 'logs a run.command whose arguments did not parse instead of dropping it' do
      calls = run_command_calls('ruby -c a.rb', 'rm -rf /tmp/x')
      calls[1][:function][:arguments] = '{"command":"rm -rf /tmp'

      expect(harness.run_command_batch_commands(calls)).to eq(['ruby -c a.rb'])
      expect(File.read(harness.session_log_path))
        .to include('run.command arguments did not parse')
    end

    # The whole point of the fix: a call whose arguments lost their shape must
    # not read as a malformed call when the request that made it was cut.
    it 'pre-checks a batch normally when every call parsed' do
      expect(harness.run_command_batch_commands(run_command_calls('a', 'b'))).to eq(%w[a b])
    end

    it 'an empty or missing arguments payload is not a parse error' do
      calls = [run_command_calls('a')[0], { id: 'c2', function: { name: 'run.command', id: 'run.command' } }]

      expect(harness.run_command_batch_commands(calls)).to eq(['a'])
      expect(File.read(harness.session_log_path)).not_to include('did not parse')
    end
  end

  # issue #28: the streaming posture. It decides whether a request's response
  # is consumed chunk by chunk, so it is harness state (like YOLO), not
  # conversation state - and it is read PER REQUEST, so /stream takes effect
  # on the next request of the same turn.
end

