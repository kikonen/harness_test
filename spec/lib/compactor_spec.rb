# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'compactor'
require 'job_registry'
require 'system_settings'

# A Task always runs on a registry + job (#286); an un-started one is enough to
# capture Task.emit events. Build the smallest real registry.
def compactor_emit_task
  registry = JobRegistry.new
  Task.new(registry:, job: registry.add_job(kind: :main))
end

RSpec.describe Compactor do
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }
  let(:max_words) { SystemSettings::DEFAULT_COMPACT_MAX_SIZE }
  let(:tools_payload) { [{ type: 'function', function: { name: 'test.echo', id: 'test.echo' } }] }
  let(:client) { double('client') }
  let(:chain) do
    [{ role: 'system', content: 'system prompt' }] +
      (0...4).flat_map { |i| [{ role: 'user', content: "msg #{i}" },
                              { role: 'assistant', content: "reply #{i}" }] }
  end
  let(:compactor) do
    described_class.new(client: client, tools_payload: tools_payload,
                        max_words: max_words, logger: logger)
  end

  # Drains the events one summarize call pushed onto a Task's outbox.
  def with_task
    task = compactor_emit_task
    old = Thread.current[:harness_task]
    Thread.current[:harness_task] = task
    begin
      value = yield
      events = []
      loop do
        m = task.poll(0)
        break unless m
        events << m
      end
      [value, events]
    ensure
      Thread.current[:harness_task] = old
    end
  end

  def answer(content, tool_calls: nil)
    message = { content: content }
    message[:tool_calls] = tool_calls if tool_calls
    { choices: [{ message: message }] }
  end

  describe '#request_summary (the call both compact paths make)' do
    # A prefix cache matches the RENDERED prompt from token 0 and a chat template
    # renders the tool definitions into it, so the request must be the live chain
    # plus its instruction AND the live turn's own tool payload: dropping either
    # half makes it a different prompt, not a longer one (issue #246; both axes
    # are measured by analysis/246/repro.rb, the reasoning is
    # doc/compaction_cache_design.md).
    it 'sends the FULL chain, system message included, plus the instruction' do
      captured = nil
      allow(client).to receive(:chat) do |msgs|
        captured = msgs
        answer('summary text')
      end

      expect(compactor.request_summary(chain, 'Summarize.')).to eq('summary text')
      expect(captured.first(chain.size)).to eq(chain)
      expect(captured.first[:role]).to eq('system')
      expect(captured.size).to eq(chain.size + 1)
      expect(captured.last[:role]).to eq('user')
      expect(captured.last[:content]).to include('Keep it under 500 words')
    end

    it 'sends the live tools payload' do
      captured_tools = nil
      allow(client).to receive(:chat) do |_msgs, tools: nil|
        captured_tools = tools
        answer('summary text')
      end

      compactor.request_summary(chain, 'Summarize.')
      expect(captured_tools).to eq(tools_payload)
    end

    # The fork sends the live tool payload, so the model CAN answer a summary
    # request with a tool call. Nothing in a fork is executed (there is no tool
    # loop here), so the shape must be reported, not swallowed as an "empty
    # summary" - and never mistaken for a summary.
    it 'raises naming the tool call when the answer is one' do
      allow(client).to receive(:chat).and_return(
        answer('', tool_calls: [{ id: 'x1',
                                  function: { name: 'file.write', arguments: '{}' } }])
      )

      expect { compactor.request_summary(chain, 'Summarize.') }
        .to raise_error(HarnessError, /tool call \(file.write\) instead of a summary/)
    end

    it 'keeps a text answer that also carries tool calls, and logs the calls' do
      allow(client).to receive(:chat).and_return(
        answer('REAL SUMMARY',
               tool_calls: [{ id: 'x1', function: { name: 'session.note', arguments: '{}' } }])
      )

      expect(compactor.request_summary(chain, 'Summarize.')).to eq('REAL SUMMARY')
      expect(log_io.string).to include('summary call returned tool calls (session.note) - ignored')
    end

    it 'reports the plain empty-summary error when no tool call came back' do
      allow(client).to receive(:chat).and_return(answer('   '))

      expect { compactor.request_summary(chain, 'Summarize.') }
        .to raise_error(HarnessError, /empty summary/)
    end
  end

  # The fork sends the FULL chain, so it is larger than the request that just
  # failed and can be rejected for the same reason (#503). It then drops oldest
  # conversation entries and retries.
  describe '#summarize (issue #503)' do
    # The client fails the first `fail_first` calls with a context-exceeded
    # LLMError, then answers with a summary.
    let(:fail_first) { 0 }
    let(:seen_chains) { [] }
    before do
      limit = fail_first
      calls = 0
      chains = seen_chains
      allow(client).to receive(:chat) do |msgs|
        calls += 1
        chains << msgs
        if calls <= limit
          raise LLMError, 'llama.cpp: context window exceeded (requested 70000 tokens)'
        end
        answer('recovered summary')
      end
    end

    it 'sends the full chain on the first attempt (no dropping needed)' do
      summary, events = with_task { compactor.summarize(chain, 'Summarize.') }

      expect(summary).to eq('recovered summary')
      expect(seen_chains.size).to eq(1)
      expect(events.map { |e| e[:type] }).to eq([])
    end

    context 'when the first two calls are rejected for a full context' do
      let(:fail_first) { 2 }
      let(:chain) do
        [{ role: 'system', content: 'system prompt' }] +
          (0...30).map { |i| { role: 'user', content: "msg #{i}" } }
      end

      it 'drops oldest entries and retries until the summary fits' do
        summary, events = with_task { compactor.summarize(chain, 'Summarize.') }
        last = seen_chains.last

        expect(summary).to eq('recovered summary')
        expect(seen_chains.size).to eq(3)
        # Message 0 (the system prompt) survives every round and the NEWEST
        # entries are the ones kept.
        expect(last.first[:role]).to eq('system')
        expect(last[-2][:content]).to eq('msg 29')
        # chain + the instruction message, with 2 * DROP_ROUND entries dropped.
        expect(last.size).to eq(chain.size + 1 - (2 * Compactor::DROP_ROUND))
        expect(events.map { |e| e[:type] }).to eq(%i[compact compact compact])
        expect(events.map { |e| e[:origin] }).to eq(%i[compactor] * 3)
        expect(events.last[:content]).to include('succeeded after dropping 2 oldest-entry round')
      end
    end

    context 'when a cut would land on an unanswered assistant tool_calls message' do
      let(:fail_first) { 1 }
      let(:chain) do
        [{ role: 'system', content: 'system prompt' },
         { role: 'user', content: 'implement X' }] +
          (0...9).flat_map do |i|
            [{ role: 'assistant', content: nil,
               tool_calls: [{ id: "c#{i}", function: { name: 'file.read', arguments: '{}' } }] },
             { role: 'tool', tool_call_id: "c#{i}", content: "result #{i}" }]
          end
      end

      it 'walks the cut off the tool rows so no tool_calls is orphaned' do
        _, events = with_task { compactor.summarize(chain, 'Summarize.') }
        last = seen_chains.last
        # The chain ends on a tool result, so the request that failed was a
        # pending tool round; the kept half must still be sendable.
        expect(chain.last[:role]).to eq('tool')
        expect(last[1][:role]).not_to eq('tool')
        # 4 assistant/tool rounds survive out of the 9, plus the instruction.
        expect(last.map { |m| m[:role] }).to eq(%w[system] + (%w[assistant tool] * 4) + %w[user])

        expect(events.first[:content]).to include('retrying with the')
      end
    end

    it 'gives up rather than looping when nothing is left to drop' do
      allow(client).to receive(:chat).and_raise(
        LLMError, 'request exceeds the context window: prompt leaves no room to answer')
      small = [{ role: 'system', content: 'system prompt' },
               { role: 'user', content: 'one huge message' }]

      expect { compactor.summarize(small, 'Summarize.') }
        .to raise_error(LLMError, /leaves no room to answer/)
      expect(client).to have_received(:chat).once
    end

    it 'does not retry a non-context failure - dropping cannot fix it' do
      allow(client).to receive(:chat).and_return(answer('   '))

      expect { compactor.summarize(chain, 'Summarize.') }
        .to raise_error(HarnessError, /empty summary/)
      expect(client).to have_received(:chat).once
    end
  end

  describe '#drop_oldest_entries' do
    it 'keeps message 0 and the newest entries' do
      long = [{ role: 'system', content: 'sp' }] +
             (0...25).map { |i| { role: 'user', content: "m#{i}" } }
      kept = compactor.drop_oldest_entries(long)

      expect(kept.size).to eq(long.size - Compactor::DROP_ROUND)
      expect(kept.first[:content]).to eq('sp')
      expect(kept.last[:content]).to eq('m24')
    end

    it 'returns the chain unchanged when only one conversation message is left' do
      tiny = [{ role: 'system', content: 'sp' }, { role: 'user', content: 'only one' }]

      expect(compactor.drop_oldest_entries(tiny)).to eq(tiny)
    end
  end

  describe '.context_exceeded?' do
    it 'recognizes the wordings servers actually use' do
      [
        'llama.cpp: context window exceeded (requested 70000 tokens)',
        'request exceeds the context window: prompt leaves no room to answer',
        'num_ctx too small for this prompt',
        'too many tokens in prompt',
        'maximum context length is 8192 tokens'
      ].each do |msg|
        expect(described_class.context_exceeded?(msg)).to be_truthy
      end
    end

    it 'is false for an unrelated failure' do
      expect(described_class.context_exceeded?('connection refused')).to be_falsey
    end
  end
end
