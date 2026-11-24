# frozen_string_literal: true

require 'logger'
require 'task'
require 'harness'
require 'job_registry'
require 'ui/spinner'
require 'stringio'

RSpec.describe Task do
  def drain_outbox(task)
    events = []
    loop do
      msg = task.poll(0)
      break unless msg
      events << msg
    end
    events
  end

  def spec_harness
    Class.new do
      def initialize
        @output_log = OutputBuffer.new
        @settings   = SystemSettings.from_options({ output_palette: 'none' })
      end

      attr_reader :output_log
      attr_reader :settings

      # #286: a non-nil harness answers the whole interface Task#prepare reads
      # off it; the palette and markdown knobs live under #settings (none = plain).
      def logger = nil
    end.new
  end

  # A Task always runs on a registry + job (#286): the run's registry is its
  # executor and the home of the run record. These stand-ins build the smallest
  # real one (a single main job) so every Task here is a genuine registry task.
  def new_task(input_path: nil, &block)
    registry = JobRegistry.new
    job = registry.add_job(kind: :main)
    described_class.new(registry:, job:, input_path:, &block)
  end

  describe 'push_event (single event queue)' do
    it 'delivers messages to the outbox in order' do
      task = new_task do |t|
        t.push_event(type: :output, origin: :harness, content: 'hello')
        t.push_event(type: :stats, origin: :harness, content: '3 iterations')
      end
      task.start

      sleep 0.1 # let the thread start and push its events before draining
      messages = drain_outbox(task)

      expect(messages.map { |m| m[:type] }).to eq(%i[output stats done])
      expect(messages[0][:content]).to eq('hello')
      expect(messages[1][:content]).to eq('3 iterations')
    end

    it 'delivers a :done message when the block completes' do
      task = new_task { |_t| }
      task.start

      msg = nil
      20.times do
        msg = task.poll(0.5)
        break if msg && msg[:type] == :done
      end
      expect(msg[:type]).to eq(:done)
    end
  end

  describe 'request / respond' do
    it 'blocks the task thread until the main thread responds' do
      task = new_task do |t|
        reply = t.request(:test_request, key: 'value')
        # After unblock, push the received value for verification
        t.push_event(type: :result, origin: :task, content: reply)
      end
      task.start

      # Poll for the request message
      msg = nil
      20.times do
        msg = task.poll(0.5)
        break if msg && msg[:type] == :__request__
      end

      expect(msg).to be_a(Hash)
      expect(msg[:type]).to eq(:__request__)
      expect(msg[:kind]).to eq(:test_request)
      expect(msg[:key]).to eq('value')

      # Respond to unblock the task thread
      task.respond('the_answer')

      # Now poll for the result (pushed after unblock)
      result_msg = nil
      20.times do
        m = task.poll(0.5)
        next if m.nil?

        result_msg = m if m[:type] == :result
        break if m[:type] == :done
      end

      expect(result_msg[:content]).to eq('the_answer')
    end

    it 'captures the error when task is stopped while waiting' do
      task = new_task do |t|
        t.request(:forever) # will never be responded to
      end
      task.start

      # Wait for the request to arrive in the outbox
      msg = nil
      20.times do
        msg = task.poll(0.5)
        break if msg && msg[:type] == :__request__
      end
      expect(msg[:type]).to eq(:__request__)

      # Stop the task: sends STOP to inbox, unblocking the pending request
      task.stop(2)

      # Drain remaining messages (the rescue in start ensures :error_ctrl + :done)
      got_done = false
      20.times do
        m = task.poll(0.5)
        break if m.nil?

        got_done = true if m[:type] == :done
        break if got_done
      end
      expect(got_done).to be(true)
    end

    # issue #424: a steering note that already sits in the shared inbox (typed
    # earlier in the turn, before the dialog opened) must NOT be mistaken for
    # the request's answer. A dedicated per-request reply channel keeps the
    # answer apart from inbox-resident notes, so the request gets the real
    # answer and the note stays queued for steering.
    it 'does not consume a queued steering note as the request answer' do
      registry = JobRegistry.new
      main     = registry.add_job(kind: :main)
      note     = { type: :note, content: 'a steering note' }
      # The note lands in the inbox BEFORE the request is posted.
      main.deliver(note)

      task = described_class.new(registry:, job: main) do |t|
        t.push_event(type: :result, origin: :task, content: t.request(:dialog))
      end
      task.start

      msg = nil
      20.times { msg = task.poll(0.5); break if msg && msg[:type] == :__request__ }
      expect(msg[:type]).to eq(:__request__)

      task.respond(:allow)

      answer = nil
      20.times do
        m = task.poll(0.5)
        next if m.nil?

        answer = m[:content] if m[:type] == :result
        break if m[:type] == :done
      end
      expect(answer).to eq(:allow)
      # The note was NOT swallowed as the answer - it stays for steering.
      expect(main.poll(0)).to eq(note)
    end
  end

  describe 'stop' do
    it 'joins the thread and sets @thread to nil' do
      task = new_task do |t|
        t.request(:forever) # blocks forever
      end
      task.start
      expect(task.alive?).to be(true)

      task.stop(2)
      expect(task.thread).to be_nil
    end

    # Ctrl+C: the default join grace is short, not 5s. A task thread blocked in
    # a long call (the LLM read) never reads STOP, so the old 5s join was why an
    # interrupted turn stalled ~5s before killing it.
    it 'uses a short default join grace (Ctrl+C must not stall on a blocked thread)' do
      expect(described_class::DEFAULT_STOP_JOIN_TIMEOUT).to be <= 1.0
    end

    # A force-stopped turn answers every request it still owes with a VALUE, not
    # STOP: STOP is not an answer, so a requester blocked on that request would
    # raise on it. Here the owed request belongs to another job (a background
    # round), so it is answered and the stopping worker still gets its own STOP
    # on its await queue (the job inbox is the drain loop's reader-side queue).
    it 'answers another job owed request and still stops its own thread' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      background = registry.add_job(kind: :command, requested_by: main)
      task = described_class.new(registry:, job: main) { }
      background.mark_awaiting

      task.stop(0.1)

      expect(background.inbox.pop(true)).to eq(Job::INTERRUPTED_ANSWER)
      expect(task.await_work.pop(true)).to equal(Task::STOP)
    end

    # When the owed request is the stopping thread's OWN inbox, the interrupted
    # answer already lands there, so no STOP is pushed on top of it.
    it 'does not push STOP over the answer it just delivered to its own inbox' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      task = described_class.new(registry:, job: main) { }
      main.mark_awaiting

      task.stop(0.1)

      answer = main.inbox.pop(true)
      expect(answer).to eq(Job::INTERRUPTED_ANSWER)
      expect(answer).not_to equal(Job::STOP)
      expect(main.awaiting?).to be false
      expect(main.inbox).to be_empty
    end
  end

  describe 'Task.puts (single event queue)' do
    it 'pushes :text events onto the active task outbox' do
      task = new_task { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        Task.puts 'hello from task'
        Task.puts 'second line'
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events.map { |m| m[:type] }).to eq(%i[text text])
      expect(events[0][:content]).to eq('hello from task')
      expect(events[1][:content]).to eq('second line')
    end

    it 'is a no-op when no task is active (CLI owns main-thread output)' do
      expect { Task.puts 'no task around' }.not_to raise_error
    end
  end

  # Tool.puts is gone (issue #146): a status emitter states a VERDICT and the
  # bracket label, and UI::Renderer builds the line from them.
  describe 'Tool#status (tools push a verdict event onto the active task outbox)' do
    it 'pushes the verdict type with the tool name as origin' do
      task = new_task { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task
      tool = Class.new(Tool) do
        def initialize
          super(name: 'test.tool', description: 'spec tool', parameters: {})
        end
      end.new

      begin
        tool.status(:ok, 'ok')
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events[0][:type]).to eq(:status_ok)
      expect(events[0][:origin]).to eq('test.tool')
      expect(events[0][:content]).to eq('ok')
      expect(UI::Renderer.new.line(**events[0].slice(:type, :content, :origin))).to eq(
        '  [test.tool] ✓ ok'
      )
    end

    it 'is a no-op when no task is active (CLI owns main-thread output)' do
      expect { Tool.push_status(label: 'test.tool', verdict: :ok, message: 'ok') }.not_to raise_error
    end
  end

  describe 'Task.emit (structured events on the outbox)' do
    it 'pushes a typed event onto the active task outbox' do
      task = new_task { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        Task.emit(:plan, origin: :harness, content: 'read the tool first')
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events[0][:type]).to eq(:plan)
      expect(events[0][:origin]).to eq(:harness)
      expect(events[0][:content]).to eq('read the tool first')
    end

    it 'is a no-op when no task is active (nothing to drain for)' do
      expect { Task.emit(:stats, origin: :harness, content: '3 iterations') }.not_to raise_error
    end

    it 'stores non-string payloads (e.g. spinner_detail Hashes) intact' do
      task = new_task { }
      old_current = Thread.current[:harness_task]
      Thread.current[:harness_task] = task

      begin
        payload = { message: 'Sending', suffix: 'ctx 99%' }
        Task.emit(:spinner_detail, origin: :session_manager, content: payload)
      ensure
        Thread.current[:harness_task] = old_current
      end

      events = drain_outbox(task)
      expect(events[0][:type]).to eq(:spinner_detail)
      expect(events[0][:content]).to be_a(Hash)
      expect(events[0][:content][:message]).to eq('Sending')
    end
  end

  describe 'the ONE spinner (owned by the drain loop)' do
    let(:task) { new_task { |_t| } }

    def make_spinner(running: true)
      sp = UI::Spinner.new('Working', ui: UI::Console.new(stdout: StringIO.new))
      running ? sp.start : nil
      sp
    end

    it 'spinner= replaces the spinner and visible_spinner tracks it' do
      a = make_spinner
      b = make_spinner

      task.spinner = a
      expect(task.visible_spinner).to equal(a)

      b.start
      task.spinner = b
      expect(task.visible_spinner).to equal(b)
    end

    it 'visible_spinner is nil when no spinner has been set yet' do
      expect(task.spinner).to be_nil
      expect(task.visible_spinner).to be_nil
    end

    it 'visible_spinner is nil once the spinner is stopped' do
      sp = make_spinner
      task.spinner = sp
      sp.stop

      expect(task.visible_spinner).to be_nil
    end

    it 'clear_all_spinners stops the spinner' do
      sp = make_spinner
      task.spinner = sp

      task.clear_all_spinners

      expect(sp.running?).to be(false)
      expect(task.visible_spinner).to be_nil
    end
  end

  # issue #221 review (bug 1): the spinner content the task asked for is
  # remembered, so a spinner rebuilt later in the same wait does not fall
  # back to the bare 'Working' default.
  # issue #286: the head cell IS the memory. A re-point lands in the buffer's
  # head (never the tail), and the rebuild reads the most recently updated
  # spinner head cell - so the live state and the replay are the same object.
  describe 'spinner head memory (issue #286)' do
    let(:task) { new_task { |_t| } }

    it 'the spinner head cell is nil until a re-point lands in the head' do
      expect(task.buffer.latest_head(:spinner_detail)).to be_nil
    end

    it 'a re-point lands as a head cell, never a tail entry' do
      task.buffer.put(type: :spinner_detail, origin: :session_manager,
                      content: { message: 'Sending', suffix: 'ctx 12%' })

      expect(task.buffer.head.size).to eq(1)
      expect(task.buffer.tail).to be_empty
      expect(task.buffer.latest_head(:spinner_detail).content)
        .to eq(message: 'Sending', suffix: 'ctx 12%')
    end

    # A new wait must re-play its OWN re-point, not one from a finished wait:
    # the head cell for a spinner is replaced, so it holds the newest state.
    it 'the head holds the newest re-point, not one from an earlier wait' do
      task.buffer.put(type: :spinner_detail, origin: :session_manager,
                      content: { message: 'Compacting session mid-task' })
      task.buffer.put(type: :spinner_detail, origin: :session_manager,
                      content: { message: 'Sending to model' })

      expect(task.buffer.latest_head(:spinner_detail).content).to eq(message: 'Sending to model')
    end

  end

  describe 'Task#elapsed_label (issue #277)' do
    it 'counts whole seconds below a minute' do
      task = new_task { |_t| }
      task.instance_variable_set(:@started_at, Time.now - 12.7)

      expect(task.elapsed_label).to eq('12s')
    end

    it 'switches to minutes past a minute, zero-padded seconds' do
      task = new_task { |_t| }
      task.instance_variable_set(:@started_at, Time.now - 123)

      expect(task.elapsed_label).to eq('2m 03s')
    end
  end


  # issue #286 increment 2: a task built for a job reads the registry's ONE
  # queue instead of its own outbox, its inbox IS the job's inbox, and the
  # block's value becomes the result the caller awaits on :done.
  describe 'a task built for a job (the registry is the executor)' do
    def registry_task(registry, job, &)
      task = described_class.new(registry:, job:, &)
      task.ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      task
    end

    it 'its inbox IS the job inbox, so the registry answer reaches it' do
      registry = JobRegistry.new
      job = registry.add_job(kind: :main)
      task = registry_task(registry, job) { }
      task.respond('answer')

      # Same queue seen from both sides - the registry routes answers to it.
      expect(job.poll(0)).to eq('answer')
    end

    it 'its buffer IS the job buffer' do
      registry = JobRegistry.new
      job = registry.add_job(kind: :main)
      task = registry_task(registry, job) { }

      expect(task.buffer).to equal(job.buffer)
    end

    # A Task is a job's RUNNER, not the queue's reader: #poll hands back the next
    # event whatever job it names. Deciding which job's events to show - and
    # recording the rest - is the drain loop's (main_loop_spec).
    it 'poll returns a foreign-job event without recording it' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      task = registry_task(registry, main) { }
      other.push_event(type: :text, origin: :task, content: 'from job 1')

      event = task.poll(0)
      expect(event[:job]).to eq(other.id)
      expect(other.buffer.tail).to be_empty
      expect(main.buffer.tail).to be_empty
    end

    it 'outbox_empty? reads the ONE registry queue' do
      registry = JobRegistry.new
      job = registry.add_job(kind: :main)
      task = registry_task(registry, job) { }

      expect(task.outbox_empty?).to be true
      job.push_event(type: :text, content: 'waiting')
      expect(task.outbox_empty?).to be false
    end

    # service_turn pushes :done with the block's value; JobRegistry#record is
    # what turns that event into the job's finish + result.
    it 'the block value lands as the :done result record finishes the job with' do
      registry = JobRegistry.new
      job = registry.add_job(kind: :main)

      registry.record(job.push_event(type: :done, result: :turn_value))

      expect(job.finished?).to be true
      expect(job.result).to eq(:turn_value)
    end
  end
end
