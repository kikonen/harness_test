# frozen_string_literal: true

require 'logger'
require 'main_loop'
require 'task'
require 'harness'
require 'input_path'
require 'job_registry'
require 'ui/spinner'
require 'stringio'

# The MainLoop is the run's ONE main loop (issue #286 increment 3): the idle
# prompt read and a turn's event drain are two modes of it. These specs drive
# those methods the way the loop calls them: the instance methods through a
# MainLoop built around a parked worker, the posture-badge helper as a class
# method.
RSpec.describe MainLoop do
  # A worker always runs on a registry + job (#286): these specs build the
  # smallest real one (a single main job) so every worker is a genuine
  # registry task. The commands double answers what the loop dispatches.
  def spec_loop(input_path: nil, worker: nil, **kwargs)
    registry = JobRegistry.new
    job = registry.add_job(kind: :main)
    worker ||= Task.new(registry:, job:, input_path:)
    worker.ui = UI::Console.new(stdout: StringIO.new) if worker.ui.nil?
    commands = kwargs.delete(:commands) { Object.new }
    described_class.new(registry:, ui: worker.ui, commands:,
                        input_path: input_path || InputPath.new(ui: worker.ui),
                        worker:, **kwargs)
  end

  # A worker on its own registry, for loops built explicitly.
  def spec_worker(_ui)
    registry = JobRegistry.new
    Task.new(registry:, job: registry.add_job(kind: :main))
  end

  describe 'spinner head memory (issue #286)' do
    # The order is the point (issue #286): the data lands in the HEAD first,
    # and the spinner content is built FROM the head cell - not from the raw
    # event. A recording stand-in spinner proves the value it receives is the
    # head cell's content, so the head is the single source of live state.
    it 'store_and_render puts the head first, then builds the spinner from the head' do
      loop_ = spec_loop
      seen = []
      recorder = Class.new do
        define_method(:update_detail) { |message:, suffix:| seen << [message, suffix] }
        define_method(:running?) { true }
      end.new
      loop_.spinner = recorder

      loop_.store_and_render({ type: :spinner_detail, origin: :session_manager,
                               content: { message: 'Sending', suffix: 'ctx 12%' } })

      expect(loop_.shown_job.buffer.cell(:session_manager, :spinner_detail).content)
        .to eq(message: 'Sending', suffix: 'ctx 12%')
      expect(seen).to eq([['Sending', 'ctx 12%']])
    end
  end

  # issue #224 follow-up: the spinner badge ALWAYS shows the command
  # consent mode (live, re-read every frame) when the harness exposes it.
  describe 'MainLoop#ensure_spinner_running mode badge (issue #224 follow-up)' do
    def mode_harness(label)
      # #286: the consent/stream labels live under harness#settings; the plan
      # label is Harness-owned. A stand-in settings answers the posture labels.
      settings = Object.new
      settings.define_singleton_method(:command_mode_label) { label }
      settings.define_singleton_method(:stream_mode_label) { nil }
      h = Object.new
      h.define_singleton_method(:settings) { settings }
      h.define_singleton_method(:plan_mode_label) { nil }
      h
    end

    def loop_with_harness(harness)
      loop_ = spec_loop
      loop_.worker.harness = harness
      loop_
    end

    it 'installs a live badge callable when the harness has a mode label' do
      loop_with_harness(mode_harness('AUTO-APPROVE')).ensure_spinner_running

      expect(loop_with_harness(nil).worker).not_to be_nil
      loop_ = loop_with_harness(mode_harness('AUTO-APPROVE'))
      loop_.ensure_spinner_running
      expect(loop_.visible_spinner.badge).to respond_to(:call)
      expect(loop_.visible_spinner.badge.call).to eq('[job 0 main] [AUTO-APPROVE]')
    end

    it 'installs no badge when there is no harness at all (unit-test harness)' do
      loop_ = loop_with_harness(nil) # the job half of the badge needs no harness
      loop_.ensure_spinner_running

      # The job half exists on its own: a badge names which job is working even
      # with no harness and no posture tag.
      expect(loop_.visible_spinner.badge.call).to eq('[job 0 main]')
    end

    # #548: the spinner line must say WHICH job is working once a run has more
    # than one agent. The badge carries it ahead of the posture tags.
    describe 'the job half of the badge (issue #548)' do
      def job_loop(kind, harness: nil)
        registry = JobRegistry.new
        job      = registry.add_job(kind: kind)
        worker   = Task.new(registry:, job:) { nil }
        worker.ui = UI::Console.new(stdout: StringIO.new)
        worker.harness = harness
        described_class.new(registry:, ui: worker.ui, commands: Object.new,
                            input_path: InputPath.new(ui: worker.ui), worker:)
      end

      it 'names a non-main job the turn belongs to' do
        loop_ = job_loop(:sub_agent)
        loop_.ensure_spinner_running
        expect(loop_.visible_spinner.badge.call).to eq('[job 0 sub_agent]')
      end

      it 'names the job and the posture on the same badge' do
        loop_ = job_loop(:command, harness: mode_harness('YOLO'))
        expect(described_class.turn_badge(job: loop_.shown_job, harness: loop_.worker.harness))
          .to eq('[job 0 command] [YOLO]')
      end

      it 'names the main job too (every job reads the same way)' do
        expect(described_class.job_tag(JobRegistry.new.add_job(kind: :main)))
          .to eq('[job 0 main]')
      end
    end

    it 'mode_badge is nil when the label is nil (safety check off)' do
      expect(described_class.mode_badge(mode_harness(nil))).to be_nil
    end

    def posture_harness(consent, stream, plan = nil)
      settings = Object.new
      settings.define_singleton_method(:command_mode_label) { consent }
      settings.define_singleton_method(:stream_mode_label) { stream }
      h = Object.new
      h.define_singleton_method(:settings) { settings }
      h.define_singleton_method(:plan_mode_label) { plan }
      h
    end

    it 'mode_badge brackets the bare label for display' do
      expect(described_class.mode_badge(mode_harness('MANUAL')))
        .to eq('[MANUAL]')
      expect(described_class.mode_badge(mode_harness('AUTO-APPROVE')))
        .to eq('[AUTO-APPROVE]')
      expect(described_class.mode_badge(mode_harness('YOLO'))).to eq('[YOLO]')
    end

    it 'mode_badge adds the stream tag alongside the consent tag' do
      harness = posture_harness('MANUAL', 'STREAM')
      expect(described_class.mode_badge(harness)).to eq('[MANUAL] [STREAM]')
    end

    it 'mode_badge shows only the stream tag when the consent label is nil' do
      expect(described_class.mode_badge(posture_harness(nil, 'STREAM')))
        .to eq('[STREAM]')
    end

    it 'mode_badge shows no stream tag when streaming is off' do
      expect(described_class.mode_badge(posture_harness('MANUAL', nil)))
        .to eq('[MANUAL]')
    end

    it 'mode_badge adds the plan tag alongside the consent and stream tags' do
      harness = posture_harness('MANUAL', 'STREAM', 'PLAN')
      expect(described_class.mode_badge(harness)).to eq('[MANUAL] [STREAM] [PLAN]')
    end

    it 'mode_badge shows no plan tag when planning is off' do
      expect(described_class.mode_badge(posture_harness('MANUAL', nil, nil)))
        .to eq('[MANUAL]')
    end

    it 'installs a badge when the harness only exposes the plan label' do
      harness = posture_harness(nil, nil, 'PLAN')
      loop_ = loop_with_harness(harness)
      loop_.ensure_spinner_running

      expect(loop_.visible_spinner.badge.call).to eq('[job 0 main] [PLAN]')
    end

    it 'installs a badge when the harness only exposes the stream label' do
      harness = posture_harness(nil, 'STREAM')
      loop_ = loop_with_harness(harness)
      loop_.ensure_spinner_running

      expect(loop_.visible_spinner.badge.call).to eq('[job 0 main] [STREAM]')
    end

    it 're-reads both tags on every frame (a mid-turn toggle shows at once)' do
      harness = posture_harness('MANUAL', nil)
      loop_ = loop_with_harness(harness)
      loop_.ensure_spinner_running
      badge = loop_.visible_spinner.badge

      expect(badge.call).to eq('[job 0 main] [MANUAL]')
      harness.settings.define_singleton_method(:command_mode_label) { 'YOLO' }
      harness.settings.define_singleton_method(:stream_mode_label) { 'STREAM' }
      expect(badge.call).to eq('[job 0 main] [YOLO] [STREAM]')
    end

    it 'does not replace an already running spinner' do
      loop_ = loop_with_harness(nil)
      first = UI::Spinner.new('first', nil, ui: loop_.ui)
      first.start
      loop_.spinner = first
      loop_.ensure_spinner_running

      expect(loop_.spinner).to equal(first)
      loop_.clear_spinner
    end

    it 'a rebuilt spinner re-plays the recorded spinner detail' do
      loop_ = loop_with_harness(nil)
      loop_.store_and_render({ type: :spinner_detail, origin: :task,
                               content: { message: 'Sending', suffix: 'ctx 9%' } })
      loop_.clear_spinner
      loop_.ensure_spinner_running

      expect(loop_.visible_spinner.frame_line).to include('Sending')
    end

    it 'installs a live elapsed clock on the spinner' do
      loop_ = loop_with_harness(nil)
      loop_.ensure_spinner_running

      expect(loop_.visible_spinner.elapsed).to respond_to(:call)
    end

    it 'elapsed_label is nil before the worker has served a turn' do
      loop_ = loop_with_harness(nil)
      loop_.ensure_spinner_running

      expect(loop_.worker.elapsed_label).to be_nil
    end
  end

  describe 'MainLoop#poll_for_note with no harness (the guard, at unit level)' do
    # The CLI always builds the worker with the job's harness, so the
    # harness-less loop is not a production path any more. The guard itself is
    # still real and is pinned at unit level: a worker with no harness never
    # reads stdin, so nothing on the note path can consume a line the dialog
    # needs.
    it 'never polls stdin for a worker with no harness' do
      fake_in = Object.new
      def fake_in.input_pending?
        raise 'stdin must not be polled without a harness'
      end
      def fake_in.gets
        raise 'stdin must not be read without a harness'
      end

      ui = UI::Console.new(stdout: StringIO.new, stdin: fake_in)
      loop_ = spec_loop(input_path: InputPath.new(ui:), worker: spec_worker(ui))

      expect { loop_.poll_for_note }.not_to raise_error
    end
  end

  # Mid-turn command dispatch (issue #286): in edit mode a "/command" submit
  # runs through the run's CommandHandler on the main thread (the loop IS the
  # main thread), NOT the note path - this is what removes the old /yolo
  # note-gesture hack (#221/#267): /yolo is now just a command. Bare text keeps
  # the note route exactly. Design: doc/unified_loop_design.md.
  describe 'MainLoop mid-turn command dispatch (issue #286)' do
    # A stand-in CommandHandler: records what the loop dispatched.
    def fake_handler
      handler = Object.new
      def handler.run_mid_turn(text)
        (@seen ||= []) << text
      end
      def handler.seen
        @seen || []
      end
      handler
    end

    def note_harness
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

    # Drive poll_for_note for one submitted block. The loop shares one input
    # path (the read poll_for_note uses); poll_for_note feeds its result to
    # MainLoop#commit_read, where a "/command" diverges from a bare note.
    def loop_for_submit(text, commands: fake_handler)
      editor = instance_double(UI::Editor)
      allow(editor).to receive(:read_multiline)
        .and_return(UI::Editor::EDITOR_RESULT.new(text, :submitted, nil))
      stdin = StringIO.new
      def stdin.input_pending?
        true
      end
      ui   = UI::Console.new(stdout: StringIO.new, stdin: stdin)
      path = InputPath.new(ui: ui, editor: editor)
      worker = spec_worker(ui)
      worker.note_draft = nil
      worker.harness = note_harness
      described_class.new(registry: worker.registry, ui: ui, commands:,
                          input_path: path, worker:)
    end

    it "sends a '/command' submit to the handler, not the note path" do
      loop_ = loop_for_submit('/yolo')

      loop_.poll_for_note

      expect(loop_.commands.seen).to eq(['/yolo'])
      expect(loop_.worker.harness.notes).to be_empty # never injected as a steering note
    end

    it 'sends a bare submit down the note path, never to the handler' do
      loop_ = loop_for_submit('please run it with yolo off')

      loop_.poll_for_note

      expect(loop_.commands.seen).to be_empty
      expect(loop_.worker.harness.notes).to eq(['please run it with yolo off'])
    end

    it 'routes /yolo on to the handler as a command, not a loop gesture' do
      loop_ = loop_for_submit('/yolo on')

      loop_.poll_for_note

      expect(loop_.commands.seen).to eq(['/yolo on'])
      expect(loop_.worker.harness.notes).to be_empty
    end

    # The loop always dispatches a "/command" submit to its commands object:
    # increment 3 removed the old "no handler wired" fall-through to the note
    # path (the loop is always built with the run's CommandHandler).
    it 'routes a /command to the commands object even in a unit-test loop' do
      loop_ = loop_for_submit('/stream')

      loop_.poll_for_note

      expect(loop_.commands.seen).to eq(['/stream'])
      expect(loop_.worker.harness.notes).to be_empty
    end
  end

  # issue #298: Ctrl+G inside the MID-TURN note editor hands the buffer to the
  # external editor. The note path keeps the hand-off the same way it keeps an
  # Esc'd buffer - back into the worker's note draft, prefilled the next time
  # the note editor opens - and NOT committed as a note: an editor round-trip
  # is not a submission, and a note that reaches the model just because an
  # editor was closed would inject text the user never sent.
  describe 'MainLoop#poll_for_note and the Ctrl+G hand-off (issue #298)' do
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

    def stubbed_pending_stdin
      io = StringIO.new
      def io.input_pending?
        true
      end
      io
    end

    # A worker with its note editor stubbed: poll_for_note is driven directly,
    # so no turn and no real terminal are needed.
    def loop_with_note_editor(result)
      editor = instance_double(UI::Editor)
      allow(editor).to receive(:read_multiline)
        .and_return(UI::Editor::EDITOR_RESULT.new(result[:text], result[:status],
                                                  result[:note]))
      ui = UI::Console.new(stdout: StringIO.new, stdin: stubbed_pending_stdin)
      worker = spec_worker(ui)
      worker.harness = note_harness
      path = InputPath.new(ui: ui, editor: editor)
      loop_ = described_class.new(registry: worker.registry, ui: ui,
                                  commands: Object.new, input_path: path, worker:)
      [loop_, editor]
    end

    # issue #561: the mid-turn read shares the run's InputPath, whose prompt is
    # the idle PROMPT - two spaces, a CONTINUATION marker that reads fine under
    # a modeline ending ' > ' but is invisible with nothing above it. A lone
    # dead-keypress opens the editor (the #473 raw hold), and with no label the
    # turn just looked frozen. The read must state a visible prompt of its own.
    it 'labels the mid-turn read so an opened editor is visible' do
      loop_, editor = loop_with_note_editor(text: 'a note', status: :submitted)

      loop_.poll_for_note

      expect(editor).to have_received(:read_multiline)
        .with(prompt: MainLoop::NOTE_PROMPT, prefill: nil)
      expect(MainLoop::NOTE_PROMPT).to include('>')
    end

    it 'keeps the edited text as the note draft instead of committing it' do
      loop_, _editor = loop_with_note_editor(
        text: 'draft from vim', status: :edited, note: 'edited with vim'
      )

      loop_.poll_for_note

      expect(loop_.worker.note_draft).to eq('draft from vim')
      expect(note_harness.notes).to be_empty
    end

    it 'prefills the draft on the next note read (the round-trip is not lost)' do
      loop_, editor = loop_with_note_editor(
        text: 'draft from vim', status: :edited, note: 'edited with vim'
      )
      allow(editor).to receive(:read_multiline).and_return(
        UI::Editor::EDITOR_RESULT.new('draft from vim', :edited, 'edited with vim'),
        UI::Editor::EDITOR_RESULT.new('draft from vim', :empty, nil)
      )

      loop_.poll_for_note
      loop_.poll_for_note

      expect(editor).to have_received(:read_multiline).with(
        prefill: 'draft from vim', prompt: MainLoop::NOTE_PROMPT
      )
      expect(note_harness.notes).to be_empty
    end
  end

  # issue #473: the loop holds a REAL-TTY stdin in raw mode so a lone
  # keypress makes input_pending? true and the note editor opens (the Linux/
  # KDE symptom: cooked tty line-buffers, so the peek never fired). The
  # guard must reach only a stream that answers BOTH #raw (io/console) and
  # a true #tty? - every spec stdin (StringIO, IO.pipe, Object, the
  # FakePendingStdin wrapper) fails one of those and must be left untouched,
  # otherwise the whole note suite above would call raw! on a pipe.
  describe 'MainLoop#hold_raw_stdin (issue #473 raw-mode guard)' do
    def loop_with_stdin(stdin)
      ui = UI::Console.new(stdout: StringIO.new, stdin: stdin)
      spec_loop(ui: ui, worker: spec_worker(ui))
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

      expect(loop_with_stdin(stdin).hold_raw_stdin).to be_nil
      expect(raw_called.call).to be(false)
    end

    # On a POSIX host (Linux/KDE) the same tty IS held: that is the steering fix.
    it 'holds a fully capable tty when the host supports the hold' do
      with_host(true)
      stdin, raw_called = posix_tty_stdin

      held = loop_with_stdin(stdin).hold_raw_stdin
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
      expect(loop_with_stdin(stdin).hold_raw_stdin).to be_nil
    end

    it 'holds nothing when tty? is false (a redirected stdin)' do
      stdin = Object.new
      def stdin.tty? = false
      def stdin.raw!(*_args) = raise 'raw! must not be called on a non-tty'
      expect(loop_with_stdin(stdin).hold_raw_stdin).to be_nil
    end

    it 'holds nothing for a StringIO (no #raw, no #tty?); note suite untouched' do
      expect(loop_with_stdin(StringIO.new).hold_raw_stdin).to be_nil
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
      expect(loop_with_stdin(stdin).hold_raw_stdin).to be_nil
    end
  end

  # The loop is the queue's reader for EVERY job: it records all of them and
  # renders only the job it shows. doc/task_model_design.md.
  describe 'the loop polls all jobs and shows one (issue #286)' do
    def two_jobs
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      [registry, main, registry.add_job(kind: :command, requested_by: main)]
    end

    def loop_for(registry, job, commands: Object.new)
      ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      worker = Task.new(registry:, job:)
      worker.ui = ui
      described_class.new(registry:, ui: ui, commands:,
                          input_path: InputPath.new(ui:), worker:)
    end

    # run_turn always hands the turn's error (nil when there was none) to the
    # commands object; a plain Object stand-in has no reporter.
    def turn_commands
      commands = Object.new
      def commands.report_turn_error(_job, _error); end
      commands
    end

    it 'next_shown_event records a foreign event and keeps pulling to the shown one' do
      registry, main, other = two_jobs
      loop_ = loop_for(registry, main)
      other.push_event(type: :text, origin: :task, content: 'from job 1')
      main.push_event(type: :text, origin: :task, content: 'mine')

      event = loop_.next_shown_event(0)

      expect(event[:content]).to eq('mine')
      # The foreign event landed in ITS OWN buffer and never reached the shown one.
      expect(other.buffer.tail.map(&:content)).to eq(['from job 1'])
      expect(main.buffer.tail).to be_empty
    end

    it 'next_shown_event returns nil when only foreign events are queued' do
      registry, main, other = two_jobs
      loop_ = loop_for(registry, main)
      other.push_event(type: :text, origin: :task, content: 'from job 1')

      expect(loop_.next_shown_event(0)).to be_nil
      expect(other.buffer.tail.map(&:content)).to eq(['from job 1'])
    end

    # A background job finishing is recorded and its result delivered, but it does
    # not end the loop: the shown job's turn is still running.
    it 'a foreign :done is recorded and does not end the drain' do
      registry, main, other = two_jobs
      worker = Task.new(registry:, job: main) { nil }
      worker.start
      loop_ = loop_for(registry, main, commands: turn_commands)
      other.push_event(type: :done, result: 'child answer')
      worker.submit_work { nil }

      loop_.run_turn { nil }

      expect(other.finished?).to be true
      expect(other.result).to eq('child answer')
      expect(loop_.ui.stdout.string).not_to include('child answer')
    end
  end

  # A job outside the foreground cannot be shown a dialog, so its request gets an
  # answer VALUE the tool can return to the model; a grant dialog is excepted.
  describe 'MainLoop#handle_request and the background denial (issue #286)' do
    def denied_loop
      registry = JobRegistry.new
      main = registry.add_job(kind: :main)
      background = registry.add_job(kind: :command, requested_by: main)
      ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      # The request arrives on the background job's own worker, so the denial
      # answer lands on ITS inbox - which is the worker's job's inbox.
      worker = Task.new(registry:, job: background)
      worker.ui = ui
      loop_ = described_class.new(registry:, ui: ui, commands: Object.new,
                                  input_path: InputPath.new(ui:), worker:)
      [loop_, background]
    end

    it 'denies a background dialog with the answer value' do
      loop_, background = denied_loop
      dialog = UI::Dialog.new(title: 'pick',
                              options: [UI::Dialog::Option.new(title: 'Yes', value: :yes)])

      loop_.handle_request(
        { type: :__request__, kind: :dialog, job: background.id, dialog: }
      )

      expect(background.poll(0)).to eq(Job::DENIED_ANSWER)
    end
  end

  # run_turn is the turn mode: submit the block as a WORK item to the parked
  # worker and drain the queue until the shown job's :done (issue #286
  # increment 3 - the loop that read the prompt now drains the turn).
  describe 'MainLoop#run_turn (issue #286 increment 3)' do
    def turn_loop(harness: nil)
      registry = JobRegistry.new
      job = registry.add_job(kind: :main, harness:)
      ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      worker = Task.new(registry:, job:)
      worker.ui = ui
      worker.prepare(harness:, ui:)
      worker.start
      commands = Object.new
      def commands.report_turn_error(_job, _error); end
      described_class.new(registry:, ui: ui, commands:,
                          input_path: InputPath.new(ui:), worker:)
    end

    it 'runs the block on the worker and drains its events to :done' do
      loop_ = turn_loop
      seen = nil
      loop_.run_turn do |task|
        task.push_event(type: :text, origin: :task, content: 'working')
        seen = Thread.current.name
        :answer
      end

      expect(loop_.ui.stdout.string).to include('working')
      expect(seen).to eq('job-0')
      expect(loop_.shown_job.buffer.tail.map(&:content)).to include('working')
    end

    it 'reports a worker error through the handler and keeps the loop alive' do
      reported = nil
      registry = JobRegistry.new
      job = registry.add_job(kind: :main)
      ui = UI::Console.new(stdout: StringIO.new, stdin: StringIO.new)
      worker = Task.new(registry:, job:)
      worker.ui = ui
      worker.prepare(harness: nil, ui:)
      worker.start
      commands = Object.new
      commands.define_singleton_method(:report_turn_error) do |job_, error|
        reported = [job_.id, error]
      end
      loop_ = described_class.new(registry:, ui: ui, commands:,
                                  input_path: InputPath.new(ui:), worker:)

      loop_.run_turn { raise 'boom' }

      expect(reported).to eq([0, 'RuntimeError: boom'])
      expect(loop_.worker.alive?).to be true # the worker parks on for the next turn
    end

    it 'drains events pushed in the :done window' do
      loop_ = turn_loop
      loop_.run_turn do |task|
        task.push_event(type: :text, origin: :task, content: 'late')
        task.push_event(type: :text, origin: :task, content: 'done-side')
        nil
      end

      expect(loop_.ui.stdout.string).to include('late')
      expect(loop_.ui.stdout.string).to include('done-side')
    end
  end
end
