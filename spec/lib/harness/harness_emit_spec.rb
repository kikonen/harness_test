# frozen_string_literal: true

require_relative 'harness_spec_support'

RSpec.describe Harness, 'emit and tool-execution display (issues #131, #40, #138, #36)' do
  include HarnessSpecSupport

  describe '#user_note / call_llm mid-turn note injection (issue #36)' do
    let(:harness) { build_harness_with_responses }

    it 'injects a pending note into the chain before the next LLM call' do
      harness.session.add_user('original prompt')
      harness.user_note_text = 'steer left'

      harness.call_llm

      sent = harness.client.calls.first
      expect(sent.last).to eq({ role: 'user', content: 'User note (mid-turn): steer left' })
    end

    it 'hands injected notes to the caller list and clears the pending slot' do
      harness.session.add_user('original prompt')
      harness.user_note_text = 'steer left'

      notes = []
      harness.call_llm(notes: notes)

      expect(notes).to eq(['steer left'])
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
      notes = []
      harness.call_llm(notes: notes)

      sent = harness.client.calls.first
      expect(sent.map { |m| m[:content].to_s }).not_to include('User note (mid-turn):')
      expect(notes).to be_empty
    end

    it 'keeps only the LATEST pending note (single slot in flight)' do
      # The user corrects their course mid-turn: the second line replaces
      # the first, so the model sees only the latest steering.
      harness.session.add_user('original prompt')
      harness.user_note_text = 'use ruby'
      harness.user_note_text = 'no - use python'

      notes = []
      harness.call_llm(notes: notes)

      sent = harness.client.calls.first
      # Restrict to user messages: the built-in system prompt itself
      # documents the "User note (mid-turn):" prefix, so a substring match
      # over the whole chain would also catch the system message.
      injected = sent.select { |m| m[:role] == 'user' && m[:content].to_s.include?('User note (mid-turn):') }
      expect(injected).to eq([{ role: 'user', content: 'User note (mid-turn): no - use python' }])
      expect(notes).to eq(['no - use python'])
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
      # The note arrived mid-call: nothing was injected, so the list stays empty.

      sent = harness.client.calls.first
      notes = sent.select { |m| m[:role] == 'user' && m[:content].to_s.include?('User note (mid-turn):') }
      expect(notes).to be_empty
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
      expect(File.read(harness.locator.session_log_path))
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
        expect(File.read(harness.locator.session_log_path))
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

