# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'spec_helper'
require 'file_list'
require 'system_settings'
require 'tool_registry'
require 'session'
require 'session_file_cache'
require 'session_logger'
require 'session_locator'
require 'result_spill'
require 'model_config'
require 'tool_call_runner'
require 'tool_call_ports'
require 'safety_check'

# The batch safety pre-check, tested at the ToolCallRunner seam (issue #582):
# the fixture supplies the ports, no Harness is built.
RSpec.describe ToolCallRunner do
  def build_fixture(options = {})
    workdir = Dir.mktmpdir('precheck-spec')
    (@workdirs ||= []) << workdir
    log_path = File.join(workdir, ".harness", "sessions", "spec", "harness.log")
    FileUtils.mkdir_p(File.dirname(log_path))
    logger   = SessionLogger.build(log_path)
    settings = SystemSettings.from_options(options)
    registry = ToolRegistry.new
    session  = Session.new("system prompt", file_cache: SessionFileCache.new)
    spill    = ResultSpill.new(SessionLocator.new(workdir, session_id: "spec"), job_id: 0)
    flist    = FileList.new([], workdir: workdir)
    fixture  = Struct.new(:workdir, :log_path, :settings, :session, :client,
                          :tool_registry).new(workdir, log_path, settings, session, nil, registry)
    ports = ToolCallPorts.new(
      logger: logger,
      settings: settings,
      tool_registry: registry,
      session: session,
      model_config: ModelConfig.new(options),
      file_list: flist,
      spill_reader: nil,
      result_spill: -> { spill },
      text_tool_call_parser: nil,
      tool_wait_suffix: -> { nil },
      client: -> { fixture.client }
    )
    [fixture, ports]
  end

  after do
    Array(@workdirs).each { |d| FileUtils.remove_entry(d) if File.directory?(d) }
  end

  let(:precheck_fixture) { build_fixture(command_safety_check: true) }
  let(:runner) { ToolCallRunner.new }

  describe '#precheck_batch_safety (issue #224)' do
    def run_command_calls(*commands)
      commands.each_with_index.map do |c, i|
        { id: "c#{i + 1}",
          function: { name: 'run.command',
                      arguments: JSON.dump(command: c) } }
      end
    end

    let(:fixture) { precheck_fixture[0] }
    let(:ports) { precheck_fixture[1] }
    let(:harness) { fixture }

    # YOLO's auto-approval branch in CommandRunner#run returns before
    # safety_verdict_for is reached, so batch verdicts produced here can only be
    # thrown away - a forked LLM round trip paid for nothing, on the prefix the
    # batch's own request just filled (#238). The skip must be logged, or a
    # session that stopped pre-checking has nothing to explain it.
    it 'is skipped in the YOLO posture, with the reason logged' do
      on, on_ports = build_fixture(command_safety_check: true, yolo: true)
      client = instance_double('client')
      allow(client).to receive(:chat)
      on.client = client
      on.session.add_user('go')

      expect(ToolCallRunner.new.precheck_batch_safety(run_command_calls('echo a', 'echo b'), on_ports))
        .to be_nil
      expect(on.settings.safety_verdicts).to be_nil
      expect(client).not_to have_received(:chat)
      expect(File.read(on.log_path))
        .to include('safety pre-check skipped (YOLO consumes no verdicts)')
    end

    it 'is a no-op when the option is disabled' do
      _, off_ports = build_fixture(command_safety_check: false)
      expect(ToolCallRunner.new.precheck_batch_safety(run_command_calls('a', 'b'), off_ports))
        .to be_nil
    end

    it 'is a no-op for a batch with fewer than two run.command calls' do
      expect(runner.precheck_batch_safety(run_command_calls('echo hi'), ports))
        .to be_nil
      expect(fixture.settings.safety_verdicts).to be_nil
    end

    it 'caches {command => verdict} in options when the batch has two or more' do
      client = instance_double('client')
      allow(client).to receive(:chat)
        .and_return({ choices: [{ message: { content:
          "safe: syntax check\nsafe: writes to tmp only" } }], usage: {} })

      fixture.client = client
      fixture.session.add_user('go')

      verdicts = runner.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'), ports)

      expect(verdicts).to eq('ruby -c lib/a.rb' => 'safe: syntax check',
                             'bundle exec rspec' => 'safe: writes to tmp only')
      expect(fixture.settings.safety_verdicts).to eq(verdicts)
    end

    # issue #344: the batch consumer binds by the number the model wrote, so an
    # out-of-order answer is still correct - and an answer that cannot be placed
    # caches NO verdicts (the runner then opens the dialog) instead of a shifted
    # set. The drop itself goes to harness.log.
    it 'binds batch verdicts by number, and caches none when the answer cannot be placed' do
      numbered = instance_double('client')
      allow(numbered).to receive(:chat).and_return({ choices: [{ message: { content:
        "2: dangerous: drops the table\n1: safe: syntax check" } }], usage: {} })

      fixture.client = numbered
      fixture.session.add_user('go')

      expect(runner.precheck_batch_safety(run_command_calls('ruby -c a.rb', 'DROP TABLE x'), ports))
        .to eq('ruby -c a.rb' => 'safe: syntax check', 'DROP TABLE x' => 'dangerous: drops the table')

      shifted = instance_double('client')
      allow(shifted).to receive(:chat).and_return({ choices: [{ message: { content:
        "Here are my verdicts:\nsafe: syntax check\ndangerous: drops the table" } }], usage: {} })
      fixture.client = shifted

      expect(runner.precheck_batch_safety(run_command_calls('ruby -c a.rb', 'DROP TABLE x'), ports))
        .to eq('ruby -c a.rb' => nil, 'DROP TABLE x' => nil)
      expect(File.read(fixture.log_path))
        .to include('safety check: line "Here are my verdicts:" carries no ' \
                    'safe:/dangerous: shape; 2 unnumbered verdict line(s) cannot be placed')
    end

    it 'sends one check request with the live tool payload, forked from the chain' do
      ports.tool_registry.register(
        Tool.new(name: "test.echo", description: "echo", parameters: {})
      )
      client = instance_double('client')
      captured = []
      allow(client).to receive(:chat) do |chain, tools: nil, timeout: nil|
        captured << { chain: chain, tools: tools, timeout: timeout }
        { choices: [{ message: { content: "safe\nsafe" } }], usage: {} }
      end

      fixture.client = client
      fixture.session.add_user('go')

      runner.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'), ports)

      expect(captured.size).to eq(1)
      # #246: the fork carries the SAME tool definitions the live turn sends
      # (Harness#tools_payload -> the live turn's own payload), because a chat
      # template renders them into the prompt - omitting them makes the fork a
      # different prompt, not a longer one. doc/compaction_cache_design.md.
      expect(captured[0][:tools]).to eq(ports.tool_registry.to_openai)
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

      fixture.client = client
      fixture.session.add_user('go')

      expect(runner.precheck_batch_safety(
               run_command_calls('a', 'b'), ports)).to be_nil
      expect(fixture.settings.safety_verdicts).to be_nil
    end

    # issue #241: allowlisted commands never reach a consent dialog (the
    # runner auto-approves them), so the model must not be asked about
    # them - only the unapproved commands are checked.
    def allowlist(*prefixes)
      FileUtils.mkdir_p(File.join(fixture.workdir, '.harness'))
      File.write(File.join(fixture.workdir, '.harness', 'allowed_commands.yml'),
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

      fixture.client = client
      fixture.session.add_user('go')

      verdicts = runner.precheck_batch_safety(
        run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec', 'git status'), ports)

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

      fixture.client = client
      fixture.session.add_user('go')

      expect(runner.precheck_batch_safety(
               run_command_calls('ruby -c lib/a.rb', 'bundle exec rspec'), ports)).to be_nil
      expect(client).not_to have_received(:chat)
    end

    it 'makes no batch call when only one command is left after filtering' do
      allowlist('ruby')
      client = instance_double('client')
      allow(client).to receive(:chat)

      fixture.client = client
      fixture.session.add_user('go')

      expect(runner.precheck_batch_safety(
               run_command_calls('ruby -c lib/a.rb', 'ruby -c lib/b.rb',
                                 'bundle exec rspec'), ports)).to be_nil
      expect(client).not_to have_received(:chat)
    end

    # issue #332's candidate: a run.command whose arguments were cut mid-JSON
    # used to parse to {}, so the command vanished and a batch of two truncated
    # calls was safety pre-checked as ZERO commands. The skip must be visible.
    it 'logs a run.command whose arguments did not parse instead of dropping it' do
      calls = run_command_calls('ruby -c a.rb', 'rm -rf /tmp/x')
      calls[1][:function][:arguments] = '{"command":"rm -rf /tmp'

      expect(runner.send(:batch_run_commands, calls, ports)).to eq(['ruby -c a.rb'])
      expect(File.read(fixture.log_path))
        .to include('run.command arguments did not parse')
    end

    # The whole point of the fix: a call whose arguments lost their shape must
    # not read as a malformed call when the request that made it was cut.
    it 'pre-checks a batch normally when every call parsed' do
      expect(runner.send(:batch_run_commands, run_command_calls('a', 'b'), ports)).to eq(%w[a b])
    end

    it 'an empty or missing arguments payload is not a parse error' do
      calls = [run_command_calls('a')[0], { id: 'c2', function: { name: 'run.command', id: 'run.command' } }]

      expect(runner.send(:batch_run_commands, calls, ports)).to eq(['a'])
      expect(File.read(fixture.log_path)).not_to include('did not parse')
    end
  end
end
