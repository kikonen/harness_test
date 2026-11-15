# frozen_string_literal: true

require 'logger'
require 'poller'
require 'task'
require 'harness'
require 'ui/spinner'
require 'stringio'

# The Poller owns the drain loop, the spinner, the input path and the dialog
# serving that the Task no longer runs directly (issue #286). These specs drive
# those methods the way the loop calls them: the instance methods through a
# Poller built around a task, the posture/gesture helpers as class methods.
RSpec.describe Poller do
  def spec_buffer
    OutputBuffer.new
  end

  describe 'spinner head memory (issue #286)' do
    # The order is the point (issue #286): the data lands in the HEAD first,
    # and the spinner content is built FROM the head cell - not from the raw
    # event. A recording stand-in spinner proves the value it receives is the
    # head cell's content, so the head is the single source of live state.
    it 'store_and_render puts the head first, then builds the spinner from the head' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      seen = []
      recorder = Class.new do
        define_method(:update_detail) { |message:, suffix:| seen << [message, suffix] }
        define_method(:running?) { true }
      end.new
      task.spinner = recorder

      Poller.new(task).store_and_render({ type: :spinner_detail, origin: :session_manager,
                                          content: { message: 'Sending', suffix: 'ctx 12%' } })

      expect(task.buffer.cell(:session_manager, :spinner_detail).content)
        .to eq(message: 'Sending', suffix: 'ctx 12%')
      expect(seen).to eq([['Sending', 'ctx 12%']])
    end
  end

  # issue #224 follow-up: the spinner badge ALWAYS shows the command
  # consent mode (live, re-read every frame) when the harness exposes it.
  describe 'Poller#ensure_spinner_running mode badge (issue #224 follow-up)' do
    def mode_harness(label)
      h = Class.new do
        define_method(:command_mode_label) { label }
      end.new
      h
    end

    it 'installs a live badge callable when the harness has a mode label' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('AUTO-APPROVE')

      described_class.new(task).ensure_spinner_running

      expect(task.visible_spinner.badge).to respond_to(:call)
      expect(task.visible_spinner.badge.call).to eq('[AUTO-APPROVE]')
    end

    it 'installs no badge for a harness without a mode (unit-test harness)' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = Object.new # no command_mode_label

      described_class.new(task).ensure_spinner_running

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
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = Class.new { def plan_mode_label = 'PLAN'; }.new

      described_class.new(task).ensure_spinner_running

      expect(task.visible_spinner.badge.call).to eq('[PLAN]')
    end

    it 'installs a badge when the harness only exposes the stream label' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = Class.new { def stream_mode_label = 'STREAM'; }.new

      described_class.new(task).ensure_spinner_running

      expect(task.visible_spinner.badge.call).to eq('[STREAM]')
    end

    # A live callable: a /stream toggle mid-turn shows on the very next frame.
    it 're-reads both tags on every frame (a mid-turn toggle shows at once)' do
      stream = false
      harness = Class.new do
        define_method(:command_mode_label) { 'MANUAL' }
        define_method(:stream_mode_label) { stream ? 'STREAM' : nil }
      end.new
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = harness

      described_class.new(task).ensure_spinner_running
      before = task.visible_spinner.badge.call
      stream = true
      after = task.visible_spinner.badge.call

      expect(before).to eq('[MANUAL]')
      expect(after).to eq('[MANUAL] [STREAM]')
    end

    it 'does not replace an already running spinner' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('MANUAL')

      described_class.new(task).ensure_spinner_running
      first = task.spinner
      described_class.new(task).ensure_spinner_running
      expect(task.spinner).to equal(first)
    end

    # issue #221 review (bug 1): the spinner is recreated whenever the
    # outbox empties again after an output batch cleared it - the new
    # spinner must show the message the task asked for, not 'Working'.
    it 'a rebuilt spinner re-plays the recorded spinner detail' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('MANUAL')
      # The head cell is the memory the rebuild reads (issue #286): the
      # store_and_render path lands the re-point as a head cell.
      task.buffer.put(type: :spinner_detail, origin: :session_manager,
                      content: { message: 'Sending to qwen', suffix: 'ctx 12%' })

      described_class.new(task).ensure_spinner_running
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
      task = Task.new(buffer: spec_buffer) { nil }
      task.ui = UI::Console.new(stdout: StringIO.new)
      task.harness = mode_harness('MANUAL')
      task.start

      described_class.new(task).ensure_spinner_running
      expect(task.visible_spinner.elapsed).to respond_to(:call)
      expect(task.visible_spinner.elapsed.call).to match(/\A\d+s\z/)
    end

    it 'elapsed_label is nil before the task is started (no turn to measure)' do
      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new)

      expect(task.elapsed_label).to be_nil
      described_class.new(task).ensure_spinner_running
      expect(task.visible_spinner.frame_line)
        .to eq("#{UI::Spinner::FRAMES[0]} Working...")
    end
  end

  describe 'Poller#poll_for_note with no harness (the guard, at unit level)' do
    # Task.run always arrives with a harness (only run_on_task calls it), so the
    # harness-less turn is not a production path any more. The guard itself is
    # still real and is pinned at unit level: a task with no harness never reads
    # stdin, so nothing on the note path can consume a line the dialog needs.
    it 'never polls stdin for a task with no harness' do
      fake_in = Object.new
      def fake_in.input_pending?
        raise 'stdin must not be polled without a harness'
      end
      def fake_in.gets
        raise 'stdin must not be read without a harness'
      end

      task = Task.new(buffer: spec_buffer)
      task.ui = UI::Console.new(stdout: StringIO.new, stdin: fake_in)
      task.note_editor = instance_double(UI::Editor)

      expect { described_class.new(task).poll_for_note }.not_to raise_error
    end
  end

  # issue #221: a steering note that is EXACTLY "/yolo" is consumed as a
  # control gesture (posture toggle) instead of being injected into the
  # chain. Unit-level on Poller#commit_note - the drain-loop wiring is the
  # same one the note specs in task_spec already prove.
  #
  # HACK (acknowledged, issue #267): the gesture is
  # special-cased per command inside the poller's note plumbing. These specs pin
  # the CONTRACT (only an exact /yolo flips state, a real note never
  # does, the ack lands on ui + buffer) so the gesture-dispatch refactor
  # promised in the async-task + CLI work can be verified against it.
  describe 'Poller#commit_note /yolo control gesture (issue #221)' do
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

      described_class.new(task).commit_note('/yolo')

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

      described_class.new(task).commit_note('/yolo on')
      described_class.new(task).commit_note('/yolo on') # idempotent
      expect(harness.yolo?).to be(true)
      expect(harness.toggles).to eq(0) # explicit forms never blind-toggle

      described_class.new(task).commit_note('/YOLO OFF') # casing tolerated
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

      described_class.new(task).commit_note('please run it with yolo off')
      described_class.new(task).commit_note('yolo')
      described_class.new(task).commit_note('/yolo please do it anyway')

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
  describe 'Poller#poll_for_note and the Ctrl+G hand-off (issue #298)' do
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
      task = Task.new(buffer: spec_buffer)
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

      described_class.new(task).poll_for_note

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

      described_class.new(task).poll_for_note
      described_class.new(task).poll_for_note

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
  describe 'Poller#hold_raw_stdin (issue #473 raw-mode guard)' do
    def task_with_stdin(stdin)
      t = Task.new(buffer: spec_buffer)
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

      expect(described_class.new(task_with_stdin(stdin)).hold_raw_stdin).to be_nil
      expect(raw_called.call).to be(false)
    end

    # On a POSIX host (Linux/KDE) the same tty IS held: that is the steering fix.
    it 'holds a fully capable tty when the host supports the hold' do
      with_host(true)
      stdin, raw_called = posix_tty_stdin

      held = described_class.new(task_with_stdin(stdin)).hold_raw_stdin
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
      expect(described_class.new(task_with_stdin(stdin)).hold_raw_stdin).to be_nil
    end

    it 'holds nothing when tty? is false (a redirected stdin)' do
      stdin = Object.new
      def stdin.tty? = false
      def stdin.raw!(*_args) = raise 'raw! must not be called on a non-tty'
      expect(described_class.new(task_with_stdin(stdin)).hold_raw_stdin).to be_nil
    end

    it 'holds nothing for a StringIO (no #raw, no #tty?); note suite untouched' do
      expect(described_class.new(task_with_stdin(StringIO.new)).hold_raw_stdin).to be_nil
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
      expect(described_class.new(task_with_stdin(stdin)).hold_raw_stdin).to be_nil
    end
  end

  # A job outside the foreground cannot be shown a dialog, so its request gets an
  # answer VALUE the tool can return to the model; a grant dialog is excepted.
  describe 'Poller#handle_request and the background denial (issue #286)' do
    def denied_registry
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      [registry, main, registry.add_job(kind: :command, requested_by: main)]
    end

    it 'denies a background dialog with the answer value' do
      registry, _main, background = denied_registry
      # The request arrives on the background job's own task, so the denial
      # answer lands on ITS inbox - which is the task's inbox.
      task = Task.new(buffer: nil, registry:, job: background)
      task.ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      dialog = UI::Dialog.new(title: 'pick',
                              options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)])

      described_class.new(task).handle_request(
        { type: :__request__, kind: :dialog, job: background.id, dialog: }
      )

      expect(background.poll(0)).to eq(Job::DENIED_ANSWER)
    end
  end
end
