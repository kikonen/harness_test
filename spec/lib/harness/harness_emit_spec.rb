# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'emit and tool-execution display (issues #131, #40, #138, #36)' do
  include HarnessSpecSupport

  describe '#emit_step (issue #131)' do
    let(:harness) { build_harness }
    # The roles emit_step is allowed to emit (issue #146).
    let(:step_roles) { %i[step_label plan interstitial tool_plan] }
    # issue #40 follow-up: emit_step emits typed events onto the
    # Task's outbox (single event queue) via Task.emit. Set the thread-local
    # task so Task.emit finds it, then drain the outbox to assert on the
    # lines - exactly what the real drain loop does.
    let(:task) { emit_task }
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end
    let(:drained_lines) { drain_outbox(task).map { |m| m[:content] } }
    def drain_outbox(t)
      ms = []
      loop do
        m = t.poll(0); break unless m
        ms << m
      end
      ms
    end

    let(:message) do
      {
        reasoning: 'First I will inspect the spinner, then run the specs.',
        tool_calls: [
          { id: 'c1', function: { name: 'file.read', arguments: '{"path":"lib/ui/spinner.rb"}' } },
          { id: 'c2', function: { name: 'run.command', arguments: '{"command":"bundle exec rspec"}' } }
        ]
      }
    end

    it 'emits the step number, a digest of the reasoning and the tools called' do
      harness.send(:emit_step, message)
      events = drain_outbox(task)
      lines = events.map { |m| m[:content] }

      # Content is the ROLE the emitter stated; the pattern ('step ',
      # 'plan:  ') belongs to UI::Renderer, so it is asserted here on the
      # rendered line (spec/lib/ui/renderer_spec.rb covers the labels).
      step = events.find { |m| m[:type] == :step_label }[:content]
      expect(step[:number]).to eq(1)
      # The count is the number of tool calls in this step.
      expect(step[:calls]).to eq(2)
      expect(lines).to include('First I will inspect the spinner, then run the specs.')
      expect(lines).to include('file.read, run.command')
    end

    # issue #577: the step number is a job-wide monotonic counter, not the
    # per-call_llm loop counter - repeated emit_step calls never repeat a number
    # and never go backwards, so a turn that restarts cannot re-issue a step.
    it 'numbers steps monotonically across repeated calls (issue #577)' do
      numbers = 3.times.map do
        harness.send(:emit_step, message)
        drain_outbox(task).find { |m| m[:type] == :step_label }[:content][:number]
      end

      expect(numbers).to eq([1, 2, 3])
    end

    it 'falls back to message content when there is no reasoning' do
      msg = { reasoning: nil, content: 'checking the test suite', tool_calls: [{ id: 'c1', function: { name: 'run.command', id: 'run.command' } }] }

      harness.send(:emit_step, msg)
      lines = drained_lines

      expect(lines).to include('checking the test suite')
      expect(lines).to include('run.command')
    end

    it 'emits the reasoning digest and the interstitial as distinct roles' do
      harness.send(:emit_step, message)
      rendered = drain_outbox(task).map { |m| UI::Renderer.new.line(type: m[:type], content: m[:content]) }

      expect(rendered).to include('plan:  First I will inspect the spinner, then run the specs.')
      expect(rendered).not_to include(a_string_matching(/>>>/))
      expect(rendered).not_to include(a_string_matching(/\|\|\|/))
    end

    it 'emits only the tool line when there is no reasoning text at all' do
      msg = { reasoning: nil, content: nil, tool_calls: [{ id: 'c1', function: { name: 'file.search', id: 'file.search' } }] }

      harness.send(:emit_step, msg)
      lines = drained_lines

      expect(lines).to include('file.search')
    end

    it 'emits only the step roles - no spinner pause/resume (drain loop owns that)' do
      harness.send(:emit_step, message)

      types = drain_outbox(task).map { |m| m[:type] }
      expect(types - step_roles).to be_empty
      expect(types).not_to include(:progress_pause, :progress_resume, :spinner_detail)
    end

    it 'emits nothing when disabled via HARNESS_STEP_DISPLAY=off' do
      original = ENV['HARNESS_STEP_DISPLAY']
      ENV['HARNESS_STEP_DISPLAY'] = 'off'

      begin
        harness.send(:emit_step, message)

        expect(drain_outbox(task)).to be_empty
      ensure
        ENV['HARNESS_STEP_DISPLAY'] = original
      end
    end
  end

  describe '#execute_tool_call spinner_detail (issue #40)' do
    let(:harness) { build_harness }
    let(:task) { emit_task }
    def drain_outbox(t)
      ms = []
      loop do
        m = t.poll(0); break unless m
        ms << m
      end
      ms
    end
    around do |example|
      @old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      example.run
    ensure
      Thread.current[:harness_task] = @old_current
    end

    let(:fake_tool) do
      Class.new(Tool) do
        def execute(_args)
          'ok'
        end
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
    end

    # issue #362: a wait is announced by whoever starts it, and the tool round
    # IS a wait (a slow command, a consent dialog). Without this re-point the
    # drain loop replays the LLM request line that already finished, so a
    # 40-second run.command reads as if the model were still generating.
    it 're-points the spinner with the tool name before the tool runs' do
      harness.tool_registry.register(fake_tool)
      call  = { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }

      expect(harness.send(:execute_tool_call, call)).to eq('ok')

      details = drain_outbox(task).select { |m| m[:type] == :spinner_detail }
      expect(details.size).to eq(1)
      # The origin is the emitter's symbol (the buffer records who spoke).
      expect(details.first[:origin]).to eq(:harness)
      expect(details.first[:content][:message]).to eq('ui.notify')
      # A tool round has no request in flight, so it carries no rate segment -
      # the suffix is the live context estimate, not a tok/s number.
      expect(details.first[:content][:suffix]).to respond_to(:call)
    end

    # The spinner line is ONE line, and tool arguments are model-supplied text
    # that must never be echoed onto it.
    it 'names the tool only - never its arguments' do
      harness.tool_registry.register(fake_tool)
      long  = { id: 'c1', function: { name: 'ui.notify',
                                      arguments: JSON.dump(text: 'x' * 500) } }

      harness.send(:execute_tool_call, long)

      detail = drain_outbox(task).find { |m| m[:type] == :spinner_detail }
      expect(detail[:content][:message]).to eq('ui.notify')
    end

    # issue #257: the tool result goes straight back into the message chain,
    # so an undecodable byte in it made the next JSON.generate (the request
    # body AND the session save) raise JSON::GeneratorError - and the failure
    # was invisible because the save that should record it died on the same
    # byte. execute_tool_call normalizes what enters the chain.
    it 'normalizes a tool result that carries an invalid byte' do
      harness = build_harness
      bad = [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)

      raw_tool = Class.new(Tool) do
        define_method(:execute) { |_args| bad }
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
      harness.tool_registry.register(raw_tool)

      result = harness.send(:execute_tool_call,
                            { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } })
      expect(result.valid_encoding?).to be true
      expect(result).to eq('?')
      # What the session save (JSON.generate) choked on before the fix.
      expect { JSON.generate({ 'content' => bad }) }.to raise_error(JSON::GeneratorError)
      expect { JSON.generate({ 'content' => result }) }.not_to raise_error
    end

    it 'does not emit spinner_detail for an unknown tool' do
      call = { id: 'c1', function: { name: 'nope.missing', arguments: '{}' } }

      expect(harness.send(:execute_tool_call, call)).to include('unknown tool')

      expect(drain_outbox(task).map { |m| m[:type] }).not_to include(:spinner_detail)
    end

    # issue #409: a tool that raises is an unexpected crash - the frames are
    # what explains it, so the log records them (ErrorText.detailed). The
    # string returned to the model stays the one-line label: a backtrace in a
    # tool result is noise it cannot act on, replayed on every request.
    it 'logs a raising tool WITH ITS FRAMES and returns the label to the model' do
      boom_tool = Class.new(Tool) do
        define_method(:execute) { |_args| nil.record }
      end.new(name: 'ui.notify', description: 'fake', parameters: {})
      harness.tool_registry.register(boom_tool)
      call = { id: 'c1', function: { name: 'ui.notify', arguments: '{}' } }

      result = harness.send(:execute_tool_call, call)

      expect(result).to eq(
        "error: NoMethodError: undefined method 'record' for nil"
      )
      log = File.read(harness.session_log_path)
      expect(log).to include("tool ui.notify failed: " \
                             "NoMethodError: undefined method 'record' for nil")
      expect(log).to include('harness_emit_spec.rb')
    end
  end

  # Some models wrap a call's arguments in an extra top-level "arguments" key,
  # so the tool reads its own parameters as missing (e.g. run.command gets
  # {"arguments": {"command": ...}} and 'command' is nil). execute_tool_call
  # unwraps that envelope through Tool#normalize_arguments before dispatch.
  describe '#execute_tool_call wrapped arguments envelope' do
    it 'runs a call whose arguments arrived wrapped in an extra arguments key' do
      h = build_harness
      wrapped = { 'arguments' => { 'text' => 'echoed' } }
      call = { id: 'c1', function: { name: 'test.echo',
                                     arguments: JSON.generate(wrapped) } }

      expect(h.send(:execute_tool_call, call)).to eq('echoed')
      expect(File.read(h.session_log_path))
        .to include("tool test.echo arguments arrived wrapped in an extra 'arguments' key")
    end

    it 'leaves a normal call untouched (no unwrap log line)' do
      h = build_harness
      call = { id: 'c1', function: { name: 'test.echo', arguments: '{"text":"plain"}' } }

      expect(h.send(:execute_tool_call, call)).to eq('plain')
      expect(File.read(h.session_log_path))
        .not_to include("arrived wrapped in an extra 'arguments' key")
    end
  end

  describe '#record_note (issue #138)' do
    def note_call(text)
      { id: 'c1', function: { name: 'session.note', arguments: JSON.dump(text: text) } }
    end

    it 'buffers the note when a session.note call succeeds' do
      harness = build_harness

      harness.record_note(note_call('granted read on lib/'), 'ok: noted 19 chars')

      expect(harness.session.instance_variable_get(:@notes))
        .to eq(['granted read on lib/'])
    end

    it 'does not buffer anything for a different tool' do
      harness = build_harness

      call = { id: 'c1', function: { name: 'file.read', arguments: '{}' } }
      harness.record_note(call, 'ok: noted 19 chars')

      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'does not buffer anything when the session.note call failed' do
      harness = build_harness

      harness.record_note(note_call('should not appear'), 'error: empty note')

      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end

    it 'survives a malformed arguments payload without raising' do
      harness = build_harness

      call = { id: 'c1', function: { name: 'session.note', arguments: '{not json' } }

      expect { harness.record_note(call, 'ok: noted 5 chars') }.not_to raise_error
      expect(harness.session.instance_variable_get(:@notes)).to be_nil
      # issue #345: the drop is now visible. It used to rescue to nothing, so a
      # session.note whose arguments never arrived was silently not buffered.
      expect(File.read(harness.session_log_path))
        .to include('session.note arguments did not parse')
    end

    it 'does not buffer anything when the result is not a string' do
      harness = build_harness

      harness.record_note(note_call('nope'), nil)

      expect(harness.session.instance_variable_get(:@notes)).to be_nil
    end
  end


  describe '#user_note / call_llm mid-turn note injection (issue #36)' do
    let(:harness) { build_harness_with_responses }

    it 'injects a pending note into the chain before the next LLM call' do
      harness.session.add_user('original prompt')
      harness.user_note_text = 'steer left'

      harness.call_llm

      sent = harness.client.calls.first
      expect(sent.last).to eq({ role: 'user', content: 'User note (mid-turn): steer left' })
    end

    it 'tracks injected notes on #user_notes and clears the pending slot' do
      harness.session.add_user('original prompt')
      harness.user_note_text = 'steer left'

      harness.call_llm

      expect(harness.user_notes).to eq(['steer left'])
      # issue #208: the note committed into the SESSION directly (it is in
      # the chain now), and a second turn sends that chain - nothing is
      # replayed or double-appended.
      expect(harness.session.messages.map { |m| m[:content].to_s })
        .to include('User note (mid-turn): steer left')
      expect(harness.session.pending?).to be(false)
      harness.session.add_user('next prompt')
      harness.call_llm

      second = harness.client.calls.last
      notes = second.select { |m| m[:content].to_s == 'User note (mid-turn): steer left' }
      expect(notes.size).to eq(1)
    end

    it 'ignores blank notes (the setter clears the slot)' do
      harness.user_note_text = '   '

      harness.session.add_user('original prompt')
      harness.call_llm

      sent = harness.client.calls.first
      expect(sent.map { |m| m[:content].to_s }).not_to include('User note (mid-turn):')
      expect(harness.user_notes).to be_empty
    end

    it 'keeps only the LATEST pending note (single slot in flight)' do
      # The user corrects their course mid-turn: the second line replaces
      # the first, so the model sees only the latest steering.
      harness.session.add_user('original prompt')
      harness.user_note_text = 'use ruby'
      harness.user_note_text = 'no - use python'

      harness.call_llm

      sent = harness.client.calls.first
      # Restrict to user messages: the built-in system prompt itself
      # documents the "User note (mid-turn):" prefix, so a substring match
      # over the whole chain would also catch the system message.
      notes = sent.select { |m| m[:role] == 'user' && m[:content].to_s.include?('User note (mid-turn):') }
      expect(notes).to eq([{ role: 'user', content: 'User note (mid-turn): no - use python' }])
      expect(harness.user_notes).to eq(['no - use python'])
      expect(harness.session.pending?).to be(false) # final reply committed
    end

    # issue #430: a note typed WHILE the final answer's request is in flight
    # cannot steer that answer any more. It is dropped, not kept for a later
    # turn: the honest ack ("arrived too late") replaces the phantom injection.
    def drained_status_events(task)
      events = []
      loop do
        m = task.poll(0)
        break unless m
        events << m
      end
      events.select { |m| m[:type].to_s.start_with?('status_') }
    end

    def late_note_harness
      client = fake_scripted_client([{ content: 'the final answer' }])
      h = build_harness_with_responses([{ content: 'the final answer' }])
      h.instance_variable_set(:@client, client)
      # The hook runs after the final answer is built but before call_llm
      # returns - exactly the race the issue describes.
      client.after_call = -> { h.user_note_text = 'use ruby instead' }
      [h, client]
    end

    it 'discards a note that arrives while the final answer is being produced' do
      harness, = late_note_harness
      harness.session.add_user('original prompt')

      expect(harness.call_llm[:content]).to eq('the final answer')

      sent = harness.client.calls.first
      notes = sent.select { |m| m[:role] == 'user' && m[:content].to_s.include?('User note (mid-turn):') }
      expect(notes).to be_empty
      expect(harness.user_notes).to be_empty
      # Nothing phantom is left for a later turn either.
      expect(harness.session.messages.map { |m| m[:content].to_s })
        .not_to include(a_string_including('use ruby instead'))
      expect(harness.client.calls.size).to eq(1)
    end

    it 'does not leak a late note into the NEXT turn (the reported bug)' do
      harness, = late_note_harness
      harness.session.add_user('original prompt')
      harness.call_llm

      harness.session.add_user('an unrelated prompt')
      harness.call_llm

      second = harness.client.calls.last
      expect(second.map { |m| m[:content].to_s }).not_to include(a_string_including('use ruby instead'))
      expect(second.map { |m| m[:content].to_s }).to include('an unrelated prompt')
    end

    it 'says on the console that the late note was NOT applied (issue #430)' do
      harness, = late_note_harness
      task = emit_task
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drained_status_events(task)
      late = events.select { |m| m[:origin] == 'note' }
      expect(late.size).to eq(1)
      expect(late.first[:type]).to eq(:status_warn)
      expect(late.first[:content]).to include('arrived too late to steer this answer')
      expect(late.first[:content]).to include('NOT sent to the model')
      # issue #450: the console line must name WHICH note, not only why it
      # was dropped - the log line already carried the text, the console did not.
      expect(late.first[:content]).to include('use ruby instead')
      # The note itself is named, so the user knows which one the line refers to.
      expect(File.read(harness.session_log_path))
        .to include('user mid-turn note discarded (late): use ruby instead')
    end

    it 'leaves the "sent to model" ack when the note WAS injected' do
      task = emit_task
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.user_note_text = 'steer left'
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      expect(drained_status_events(task).map { |m| m[:content] })
        .not_to include(a_string_matching(/too late/))
    end

    it 'says nothing when no note is pending at the final answer' do
      task = emit_task
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      expect(drained_status_events(task).select { |m| m[:origin] == 'note' }).to be_empty
    end

    describe '#discard_pending_user_note (issue #430)' do
      it 'returns nil and emits nothing when nothing is pending' do
        task = emit_task
        old_current = Thread.current[:harness_task]
        Thread.current[:harness_task] = task
        begin
          expect(harness.discard_pending_user_note(:leftover)).to be_nil
        ensure
          Thread.current[:harness_task] = old_current
        end

        expect(drained_status_events(task)).to be_empty
      end

      it 'clears the pending slot so the note cannot reach a later turn' do
        harness.user_note_text = 'stale steering'

        expect(harness.discard_pending_user_note(:leftover)).to eq('stale steering')

        harness.session.add_user('next prompt')
        harness.call_llm
        expect(harness.client.calls.last.map { |m| m[:content].to_s })
          .not_to include(a_string_including('stale steering'))
      end

      it 'names the leftover case differently from the late one' do
        task = emit_task
        old_current = Thread.current[:harness_task]
        Thread.current[:harness_task] = task
        begin
          harness.user_note_text = 'stale steering'
          harness.discard_pending_user_note(:leftover)
        ensure
          Thread.current[:harness_task] = old_current
        end

        line = drained_status_events(task).first[:content]
        expect(line).to include('left over from your previous turn')
        # issue #450: the leftover line names WHICH note too.
        expect(line).to include('stale steering')
        expect(File.read(harness.session_log_path))
          .to include('user mid-turn note discarded (leftover): stale steering')
      end
    end

    it 'shows a console ack that the note was sent to the model (issue #198)' do
      task = emit_task
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.user_note_text = 'steer left'
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      # The ack is a STATUS event: content is the message, the bracket label
      # is the origin and UI::Renderer supplies the indent and the bracket.
      expect(drained_lines(task)).to include('sent to model')
    end

    it 'shows no "sent to model" ack when there is no note' do
      task = emit_task
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      begin
        harness.session.add_user('original prompt')
        harness.call_llm
      ensure
        Thread.current[:harness_task] = old_current
      end

      expect(drained_lines(task)).not_to include('sent to model')
    end
  end

  # issue #548 F: a save request flips a flag; the AGENT saves its own chain at the
  # next tool-loop iteration (on the job's own thread), never read by another thread.
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

end

