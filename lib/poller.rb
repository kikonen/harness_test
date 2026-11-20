# frozen_string_literal: true

# Poller: the main-thread drain loop that owns the console for a task's turn -
# it polls the event queue, renders output, drives the spinner, serves dialogs,
# and reads mid-turn notes. The spinner and the input path are the poller's,
# not the Task's: a Task is just the background runner of the block.
# Design and protocol: doc/task_design.md (issue #286).

require "io/console"
require_relative "input_path"
require_relative "ui/spinner"

class Poller
  # Constructed around the task whose events this loop drains. The task carries
  # the single sink (ui), the renderer, the note editor and the spinner storage;
  # the Poller is the only code that touches console, stdin and the spinner.
  def initialize(task)
    @task = task
  end

  # Drain loop (called from the MAIN thread). Traps SIGINT for the duration so
  # an interrupt targets the loop (which force-stops the task thread) and
  # re-raises for the caller's cleanup path. Returns [error_msg, task].
  def run
    task = @task
    error_msg  = nil
    old_trap   = trap("INT") { raise Interrupt }
    raw_stdin  = hold_raw_stdin

    begin
      task.start

      # Input waiting at turn start must not be lost to an immediate :done.
      poll_for_note

      loop do
        poll_for_note

        # Wait for the next event on the SINGLE queue (blocks up to timeout).
        msg = task.poll
        # Issue #221 review (bug 1): poll FIRST, animate only on a quiet
        # tick. Polling first gives the task thread its first ~100ms to say
        # what it is doing (:spinner_detail), so the very first frame is the
        # real message ("Sending to model...") instead of a stray 'Working'
        # frame the user saw flash at the start of every turn.
        if msg.nil?
          # Timeout expired: no data means the task is silently working.
          show_spinner_if_waiting
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
            # The registry is the only writer of the record, so the finish (and
            # the result the caller awaits) lands there, not here. A drain-loop
            # task is always built by the registry, so its registry is never nil.
            task.registry.record(msg)
            break
          when :error_ctrl
            error_msg = msg[:content]
          when :__request__
            handle_request(msg)
          when :spinner_detail
            # Re-points the spinner (keeps it alive for the next tick).
          end

          # Control events are handled above and must not be rendered; only
          # output events (text, spinner_detail, ...) go to buffer + stdout.
          unless Task::CONTROL_EVENTS.include?(msg[:type])
            store_and_render(msg)
          end

          msg = task.poll(0) # non-blocking: grab next if available
          break unless msg
        end

        break if finished
      end

      # Final drain: one last pass so an event pushed in the same window
      # as :done is not lost. After :done the task block has finished, so
      # no more pushes occur - this is complete and idempotent.
      drain_remaining
      [error_msg, task]
    rescue Task::NoteAbort
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
      trap("INT", old_trap)
      raw_stdin&.cooked!
    end
  end

  # Hold a POSIX real-tty stdin in raw mode for the turn so a lone keypress
  # opens the note editor; gated off on Windows, where raw mode breaks Ctrl+C.
  # Rationale: doc/task_design.md (issue #473).
  def hold_raw_stdin
    stdin = @task.ui.stdin
    return nil unless self.class.raw_hold_host_supported? &&
      stdin.respond_to?(:raw) &&
      stdin.respond_to?(:tty?) && stdin.respond_to?(:input_pending?) && stdin.tty?

    stdin.raw!(intr: true)
    stdin
  rescue StandardError
    # A tty that refuses the mode change (some PTYs) - steering degrades to
    # the pre-fix behaviour rather than breaking the turn.
    nil
  end

  # Host gate (not a capability probe): raw hold is POSIX-only. Specs stub it to
  # exercise the held shape on a Windows box.
  def self.raw_hold_host_supported?
    !windows_console_host?
  end

  def self.windows_console_host?
    RbConfig::CONFIG.fetch("host_os", "").match?(/mswin|mingw|cygwin/)
  end

  # Create the single spinner when none is running.
  def ensure_spinner_running
    task = @task
    return if task.visible_spinner

    # Re-play the last requested spinner content (bug 1): a spinner built
    # after an output batch cleared the previous one shows the SAME message
    # the task asked for, not the bare default.
    # The head cell is the memory now (issue #286): the live spinner state lives
    # in the buffer's head, so the rebuild reads it instead of an ivar copy.
    detail  = task.buffer.latest_head(:spinner_detail)&.content || {}
    spinner = UI::Spinner.new(detail[:message] || Task::DEFAULT_SPINNER_MESSAGE,
                              detail[:suffix], ui: task.ui)
    # A live badge so a mid-turn /yolo toggle is visible at once.
    harness = task.harness
    if harness
      spinner.badge = -> { self.class.mode_badge(harness) }
    end
    # The turn clock (issue #277): a live callable, so every rebuilt spinner
    # of the same turn keeps counting from the turn's start, not its own.
    spinner.elapsed = -> { task.elapsed_label }
    spinner.start
    task.spinner = spinner
  end

  # The spinner's posture tags: one bracket per NON-default posture (the command
  # consent mode, the streaming mode, the planning mode). Re-read every frame, so
  # a mid-turn /yolo, /stream or /plan toggle shows at once. Shared with the idle
  # prompt line (PromptReader) so a posture cannot read differently in the two.
  def self.mode_badge(harness)
    tags = []
    tags << "[#{harness&.settings&.command_mode_label}]" if harness&.settings&.command_mode_label
    tags << "[#{harness&.settings&.stream_mode_label}]" if harness&.settings&.stream_mode_label
    tags << "[#{harness&.plan_mode_label}]" if harness&.plan_mode_label
    tags.empty? ? nil : tags.join(" ")
  end

  # Spinner frame for this tick: visible only while waiting on an EMPTY
  # queue. No data => the task is silently working => animate.
  def show_spinner_if_waiting
    task = @task
    return unless task.outbox_empty?

    ensure_spinner_running
    task.visible_spinner&.render!
  end

  # The ONE input path, reached the same way the loop reaches it here: it peeks,
  # and once the user starts typing the loop falls into the edit state. MULTILINE
  # read: Enter inserts a newline, the submit key commits the whole block as ONE
  # input event routed to the job's inbox. Safe to call every tick: the read only
  # PEEKS, and while the editor is open this thread owns stdin. Cancel
  # (:cancelled / :empty) keeps the task running; :eof raises Task::NoteAbort.
  def poll_for_note
    task = @task
    return unless task.note_editor && task.harness

    path = task.input_path || InputPath.new(ui: task.ui, editor: task.note_editor)
    return unless path.pending?

    # The user is at the keyboard: drop any spin frame first so the editor
    # prompt starts on a clean line (the spinner resumes itself on the next
    # tick once the editor returns).
    task.clear_all_spinners
    commit_read(path.read(prefill: task.note_draft))
  end

  # A submitted block commits as one input event; EOF aborts the running turn.
  def commit_read(result)
    task = @task
    case result.status
    when :submitted
      task.note_draft = nil
      # In edit mode a "/command" submit runs through the run's CommandHandler
      # (the poll loop IS the main thread), NOT the note path - so any command
      # available at the idle prompt is available mid-turn (a safe one), and the
      # old /yolo note gesture is gone. Bare text keeps the note route exactly.
      # The handler is a loop-level collaborator on the shared input path (like
      # target/registry), a callable so a /resume rebuild repoints it.
      # Design: doc/unified_loop_design.md.
      text = result.text.to_s
      handler = task.input_path&.command_handler
      handler = handler.call if handler.respond_to?(:call)
      if handler && text.strip.start_with?("/")
        handler.run_mid_turn(text)
        return
      end
      commit_input(task.registry.note_event(result.text))
    when *InputPath::ROUND_TRIP
      # An editor round-trip is NOT an input commit - closing an editor is not
      # a submission, and a note that reached the model just because an editor
      # was closed would inject text the user never sent.
      task.note_draft = result.text
    when :eof
      raise Task::NoteAbort
    end
  end

  # Commit one input event: route it to the job's inbox (so the override rule
  # applies - a note replaces a pending note only, otherwise it queues behind),
  # then ack and record it. Main thread only (single-thread I/O rule).
  def commit_input(event)
    task = @task
    task.registry.route_input(task.job.id, event)

    commit_note(event[:content])
  end

  # Main thread only (single-thread I/O rule).
  def commit_note(note)
    task = @task
    # Bare note only: a "/command" never reaches here (#commit_read routes it to
    # the CommandHandler), so the old /yolo note-gesture special case is gone.
    task.harness.user_note_text = note
    ui = task.ui
    # The ack and the note are two roles, not one baked string (the #466/#470
    # theme). "[note] got it" is a bracketed ack the RENDERER owns; the note
    # body is a :note paragraph the renderer wraps + indents, so a multi-line
    # note no longer spills past the prompt. The buffer stores the RAW note as
    # :note (not a baked :text line) so the resume replay redraws it wrapped too.
    ack  = task.renderer.line(type: :kind, content: "got it", origin: "note")
    body = task.renderer.line(type: :note, content: note)
    ui.puts(ack)
    ui.puts(body)
    task.buffer.put(type: :note, origin: :user_note, content: note)
  end

  def handle_request(msg)
    task = @task
    return task.respond(nil) unless msg[:kind] == :dialog

    dialog = msg[:dialog]
    # A job outside the foreground cannot be shown a dialog, so it gets an
    # answer VALUE the tool can return to the model. Grant dialogs are excepted:
    # denying one would stop the job from working at all.
    target = task.registry.job(msg[:job])
    if task.registry.denied?(target, dialog)
      task.respond(Job::DENIED_ANSWER)
      return
    end

    task.instance_variable_set(:@dialog_open, true)
    begin
      # No reader thread during the turn, so the dialog can read stdin with
      # nothing to race for the keyboard. The task's OWN console serves the
      # dialog: it is the same stdout/stdin pair the drain loop renders to
      # (single-thread order) and it already carries the run's presentation,
      # so nothing here has to know how a dialog renders or which palette a
      # turn chose (issue #388).
      answer = dialog.perform_direct(ui: task.ui)
      task.respond(answer)
    ensure
      task.instance_variable_set(:@dialog_open, false)
    end
  end

  # Store one output event into the OutputBuffer (structured log) and render
  # it to the task's console. The buffer keeps the ROLE CONTENT as the emitter
  # stated it; the console line is UI::Renderer's decision (label, and from
  # issue #303 the color) - so a future renderer can re-render the buffer
  # another way without the record carrying today's formatting (issue #146).
  def store_and_render(msg)
    task = @task
    ui = task.ui
    type = msg[:type]

    case type
    when :spinner_detail
      # The DATA lands in the buffer HEAD first, and the spinner is rendered FROM
      # the head cell - the head is the single source of the live state (issue
      # #286), so a refresh and the spinner read the same object. The order is the
      # point: put data in the head, then build the spinner content from the head.
      origin = msg[:origin] || :task
      task.buffer.put(type: :spinner_detail, origin:, content: msg[:content])
      payload = task.buffer.cell(origin, :spinner_detail).content
      payload = payload.is_a?(Hash) ? payload : { message: payload.to_s }
      # Ensure the spinner is alive for this re-point (it may have been
      # cleared if the previous batch was non-spinner output).
      ensure_spinner_running unless task.visible_spinner
      task.visible_spinner&.update_detail(**payload)
    when :text
      line = task.renderer.line(type:, content: msg[:content], origin: msg[:origin])
      ui.puts(line)
      task.buffer.put(type: :text, origin: msg[:origin] || :task, content: msg[:content])
      task.buffer.keep_window
    else
      line = task.renderer.line(type:, content: msg[:content], origin: msg[:origin])
      ui.puts(line) unless msg[:content].nil?
      task.buffer.put(type: msg[:type], origin: msg[:origin] || :task, content: msg[:content])
      task.buffer.keep_window
    end
  end

  # After :done, drain any remaining events from the queue and render them.
  def drain_remaining
    loop do
      msg = @task.poll(0)
      break unless msg
      next if msg[:type] == :done || msg[:type] == :error_ctrl

      store_and_render(msg)
    end
  end
end
