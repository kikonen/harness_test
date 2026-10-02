# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'spec_helper'
require 'harness'

# Display-layer coverage for issue #63: the context indicator (shown above
# the prompt and in the per-response stats) and the /ctx report. Both are
# pure instance methods, so a real Harness instance is enough - no network.
RSpec.describe Harness do
  # Use a temp workdir so building the Harness (which creates .harness/)
  # does not pollute the project root.
  let(:workdir) { Dir.mktmpdir('harness-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  def build_harness(options = {})
    file_list = FileList.new([], workdir: workdir)
    opts      = { system: 'system prompt', num_ctx: 65_536 }.merge(options)
    described_class.new(opts, file_list)
  end

  # Capture everything written to $stdout while the block runs.
  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  def seed_usage(harness, prompt_tokens)
    harness.session.add_user('hello')
    harness.session.add_assistant('hi')
    harness.session.record_stats(usage: { prompt_tokens: prompt_tokens, total_tokens: prompt_tokens + 867 })
  end

  describe '#context_indicator' do
    it 'is nil when there is no conversation yet' do
      expect(build_harness.context_indicator).to be_nil
    end

    it 'shows exact usage from the last response' do
      harness = build_harness
      seed_usage(harness, 42_133)

      expect(harness.context_indicator).to eq('🧠 ctx 42133/65536 (64%)')
    end

    it 'marks estimates with ~' do
      harness = build_harness
      harness.session.add_user('a' * 160) # ~40 tokens at 4 chars/token (estimate)

      expect(harness.context_indicator).to include('~')
    end

    it 'respects a custom context window from options' do
      harness = build_harness(num_ctx: 10_000)
      seed_usage(harness, 5_000)

      expect(harness.context_indicator).to eq('🧠 ctx 5000/10000 (50%)')
    end
  end

  describe '#context_indicator_live (issue #126)' do
    it 'is nil when there is no conversation yet' do
      expect(build_harness.context_indicator_live).to be_nil
    end

    it 'shows EXACT usage (no ~) when the last response reported it' do
      harness = build_harness
      seed_usage(harness, 5_915)

      expect(harness.context_indicator_live).to eq('🧠 ctx 5915/65536 (9%)')
    end

    it 'marks estimates with ~ when no usage was reported yet' do
      harness = build_harness
      harness.session.add_user('a' * 160)

      expect(harness.context_indicator_live).to include('~')
    end

    it 'always estimates an explicit chain (mid-turn / in-loop compaction)' do
      harness = build_harness
      seed_usage(harness, 5_915)
      chain = [{ role: 'user', content: 'a' * 400 }]

      expect(harness.context_indicator_live(chain)).to include('~')
    end
  end

  describe '#context_report' do
    it 'reports "nothing to measure" for an empty session' do
      expect(build_harness.context_report)
        .to eq('No conversation yet - nothing to measure.')
    end

    it 'shows usage, headroom and auto-compact status' do
      harness = build_harness
      seed_usage(harness, 42_133)

      report = harness.context_report

      expect(report).to include('42133 tokens (64% of 65536)')
      expect(report).to include('Headroom:    23403 tokens')
      expect(report).to include('last LLM response')
      expect(report).to include('not due (threshold 88%)')
    end

    it 'flags auto-compact as due when the threshold is exceeded' do
      harness = build_harness
      seed_usage(harness, 60_000)

      expect(harness.context_report).to include('due (threshold 88%)')
    end
  end

  describe '#session_log_path (issue #113)' do
    it 'resolves to .harness/sessions/<session-id>/harness.log' do
      harness = build_harness

      expected = File.join(workdir, Harness::HARNESS_DIR,
                           'sessions', harness.session.session_id,
                           Harness::SESSION_LOG_FILE)
      expect(harness.session_log_path).to eq(expected)
    end

    it 'creates the log file at the per-session path on first use' do
      harness = build_harness

      # The logger is deferred (issue #123): touching it creates the file.
      expect { harness.logger }.to change { File.file?(harness.session_log_path) }.from(false).to(true)
    end

    it 'does not write to the legacy shared .harness/harness.log' do
      harness = build_harness
      harness.logger # force creation via the lazy accessor

      expect(File.exist?(File.join(workdir, Harness::HARNESS_DIR, 'harness.log'))).to be false
    end
  end

  describe '#initialize logger deferral (issue #123)' do
    it 'does NOT create a log directory for the fresh random id' do
      harness = build_harness

      expect(harness.instance_variable_get(:@logger)).to be_nil
      expect(File.directory?(File.dirname(harness.session_log_path))).to be false
    end

    it 'creates no session dir at all when nothing logs before a resume' do
      build_harness

      sessions_dir = File.join(workdir, Harness::HARNESS_DIR, 'sessions')
      expect(Dir.exist?(sessions_dir) ? Dir.children(sessions_dir) : []).to be_empty
    end
  end

  describe '#rebind_logger (issue #113 / #123)' do
    it 'points the logger at the CURRENT session id after a resume swaps it in' do
      harness = build_harness
      resumed_id = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'

      # Simulate resume: the session id changes but the logger was still
      # bound to the fresh id created at startup (or not created at all).
      harness.session.instance_variable_set(:@session_id, resumed_id)

      expect(harness.session_log_path).to include(resumed_id)

      new_logger = harness.rebind_logger

      expect(new_logger).to be_a(Logger)
      expect(File.file?(File.join(workdir, Harness::HARNESS_DIR, 'sessions', resumed_id, 'harness.log'))).to be true
    end

    it 'closes the old logger when re-binding after a late id change' do
      harness = build_harness
      fresh_id = harness.session.session_id
      harness.logger # force creation for the fresh id

      old_logger = harness.instance_variable_get(:@logger)
      expect(old_logger).not_to be_nil

      harness.session.instance_variable_set(:@session_id, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      harness.rebind_logger

      expect(harness.instance_variable_get(:@logger)).not_to equal(old_logger)
    end

    it 're-points the LLM client so HTTP logging follows the new session' do
      harness = build_harness

      harness.session.instance_variable_set(:@session_id, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      harness.rebind_logger

      expect(harness.client.instance_variable_get(:@logger)).to equal(harness.logger)
    end
  end

  describe '#print_step_display (issue #131)' do
    let(:harness) { build_harness }

    let(:message) do
      {
        reasoning: 'First I will inspect the spinner, then run the specs.',
        tool_calls: [
          { id: 'c1', function: { name: 'file.read', arguments: '{"path":"lib/ui/spinner.rb"}' } },
          { id: 'c2', function: { name: 'run.command', arguments: '{"command":"bundle exec rspec"}' } }
        ]
      }
    end

    it 'prints the step number, a digest of the reasoning and the tools called' do
      out = capture_stdout { harness.send(:print_step_display, 3, message) }

      expect(out).to include('[step 3]')
      expect(out).to include('>>> First I will inspect the spinner, then run the specs. <<<')
      expect(out).to include('-> file.read, run.command')
    end

    it 'falls back to message content when there is no reasoning' do
      msg = { reasoning: nil, content: 'checking the test suite', tool_calls: [{ id: 'c1', function: { name: 'run.command' } }] }

      out = capture_stdout { harness.send(:print_step_display, 2, msg) }

      expect(out).to include('[step 2]')
      expect(out).to include('||| checking the test suite |||')
      expect(out).to include('-> run.command')
    end

    it 'prints only the tool line when there is no reasoning text at all' do
      msg = { reasoning: nil, content: nil, tool_calls: [{ id: 'c1', function: { name: 'file.search' } }] }

      out = capture_stdout { harness.send(:print_step_display, 4, msg) }

      expect(out).to include('[step 4]')
      expect(out).to include("    -> file.search\n")
    end

    it 'prints nothing when disabled via HARNESS_STEP_DISPLAY=off' do
      original = ENV['HARNESS_STEP_DISPLAY']
      ENV['HARNESS_STEP_DISPLAY'] = 'off'

      begin
        out = capture_stdout { harness.send(:print_step_display, 1, message) }

        expect(out).to be_empty
      ensure
        ENV['HARNESS_STEP_DISPLAY'] = original
      end
    end
  end
end
