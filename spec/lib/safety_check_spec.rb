# frozen_string_literal: true

require 'spec_helper'
require 'safety_check'

# issue #224: the check request is a fork of the live chain truncated at the
# last complete round. These specs lock the truncation contract (what the
# fork may and may not end on) and the one-shot call contract (tools as given,
# one line per command, no mutation of the caller's chain, errors propagate),
# plus the tools payload the caller hands in (#246: the fork must render the
# same prompt prefix the live turn rendered - doc/compaction_cache_design.md).
#
# issue #344: a verdict binds to its command by the NUMBER the model wrote,
# never by line position - position is consulted only when the whole answer is
# unnumbered, well-shaped and exactly as long as the command list. An answer
# that cannot be placed yields NO verdicts (not a shifted set), each drop
# logged. Binding rule and why: doc/safety_check_design.md.
#
# Purity contract (documented in lib/safety_check.rb): SafetyCheck NEVER
# touches Session - it is a free function over a plain chain array, so it
# cannot trigger in-loop compaction, token anchoring, or any session state
# change. The only sink it may write to is a logger the CALLER injects, for the
# reason a verdict was dropped.
RSpec.describe SafetyCheck do
  # Minimal LLM client stand-in: records every request, answers scripted
  # text. :fail raises LLMError like a dead connection would.
  class FakeClient
    attr_reader :calls

    def initialize(response_text = "1: safe: only syntax-checks project files")
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

    it 'sends the truncated chain plus a check question (no tools by default)' do
      client = FakeClient.new
      described_class.run(client, mid_loop_chain, [command])

      req = client.calls.first
      expect(req[:tools]).to be_nil
      expect(req[:messages].map { |m| m[:role] })
        .to eq(%w[system user assistant tool user])
      expect(req[:messages].last[:content]).to include(command)
    end

    # A chat template renders the tool definitions into the prompt, so a fork
    # that omits them is a DIFFERENT prompt, not a longer version of the live
    # turn's - which is what made the prefix reuse fail (#246). The payload is
    # the caller's to supply (SafetyCheck holds no registry of its own) and
    # must reach chat untouched.
    it 'forwards the caller tools payload to chat unchanged' do
      client = FakeClient.new
      tools  = [{ type: 'function', function: { name: 'file.read' } }]
      described_class.run(client, mid_loop_chain, [command], tools:)

      expect(client.calls.first[:tools]).to eq(tools)
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

      # The number is the binding, not part of the verdict: what the model
      # wrote as its reason is kept verbatim, so the consumer's /\Asafe:/
      # test sees the kind it expects (issue #344).
      expect(result).to eq('ruby -c a.rb' => 'safe: read-only syntax check',
                           'rm -rf tmp/x' => 'dangerous: deletes files')
    end

    it 'returns NO verdicts when a preamble line shifts the answer (issue #344)' do
      client = FakeClient.new("Here are my verdicts:\nsafe: syntax check\ndangerous: deletes files")
      result = described_class.run(client, mid_loop_chain, ['ruby -c a.rb', 'rm -rf /tmp/x'])

      # The old code mapped line 1 onto command 1: the destructive command was
      # reported "safe: syntax check". An unverifiable answer must yield the
      # no-verdict state (plain dialog), never a shifted one.
      expect(result).to eq('ruby -c a.rb' => nil, 'rm -rf /tmp/x' => nil)
    end

    it 'binds by the number the model wrote, even when the lines are out of order' do
      client = FakeClient.new("2: dangerous: deletes files\n1: safe: syntax check")
      result = described_class.run(client, mid_loop_chain, ['ruby -c a.rb', 'rm -rf /tmp/x'])

      expect(result['ruby -c a.rb']).to eq('safe: syntax check')
      expect(result['rm -rf /tmp/x']).to eq('dangerous: deletes files')
    end

    it 'keeps the numbered verdicts when a preamble line accompanies them' do
      client = FakeClient.new("Sure, here you go:\n1: safe: syntax check\n2: dangerous: deletes files")
      result = described_class.run(client, mid_loop_chain, ['a', 'b'])

      expect(result).to eq('a' => 'safe: syntax check', 'b' => 'dangerous: deletes files')
    end

    it 'gives NO verdict to a command answered twice (the duplicate is dropped, not chosen)' do
      client = FakeClient.new("1: safe: looks fine\n1: dangerous: wait, it deletes")
      result = described_class.run(client, mid_loop_chain, ['a', 'b'])

      expect(result).to eq('a' => nil, 'b' => nil)
    end

    it 'drops an ordinal that names no command' do
      client = FakeClient.new("1: safe: a\n3: dangerous: not a command")
      result = described_class.run(client, mid_loop_chain, ['a', 'b'])

      expect(result).to eq('a' => 'safe: a', 'b' => nil)
    end

    it 'falls back to position ONLY when the answer is unnumbered, shaped and exact' do
      client = FakeClient.new("safe: syntax check\ndangerous: deletes files")
      result = described_class.run(client, mid_loop_chain, ['a', 'b'])

      expect(result).to eq('a' => 'safe: syntax check', 'b' => 'dangerous: deletes files')
    end

    it 'returns NO verdicts when the line count does not match an unnumbered answer' do
      client = FakeClient.new("safe: only one answer")
      result = described_class.run(client, mid_loop_chain, ['a', 'b'])

      expect(result).to eq('a' => nil, 'b' => nil)

      client2 = FakeClient.new("safe: one\nsafe: two\nsafe: three")
      expect(described_class.run(client2, mid_loop_chain, ['a', 'b'])).to eq('a' => nil, 'b' => nil)
    end

    it 'normalizes the kind so the consumer can match it, and keeps the reason verbatim' do
      client = FakeClient.new('SAFE: Writes to tmp/ only')
      result = described_class.run(client, mid_loop_chain, [command])

      expect(result).to eq(command => 'safe: Writes to tmp/ only')
    end

    it 'treats a line that is not a verdict shape as no verdict at all' do
      client = FakeClient.new("not really safe, just checking")
      result = described_class.run(client, mid_loop_chain, [command])

      expect(result).to eq(command => nil)
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

    # The numbered answer is what makes the binding possible (issue #344): the
    # ordinal is the only identity a verdict line carries, so the question must
    # demand it. Drift here silently degrades the binding to position-only.
    it 'asks for one numbered line per command, naming the number' do
      client = FakeClient.new
      described_class.run(client, mid_loop_chain, ['ruby -c a.rb', 'git status'])

      question = client.calls.first[:messages].last[:content]
      expect(question).to include('1. ruby -c a.rb')
      expect(question).to include('2. git status')
      expect(question).to include("Each line must start with that command's number")
      expect(question).to include('safe: or dangerous:')
    end

    # Sending the live tool payload means an answer CAN come back as a tool call
    # instead of verdict lines. That is a no-verdict state produced by the MODEL's
    # shape, not by a dropped line, so it must be recoverable from harness.log too
    # - and it must never be read as a verdict (nothing in a fork is executed).
    it 'logs that no verdict lines arrived when the answer was a tool call' do
      client = double('client')
      allow(client).to receive(:chat).and_return({
        choices: [{ message: { content: nil,
                              tool_calls: [{ id: 'z1',
                                            function: { name: 'run.command' } }] } }]
      })
      logged = []
      logger = double('logger')
      allow(logger).to receive(:info) { |m| logged << m }

      result = described_class.run(client, mid_loop_chain, [command],
                                   tools: [{ type: 'function' }], logger:)

      expect(result).to eq(command => nil)
      expect(logged).to include('safety check: no verdict lines (answer was ' \
                               'a tool call: run.command)')
    end

    # 'No verdict' is now produced by a decision (a dropped line), not only by a
    # network error - so the reason must land in harness.log, or an AUTO-APPROVE
    # that silently stopped approving has nothing to explain it.
    it 'logs why a verdict was dropped when a logger is given' do
      client   = FakeClient.new("1: safe: fine\n1: dangerous: it deletes")
      logged   = []
      logger   = double('logger')
      allow(logger).to receive(:info) { |msg| logged << msg }

      described_class.run(client, mid_loop_chain, ['a', 'b'], logger: logger)

      expect(logged.size).to eq(1)
      expect(logged.first).to include('safety check:')
      expect(logged.first).to include('answered twice')
    end

    it 'writes nothing when the answer binds cleanly (no logger needed)' do
      client = FakeClient.new("1: safe: fine\n2: dangerous: it deletes")

      expect(described_class.run(client, mid_loop_chain, ['a', 'b'])).to eq(
        'a' => 'safe: fine', 'b' => 'dangerous: it deletes'
      )
    end
  end
end
