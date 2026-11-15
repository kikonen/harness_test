# frozen_string_literal: true

# Task: runs the turn block on a background thread and owns ALL console I/O
# for it (single-thread I/O rule); design and protocol: doc/task_design.md

require "io/console"
require_relative "job"
require_relative "input_path"
require_relative "requester"
require_relative "sub_agent"
require_relative "output_buffer"
require_relative "ui/renderer"
require_relative "ui/editor"
require_relative "ui/spinner"
require_relative "error_text"

class Task
  include Requester

  # Default spinner message while the runner waits for the task thread.
  # Any :spinner_detail event may override it (and its suffix) for the
  # rest of the wait.
  DEFAULT_SPINNER_MESSAGE = "Working"

  # Sentinel pushed to inbox when #stop is called, to unblock a pending
  # #request so the task thread can exit cleanly.
  # ONE sentinel for the whole model. A task and a sub-agent round can block on
  # the SAME job inbox, so two distinct objects could not both recognize the stop.
  STOP = Job::STOP

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

  attr_reader :thread, :buffer, :ui, :renderer, :job, :registry, :input_path, :inbox

  # Set by #run from the harness's configured palette; the constructor's own
  # renderer colors nothing, which is what a Task without a harness needs.
  attr_writer :renderer

  attr_accessor :note_editor
  attr_accessor :harness

  # A task built for a job reads the registry's ONE queue instead of its own
  # outbox, and its inbox IS the job's inbox (the registry routes answers to it).
  def initialize(buffer:, registry: nil, job: nil, input_path: nil, &block)
    @block   = block
    # main -> task (responses, stop). For a job this IS the job's inbox.
    @inbox   = job ? job.inbox : Thread::Queue.new
    # task -> main (SINGLE event queue). Under the registry (issue #286) this is
    # the registry's ONE fan-in queue: events carry the job id, so ordering holds.
    @outbox  = Thread::Queue.new
    @registry = registry
    @job      = job
    # The task USES the buffer it is given (issue #286): the registry's job
    # supplies its own buffer, otherwise the caller hands the run buffer. The
    # task never builds one - the buffer's own limits belong to the buffer. The
    # drain loop is the single writer; the task thread never touches it.
    @buffer       = job ? job.buffer : buffer
    # Patterns and colors are the renderer's decision, so the drain loop asks
    # it instead of printing content as the emitter wrote it. #run replaces it
    # with the harness's configured palette; this one colors nothing.
    @renderer  = UI::Renderer.new
    @spinner = nil
    @thread  = nil
    @ui = nil # set by Task.run before start
    @dialog_open = false           # true while perform_direct is on stdin
    @note_editor  = nil
    @input_path   = input_path
    @started_at   = nil            # turn clock (issue #277), set by #start
    @harness      = nil
  end

  attr_writer :ui

  # While true, store_and_render must not clear output lines: a Choice
  # prompt on stdin would vanish with them.
  def dialog_open?
    @dialog_open
  end

  # True while the poll loop is in the edit state (the user is typing); the
  # loop enters it when the shared input path's peek sees a keypress.
  def edit_state?
    input_path&.edit_state?
  end

  attr_accessor :note_draft

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
        value = @block.call(self)
      rescue => e
        # The event goes FIRST: a logger that cannot write must not swallow the
        # error the user is owed.
        push_event(type: :error_ctrl, content: ErrorText.label(e))
        record_task_error(e)
      ensure
        # The block's value IS the job's result, so the caller awaiting the job
        # gets it back on the :done event.
        push_event(type: :done, result: value)
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

  # Non-blocking poll: returns one message from the queue, or nil after the
  # timeout elapses with nothing available. Over the registry an event naming
  # ANOTHER job is recorded into that job's own buffer and skipped - the
  # foreground task never renders another job's lines.
  def poll(timeout = DEFAULT_POLL_TIMEOUT)
    return @outbox.pop(false, timeout:) unless @registry && @job

    event = @registry.poll(timeout)
    return nil if event.nil?
    return event if event[:job] == @job.id

    @registry.record(event)
    poll(0)
  rescue ThreadError
    nil
  end

  # True when no events are waiting (used by the drain loop to decide whether
  # to show the spinner).
  def outbox_empty?
    return @registry.queue_empty? if @registry && @job

    @outbox.empty?
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

  # The frames go to the session's harness.log: a task thread owns no console
  # (single-thread I/O rule) and the outbox carries ONE line, so without this
  # the trace dies with the thread.
  def record_task_error(error)
    logger = @harness.respond_to?(:logger) ? @harness.logger : nil
    return unless logger

    logger.error ErrorText.detailed(error, "task thread raised")
  end

  # Push a typed event onto the single event queue (the outbox). This is the
  # ONLY way task-thread code communicates output to the main thread.
  def push_event(type:, origin: nil, content: nil, **extra)
    event = { type: type.to_sym, origin:, content: }
    event.merge!(extra) unless extra.empty?
    event[:job] = @job.id if @job
    (@registry || @outbox) << event
    event
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

    task.push_event(type:, origin:, content:)
  end

  # Write lines as :text events on the active task's outbox. One event per
  # argument (like Kernel.puts). No-op when no task is active (the CLI owns
  # main-thread output through its UI::Console).
  def self.puts(*args)
    task = current
    return unless task

    args = [""] if args.empty?
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
  #   1. Shows the spinner ONLY while the queue is empty (the task is
  #      silently working - i.e. waiting on something slow such as an LLM).
  #   2. Polls the SINGLE event queue one message at a time. Output events are
  #      stored into the buffer and rendered to stdout in order; control events
  #      (:done, :error_ctrl, :__request__) are handled directly.
  #   3. A :spinner_detail batch keeps the spinner alive with its new message.
  #
  # The same loop owns the ONE input path: the prompt and a mid-turn note are
  # the same read, and the edit state is entered when typing starts.
  #
  # The required `ui:` console is the single sink used for ALL output - spinner
  # frames, text lines, dialog prompts. Tests can pass a StringIO-backed
  # UI::Console to capture everything deterministically.
  #
  # Ctrl+C: SIGINT is trapped for the duration of this call, so an interrupt
  # always hits the drain loop (which then force-stops the task thread) and
  # re-raises Interrupt for the caller's cleanup path.
  #
  # Returns [error_msg, task] where error_msg is nil on success.
  def self.run(
    harness:,
    ui:,
    registry: nil,
    job: nil,
    input_path: nil,
    &block
  )
    # A task built for a job uses that job's buffer and inbox through the
    # registry; otherwise the harness' run buffer is the single record. The
    # drain loop is the single main-thread writer, so every put lands in the
    # same record a save reads.
    task = Task.new(buffer: harness.output_log, registry:, job:, input_path:, &block)
    task.ui = ui
    # The input path is the ONE reader the main thread's poll loop shares with
    # the idle prompt. It only PEEKS stdin until typing starts, so nothing races
    # for the keyboard. Input needs a harness to land on (nil = unit test).
    task.harness = harness
    # The palette is the harness's (issue #303). A harness double in a spec
    # may not answer #output_palette, and a Task without a harness colors
    # nothing, so the constructor's plain renderer stays unless one is given.
    palette = harness.respond_to?(:output_palette) ? harness.output_palette : nil
    # Markdown rendering of the assistant answer is opt-in (issue #106): the
    # posture is read here (a Task builds its renderer once per turn), so a
    # mid-run /markdown toggle lands on the next turn (the same as /palette).
    # A harness double in a spec may not answer #markdown?, so default off.
    markdown = harness.respond_to?(:markdown?) ? harness.markdown? : false
    # The table-width basis (issue #106): config-derived, read once per turn
    # like the palette. nil = the renderer's default (80% of the terminal).
    max_width = harness.respond_to?(:markdown_max_width) ? harness.markdown_max_width : nil
    task.renderer = UI::Renderer.new(palette:, markdown:, markdown_max_width: max_width)
    task.note_editor = UI::Editor.new(ui.stdin) if ui.stdin && harness
    error_msg   = nil
    old_trap    = trap("INT") { raise Interrupt }
    raw_stdin   = hold_raw_stdin(task)

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
            # The registry is the only writer of the record, so the finish (and
            # the result the caller awaits) lands there, not here.
            task.registry&.record(msg)
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

          msg = task.poll(0) # non-blocking: grab next if available
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
      trap("INT", old_trap)
      raw_stdin&.cooked!
    end
  end

  # issue #473: a lone keypress during the spinner only opens the note editor
  # if the drain-loop peek (stdin.input_pending?) can SEE the key. On a cooked
  # tty (Linux/KDE) the tty line-buffers until Enter, so input_pending? stays
  # false and the editor never opens. Holding a real-tty stdin in raw mode for
  # the wait makes input_pending? report a single keypress. But raw mode is a
  # pure cost where the peek never runs, so the guard requires the capability
  # the peek consumes: #input_pending? (issue #473 Ctrl+C regression - Windows
  # answers #raw && #tty? so this fired every turn, yet its mingw build has no
  # input_pending?, so the editor is never opened there and the raw(intr:true)
  # hold only broke Ctrl+C. Gating on input_pending? leaves Windows cooked and
  # keeps the Linux/KDE hold). StringIO/pipe/Object spec fakes and a redirected
  # stdin still fail the guard. intr:true keeps Ctrl-C raising Interrupt (the
  # drain loop traps it). Reline's editor reads nest their own raw(...) block,
  # restoring to this held raw mode on exit; the caller's ensure #cooked!
  # restores the tty for the next caller.
  def self.hold_raw_stdin(task)
    stdin = task.ui.stdin
    return nil unless stdin.respond_to?(:raw) &&
      stdin.respond_to?(:tty?) && stdin.respond_to?(:input_pending?) && stdin.tty?

    stdin.raw!(intr: true)
    stdin
  rescue StandardError
    # A tty that refuses the mode change (some PTYs) - steering degrades to
    # the pre-fix behaviour rather than breaking the turn.
    nil
  end

  # Create the runner's single spinner when none is running.
  def self.ensure_spinner_running(task)
    return if task.visible_spinner

    # Re-play the last requested spinner content (bug 1): a spinner built
    # after an output batch cleared the previous one shows the SAME message
    # the task asked for, not the bare default.
    # The head cell is the memory now (issue #286): the live spinner state lives
    # in the buffer's head, so the rebuild reads it instead of an ivar copy.
    detail  = task.buffer.latest_head(:spinner_detail)&.content || {}
    spinner = UI::Spinner.new(detail[:message] || DEFAULT_SPINNER_MESSAGE,
                              detail[:suffix], ui: task.ui)
    # A live badge so a mid-turn /yolo toggle is visible at once.
    harness = task.harness
    if harness.respond_to?(:command_mode_label) || harness.respond_to?(:stream_mode_label) ||
        harness.respond_to?(:plan_mode_label)
      spinner.badge = -> { mode_badge(harness) }
    end
    # The turn clock (issue #277): a live callable, so every rebuilt spinner
    # of the same turn keeps counting from the turn's start, not its own.
    spinner.elapsed = -> { task.elapsed_label }
    spinner.start
    task.spinner = spinner
  end

  # The spinner's posture tags: one bracket per NON-default posture (the command
  # consent mode, the streaming mode, the planning mode). Re-read every frame, so
  # a mid-turn /yolo, /stream or /plan toggle shows at once.
  def self.mode_badge(harness)
    tags = []
    label = harness.command_mode_label if harness.respond_to?(:command_mode_label)
    tags << "[#{label}]" if label
    stream = harness.stream_mode_label if harness.respond_to?(:stream_mode_label)
    tags << "[#{stream}]" if stream
    plan = harness.plan_mode_label if harness.respond_to?(:plan_mode_label)
    tags << "[#{plan}]" if plan
    tags.empty? ? nil : tags.join(" ")
  end

  # Spinner frame for this tick: visible only while waiting on an EMPTY
  # queue. No data => the task is silently working => animate.
  def self.show_spinner_if_waiting(task)
    return unless task.outbox_empty?

    ensure_spinner_running(task)
    task.visible_spinner&.render!
  end

  # The ONE input path, reached the same way the loop reaches it here: it peeks,
  # and once the user starts typing the loop falls into the edit state. MULTILINE
  # read: Enter inserts a newline, the submit key commits the whole block as ONE
  # input event routed to the job's inbox. Safe to call every tick: the read only
  # PEEKS, and while the editor is open this thread owns stdin. Cancel
  # (:cancelled / :empty) keeps the task running; :eof raises NoteAbort.
  def self.poll_for_note(task)
    return unless task.note_editor && task.harness

    path = task.input_path || InputPath.new(ui: task.ui, editor: task.note_editor)
    return unless path.pending?

    # The user is at the keyboard: drop any spin frame first so the editor
    # prompt starts on a clean line (the spinner resumes itself on the next
    # tick once the editor returns).
    task.clear_all_spinners
    commit_read(task, path.read(prefill: task.note_draft))
  end

  # A submitted block commits as one input event; EOF aborts the running turn.
  def self.commit_read(task, result)
    case result.status
    when :submitted
      task.note_draft = nil
      commit_input(task, task.registry&.note_event(result.text) ||
                              { type: :note, content: result.text })
    when *InputPath::ROUND_TRIP
      # An editor round-trip is NOT an input commit - closing an editor is not
      # a submission, and a note that reached the model just because an editor
      # was closed would inject text the user never sent.
      task.note_draft = result.text
    when :eof
      raise NoteAbort
    end
  end

  # Commit one input event: route it to the job's inbox (so the override rule
  # applies - a note replaces a pending note only, otherwise it queues behind),
  # then ack and record it. Main thread only (single-thread I/O rule).
  def self.commit_input(task, event)
    task.registry&.route_input(task.job&.id, event)

    commit_note(task, event[:content])
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
    # The ack and the note are two roles, not one baked string (the #466/#470
    # theme). "[note] got it" is a bracketed ack the RENDERER owns; the note
    # body is a :note paragraph the renderer wraps + indents, so a multi-line
    # note no longer spills past the prompt. The buffer stores the RAW note as
    # :note (not a baked :text line) so the resume replay redraws it wrapped too.
    ack  = task.renderer&.line(type: :kind, content: "got it", origin: "note")
    body = task.renderer&.line(type: :note, content: note)
    ui.puts(ack || "  [note] got it")
    ui.puts(body || "  #{note}")
    task.buffer.put(type: :note, origin: :user_note, content: note)
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

  def self.handle_request(task, msg)
    case msg[:kind]
    when :dialog then handle_dialog(task, msg)
    when :sub_agent then handle_sub_agent(task, msg)
    else task.respond(nil)
    end
  end

  # The main thread registers the job (it is the single poller and the only stdin
  # reader), so the spawn happens HERE - the tool only asked. The request is NOT
  # answered at spawn time: the answer IS the job's finish delivery, which lands on
  # the requester's inbox through requested_by. Answering here would let the tool
  # return before the round had any result.
  def self.handle_sub_agent(task, msg)
    registry = task.registry
    harness  = task.harness
    return task.respond("error: no registry to register the job on") if registry.nil?
    return task.respond("error: no harness to run the round with") if harness.nil?

    job = registry.add_job(kind: :sub_agent, requested_by: task.job)
    SubAgent.new(
      harness:,
      job:,
      registry: msg[:registry],
      instruction: msg[:instruction],
      max_iterations: harness.respond_to?(:sub_agent_max_iterations) ?
        harness.sub_agent_max_iterations : SubAgent::DEFAULT_MAX_ITERATIONS).start
    nil
  end

  def self.handle_dialog(task, msg)
    dialog = msg[:dialog]
    registry = task.registry
    target = registry&.job(msg[:job])
    answer = registry&.denied?(target, dialog) ? Job::DENIED_ANSWER : read_dialog(task, dialog)
    # Answer the requester the EVENT names. Over the registry that is the job's own
    # inbox - which is how a background round gets its answer instead of the
    # foreground turn (the registry routes answers to the RIGHT inbox).
    registry ? registry.answer(msg[:job], answer) : task.respond(answer)
  end

  # A dialog is serviced on the MAIN thread - the only code that reads stdin
  # (single-thread I/O rule). @dialog_open keeps the spinner from clearing the
  # prompt lines a Choice prompt on stdin would erase. The task's OWN console
  # serves it: same stdout/stdin pair the drain loop renders to, and it already
  # carries the run's presentation (issue #388).
  def self.read_dialog(task, dialog)
    task.instance_variable_set(:@dialog_open, true)
    dialog.perform_direct(ui: task.ui)
  ensure
    task.instance_variable_set(:@dialog_open, false)
  end

  # Store one output event into the OutputBuffer (structured log) and render
  # it to the task's console. The buffer keeps the ROLE CONTENT as the emitter
  # stated it; the console line is UI::Renderer's decision (label, and from
  # issue #303 the color) - so a future renderer can re-render the buffer
  # another way without the record carrying today's formatting (issue #146).
  def self.store_and_render(task, msg)
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
      ensure_spinner_running(task) unless task.visible_spinner
      task.visible_spinner&.update_detail(**payload)
    when :text
      # For a status type the origin IS the bracket label. A Task with a
      # stand-in console (specs) may carry no renderer at all.
      line = task.renderer&.line(type:, content: msg[:content], origin: msg[:origin]) || msg[:content].to_s
      ui.puts(line)
      task.buffer.put(type: :text, origin: msg[:origin] || :task, content: msg[:content])
      task.buffer.keep_window
    else
      line = task.renderer&.line(type:, content: msg[:content], origin: msg[:origin]) || msg[:content].to_s
      ui.puts(line) unless msg[:content].nil?
      task.buffer.put(type: msg[:type], origin: msg[:origin] || :task, content: msg[:content])
      task.buffer.keep_window
    end
  end

  # After :done, drain any remaining events from the queue and render them.
  def self.drain_remaining(task)
    loop do
      msg = task.poll(0)
      break unless msg
      next if msg[:type] == :done || msg[:type] == :error_ctrl

      store_and_render(task, msg)
    end
  end
end
