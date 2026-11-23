# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'call_llm: the tool loop' do
  include HarnessSpecSupport

  describe '#call_llm mid-loop failure keeps the tool trail (issue #208)' do
    def echo_tool_round
      { content: nil,
        tool_calls: [{ id: 'call_1', function: { name: 'test.echo', arguments: '{"text":"hi"}' } }] }
    end

    it 'keeps the assistant tool_calls and the tool result in the session' do
      harness = build_harness_with_responses([echo_tool_round, :fail])
      harness.session.add_user('implement feature X')

      expect { harness.call_llm }.to raise_error(LLMError, /connection lost/)

      messages = harness.session.messages
      expect(messages.map { |m| m[:role] }).to eq(%w[system user assistant tool])
      # The assistant message carries the exact tool_calls the model made.
      expect(messages[-2][:tool_calls].map { |tc| tc[:function][:name] }).to eq(['test.echo'])
      # The tool actually ran and its result committed too.
      expect(messages.last).to eq(role: 'tool', tool_call_id: 'call_1', content: 'hi')

      # The chain is now RESENDABLE from this point.
      expect(harness.session.pending?).to be(true)
    end

    it 'keeps only the pending prompt when the failure hits before any tool round' do
      harness = build_harness_with_responses([:fail])
      harness.session.add_user('implement feature X')

      expect { harness.call_llm }.to raise_error(LLMError)

      # Only the pending prompt remains - /retry re-sends it (old behavior).
      expect(harness.session.messages.map { |m| m[:role] }).to eq(%w[system user])
      expect(harness.session.pending?).to be(true)
    end

    it 'keeps a mid-turn steering note in the trail across the failure' do
      harness = build_harness_with_responses([echo_tool_round, :fail])
      harness.session.add_user('implement feature X')
      harness.user_note_text = 'fix the naming first'

      expect { harness.call_llm }.to raise_error(LLMError)

      contents = harness.session.messages.map { |m| m[:content].to_s }
      expect(contents).to include('User note (mid-turn): fix the naming first')
      expect(harness.session.pending?).to be(true)
    end
  end

  # issue #567: a turn that dies mid-loop still reports what it did.
  describe '#aborted_turn_stats_line (issue #567)' do
    def echo_round
      { content: nil,
        tool_calls: [{ id: 'call_1', function: { name: 'test.echo', arguments: '{"text":"hi"}' } }] }
    end

    def turn_on_job(h, id)
      h.session_manager.job_id = id
    end

    it 'reports the iterations that answered and the request that never came back' do
      h = build_harness_with_responses([echo_round, :fail], num_ctx: 65_536)
      turn_on_job(h, 0)
      expect { h.session_manager.run_prompt('go') }.to raise_error(LLMError)

      line = h.aborted_turn_stats_line(0)

      expect(line).to include('1 of 2 iterations answered')
      expect(line).to include('⏱')
    end

    it 'reports nothing when no request of the turn ever answered' do
      h = build_harness_with_responses([:fail], num_ctx: 65_536)
      turn_on_job(h, 0)
      expect { h.session_manager.run_prompt('go') }.to raise_error(LLMError)

      expect(h.aborted_turn_stats_line(0)).to be_nil
    end

    it 'reports nothing for a committed turn (it already printed its own line)' do
      h = build_harness_with_responses([{ content: 'all good' }], num_ctx: 65_536)
      h.session_manager.run_prompt('go')

      expect(h.aborted_turn_stats_line(0)).to be_nil
    end

    it "does not carry the previous turn's numbers into the next one" do
      h = build_harness_with_responses([echo_round, :fail], num_ctx: 65_536)
      turn_on_job(h, 0)
      expect { h.session_manager.run_prompt('first') }.to raise_error(LLMError)
      expect(h.aborted_turn_stats_line(0)).to include('1 of 2 iterations answered')

      h.session_manager.run_prompt('second')

      expect(h.aborted_turn_stats_line(0)).to be_nil
    end

    it 'reports nothing when the open turn belongs to another job' do
      h = build_harness_with_responses([echo_round, :fail], num_ctx: 65_536)
      turn_on_job(h, 1)
      expect { h.session_manager.run_prompt('go') }.to raise_error(LLMError)

      expect(h.aborted_turn_stats_line(0)).to be_nil
      expect(h.aborted_turn_stats_line(1)).to include('1 of 2 iterations answered')
    end
  end

  # Issue #246: a prompt-prefix cache matches the rendered prompt from token 0,
  # and a chat template renders the tool definitions into it. So EVERY request
  # of a session - the live turn and each advisory fork - must carry the same
  # tool payload, or the fork is a DIFFERENT prompt and re-prefills cold.
  describe 'every request carries the same tools payload (issue #246)' do
    def scripted(harness, responses)
      client = fake_scripted_client(responses)
      harness.instance_variable_set(:@client, client)
      client
    end

    it 'sends tool_registry.to_openai on the live turn' do
      h = build_harness
      client = scripted(h, [{ content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      expect(client.tool_payloads).to eq([h.tools_payload])
      expect(h.tools_payload.map { |t| t[:function][:name] })
        .to eq(h.tool_registry.names)
    end

    # num_ctx 10 with no reserved headroom: the turn trips in-loop compaction,
    # so the scripted queue's 3rd answer is the SUMMARY call's (the guard needs
    # 4 conversation messages, hence two tool rounds first) and that request
    # carries the SAME tools as the turn's own.
    it 'sends it on the in-loop summary call too' do
      h = build_harness(model: 'test-model', num_ctx: 10, compact_reserved: 0)
      echo = lambda do |id|
        { content: nil,
          tool_calls: [{ id: id, function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
      end
      client = scripted(h, [echo.call('c1'), echo.call('c2'),
                            { content: 'HANDOFF SUMMARY' }, { content: 'final' }])
      h.session.add_user('do the thing')

      h.call_llm

      expect(client.tool_payloads.uniq.size).to eq(1)
      expect(client.tool_payloads.first).to eq(h.tools_payload)
    end
    # Carrying the live tool payload means the model CAN answer the summary
    # request with a tool call. A fork has no tool loop - #execute_tool_call is
    # reached only from call_llm's own tool round - so such a call must fail the
    # compaction and NEVER be run.
    it 'never executes a tool call the summary fork answered with' do
      h = build_harness(model: 'test-model', num_ctx: 10, compact_reserved: 0)
      echo = lambda do |id|
        { content: nil,
          tool_calls: [{ id: id, function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
      end
      # The 3rd scripted answer is the summary fork's; its tool call is one the
      # user never asked for, and PWNED is what running it would produce.
      pwned = { content: nil,
                tool_calls: [{ id: 'S1', function: { name: 'test.echo',
                                                     arguments: '{"text":"PWNED"}' } }] }
      client = scripted(h, [echo.call('c1'), echo.call('c2'), pwned, { content: 'final' }])
      h.session.add_user('do the thing')

      task = emit_task
      old = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      events = []
      begin
        expect(h.call_llm[:content]).to eq('final')
        loop { e = task.poll(0); break unless e; events << e[:content].to_s }
      ensure
        Thread.current[:harness_task] = old
      end

      expect(events.join("\n"))
        # issue #409: a failed compaction is a KNOWN degrade, so the outbox line
        # is the label - the class names the failure alongside its message.
        .to include('in-loop compaction failed: HarnessError: LLM answered the ' \
                    'summary request with a tool call (test.echo)')
      expect(File.read(h.session_log_path)).not_to include('PWNED')
      expect(client.calls.size).to eq(4) # turn, turn, summary fork, post-compact turn
    end
  end

  # issue #577: an in-loop compaction must not fire on two consecutive
  # iterations. The request made right after one has not been re-measured, so a
  # back-to-back pair reads on the console and in the server stats as "compact
  # done twice". A re-fill that trips the trigger on a LATER iteration is still
  # a legitimate re-compaction and must still run.
  describe '#call_llm in-loop compaction cannot fire back-to-back (issue #577)' do
    # A client whose usage carries a per-response prompt_tokens, so a spec can
    # drive the loop's last_prompt_tokens exactly.
    class PromptCountingClient
      attr_reader :chats
      def initialize(responses)
        @responses = responses
        @chats = 0
      end
      def chat(messages, tools: nil, timeout: nil, stream: false, on_delta: nil)
        @chats += 1
        r = @responses.shift || { content: 'done', prompt_tokens: 100 }
        msg = { content: r[:content], reasoning: nil, tool_calls: r[:tool_calls] }
        { choices: [{ message: msg }],
          usage: { prompt_tokens: r[:prompt_tokens], completion_tokens: 5,
                   total_tokens: r[:prompt_tokens] + 5 } }
      end
    end

    # num_ctx 1000, threshold 90 -> trigger 900. Seed a chain already over it.
    def over_trigger_harness(responses)
      h = build_harness(model: 'test-model', num_ctx: 1000,
                        compact_reserved: 0, compact_auto_threshold: 90)
      big = 'x' * 400
      h.session.add_user('big task')
      3.times do |i|
        h.session.add_assistant_message({ role: 'assistant', content: "a#{i}",
                                          tool_calls: [{ id: "p#{i}", function: { name: 'test.echo', arguments: '{}' } }] })
        h.session.add_assistant({ role: 'tool', content: big })
      end
      h.session.record_prompt_tokens(950, h.session.messages.size)
      h.instance_variable_set(:@client, PromptCountingClient.new(responses))
      h
    end

    def round(id, pt)
      { prompt_tokens: pt, tool_calls: [{ id: id, function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    def count_compactions(h)
      sm = h.session_manager
      orig = sm.method(:check_inloop_compaction)
      hits = 0
      sm.define_singleton_method(:check_inloop_compaction) do |messages, lpt|
        r = orig.call(messages, lpt)
        hits += 1 if r
        r
      end
      -> { hits }
    end

    it 'compacts once when the post-compact request is still over the trigger' do
      # iter1 over trigger -> compaction at iter2; iter2's request ALSO over
      # trigger. Without the guard this would compact twice in a row.
      h = over_trigger_harness([round('c1', 950), { content: 'HANDOFF', prompt_tokens: 500 },
                                round('c2', 960), { content: 'final', prompt_tokens: 500 }])
      hits = count_compactions(h)

      h.call_llm

      expect(hits.call).to eq(1)
    end

    it 'still re-compacts when the context re-fills on a later iteration' do
      # iter2 request small (500), iter3 request re-fills over trigger (960):
      # the second compaction is on a NON-adjacent iteration and must run.
      h = over_trigger_harness([round('c1', 950), { content: 'HANDOFF1', prompt_tokens: 500 },
                                round('c2', 500), round('c3', 960),
                                { content: 'HANDOFF2', prompt_tokens: 500 },
                                { content: 'final', prompt_tokens: 500 }])
      hits = count_compactions(h)

      h.call_llm

      expect(hits.call).to eq(2)
    end
  end

  # Issue #283: call_llm emits the request line before every request, so a
  # re-point made by an earlier wait (an in-loop compaction) cannot stick for
  # the rest of the turn.
  describe '#call_llm spinner announcements (issue #283)' do
    let(:task) { emit_task }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    def spinner_details
      events = []
      loop do
        m = task.poll(0)
        break unless m
        events << m[:content][:message] if m[:type] == :spinner_detail
      end
      events
    end

    # num_ctx 10: the scripted client's prompt_tokens (10) are over the
    # trigger and no headroom is reserved in such a small window.
    def loop_options
      { model: 'test-model', num_ctx: 10, compact_reserved: 0 }
    end

    def echo_round(id)
      { content: nil,
        tool_calls: [{ id: id,
                       function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    it 'announces the send line before each request of a tool loop' do
      h = build_harness(loop_options)
      h.instance_variable_set(:@client, fake_scripted_client(
        [echo_round('c1'), { content: 'final' }]
      ))
      h.session.add_user('do the thing')

      h.call_llm

      # Each request announces itself AND each tool round announces itself
      # (issue #362) - the two kinds alternate, and a request line always
      # follows the tool line of the round it produced.
      expect(spinner_details).to eq(['Sending (test-model)', 'test.echo',
                                     'Sending (test-model)'])
    end

    it 're-announces the send line after an in-loop compaction' do
      # Two tool rounds build a chain big enough to summarize, then the
      # threshold trips: iteration 3 first compacts (its own spinner line)
      # and then announces its own request.
      h = build_harness(loop_options)
      h.instance_variable_set(:@client, fake_scripted_client(
        [echo_round('c1'), echo_round('c2'),
         { content: 'HANDOFF SUMMARY' }, { content: 'final' }]
      ))
      h.session.add_user('do the thing')

      h.call_llm

      details = spinner_details
      compact = details.index { |d| d.include?('Compacting session mid-task') }
      expect(compact).not_to be_nil
      # The turn's LAST spinner line is the new request, not the finished
      # compaction, and every line BEFORE the compaction is a request line or
      # the tool line of the round that request produced (issue #362).
      expect(details.last).to eq('Sending (test-model)')
      expect(details[0, compact]).to eq(['Sending (test-model)', 'test.echo',
                                         'Sending (test-model)', 'test.echo'])
    end
  end

  # issue #251: the server-reported performance of a turn. Each request's
  # cache depth / durations describe only that request, so the turn keeps the
  # LAST request's measurement instead of summing measurements that were
  # never taken together.
  describe '#call_llm performance stats (issue #251)' do
    # A scripted client whose responses may carry their own usage.
    class PerformanceClient
      def initialize(responses)
        @responses = responses
      end

      def chat(_messages, tools: nil, timeout: nil, stream: false, on_delta: nil)
        @responses.shift
      end
    end

    def answer(usage)
      { choices: [{ message: { content: 'done', reasoning: nil } }], usage: }
    end

    def tool_round(id, usage)
      { choices: [{ message: { content: nil, reasoning: nil,
                              tool_calls: [{ id: id, function: { name: 'test.echo',
                                                                arguments: '{"text":"x"}' } }] } }],
        usage: }
    end

    def harness_with(usage)
      h = build_harness
      h.instance_variable_set(:@client, PerformanceClient.new([answer(usage)]))
      h.session.add_user('go')
      h.call_llm[:stats]
    end

    it 'reports no performance when the server sent none' do
      stats = harness_with({ prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 })

      expect(stats[:performance]).to be_nil
    end

    it 'keeps the LAST request\'s measurement, not a sum of them' do
      h = build_harness
      h.instance_variable_set(:@client, PerformanceClient.new([
        tool_round('c1', { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15,
                           cached_tokens: 100, eval_ms: 1000.0 }),
        answer({ prompt_tokens: 20, completion_tokens: 5, total_tokens: 25,
                 cached_tokens: 900, eval_ms: 200.0 })
      ]))
      h.session.add_user('go')

      stats = h.call_llm[:stats]

      # The core accounting still sums across the turn (it always did).
      expect(stats[:usage]).to eq(prompt_tokens: 30, completion_tokens: 10, total_tokens: 40)
      expect(stats[:performance]).to eq(
        cached_tokens: 900, eval_ms: 200.0, prompt_tokens: 20, completion_tokens: 5
      )
    end

    it 'shows the performance on the stats line' do
      stats = harness_with({ prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
                             cached_tokens: 768, prompt_eval_ms: 1160.0, eval_ms: 1310.2 })
      task = emit_task
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        build_harness.emit_stats(stats)
      ensure
        Thread.current[:harness_task] = old_current
      end

      line = drained_lines(task).grep(/tokens \(/).first.to_s
      expect(line).to include('768 cached')
      expect(line).to include('prompt 200 tok/s')
      expect(line).to include('gen 38.2 tok/s')
    end
  end

  # issue #345: a response cut by the token budget is an EVENT, not a bad model
  # answer. The plumbing (finish_reason in the normalized shape) belongs to the
  # spec/lib/llm/ specs; this is what Harness#call_llm does with it.
  describe '#call_llm finish_reason (issue #345)' do
    let(:task) { emit_task }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    def event_lines(t)
      drained_lines(t).grep(/token budget|finish reason/)
    end

    def truncated_round(id)
      { content: nil, finish_reason: 'length',
        tool_calls: [{ id: id,
                       function: { name: 'test.echo', arguments: '{"text":"x"}' } }] }
    end

    it 'says on the console and in harness.log that the budget cut the answer' do
      h = build_harness_with_responses([{ content: 'partial', finish_reason: 'length' }])
      h.session.add_user('go')

      h.call_llm

      line = event_lines(task).first.to_s
      expect(line).to include('cut off by the token budget (iteration 1')
      # The harness' own budget is named next to what the server reported.
      expect(line).to include('5 completion tokens')
      expect(line).to include('no token limit configured')
      expect(File.read(h.session_log_path)).to include('cut off by the token budget')
    end

    it 'names the configured limit when one is set' do
      h = build_harness_with_responses([{ content: 'partial', finish_reason: 'length' }])
      h.model_config.max_tokens = 4096
      h.session.add_user('go')

      h.call_llm

      expect(event_lines(task).first.to_s).to include('limit 4096')
    end

    %w[stop tool_calls].each do |reason|
      it "stays silent for the normal end '#{reason}'" do
        h = build_harness_with_responses([{ content: 'done', finish_reason: reason }])
        h.session.add_user('go')

        h.call_llm

        expect(event_lines(task)).to eq([])
      end
    end

    it 'warns about an unknown reason without calling it truncation' do
      h = build_harness_with_responses([{ content: 'done', finish_reason: 'content_filter' }])
      h.session.add_user('go')

      h.call_llm

      line = event_lines(task).first.to_s
      expect(line).to include("finish reason 'content_filter' (iteration 1)")
      expect(line).not_to include('token budget')
    end

    # A well-formed call from a cut round still runs: truncation is not a
    # reason to refuse a call that arrived complete. The model is told ONCE.
    it 'runs a truncated round whose calls arrived complete, and says so to the model' do
      h = build_harness_with_responses([truncated_round('c1'), { content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      chain = h.session.messages
      expect(chain.find { |m| m[:role] == 'tool' }[:content]).to eq('x')
      told = chain.select do |m|
        m[:role] == 'user' && m[:content].to_s.include?('cut off by the token budget')
      end
      expect(told.size).to eq(1)
      expect(told.first[:content]).to include('Do NOT re-send the same call')
    end

    # THE point of the issue: a call whose arguments were cut mid-JSON must not
    # read as a malformed call (that is what #332's model kept retrying).
    it 'reports a cut-off call as truncation, not as a malformed call' do
      cut = truncated_round('c1')
      cut[:tool_calls][0][:function][:arguments] = '{"text":"x'
      h = build_harness_with_responses([cut, { content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      result = h.session.messages.find { |m| m[:role] == 'tool' }[:content]
      expect(result).to include('cut off by the token budget')
      expect(result).to include('NOT executed')
      expect(result).not_to include('not valid JSON')
      expect(File.read(h.session_log_path)).to include('arguments did not parse')
    end

    # The same parse failure with NO truncation is still named as what it is.
    it 'names an un-truncated malformed call a malformed call' do
      bad = truncated_round('c1')
      bad.delete(:finish_reason)
      bad[:tool_calls][0][:function][:arguments] = '{"text":"x'
      h = build_harness_with_responses([bad, { content: 'done' }])
      h.session.add_user('go')

      h.call_llm

      expect(h.session.messages.find { |m| m[:role] == 'tool' }[:content])
        .to include('arguments are not valid JSON')
    end
  end

  # issue #461: a model (qwen) sometimes writes a tool call as TEXT instead of a
  # structured tool_calls array. The harness parses that text and runs it
  # (lenient), but only for a name that maps to a registered tool.
  # Parsing itself is covered by spec/lib/text_tool_call_parser_spec.rb; this
  # block is the call_llm wiring. Pseudo-XML is built from tag fragments so the
  # literal pseudo-tags never sit as a contiguous token in this file.
  describe '#call_llm text-shaped tool call (issue #461)' do
    TAG = ->(name) { '<' + name + '>' }
    END_TAG = ->(name) { '</' + name + '>' }

    # qwen dialect: the name is glued to the tag with '='.
    def qwen_call(func, params)
      body = params.map { |k, v| TAG.call("parameter=#{k}") + v + END_TAG.call('parameter') }
      TAG.call('tool_call') + TAG.call("function=#{func}") + body.join +
        END_TAG.call('function') + END_TAG.call('tool_call')
    end

    def text_round(content)
      { content: content, reasoning: nil }
    end

    def drained_status(task)
      events = []
      loop { m = task.poll(0); break unless m; events << m }
      events.select { |m| m[:type].to_s.start_with?('status_') }
    end

    def with_task
      task = emit_task
      old = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        yield task
      ensure
        Thread.current[:harness_task] = old
      end
      task
    end

    it 'wires a parser built over this run\'s registry' do
      h = build_harness
      parser = h.text_tool_call_parser

      expect(parser).to be_a(TextToolCallParser)
      expect(parser.parse(qwen_call('echo', 'text' => 'hi'))[0][:function][:name])
        .to eq('test.echo')
    end

    it 'gives each recovered round a distinct id (no tool_call_id collision)' do
      h = build_harness_with_responses([
        text_round(qwen_call('test.echo', 'text' => 'a')),
        text_round(qwen_call('test.echo', 'text' => 'b')),
        { content: 'done' }
      ])
      h.session.add_user('go')

      h.call_llm

      ids = h.session.messages.filter_map { |m| m[:tool_calls]&.map { |tc| tc[:id] } }.flatten
      expect(ids).to eq(%w[text_call_1 text_call_2])
    end

    it 'runs a recovered call in the tool loop and names it (issue #461)' do
      h = build_harness_with_responses([
        text_round(qwen_call('test.echo', 'text' => 'recovered')), { content: 'done' }
      ])
      h.session.add_user('go')

      task = with_task { h.call_llm }

      # The tool actually ran: its result committed into the session chain.
      expect(h.session.messages.find { |m| m[:role] == 'tool' }[:content]).to eq('recovered')
      line = drained_status(task).find { |m| m[:origin] == 'text_call' }
      expect(line).not_to be_nil
      expect(line[:content]).to include('arrived as text/XML, not JSON')
      expect(line[:content]).to include('parsed and running')
      expect(File.read(h.session_log_path))
        .to include('tool call arrived as text/XML (issue #461), not JSON - parsed and running')
    end

    it 'does NOT run prose that merely quotes a call (name matches no tool)' do
      quoted = "the broken format looks like #{qwen_call('bogus_tool', 'path' => 'x')} here"
      h = build_harness_with_responses([text_round(quoted), { content: 'the real answer' }])
      h.session.add_user('go')

      task = with_task { h.call_llm }

      # Nothing was executed - no tool message entered the chain.
      expect(h.session.messages.map { |m| m[:role] }).not_to include('tool')
      # issue #487: the FIRST occurrence is fed back to the model, not dumped
      # at the user. The model is asked to re-issue it and, here, answers with
      # the real one - the turn ends normally, no user-facing warn.
      expect(h.client.calls.size).to eq(2)
      asked = h.client.calls.last
      expect(asked.last[:content]).to include('could not run')
      expect(asked.last[:content]).to include('Re-issue it as a structured tool call')
      expect(h.call_llm).not_to be_nil # second scripted response drove the final answer
      line = drained_status(task).find { |m| m[:origin] == 'text_call' }
      expect(line[:content]).to include('asked the model to re-issue it')
    end

    # issue #487: the feedback is bounded to ONE retry per turn. A model that
    # keeps emitting an unrunnable text call must not spin the loop - the
    # second occurrence falls through to the honest user-facing warn and the
    # turn commits.
    it 'feeds the failure back at most once, then warns and ends the turn' do
      quoted = "looks like #{qwen_call('bogus_tool', 'path' => 'x')}"
      h = build_harness_with_responses([
        text_round(quoted), text_round(quoted), text_round(quoted)
      ])
      h.session.add_user('go')

      task = with_task { h.call_llm }

      expect(h.session.messages.map { |m| m[:role] }).not_to include('tool')
      # First occurrence: fed back. Second: the bounded retry falls through to
      # the warn + commit (the third scripted response is never reached).
      expect(h.client.calls.size).to eq(2)
      events = []
      loop { m = task.poll(0); break unless m; events << m }
      warn = events.find do |m|
        m[:type] == :warn && m[:origin] == :harness && m[:content].to_s.include?('could not run')
      end
      expect(warn).not_to be_nil
    end
  end

  # issue #224: a tool batch with SEVERAL run.command calls is checked with
  # ONE forked LLM call (one verdict line per command) BEFORE the first
  # consent dialog. Advisory only; errors degrade to a verdict-less flow.
end

