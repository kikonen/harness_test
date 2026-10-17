# frozen_string_literal: true

# Task: runs the turn block on a background thread and owns ALL console I/O
# for it (single-thread I/O rule); design and protocol: doc/task_design.md

require_relative 'output_buffer'
require_relative 'ui/editor'
require_relative 'ui/spinner'

class Task
  # Default spinner message while the runner waits for the task thread.
  # Any :spinner_detail event may override it (and its suffix) for the
  # rest of the wait.
  DEFAULT_SPINNER_MESSAGE = 'Working'

  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  STOP = Object.new.freeze

  # Timeout (seconds) for polling the outbox in the drain loop.
  DEFAULT_POLL_TIMEOUT = 0.1

  # Raised by the drain loop when the note editor saw EOF (Ctrl-D pressed
  # inside it while editing a mid-turn note): aborts the running turn like
  # Ctrl+C (Task.run stops the task and returns normally).
  class NoteAbort < StandardError; end

  # Event types handled by the drain loop as control flow (never stored or
  # rendered): the task finished ([:done]) and a pending user request
  # ([:__request__], answered on the main thread).
  CONTROL_EVENTS = %i[error_ctrl __request__].freeze

  attr_reader :thread, :buffer, :ui

  attr_accessor :note_editor
  attr_accessor :harness

  def initialize(&block)
    @block   = block
    @inbox   = Thread::Queue.new   # main -> task (responses, stop)
    @outbox  = Thread::Queue.new   # task -> main (SINGLE event queue)
    @buffer  = OutputBuffer.new    # structured log (runner fills it)
    @spinner = nil
    @thread  = nil
    # The drain loop rebuilds the spinner whenever the outbox empties;
    # this replay keeps its message from resetting mid-turn.
    @spinner_detail = nil
    @ui      = nil                 # set by Task.run before start
    @dialog_open = false           # true while perform_direct is on stdin
    @note_editor  = nil
    @note_draft   = nil            # draft kept by a cancelled Esc
    @started_at   = nil            # turn clock (issue #277), set by #start
    @harness      = nil
  end

  attr_writer :ui

  # -- Spinner content memory ------------------------------------------------

  attr_reader :spinner_detail

  def record_spinner_detail(payload)
    @spinner_detail = payload if payload.is_a?(Hash)
  end

  # While true, store_and_render must not clear output lines: a Choice
  # prompt on stdin would vanish with them.
  def dialog_open?
    @dialog_open
  end

  # -- Lifecycle ---------------------------------------------------------------

  # Spawn the task thread and start running the block. The task reference is
  # published on Thread.current so nested code in the task can find it via
  # `Task.current` and push events onto its outbox. No buffer reference is
  # exposed to task code - the buffer is runner-side only.
  def start
    @started_at = Time.now
    @thread = Thread.new do
      Thread.current[:harness_task] = self

      begin
        @block.call(self)
      rescue => e
        push_event(type: :error_ctrl, content: "#{e.class.name}: #{e.message}")
      ensure
        push_event(type: :done)
        # Unblock any pending request so the thread can exit cleanly.
        @inbox << STOP
      end
    end
  end

  # The turn clock for the spinner's elapsed segment (issue #277): whole
  # seconds under a minute ("12s"), minutes beyond it ("2m 03s"). nil before
  # #start (a spinner built by a unit test that never started the task).
  def elapsed_label
    return nil if @started_at.nil?

    secs = (Time.now - @started_at).to_i
    return "#{secs}s" if secs < 60

    "#{(secs / 60)}m #{format('%02d', secs % 60)}s"
  end

  # Non-blocking poll: returns one message from the outbox, or nil after
  # the timeout elapses with no message available.
  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    @outbox.pop(false, timeout: timeout)
  rescue ThreadError
    nil
  end

  # True when no events are waiting in the outbox (used by the drain loop
  # to decide whether to show the spinner).
  def outbox_empty?
    @outbox.empty?
  end

  # Reply to a pending request (called from the main thread). Unblocks the
  # task thread's #request call with the given value.
  def respond(value)
    @inbox << value
  end

  # True when the task thread has been started and has not yet exited.
  def alive?
    !@thread.nil? && @thread.alive?
  end

  # Force-stop: signal the inbox (unblocking any pending request) and join
  # with a timeout. Kills the thread if it is still alive after the timeout.
  def stop(timeout = 5)
    @inbox << STOP
    @thread&.join(timeout)
    @thread&.kill if @thread&.alive?
    @thread = nil
  end

  # -- Task-thread side (called from inside the block) -----------------------

  # Push a typed event onto the single event queue (the outbox). This is the
  # ONLY way task-thread code communicates output to the main thread.
  def push_event(type:, origin: nil, content: nil, **extra)
    event = { type: type.to_sym, origin: origin, content: content }
    event.merge!(extra) unless extra.empty?
    @outbox << event
  end

  # Blocks until the main thread answers with #respond.
  def request(type, **payload)
    @outbox << { type: :__request__, kind: type, **payload }
    reply = @inbox.pop
    if reply.equal?(STOP)
      raise "task was stopped while waiting for response to '#{type}'"
    end
    reply
  end

  # -- Task-thread output helpers --------------------------------------------
  # These find the current task via Thread.current and push events onto
  # ITS outbox (the single event queue). They NEVER write to a stream and
  # NEVER touch the buffer. Main-thread startup/shutdown output goes through
  # the CLI's UI::Console instead - there is no Kernel fallback, and none
  # should ever be needed (production callers run on a task thread).

  # The Task running on the current thread (set by #start), or nil.
  def self.current
    Thread.current[:harness_task]
  end

  # Emit ONE typed event onto the active task's outbox (the single event
  # queue). No-op when no task is active (nothing to drain for).
  def self.emit(type, origin:, content: nil)
    task = current
    return nil unless task

    task.push_event(type: type, origin: origin, content: content)
  end

  # Write lines as :text events on the active task's outbox. One event per
  # argument (like Kernel.puts). No-op when no task is active (the CLI owns
  # main-thread output through its UI::Console).
  def self.puts(*args)
    task = current
    return unless task

    args = [''] if args.empty?
    args.each { |part| task.push_event(type: :text, origin: :task, content: part.to_s) }
    nil
  end

  # -- The ONE spinner (main-thread-only access via the drain loop) ----------

  # The task's single spinner (set by the drain loop; nil before first tick).
  attr_reader :spinner
  def spinner=(sp); @spinner = sp; end

  # The spinner while it is animating (nil when stopped).
  def visible_spinner
    @spinner if @spinner&.running?
  end

  def clear_all_spinners
    return unless @spinner
    if @ui && @spinner.running?
      @spinner.clear_line
    end
    @spinner.stop
    @spinner = nil
  end

  # -- Drain loop (called from the MAIN thread) ------------------------------
  #
  # Spawns the task, then blocks in a poll loop that:
  #   1. Shows the spinner ONLY while the outbox is empty (the task is
  #      silently working - i.e. waiting on something slow such as an LLM).
  #   2. Polls the SINGLE event queue (the outbox) one message at a time.
  #      - Output events: the stale spinner line is cleared FIRST (a spin
  #        frame must never survive above real output), then the event is
  #        stored into the OutputBuffer and rendered to stdout in order.
  #      - Control events (:done, :error_ctrl, :__request__): handled directly.
  #   3. A :spinner_detail batch keeps the spinner alive with its new
  #      message (the wait continues); every other batch has already
  #      cleared the spinner line inside store_and_render before printing.
  #
  # The required `ui:` console is the single sink used for
  # ALL output - spinner frames, text lines, dialog prompts. Tests can pass
  # a StringIO-backed UI::Console to capture everything deterministically.
  #
  # Ctrl+C: SIGINT is trapped for the duration of this call, so an interrupt
  # always hits the drain loop (which then force-stops the task thread - a
  # task must NEVER keep working in the background) and re-raises Interrupt
  # for the caller's cleanup path.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(
    harness:,
    ui:,
    &block
  )
    task = Task.new(&block)
    task.ui = ui
    # The editor only PEEKS stdin: no reader thread, so nothing races for
    # the keyboard. Notes need a harness to land on (nil = unit test).
    task.harness = harness
    task.note_editor = UI::Editor.new(ui.stdin) if ui.stdin && harness
    error_msg   = nil
    old_trap    = trap('INT') { raise Interrupt }

    begin
      task.start

      # Input waiting at turn start must not be lost to an immediate :done.
      poll_for_note(task)

      loop do
        poll_for_note(task)

        # Wait for the next event on the SINGLE queue (blocks up to timeout).
        msg = task.poll
        # Issue #221 review (bug 1): poll FIRST, animate only on a quiet
        # tick. Polling first gives the task thread its first ~100ms to say
        # what it is doing (:spinner_detail), so the very first frame is the
        # real message ("Sending to model...") instead of a stray 'Working'
        # frame the user saw flash at the start of every turn.
        if msg.nil?
          # Timeout expired: no data means the task is silently working.
          show_spinner_if_waiting(task)
          next
        end

        # Clear the spinner line BEFORE rendering any output so a stale
        # spin frame never survives above real text.
        task.clear_all_spinners if task.visible_spinner

        # Process this event and any that arrived in the same window
        # (batch-drain so we render one spinner frame per batch, not
        # one per event).
        finished = false
        loop do
          case msg[:type]
          when :done
            finished = true
            break
          when :error_ctrl
            error_msg = msg[:content]
          when :__request__
            handle_request(task, msg)
          when :spinner_detail
            # Re-points the spinner (keeps it alive for the next tick).
          end

          # Control events are handled above and must not be rendered; only
          # output events (text, spinner_detail, ...) go to buffer + stdout.
          unless CONTROL_EVENTS.include?(msg[:type])
            store_and_render(task, msg)
          end

          msg = task.poll(0)  # non-blocking: grab next if available
          break unless msg
        end

        break if finished
      end

      # Final drain: one last pass so an event pushed in the same window
      # as :done is not lost. After :done the task block has finished, so
      # no more pushes occur - this is complete and idempotent.
      drain_remaining(task)
      [error_msg, task]
    rescue NoteAbort
      # Like Ctrl+C: the task thread must not keep working in the background.
      task.stop
      [nil, task]
    rescue Interrupt
      # Ctrl+C: kill the task thread (it must NOT keep working in the
      # background) and hand the interrupt back to the caller (CLI cleanup).
      task.stop
      raise
    ensure
      # Clean up the spinner and restore the pre-existing SIGINT handler.
      task.clear_all_spinners
      trap('INT', old_trap)
    end
  end

  # Create the runner's single spinner when none is running.
  def self.ensure_spinner_running(task)
    return if task.visible_spinner

    # Re-play the last requested spinner content (bug 1): a spinner built
    # after an output batch cleared the previous one shows the SAME message
    # the task asked for, not the bare default.
    detail  = task.spinner_detail || {}
    spinner = UI::Spinner.new(detail[:message] || DEFAULT_SPINNER_MESSAGE,
                              detail[:suffix], ui: task.ui)
    # A live badge so a mid-turn /yolo or Ctrl+A toggle is visible at once.
    harness = task.harness
    spinner.badge = -> { mode_badge(harness) } if harness.respond_to?(:command_mode_label)
    # The turn clock (issue #277): a live callable, so every rebuilt spinner
    # of the same turn keeps counting from the turn's start, not its own.
    spinner.elapsed = -> { task.elapsed_label }
    spinner.start
    task.spinner = spinner
  end

  def self.mode_badge(harness)
    label = harness.command_mode_label
    label.nil? ? nil : "[#{label}]"
  end

  # Spinner frame for this tick: visible only while waiting on an EMPTY
  # outbox. No data => the task is silently working => animate.
  def self.show_spinner_if_waiting(task)
    return unless task.outbox_empty?

    ensure_spinner_running(task)
    task.visible_spinner&.render!
  end

  # MULTILINE read: Enter inserts a newline, the submit key commits the
  # whole block as one note. Safe to call every tick: the read only PEEKS,
  # and while the editor is open this thread owns stdin. Cancel (:cancelled
  # / :empty) keeps the task running; :eof raises NoteAbort.
  def self.poll_for_note(task)
    return unless task.note_editor && task.harness

    stdin = task.ui.stdin
    return if !stdin.respond_to?(:input_pending?) || stdin.input_pending? != true

    # The user is at the keyboard: drop any spin frame first so the
    # editor prompt starts on a clean line (the spinner resumes itself
    # on the next tick once the editor returns).
    task.clear_all_spinners

    result = task.note_editor.read_multiline(prefill: task.instance_variable_get(:@note_draft))
    # Ctrl+A toggled the command-consent mode while the editor was open:
    # ack it and return (no note was typed).
    if UI::Editor::CtrlAState.fired
      label = UI::Editor::CtrlAState.label
      UI::Editor::CtrlAState.reset!
      ack_command_mode(task, label)
      return
    end
    case result.status
    when :submitted
      task.instance_variable_set(:@note_draft, nil)
      commit_note(task, result.text)
    when :cancelled
      # Esc: keep the buffer as a draft; it is prefilled on the next trigger.
      task.instance_variable_set(:@note_draft, result.text)
    when :empty
      # Bare Enter: the user changed their mind mid-thought - no note.
    when :eof
      # Ctrl-D inside the editor: abort the running turn (see NoteAbort).
      raise NoteAbort
    end
  end

  # Main thread only (single-thread I/O rule).
  def self.commit_note(task, note)
    # HACK (#221, tech debt tracked by #267): hard-codes one slash command
    # into note plumbing, duplicating CommandHandler's registry. Safe only
    # because toggle_yolo is a pure main-thread boolean write.
    if (toggle = yolo_note_action(note))
      # A symbol mode: nil from an unmatched optional group would read as
      # "no gesture" and inject the command into the chain.
      case toggle
      when :on  then task.harness.yolo = true
      when :off then task.harness.yolo = false
      else           task.harness.toggle_yolo
      end
      label = task.harness.respond_to?(:yolo_mode_label) \
                ? task.harness.yolo_mode_label : nil
      line  = "  [#{label || 'YOLO toggle unavailable'}]"
      task.ui.puts(line)
      task.buffer.put(type: :text, origin: :user_note, content: line)
      return
    end

    task.harness.user_note_text = note
    ui = task.ui
    ui.puts("  [note] got it - #{note}")
    task.buffer.put(type: :text, origin: :user_note, content: "note received: #{note}")
  end

  # HACK (see commit_note): recognize the single special-cased /yolo
  # steering gesture. Returns the mode name when the note is a bare /yolo
  # control gesture (optionally with on/off), nil for any real note (a note
  # that merely MENTIONS yolo stays a note - only an exact "/yolo",
  # "/yolo on" or "/yolo off" flips the posture). Goes away with the
  # gesture-dispatch refactor.
  def self.yolo_note_action(note)
    m = note.to_s.strip.match(%r{\A/yolo(?:\s+(on|off))?\z}i)
    return nil unless m

    # :toggle for the bare marker: an unmatched OPTIONAL group returns nil,
    # which is falsy - returning it would make "/yolo" look like "no
    # gesture" and inject the command into the conversation chain.
    m[1] ? m[1].downcase.to_sym : :toggle
  end

  def self.ack_command_mode(task, label)
    ui = task.ui
    line = label.nil? ? "  [mode toggle unavailable]" \
                      : "  [mode is now #{label}]"
    ui.puts(line)
    task.buffer.put(type: :text, origin: :user_note, content: line)
  end

  def self.handle_request(task, msg)
    if msg[:kind] == :dialog
      dialog = msg[:dialog]
      task.instance_variable_set(:@dialog_open, true)
      begin
        # No reader thread during the turn, so the dialog can read stdin with
        # nothing to race for the keyboard; the Console wraps the task's streams
        # so output keeps its single-thread order.
        ui = UI::Console.new(stdout: task.ui.stdout, stdin: task.ui.stdin)
        answer = dialog.perform_direct(ui: ui)
        task.respond(answer)
      ensure
        task.instance_variable_set(:@dialog_open, false)
      end
    else
      task.respond(nil)
    end
  end

  # Store one output event into the OutputBuffer (structured log) and render
  # it to the task's console. The buffer is the durable record; the console
  # is what the user sees right now. Both happen on the main thread, in
  # outbox order.
  def self.store_and_render(task, msg)
    ui = task.ui

    case msg[:type]
    when :spinner_detail
      payload = msg[:content].is_a?(Hash) ? msg[:content] : { message: msg[:content].to_s }
      # Ensure the spinner is alive for this re-point (it may have been
      # cleared if the previous batch was non-spinner output).
      ensure_spinner_running(task) unless task.visible_spinner
      task.visible_spinner&.update_detail(**payload)
      # Remember it so a spinner rebuilt later in the same wait keeps this
      # message instead of falling back to 'Working...' (bug 1).
      task.record_spinner_detail(payload)
      task.buffer.put(type: :spinner_detail, origin: msg[:origin] || :task, content: msg[:content])
    when :text
      ui.puts(msg[:content].to_s)
      task.buffer.put(type: :text, origin: msg[:origin] || :task, content: msg[:content])
    else
      ui.puts(msg[:content].to_s) if msg[:content]
      task.buffer.put(type: msg[:type], origin: msg[:origin] || :task, content: msg[:content])
    end
  end

  # After :done, drain any remaining events from the outbox and render them.
  def self.drain_remaining(task)
    loop do
      msg = task.poll(0)
      break unless msg
      next if msg[:type] == :done || msg[:type] == :error_ctrl

      store_and_render(task, msg)
    end
  end
end
