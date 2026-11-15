# frozen_string_literal: true

require 'logger'
require 'task'
require 'harness'
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

  # Issue #286: a Task is GIVEN a buffer and never builds one, so every stand-in
  # Task here is handed one; Task.run reads the buffer off the harness, so its
  # doubles answer output_log.
  def spec_buffer
    OutputBuffer.new
  end

  def spec_harness
    Class.new do
      def initialize
        @output_log = OutputBuffer.new
      end

      attr_reader :output_log
    end.new
  end

  describe 'push_event (single event queue)' do
    it 'delivers messages to the outbox in order' do
      task = described_class.new(buffer: spec_buffer) do |t|
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
      task = described_class.new(buffer: spec_buffer) { |_t| }
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
      task = described_class.new(buffer: spec_buffer) do |t|
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
      task = described_class.new(buffer: spec_buffer) do |t|
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

      task = described_class.new(buffer: nil, registry:, job: main) do |t|
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
      task = described_class.new(buffer: spec_buffer) do |t|
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
    # round), so it is answered and the stopping thread still gets its own STOP.
    it 'answers another job owed request and still stops its own thread' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      background = registry.add_job(kind: :command, requested_by: main)
      task = described_class.new(buffer: nil, registry:, job: main) { }
      background.mark_awaiting

      task.stop(0.1)

      expect(background.inbox.pop(true)).to eq(Job::INTERRUPTED_ANSWER)
      expect(main.inbox.pop(true)).to equal(Task::STOP)
    end

    # When the owed request is the stopping thread's OWN inbox, the interrupted
    # answer already lands there, so no STOP is pushed on top of it.
    it 'does not push STOP over the answer it just delivered to its own inbox' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      task = described_class.new(buffer: nil, registry:, job: main) { }
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
      task = described_class.new(buffer: spec_buffer) { }
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
      task = described_class.new(buffer: spec_buffer) { }
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
      task = described_class.new(buffer: spec_buffer) { }
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
      task = described_class.new(buffer: spec_buffer) { }
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
    let(:task) { described_class.new(buffer: spec_buffer) { |_t| } }

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
    let(:task) { described_class.new(buffer: spec_buffer) { |_t| } }

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

    # The order is the point (issue #286): the data lands in the HEAD first,
    # and the spinner content is built FROM the head cell - not from the raw
    # event. A recording stand-in spinner proves the value it receives is the
    # head cell's content, so the head is the single source of live state.
    it 'store_and_render puts the head first, then builds the spinner from the head' do
      task.ui = UI::Console.new(stdout: StringIO.new)
      seen = []
      recorder = Class.new do
        define_method(:update_detail) { |message:, suffix:| seen << [message, suffix] }
        define_method(:running?) { true }
      end.new
      task.spinner = recorder

      Task.store_and_render(task, { type: :spinner_detail, origin: :session_manager,
                                    content: { message: 'Sending', suffix: 'ctx 12%' } })

      expect(task.buffer.cell(:session_manager, :spinner_detail).content)
        .to eq(message: 'Sending', suffix: 'ctx 12%')
      expect(seen).to eq([['Sending', 'ctx 12%']])
    end
  end

  # issue #286: ONE buffer per run. The task uses the buffer the harness hands it
  # rather than building its own, so the drain loop's writes and the record a save
  # reads are the same object. The buffer's limits belong to the buffer.
  describe 'the run buffer the task is given (issue #286)' do
    it 'the task uses the buffer the harness hands it' do
      harness = spec_harness
      _err, task = described_class.run(
        harness:,
        ui: UI::Console.new(stdout: StringIO.new, stdin: StringIO.new(''))) { |_t| }
      expect(task.buffer).to equal(harness.output_log)
    end
  end

  # issue #224 follow-up: the spinner badge ALWAYS shows the command
  # consent mode (live, re-read every frame) when the harness exposes it.
  describe 'Task.ensure_spinner_running mode badge (issue #224 follow-up)' do
    def mode_harness(label)
      h = Class.new do
        define_method(:command_mode_label) { label }
      end.new
      h
    end

    it 'installs a live badge callable when the harness has a mode label' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('AUTO-APPROVE')

      described_class.ensure_spinner_running(task)

      expect(task.visible_spinner.badge).to respond_to(:call)
      expect(task.visible_spinner.badge.call).to eq('[AUTO-APPROVE]')
    end

    it 'installs no badge for a harness without a mode (unit-test harness)' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = Object.new # no command_mode_label

      described_class.ensure_spinner_running(task)

      expect(task.visible_spinner.badge).to be_nil
    end

    it 'mode_badge is nil when the label is nil (safety check off)' do
      expect(described_class.mode_badge(mode_harness(nil))).to be_nil
    end

    # issue #221 review: the bare bracketed label IS the tag - a "cmd:"
    # prefix inside the brackets says nothing the brackets do not say.
    it 'mode_badge brackets the bare label for display' do
      expect(described_class.mode_badge(mode_harness('MANUAL')))
        .to eq('[MANUAL]')
      expect(described_class.mode_badge(mode_harness('AUTO-APPROVE')))
        .to eq('[AUTO-APPROVE]')
      # issue #221: YOLO wins the badge the same way (Harness#command_mode_label).
      expect(described_class.mode_badge(mode_harness('YOLO'))).to eq('[YOLO]')
    end

    # issue #28: the streaming posture is a second tag on the SAME badge, so
    # a mid-turn /stream toggle is visible while the answer is arriving.
    def posture_harness(command_label, stream_label, plan_label = nil)
      Class.new do
        define_method(:command_mode_label) { command_label }
        define_method(:stream_mode_label) { stream_label }
        define_method(:plan_mode_label) { plan_label }
      end.new
    end

    it 'mode_badge adds the stream tag alongside the consent tag' do
      harness = posture_harness('MANUAL', 'STREAM')

      expect(described_class.mode_badge(harness)).to eq('[MANUAL] [STREAM]')
    end

    it 'mode_badge shows only the stream tag when the consent label is nil' do
      expect(described_class.mode_badge(posture_harness(nil, 'STREAM')))
        .to eq('[STREAM]')
    end

    # Buffered is the default posture, so it gets no tag: a badge names what
    # is NOT the default (the same rule as YOLO / AUTO-APPROVE).
    it 'mode_badge shows no stream tag when streaming is off' do
      expect(described_class.mode_badge(posture_harness('MANUAL', nil)))
        .to eq('[MANUAL]')
    end

    # issue #359: the planning posture is a third tag on the SAME badge.
    it 'mode_badge adds the plan tag alongside the consent and stream tags' do
      harness = posture_harness('MANUAL', 'STREAM', 'PLAN')

      expect(described_class.mode_badge(harness)).to eq('[MANUAL] [STREAM] [PLAN]')
    end

    # Off is the default posture, so it gets no tag (the same rule as STREAM).
    it 'mode_badge shows no plan tag when planning is off' do
      expect(described_class.mode_badge(posture_harness('MANUAL', nil, nil)))
        .to eq('[MANUAL]')
    end

    it 'installs a badge when the harness only exposes the plan label' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = Class.new { def plan_mode_label = 'PLAN'; }.new

      described_class.ensure_spinner_running(task)

      expect(task.visible_spinner.badge.call).to eq('[PLAN]')
    end

    it 'installs a badge when the harness only exposes the stream label' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = Class.new { def stream_mode_label = 'STREAM'; }.new

      described_class.ensure_spinner_running(task)

      expect(task.visible_spinner.badge.call).to eq('[STREAM]')
    end

    # A live callable: a /stream toggle mid-turn shows on the very next frame.
    it 're-reads both tags on every frame (a mid-turn toggle shows at once)' do
      stream = false
      harness = Class.new do
        define_method(:command_mode_label) { 'MANUAL' }
        define_method(:stream_mode_label) { stream ? 'STREAM' : nil }
      end.new
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = harness

      described_class.ensure_spinner_running(task)
      before = task.visible_spinner.badge.call
      stream = true
      after = task.visible_spinner.badge.call

      expect(before).to eq('[MANUAL]')
      expect(after).to eq('[MANUAL] [STREAM]')
    end

    it 'does not replace an already running spinner' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('MANUAL')

      described_class.ensure_spinner_running(task)
      first = task.spinner
      described_class.ensure_spinner_running(task)
      expect(task.spinner).to equal(first)
    end

    # issue #221 review (bug 1): the spinner is recreated whenever the
    # outbox empties again after an output batch cleared it - the new
    # spinner must show the message the task asked for, not 'Working'.
    it 'a rebuilt spinner re-plays the recorded spinner detail' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('MANUAL')
      # The head cell is the memory the rebuild reads (issue #286): the
      # store_and_render path lands the re-point as a head cell.
      task.buffer.put(type: :spinner_detail, origin: :session_manager,
                      content: { message: 'Sending to qwen', suffix: 'ctx 12%' })

      described_class.ensure_spinner_running(task)
      line = task.visible_spinner.frame_line

      expect(line).to include('Sending to qwen...')
      expect(line).to include('ctx 12%')
      expect(line).not_to include('Working')
    end

    # Issue #277: the spinner shows how long the TURN has been running. The
    # clock belongs to the Task (it survives the spinner rebuilds), and the
    # spinner gets it as a callable so a rebuilt spinner keeps counting from
    # the turn's start instead of from its own construction.
    it 'installs a live elapsed clock on the spinner' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('MANUAL')
      task.start

      described_class.ensure_spinner_running(task)
      expect(task.visible_spinner.elapsed).to respond_to(:call)
      expect(task.visible_spinner.elapsed.call).to match(/\A\d+s\z/)
    end

    it 'elapsed_label is nil before the task is started (no turn to measure)' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.ui = UI::Console.new(stdout: StringIO.new)

      expect(task.elapsed_label).to be_nil
      described_class.ensure_spinner_running(task)
      expect(task.visible_spinner.frame_line)
        .to eq("#{UI::Spinner::FRAMES[0]} Working...")
    end
  end

  describe 'Task#elapsed_label (issue #277)' do
    it 'counts whole seconds below a minute' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.instance_variable_set(:@started_at, Time.now - 12.7)

      expect(task.elapsed_label).to eq('12s')
    end

    it 'switches to minutes past a minute, zero-padded seconds' do
      task = described_class.new(buffer: spec_buffer) { |_t| }
      task.instance_variable_set(:@started_at, Time.now - 123)

      expect(task.elapsed_label).to eq('2m 03s')
    end
  end

  describe 'Task.run (drain loop, issue #40)' do
    # issue #303 / #146: color reaches the CONSOLE only. The buffer is the
    # durable record a future renderer re-renders, so an escape byte in it
    # would be baked in forever.
    it 'colors the console line but stores plain role content in the buffer' do
      io_out = StringIO.new
      io_in  = StringIO.new
      palette = UI::Palette.fetch('default')
      harness = Class.new do
        define_method(:output_palette) { palette }
        define_method(:output_log) { OutputBuffer.new }
      end.new

      _err, task = described_class.run(harness: harness,
                                       ui: UI::Console.new(stdout: io_out, stdin: io_in)) do
        Task.emit(:plan, origin: :harness, content: 'read the tool first')
        Task.emit(:error, origin: :session_manager, content: 'hunk did not apply')
      end

      expect(io_out.string).to include("\e[34mplan:  read the tool first\e[0m")

      stored = task.buffer.tail
      expect(stored.map(&:content)).to eq(['read the tool first', 'hunk did not apply'])
      expect(stored.map(&:type)).to eq(%i[plan error])
      expect(stored.any? { |e| e.content.to_s.include?("\e") }).to eq(false)
    end

    # A multi-line status message is ONE buffer entry but MANY console lines:
    # the gutter and the closing rule are renderer output, never record bytes.
    it 'renders a multi-line status entry with a gutter but stores one plain entry' do
      io_out = StringIO.new
      io_in  = StringIO.new
      message = "ruby -e '\nputs 1\nputs 2\n'"

      _err, task = described_class.run(harness: spec_harness,
                                       ui: UI::Console.new(stdout: io_out, stdin: io_in)) do
        Tool.push_status(label: 'run.command', verdict: :ok, message:)
      end

      expect(io_out.string.lines.map(&:chomp)).to eq(
        ["  [run.command] ✓ ruby -e '",
         '  | puts 1',
         '  | puts 2',
         "  | '",
         '  ------------']
      )

      stored = task.buffer.tail
      expect(stored.size).to eq(1)
      expect(stored.first.type).to eq(:status_ok)
      # OutputBuffer#normalize turns every origin into a symbol, so the bracket
      # label travels as :"run.command" and the renderer interpolates it back.
      expect(stored.first.origin).to eq(:'run.command')
      expect(stored.first.content).to eq(message)
    end

    it 'runs the block and drains all output' do
      io_out = StringIO.new
      io_in = StringIO.new

      error, task = described_class.run(harness: spec_harness,
                                       ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.puts 'greeting'
      end

      expect(error).to be_nil
      expect(task.alive?).to be(false)
    end

    it 'captures an exception in the task as the return error' do
      io_out = StringIO.new
      io_in = StringIO.new

      error, _task = described_class.run(harness: spec_harness,
                                         ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        raise 'boom'
      end

      expect(error).to include('RuntimeError')
      expect(error).to include('boom')
    end

    # A task thread owns no console (single-thread I/O rule) and the drain loop
    # carries ONE line, so without the harness logger the frames die with the
    # thread: the user saw "[task error] Class: message" and harness.log had
    # nothing to trace it back to.
    it 'logs a task-thread exception WITH ITS FRAMES in the harness logger' do
      log = StringIO.new
      harness = Class.new do
        define_method(:logger) { Logger.new(log) }
        define_method(:output_log) { OutputBuffer.new }
      end.new

      error, = described_class.run(harness:,
                                   ui: UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)) do
        nil.record
      end

      expect(error).to eq("NoMethodError: undefined method 'record' for nil")
      logged = log.string
      expect(logged).to include('ERROR')
      expect(logged).to include("task thread raised: NoMethodError: undefined method 'record' for nil")
      # The frames: the raising line and the drain-loop frame that ran the block.
      expect(logged).to include('task_spec.rb')
      expect(logged).to include('lib/task.rb')
    end

    # A harness double with no logger must not turn a task error into a second
    # error on the error path.
    it 'still returns the one-line error when the harness answers no logger' do
      error, = described_class.run(harness: spec_harness,
                                   ui: UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)) do
        raise 'boom'
      end

      expect(error).to eq("RuntimeError: boom")
    end

    it 'shows a spinner automatically while waiting on the task thread' do
      io_out = StringIO.new
      io_in = StringIO.new

      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        sleep 0.3 # let the drain loop render a few default frames
      end

      expect(io_out.string).to include('Working...')
    end

    # issue #277: a waiting turn shows its elapsed time right after the glyph.
    it 'shows the turn elapsed segment in the spinner frames' do
      io_out = StringIO.new
      io_in  = StringIO.new

      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        sleep 0.35
      end

      expect(io_out.string)
        .to match(/#{Regexp.escape(UI::Spinner::FRAMES[0])} \d+s Working\.\.\./)
    end

    it 're-points the spinner from :spinner_detail events' do
      io_out = StringIO.new
      io_in = StringIO.new

      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.emit(:spinner_detail, origin: :session_manager,
                  content: { message: 'Sending', suffix: 'ctx 12%' })
        sleep 0.3 # let the drain loop render the re-pointed frames
      end

      expect(io_out.string).to include('Sending...')
      expect(io_out.string).to include('ctx 12%')
    end

    # issue #221 review, bug 1: the reported symptom - after any output
    # line the spinner came back as 'Working...' even though the task had
    # said what it was doing. The line must keep its real message for the
    # whole wait.
    it 'the spinner does NOT reset to "Working..." after an output line' do
      io_out = StringIO.new
      io_in  = StringIO.new

      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.emit(:spinner_detail, origin: :session_manager,
                  content: { message: 'Sending to model' })
        sleep 0.2                      # render 'Sending to model...' frames
        Task.puts '[step 1] working'   # clears the spinner line
        sleep 0.3                      # spinner is rebuilt here (bug 1 site)
      end

      captured = io_out.string

      expect(captured).to include('[step 1] working')
      expect(captured).to include('Sending to model...')
      expect(captured).not_to include('Working...')
    end

    # Issue #283 (the real drain loop): memory re-points a spinner for the
    # wait it was recorded during, so the NEW wait must announce itself
    # rather than inherit the finished wait's line.
    it 'a new wait shows the newest spinner line, not one from an earlier wait' do
      io_out = StringIO.new
      io_in  = StringIO.new

      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.emit(:spinner_detail, origin: :session_manager,
                  content: { message: 'Compacting session mid-task' })
        sleep 0.2
        Task.puts '[step 2] running tests'   # the compaction wait is over
        Task.emit(:spinner_detail, origin: :session_manager,
                  content: { message: 'Sending to model' })
        sleep 0.3
      end

      captured = io_out.string

      expect(captured).to include('Compacting session mid-task...')
      expect(captured).to include('Sending to model...')
      expect(captured.split('Sending to model...').last)
        .not_to include('Compacting session mid-task...')
    end

    it 'prints text events from the outbox in order (and keeps the spinner going after)' do
      io_out = StringIO.new
      io_in = StringIO.new

      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |_t|
        Task.puts '[step 1] first'
        sleep 0.1 # let the text line render and the spinner re-appear
        Task.puts '[step 2] second'
        sleep 0.2
      end

      captured = io_out.string

      expect(captured).to include('[step 1] first')
      expect(captured).to include('[step 2] second')
      # No :spinner_detail was emitted, so the default message is correct
      # here - the memory (bug 1 fix) only re-plays what the task asked for.
      expect(captured).to include('Working...')
    end

    it 'handles a dialog request from the task thread on the main thread' do
      io_out = StringIO.new
      io_in = StringIO.new("1\n") # "1" selects the first option

      choice = nil
      described_class.run(harness: spec_harness,
                          ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |t|
        dialog = UI::Dialog.new(
          title: 'Test dialog',
          options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)]
        )
        choice = t.request(:dialog, dialog: dialog)
      end

      captured = io_out.string

      expect(choice).to eq(:yes)
      expect(captured).to include('Test dialog')
    end
  end

  # issue #36 / #198 phase 1: stdin fake exposing input_pending? alongside a
  # normal gets(). The drain loop only PEEKS (input_pending?) and then reads
  # on the main thread - there is no background reader thread anymore.
  class FakePendingStdin
    def initialize(io)
      @io = io
      @pending = false
    end

    attr_writer :pending

    def input_pending?
      @pending
    end

    def gets
      line = @io.gets
      @pending = false   # a line was consumed (canonical tty semantics)
      line
    end
  end

  describe 'Task.run mid-turn user notes (issue #36 / #198 phase 1)' do
    # Minimal harness double: stores the notes the drain loop hands over
    # (blank/nil ignored, like the real setter).
    let(:fake_harness) do
      Class.new do
        attr_reader :notes
        def initialize
          @notes = []
        end

        def user_note_text=(text)
          return if text.to_s.strip.empty?

          @notes << text
        end

        def output_log = OutputBuffer.new
      end.new
    end

    # Real pipe, not StringIO: gets() BLOCKS until data or a closed write
    # end (StringIO hits EOF the moment its content is exhausted).
    def with_stdin_pipe
      reader, writer = IO.pipe
      begin
        yield reader, writer
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
      end
    end

    it 'commits a note typed before the turn onto the harness with an ack' do
      io_out  = StringIO.new
      harness = fake_harness

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts 'steer left' # typed before the turn even starts
        stdin.pending = true
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |_t|
          Task.puts 'working'
          sleep 0.3
        end
      end

      expect(harness.notes).to eq(['steer left'])
      # The ack and the note body are two renderer-owned roles now: a bracketed
      # :kind ack ("[note] got it") then the note as a wrapped :note paragraph
      # indented under the prompt (not a baked "[note] got it - <body>" run-on).
      expect(io_out.string).to include('[note] got it')
      expect(io_out.string).to include('  steer left')
      expect(io_out.string).to include('working')
    end

    it 'drops a bare Enter (:empty) - no note, the turn continues' do
      io_out  = StringIO.new
      harness = fake_harness

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts '' # bare Enter: nothing typed, no note (T3 design)
        stdin.pending = true
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |_t|
          sleep 0.2
        end
      end

      expect(harness.notes).to be_empty
      expect(io_out.string).not_to include('[note]')
    end

    it 'aborts the turn when the editor sees EOF (Ctrl-D) and no work survives' do
      io_out  = StringIO.new
      harness = fake_harness
      task    = nil

      reader, writer = IO.pipe
      stdin = FakePendingStdin.new(reader)
      stdin.pending = true
      begin
        writer.close # immediate EOF: the editor read returns :eof
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |t|
          task = t # captured so we can assert the thread was stopped
          sleep 5 # would hang forever if the EOF did not abort the turn
        end
      ensure
        reader.close unless reader.closed?
      end

      expect(task).not_to be_nil
      expect(task.alive?).to be(false) # thread stopped at EOF (no leak)
    end

    # Task.run always arrives with a harness (only run_on_task calls it), so the
    # harness-less turn is not a production path any more. The guard itself is
    # still real and is pinned at unit level: a task with no harness never reads
    # stdin, so nothing on the note path can consume a line the dialog needs.
    it 'never polls stdin for a task with no harness (the guard, at unit level)' do
      fake_in = Object.new
      def fake_in.input_pending?
        raise 'stdin must not be polled without a harness'
      end
      def fake_in.gets
        raise 'stdin must not be read without a harness'
      end

      task = Task.new(buffer: spec_buffer) { }
      task.ui = UI::Console.new(stdout: StringIO.new, stdin: fake_in)
      task.note_editor = instance_double(UI::Editor)

      expect { described_class.poll_for_note(task) }.not_to raise_error
    end

    # issue #198 phase 4: the note read is MULTILINE (read_multiline). On a
    # non-tty stream one line per read - a pipe has no submit key, so a
    # multi-line PASTE typed while the model works arrives as its FIRST
    # line here; on a tty the whole pasted block is ONE note (Reline path,
    # not testable without a real terminal). These two examples pin the
    # routing: poll_for_note must call read_multiline, never the
    # single-line read.
    it 'routes the note read through read_multiline (issue #198 phase 4)' do
      io_out  = StringIO.new
      harness = fake_harness

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts 'steer left on multiline'
        stdin.pending = true
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |_t|
          Task.puts 'working'
          sleep 0.3
        end
      end

      expect(harness.notes).to eq(['steer left on multiline'])
    end

    it 'keeps FIFO: a pre-typed line is a note; the dialog gets the next' do
      # The line already at the keyboard when the turn starts is a NOTE
      # (typed for steering); the dialog's answer must be the NEXT line.
      io_out  = StringIO.new
      harness = fake_harness
      choice  = nil

      with_stdin_pipe do |io_in, writer|
        stdin = FakePendingStdin.new(io_in)
        writer.puts '1'   # at the keyboard before anything starts -> note
        stdin.pending = true
        Thread.new do
          sleep 0.5
          writer.puts '1' # the real dialog answer (Allow), typed while open
        end
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: stdin)) do |t|
          dialog = UI::Dialog.new(
            title: 'Grant test',
            options: [UI::Dialog::Option.new(title: 'Allow', value: :allow)]
          )
          choice = t.request(:dialog, dialog: dialog)
        end
      end

      expect(harness.notes).to eq(['1']) # pre-typed line went to steering
      expect(choice).to eq(:allow)       # the dialog got the NEXT line
    end

    it 'delivers lines typed WHILE a dialog is open to the dialog (no race)' do
      # The bug scenario from issue #198: user types, a dialog appears. No
      # reader thread exists during the turn (the drain loop only peeks),
      # so the dialog's gets() has the keyboard to itself.
      io_out  = StringIO.new
      harness = fake_harness
      choice  = nil

      with_stdin_pipe do |io_in, writer|
        described_class.run(harness: harness,
                            ui: UI::Console.new(stdout: io_out, stdin: io_in)) do |t|
          dialog = UI::Dialog.new(
            title: 'Grant test',
            options: [UI::Dialog::Option.new(title: 'Allow', value: :allow)]
          )
          # Simulate the user typing while the dialog is open.
          Thread.new { sleep 0.5; writer.puts '1' }
          choice = t.request(:dialog, dialog: dialog)
        end
      end

      expect(choice).to eq(:allow) # dialog received the typed line
    end
  end

  # issue #221: a steering note that is EXACTLY "/yolo" is consumed as a
  # control gesture (posture toggle) instead of being injected into the
  # chain. Unit-level on Task.commit_note - the drain-loop wiring is the
  # same one the note specs above already prove.
  #
  # HACK (acknowledged, issue #267): the gesture is
  # special-cased per command inside Task's note plumbing. These specs pin
  # the CONTRACT (only an exact /yolo flips state, a real note never
  # does, the ack lands on ui + buffer) so the gesture-dispatch refactor
  # promised in the async-task + CLI work can be verified against it.
  describe 'Task.commit_note /yolo control gesture (issue #221)' do
    # Harness stand-in: the posture surface + the note setter, both
    # recorded so the spec can see which path was taken.
    def gesture_harness
      Class.new do
        attr_reader :notes, :toggles

        def initialize
          @notes   = []
          @toggles = 0
          @yolo    = false
        end

        def yolo?
          @yolo
        end

        def yolo=(val)
          @yolo = (val == true)
        end

        def yolo_mode_label
          @yolo ? 'YOLO ON' : 'YOLO OFF'
        end

        def toggle_yolo
          @toggles += 1
          @yolo    = !@yolo
          @yolo ? 'YOLO ON' : 'YOLO OFF'
        end

        def user_note_text=(text)
          @notes << text
        end
      end.new
    end

    # A task stand-in exposing exactly what commit_note touches (harness /
    # ui / buffer are Task's own accessors - the stand-in must answer them).
    def gesture_task(harness)
      task_class = Class.new do
        attr_accessor :harness, :ui, :buffer
        define_method(:renderer) { @renderer ||= UI::Renderer.new }
      end
      # The real buffer's #put collects the entries; a recording stand-in.
      entries = []
      buffer  = Class.new do
        define_method(:put) { |**entry| entries << entry }
      end.new
      io     = StringIO.new
      task   = task_class.new
      task.harness = harness
      task.ui      = UI::Console.new(stdout: io)
      task.buffer  = buffer
      [task, io, entries]
    end

    it 'flips the posture and does NOT inject the note into the chain' do
      harness        = gesture_harness
      task, io, buf  = gesture_task(harness)

      described_class.commit_note(task, '/yolo')

      expect(harness.yolo?).to be(true)
      expect(harness.toggles).to eq(1)
      expect(harness.notes).to be_empty # consumed, never injected
      expect(io.string).to include('[YOLO ON]')
      expect(buf.map { |e| e[:content] }).to eq(['  [YOLO ON]'])
      expect(buf.map { |e| e[:origin] }).to eq([:user_note])
    end

    it 'honours an explicit /yolo on / off form (sets, not flips)' do
      harness = gesture_harness
      task, io, _buf = gesture_task(harness)

      described_class.commit_note(task, '/yolo on')
      described_class.commit_note(task, '/yolo on') # idempotent
      expect(harness.yolo?).to be(true)
      expect(harness.toggles).to eq(0) # explicit forms never blind-toggle

      described_class.commit_note(task, '/YOLO OFF') # casing tolerated
      expect(harness.yolo?).to be(false)
      expect(io.string).to include('[YOLO OFF]')
    end

    it 'recognizes the gesture forms (bare marker is :toggle, never nil)' do
      expect(described_class.yolo_note_action('/yolo')).to eq(:toggle)
      expect(described_class.yolo_note_action('/yolo on')).to eq(:on)
      expect(described_class.yolo_note_action('  /YOLO Off  ')).to eq(:off)
      expect(described_class.yolo_note_action('foo /yolo')).to be_nil
    end

    it 'leaves every real note alone (a note merely MENTIONS yolo)' do
      harness = gesture_harness
      task, io, _buf = gesture_task(harness)

      described_class.commit_note(task, 'please run it with yolo off')
      described_class.commit_note(task, 'yolo')
      described_class.commit_note(task, '/yolo please do it anyway')

      expect(harness.yolo?).to be(false)
      expect(harness.toggles).to eq(0)
      expect(harness.notes)
        .to eq(['please run it with yolo off', 'yolo', '/yolo please do it anyway'])
      # Two renderer-owned roles: the [note] got it ack, then the note body as a
      # wrapped :note paragraph indented under the prompt.
      expect(io.string).to include('[note] got it')
      expect(io.string).to include('  yolo')
    end
  end

  # issue #298: Ctrl+G inside the MID-TURN note editor hands the buffer to the
  # external editor. The note path keeps the hand-off the same way it keeps an
  # Esc'd buffer - back into @note_draft, prefilled the next time the note
  # editor opens - and NOT committed as a note: an editor round-trip is not a
  # submission, and a note that reaches the model just because an editor was
  # closed would inject text the user never sent.
  describe 'poll_for_note and the Ctrl+G hand-off (issue #298)' do
    let(:note_harness) do
      Class.new do
        attr_reader :notes

        def initialize
          @notes = []
        end

        def user_note_text=(text)
          @notes << text
        end
      end.new
    end

    # A task with its note editor stubbed: poll_for_note is driven directly, so
    # no turn and no real terminal are needed.
    def task_with_note_editor(result)
      editor = instance_double(UI::Editor)
      allow(editor).to receive(:read_multiline)
        .and_return(UI::Editor::EDITOR_RESULT.new(result[:text], result[:status],
                                                  result[:note]))
      task = Task.new(buffer: spec_buffer) { }
      task.ui = UI::Console.new(stdout: StringIO.new, stdin: stubbed_pending_stdin)
      task.harness = note_harness
      task.note_editor = editor
      [task, editor]
    end

    def stubbed_pending_stdin
      io = StringIO.new
      def io.input_pending?
        true
      end
      io
    end

    it 'keeps the edited text as the note draft instead of committing it' do
      task, _editor = task_with_note_editor(
        text: 'draft from vim', status: :edited, note: 'edited with vim'
      )

      described_class.poll_for_note(task)

      expect(task.instance_variable_get(:@note_draft)).to eq('draft from vim')
      expect(note_harness.notes).to be_empty
    end

    it 'prefills the draft on the next note read (the round-trip is not lost)' do
      task, editor = task_with_note_editor(
        text: 'draft from vim', status: :edited, note: 'edited with vim'
      )
      allow(editor).to receive(:read_multiline).and_return(
        UI::Editor::EDITOR_RESULT.new('draft from vim', :edited, 'edited with vim'),
        UI::Editor::EDITOR_RESULT.new('draft from vim', :empty, nil)
      )

      described_class.poll_for_note(task)
      described_class.poll_for_note(task)

      expect(editor).to have_received(:read_multiline).with(prefill: 'draft from vim')
      expect(note_harness.notes).to be_empty
    end
  end

  # issue #473: the drain loop holds a REAL-TTY stdin in raw mode so a lone
  # keypress makes input_pending? true and the note editor opens (the Linux/
  # KDE symptom: cooked tty line-buffers, so the peek never fired). The
  # guard must reach only a stream that answers BOTH #raw (io/console) and
  # a true #tty? - every spec stdin (StringIO, IO.pipe, Object, the
  # FakePendingStdin wrapper) fails one of those and must be left untouched,
  # otherwise the whole note suite above would call raw! on a pipe.
  describe 'Task.hold_raw_stdin (issue #473 raw-mode guard)' do
    def task_with_stdin(stdin)
      t = Task.new(buffer: spec_buffer) { }
      t.ui = UI::Console.new(stdout: StringIO.new, stdin: stdin)
      t
    end

    # The host gate decides whether the hold is even attempted; specs run on a
    # Windows box, so they stub it to exercise both shapes deterministically.
    def with_host(supported)
      allow(described_class).to receive(:raw_hold_host_supported?)
        .and_return(supported)
    end

    # A fully capable POSIX-tty stdin: raw + tty? + input_pending? (the peek
    # consumes raw mode). Held ONLY when the host can keep Ctrl+C a signal.
    def posix_tty_stdin
      raw_called = false
      stdin = Object.new
      stdin.define_singleton_method(:tty?) { true }
      stdin.define_singleton_method(:raw) { true }
      stdin.define_singleton_method(:input_pending?) { false }
      stdin.define_singleton_method(:raw!) { |**_o| raw_called = true }
      stdin.define_singleton_method(:cooked!) { :cooked }
      [stdin, -> { raw_called }]
    end

    # issue #473 Ctrl+C regression, the real cause: msys2 answers EVERY
    # capability the old #input_pending? gate checked (it IS a pty), yet a
    # Windows console cannot turn Ctrl+C into SIGINT under raw(intr:true) - the
    # held 0x03 byte opens the note editor and the turn never aborts. So on a
    # Windows host the stdin must stay COOKED (pre-#473 Ctrl+C behaviour) even
    # for a tty that answers every capability.
    it 'holds nothing on a host where Ctrl+C cannot abort, fully capable tty included' do
      with_host(false)
      stdin, raw_called = posix_tty_stdin

      expect(described_class.hold_raw_stdin(task_with_stdin(stdin))).to be_nil
      expect(raw_called.call).to be(false)
    end

    # On a POSIX host (Linux/KDE) the same tty IS held: that is the steering fix.
    it 'holds a fully capable tty when the host supports the hold' do
      with_host(true)
      stdin, raw_called = posix_tty_stdin

      held = described_class.hold_raw_stdin(task_with_stdin(stdin))
      expect(held).to equal(stdin)
      expect(raw_called.call).to be(true)
      expect(held.cooked!).to eq(:cooked)
    end

    # Capability guards still apply even when the host gate would allow it.
    it 'holds nothing for a non-raw tty even on a supporting host' do
      with_host(true)
      stdin = Object.new
      def stdin.tty? = true
      # no #raw defined
      expect(described_class.hold_raw_stdin(task_with_stdin(stdin))).to be_nil
    end

    it 'holds nothing when tty? is false (a redirected stdin)' do
      stdin = Object.new
      def stdin.tty? = false
      def stdin.raw!(*_args) = raise 'raw! must not be called on a non-tty'
      expect(described_class.hold_raw_stdin(task_with_stdin(stdin))).to be_nil
    end

    it 'holds nothing for a StringIO (no #raw, no #tty?); note suite untouched' do
      expect(described_class.hold_raw_stdin(task_with_stdin(StringIO.new))).to be_nil
    end

    # A tty whose mode change raises (some PTYs): steering degrades to the
    # pre-fix behaviour rather than taking the turn down with it.
    it 'returns nil when a tty refuses the raw mode change' do
      with_host(true)
      stdin = Object.new
      stdin.define_singleton_method(:tty?) { true }
      stdin.define_singleton_method(:raw) { true }
      stdin.define_singleton_method(:input_pending?) { false }
      stdin.define_singleton_method(:raw!) { raise Errno::ENOTTY, 'refused' }
      expect(described_class.hold_raw_stdin(task_with_stdin(stdin))).to be_nil
    end
  end

  # issue #286 increment 2: a task built for a job reads the registry's ONE
  # queue instead of its own outbox, its inbox IS the job's inbox, and the
  # block's value becomes the result the caller awaits on :done.
  describe 'a task built for a job (the registry is the executor)' do
    def registry_task(registry, job, &)
      task = described_class.new(buffer: nil, registry:, job:, &)
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

    # The foreground task never renders another job's lines: an event naming a
    # foreign job is recorded into that job's own buffer and skipped.
    it 'records a foreign-job event into that job buffer and does not render it' do
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      other = registry.add_job(kind: :command, requested_by: main)
      task = registry_task(registry, main) { }
      other.push_event(type: :text, origin: :task, content: 'from job 1')

      event = task.poll(0)
      expect(event).to be_nil
      expect(other.buffer.tail.map(&:content)).to eq(['from job 1'])
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

    # The drain loop's spinner check is the same queue read everywhere.
    it 'the block value lands as the :done result the caller awaits' do
      registry = JobRegistry.new
      job = registry.add_job(kind: :main)
      io = StringIO.new
      harness = Object.new
      harness.define_singleton_method(:output_log) { OutputBuffer.new }
      described_class.run(harness:, ui: UI::Console.new(stdout: io, stdin: StringIO.new),
                          registry:, job:) { :turn_value }

      expect(job.result).to eq(:turn_value)
    end
  end

  # A job outside the foreground cannot be shown a dialog, so its request gets an
  # answer VALUE the tool can return to the model; a grant dialog is excepted.
  describe 'handle_request and the background denial (issue #286)' do
    def denied_registry
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      [registry, main, registry.add_job(kind: :command, requested_by: main)]
    end

    it 'denies a background dialog with the answer value' do
      registry, _main, background = denied_registry
      # The request arrives on the background job's own task, so the denial
      # answer lands on ITS inbox - which is the task's inbox.
      task = Task.new(buffer: nil, registry:, job: background) { }
      task.ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      dialog = UI::Dialog.new(title: 'pick',
                              options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)])

      Task.handle_request(task, { type: :__request__, kind: :dialog,
                                  job: background.id, dialog: })

      expect(background.poll(0)).to eq(Job::DENIED_ANSWER)
    end
  end
end
