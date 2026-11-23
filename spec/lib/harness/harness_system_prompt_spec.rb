# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'system prompt and async job self-save (issues #223, #341)' do
  include HarnessSpecSupport

  describe '#request_save (async job self-save)' do
    let(:harness) { build_harness_with_responses }

    def counted_saves(harness)
      sm   = harness.session_manager
      hits = 0
      allow(sm).to receive(:save_job_session).and_wrap_original do |orig|
        hits += 1
        orig.call
      end
      [sm, -> { hits }]
    end

    it 'flags a pending save on request and clears it after consumption' do
      harness.session.add_user('prompt')
      expect(harness.save_requested?).to be(false)

      harness.request_save
      expect(harness.save_requested?).to be(true)

      harness.call_llm # the flag is consumed at the iteration top
      expect(harness.save_requested?).to be(false)
    end

    it 'persists the agent own chain when the request is consumed' do
      harness.session.add_user('prompt')
      _sm, hits = counted_saves(harness)

      harness.request_save
      harness.call_llm

      expect(hits.call).to eq(1)
    end

    it 'does not save when no request was posted (no idle churn)' do
      harness.session.add_user('prompt')

      harness.call_llm

      expect(harness.save_requested?).to be(false)
    end
  end


  describe '#read_system_prompt (issue #223)' do
    it 'reads the built-in default file when no system_file option is set' do
      harness = build_harness(system_file: nil)

      expect(harness.send(:read_system_prompt))
        .to eq(File.read(Harness::DEFAULT_SYSTEM_PROMPT_FILE))
    end

    # issue #342: a prompt file is the first message of every chain, so it is a
    # read boundary. The assertion that catches the CLASS is the chain-level one
    # below it - a prompt-encoding assertion alone would still pass if the bad
    # string were rebuilt somewhere else.
    it 'normalizes a configured system_file whose bytes are not valid UTF-8' do
      path = File.join(workdir, 'sys.txt')
      File.binwrite(path, "You are a caf\xe9 helper\n")
      harness = build_harness(system_file: path)

      prompt = harness.send(:read_system_prompt)
      expect(prompt.valid_encoding?).to be(true)
      expect(harness.session.system_prompt.valid_encoding?).to be(true)
    end

    it 'keeps the session chain JSON-serializable after a damaged prompt file' do
      path = File.join(workdir, 'sys.txt')
      File.binwrite(path, "You are a caf\xe9 helper\n")
      harness = build_harness(system_file: path)
      harness.session.add_user('go')

      # JSON.generate is both the request body and the session save: this is
      # where the unnormalized read used to raise (JSON::GeneratorError).
      expect { JSON.generate(harness.session.messages) }.not_to raise_error
    end

    it 'reads the configured system_file when it exists' do
      path = File.join(workdir, 'my_prompt.txt')
      File.write(path, "custom prompt #{path}")
      harness = build_harness(system_file: path)

      expect(harness.send(:read_system_prompt)).to eq("custom prompt #{path}")
    end

    it 'falls back to the built-in default when the configured file is missing' do
      harness = build_harness(system_file: File.join(workdir, 'does_not_exist.txt'))

      expect(harness.send(:read_system_prompt))
        .to eq(File.read(Harness::DEFAULT_SYSTEM_PROMPT_FILE))
    end
  end

  # issue #341: harness.md is the file the harness is INVITED to edit, so a bad
  # byte is ordinary work, not an exotic input. Its content is the tail of the
  # FIRST message of every chain, so this read is a boundary too.
  describe '#build_system_prompt (issue #341)' do
    def damaged_rules(dir)
      File.binwrite(File.join(dir, 'harness.md'), "rule caf\xe9 keep 90 cols\n")
    end

    it 'builds a valid-UTF-8 prompt from a harness.md carrying an invalid byte' do
      damaged_rules(workdir)
      harness = build_harness
      prompt  = harness.session.system_prompt

      expect(prompt.valid_encoding?).to be(true)
      expect(prompt).to include('## Project-Specific Rules')
      # Asserted ON BYTES (the #318 rule): the undecodable one is the replacement.
      expect(prompt).to include('rule caf? keep 90 cols')
    end

    it 'names what it replaced, so the repair is not silent' do
      damaged_rules(workdir)
      harness = build_harness

      expect(harness.rules_repair_note)
        .to eq('1 invalid byte replaced - harness.md is not valid UTF-8')
    end

    it 'reports no repair for a clean harness.md' do
      File.write(File.join(workdir, 'harness.md'), "rule keep 90 cols\n")
      harness = build_harness

      expect(harness.rules_repair_note).to be_nil
      expect(harness.session.system_prompt).to include('rule keep 90 cols')
    end

    # The mid-session shape the issue calls WORSE: the file goes bad while the run
    # is live, so the failure surfaced on the NEXT prompt (run_prompt calls
    # check_rules_reload). utime keeps the mtime change deterministic.
    it 'survives a harness.md that turned invalid mid-session (reload path)' do
      File.write(File.join(workdir, 'harness.md'), "rule one\n")
      harness = build_harness
      damaged_rules(workdir)
      past = Time.now - 120
      File.utime(past, past, File.join(workdir, 'harness.md'))

      expect { harness.session_manager.check_rules_reload }.not_to raise_error
      expect(harness.session.system_prompt.valid_encoding?).to be(true)
      expect(harness.session.system_prompt).to include('rule caf? keep 90 cols')
      expect(harness.rules_repair_note).to include('1 invalid byte')
    end
  end

  describe '#format_elapsed (issue #226)' do
    it 'returns seconds with 2dp when under 60s' do
      expect(build_harness.format_elapsed(42.37)).to eq('42.37s')
    end

    it 'returns a bare integer seconds value' do
      expect(build_harness.format_elapsed(5)).to eq('5.0s')
    end

    it 'returns minutes + seconds (comma decimal) at 60s and above' do
      expect(build_harness.format_elapsed(60.0)).to eq('1m 00,00s')
    end

    it 'handles the canonical 5099.17s from issue #226' do
      expect(build_harness.format_elapsed(5099.17)).to eq('84m 59,17s')
    end

    it 'rounds the sub-minute remainder to 2dp' do
      expect(build_harness.format_elapsed(61.004)).to eq('1m 01,00s')
    end
  end

  describe '#max_tool_iterations (issue #226)' do
    it 'defaults to 200 when the option is not set' do
      expect(build_harness.max_tool_iterations).to eq(200)
    end

    it 'reads from options when set' do
      expect(build_harness(max_tool_iterations: 50).max_tool_iterations).to eq(50)
    end

    it 'raises ToolLoopError once the configurable limit is exceeded' do
      # The scripted client plays endless tool rounds; with a limit of 2 the
      # loop is aborted before the third iteration.
      rounds = [
        { content: nil, tool_calls: [{ id: 'c1', function: { name: 'test.echo', arguments: '{"text":"a"}' } }] },
        { content: nil, tool_calls: [{ id: 'c2', function: { name: 'test.echo', arguments: '{"text":"b"}' } }] },
        { content: nil, tool_calls: [{ id: 'c3', function: { name: 'test.echo', arguments: '{"text":"c"}' } }] }
      ]
      harness = build_harness_with_responses(rounds, max_tool_iterations: 2)

      expect { harness.call_llm }.to raise_error(ToolLoopError, /exceeded max tool iterations \(2\)/)
    end
  end

  # issue #303: the rendered-output palette is resolved once, at construction,
  # so the drain loop never re-resolves a name per line.
end

