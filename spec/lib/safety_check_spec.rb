# frozen_string_literal: true

require 'spec_helper'
require 'safety_check'

# issue #224: the check request is a fork of the live chain truncated at the
# last complete round. These specs lock the truncation contract (what the
# fork may and may not end on) and the one-shot call contract (no tools,
# one line per command, no mutation of the caller's chain, errors propagate).
#
# Purity contract (documented in lib/safety_check.rb): SafetyCheck NEVER
# touches Session - it is a free function over a plain chain array, so it
# cannot trigger in-loop compaction, token anchoring, or any session state
# change.
RSpec.describe SafetyCheck do
  # Minimal LLM client stand-in: records every request, answers scripted
  # text. :fail raises LLMError like a dead connection would.
  class FakeClient
    attr_reader :calls

    def initialize(response_text = "safe: only syntax-checks project files")
      @calls         = []
      @response_text = response_text
    end

    def chat(messages, tools: nil, timeout: nil)
      @calls << { messages: messages, tools: tools, timeout: timeout }
      raise LLMError, 'boom' if @response_text == :fail

      { choices: [{ message: { content: @response_text } }], usage: {} }
    end
  end

  # A chain mid-tool-loop: the LAST message is an assistant tool_calls with
  # no matching tool result yet (the confirmation dialog fires here).
  def mid_loop_chain
    [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'do the thing' },
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'c1', function: { name: 'test.echo', arguments: '{}' } }] },
      { role: 'tool', tool_call_id: 'c1', content: 'hi' },
      { role: 'assistant', content: nil,
        tool_calls: [{ id: 'c2', function: { name: 'run.command', arguments: '{}' } }] }
    ]
  end

  describe '.truncate_for_check' do
    it 'drops the trailing unresolved assistant tool_calls message' do
      forked = described_class.truncate_for_check(mid_loop_chain)

      expect(forked.map { |m| m[:role] }).to eq(%w[system user assistant tool])
    end

    it 'keeps a chain that already ends on a tool result' do
      chain = mid_loop_chain[0..3]

      expect(described_class.truncate_for_check(chain)).to eq(chain)
    end

    it 'keeps a chain that ends on a plain assistant reply' do
      chain = mid_loop_chain[0..3] + [{ role: 'assistant', content: 'done' }]

      expect(described_class.truncate_for_check(chain)).to eq(chain)
    end

    it 'does not mutate the caller array when the fork is extended' do
      chain  = mid_loop_chain.dup
      forked = described_class.truncate_for_check(chain)
      forked << { role: 'user', content: 'question' }

      expect(chain.size).to eq(5)
    end
  end

  describe '.run' do
    let(:command) { 'ruby -c lib/foo.rb' }

    it 'sends the truncated chain plus a check question, with no tools' do
      client = FakeClient.new
      described_class.run(client, mid_loop_chain, [command])

      req = client.calls.first
      expect(req[:tools]).to be_nil
      expect(req[:messages].map { |m| m[:role] })
        .to eq(%w[system user assistant tool user])
      expect(req[:messages].last[:content]).to include(command)
    end

    it 'does not mutate the session chain' do
      chain = mid_loop_chain.dup
      described_class.run(FakeClient.new, chain, [command])

      expect(chain.map { |m| m[:role] })
        .to eq(%w[system user assistant tool assistant])
    end

    it 'returns a verdict per command, one line each' do
      client = FakeClient.new("1: safe: read-only syntax check\n2: dangerous: deletes files")
      result = described_class.run(client, mid_loop_chain,
                                   ['ruby -c a.rb', 'rm -rf tmp/x'])

      expect(result).to eq('ruby -c a.rb' => '1: safe: read-only syntax check',
                           'rm -rf tmp/x' => '2: dangerous: deletes files')
    end

    it 'leaves the verdict nil when the answer has fewer lines than commands' do
      client = FakeClient.new('safe')
      result = described_class.run(client, mid_loop_chain, ['a', 'b'])

      expect(result).to eq('a' => 'safe', 'b' => nil)
    end

    it 'returns all nil when the answer is blank' do
      client = FakeClient.new("   \n")

      expect(described_class.run(client, mid_loop_chain, [command]))
        .to eq(command => nil)
    end

    it 'returns all nil for a degenerate chain and sends nothing' do
      client = FakeClient.new
      result = described_class.run(client, [{ role: 'system', content: 'sys' }], [command])

      expect(result).to eq(command => nil)
      expect(client.calls).to be_empty
    end

    it 'propagates LLM errors (the caller degrades to a plain dialog)' do
      client = FakeClient.new(:fail)

      expect { described_class.run(client, mid_loop_chain, [command]) }
        .to raise_error(LLMError)
    end
  end
end
