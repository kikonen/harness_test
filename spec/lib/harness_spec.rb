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
end
