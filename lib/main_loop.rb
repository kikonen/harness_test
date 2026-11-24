# frozen_string_literal: true

# MainLoop: the run's ONE main loop on the MAIN thread (issue #286 increment 3).
# It replaces CLI#run's idle loop and the per-turn drain loop: the idle prompt
# read and a turn's event drain are two modes of the SAME loop. It owns stdin,
# the spinner, the ONE event queue and the foreground job's parked worker. A
# prompt submits a WORK item to that worker and drains its events; a submit while
# a turn is live is a note or a mid-turn command. There is no second reader of
# the queue and no second main. Design: doc/unified_loop_design.md, doc/task_design.md.

require "io/console"
require_relative "input_path"
require_relative "task"
require_relative "ui/spinner"

class MainLoop
  # What the mid-turn read shows. See #poll_for_note.
  NOTE_PROMPT = "> "

  # The prompt the idle read shows (the input path's own default is the note
  # prompt; the two are the SAME read, only the label differs).
  IDLE_PROMPT = "  "

  # The run-level collaborators: the registry (the ONE queue), the single console
  # sink, the command dispatcher, the shared input path, and the foreground job's
  # parked worker. The modeline is a callable (the idle prompt's own renderer) so
  # the loop does not know what an idle line looks like.
  def initialize(registry:, ui:, commands:, input_path:, worker:, modeline: nil)
    @registry    = registry
    @ui          = ui
    @commands    = commands
    @input_path  = input_path
    @worker      = worker
    @modeline    = modeline
    @spinner     = nil
    @draft       = nil
  end

  attr_reader :registry, :ui, :commands, :input_path, :worker, :modeline

  # The job whose events this loop renders: the worker's job, which is the
  # foreground job. A /jobs switch repoints the worker (repoint_worker), so the
  # shown job follows it.
  def shown_job
    worker.job
  end

  def shown_event?(event)
    event[:job] == shown_job.id
  end

  # Repoint the loop at another job's parked worker (a /jobs foreground switch).
  # The old worker is stopped; the new one is built if none lives yet.
  def repoint_worker(job)
    return if worker.job.equal?(job)

    worker&.stop
    @worker = registry.worker_for(job, ui:, input_path:)
  end

  # The next event this loop shows: pull from the ONE queue, record what belongs
  # to another job, and keep pulling until an event for the shown job arrives or
  # the queue goes quiet. The filter lives HERE: the loop is the queue's reader.
  def next_shown_event(timeout = Task::DEFAULT_POLL_TIMEOUT)
    loop do
      event = registry.poll(timeout)
      return nil if event.nil?
      return event if shown_event?(event)

      registry.record(event)
      timeout = 0
    end
  end

  # The run loop (main thread). Traps SIGINT for the whole run so an interrupt
  # targets the loop (which force-stops the worker) and re-raises for the CLI's
  # cleanup. Returns when the user quits (Ctrl-D at the idle prompt) or a command
  # ends the run.
  def run
    old_trap  = trap("INT") { raise Interrupt }
    raw_stdin = hold_raw_stdin

    begin
      loop do
        text = read_prompt
        break if text.nil?
        break if commands.exiting?

        if prompt_submit?(text)
          registry.record_user_prompt(text)
          run_turn { |t| commands.run_prompt(t, text) }
        else
          commands.handle(text)
        end
        break if commands.exiting?

        ui.puts
        ui.puts "-" * 40
        ui.puts
      end
    rescue Interrupt
      worker&.stop
      raise
    ensure
      worker&.stop
      clear_spinner
      trap("INT", old_trap)
      raw_stdin&.cooked!
    end
  end

  # A submit that starts a turn: bare text (not a slash command, not a bang).
  # The loop records it as a user prompt and submits it to the worker; everything
  # else is a command the dispatcher runs inline.
  def prompt_submit?(text)
    !text.start_with?("/") && !text.start_with?("!")
  end

  # The idle mode: render the modeline, then the blocking read. Returns the
  # submitted text, or nil when the user quits (Ctrl-D on an empty buffer). The
  # worker is parked here, so nothing is drained - the read owns stdin.
  def read_prompt
    loop do
      modeline&.call
      result = input_path.read(prefill: @draft)
      case result.status
      when :eof
        @draft = nil
        return nil
      when *InputPath::ROUND_TRIP
        @draft = result.text.to_s
        note = result.note
        ui.puts "  (#{note} - draft kept; press the submit key to send)" if note
        next
      end

      @draft = nil
      return result.text.to_s.gsub("\r\n", "\n")
    end
  end

  # One turn: submit the block as a WORK item to the foreground worker and drain
  # the queue until the shown job's :done. This replaces the per-turn nested
  # drain loop - the same loop that read the prompt now drains the turn. A Ctrl-D
  # inside a mid-turn read aborts the turn (like Ctrl+C) and returns to idle.
  def run_turn(&)
    task = worker
    job  = task.job
    error = nil
    finished = false

    task.submit_work(&)

    catch(:turn_aborted) do
      poll_for_note
      loop do
        poll_for_note

        msg = next_shown_event
        if msg.nil?
          show_spinner_if_waiting
          next
        end

        clear_spinner if visible_spinner

        loop do
          case msg[:type]
          when :done
            finished = shown_event?(msg)
            registry.record(msg)
            break
          when :error_ctrl
            error = msg[:content] if shown_event?(msg)
          when :__request__
            handle_request(msg)
          when :spinner_detail
            # Re-points the spinner (keeps it alive for the next tick).
          end

          store_and_render(msg) unless Task::CONTROL_EVENTS.include?(msg[:type])

          msg = next_shown_event(0)
          break unless msg
        end

        break if finished
      end
    end

    drain_remaining
    commands.report_turn_error(job, error)
  end

  # Hold a POSIX real-tty stdin in raw mode for the run so a lone keypress opens
  # the note editor; gated off on Windows, where raw mode breaks Ctrl+C.
  def hold_raw_stdin
    stdin = ui.stdin
    return nil unless self.class.raw_hold_host_supported? &&
      stdin.respond_to?(:raw) &&
      stdin.respond_to?(:tty?) && stdin.respond_to?(:input_pending?) && stdin.tty?

    stdin.raw!(intr: true)
    stdin
  rescue StandardError
    nil
  end

  def self.raw_hold_host_supported?
    !windows_console_host?
  end

  def self.windows_console_host?
    RbConfig::CONFIG.fetch("host_os", "").match?(/mswin|mingw|cygwin/)
  end

  # Create the single spinner when none is running. The spinner storage is the
  # loop's (issue #286 increment 3): the loop is the only code that animates it.
  def ensure_spinner_running
    return if visible_spinner

    detail  = shown_job.buffer.latest_head(:spinner_detail)&.content || {}
    spinner = UI::Spinner.new(
      detail[:message] || Task::DEFAULT_SPINNER_MESSAGE,
      detail[:suffix],
      ui:)
    spinner.badge = -> { self.class.turn_badge(job: shown_job, harness: worker.harness) }
    spinner.elapsed = -> { worker.elapsed_label }
    spinner.start
    @spinner = spinner
  end

  # The loop's spinner (nil before first tick); a test or caller may install one.
  attr_reader :spinner

  def spinner=(value)
    @spinner = value
  end

  def visible_spinner
    @spinner if @spinner&.running?
  end

  def clear_spinner
    return unless @spinner

    @spinner.clear_line if @spinner.running?
    @spinner.stop
    @spinner = nil
  end

  # The spinner's badge: the job that is working then the posture tags.
  def self.turn_badge(job:, harness: nil)
    tags = [job_tag(job), mode_badge(harness)].compact
    tags.empty? ? nil : tags.join(" ")
  end

  # Which job a turn belongs to. EVERY job is named, main included.
  def self.job_tag(job)
    return nil if job.nil?

    "[job #{job.id} #{job.kind}]"
  end

  # The posture tags: one bracket per NON-default posture. Re-read every frame so
  # a mid-turn toggle shows at once. Shared with the idle modeline so a posture
  # cannot read differently in the two.
  def self.mode_badge(harness)
    tags = []
    tags << "[#{harness&.settings&.command_mode_label}]" if harness&.settings&.command_mode_label
    tags << "[#{harness&.settings&.stream_mode_label}]" if harness&.settings&.stream_mode_label
    tags << "[#{harness&.plan_mode_label}]" if harness&.plan_mode_label
    tags.empty? ? nil : tags.join(" ")
  end

  # Spinner frame for this tick: visible only while waiting on an EMPTY queue.
  def show_spinner_if_waiting
    return unless registry.queue_empty?

    ensure_spinner_running
    visible_spinner&.render!
  end

  # The mid-turn read: peek the shared input path; a keypress opens the editor.
  # Safe to call every tick: the read only PEEKS, and while the editor is open
  # this thread owns stdin. Cancel keeps the turn running; :eof aborts it.
  def poll_for_note
    return unless worker&.harness

    return unless input_path.pending?

    clear_spinner
    commit_read(input_path.read(prefill: worker.note_draft, prompt: NOTE_PROMPT))
  end

  # A submitted block commits as one input event; EOF aborts the running turn.
  def commit_read(result)
    case result.status
    when :submitted
      worker.note_draft = nil
      text = result.text.to_s
      if text.strip.start_with?("/")
        commands.run_mid_turn(text)
        return
      end
      commit_input(registry.note_event(result.text))
    when *InputPath::ROUND_TRIP
      worker.note_draft = result.text
    when :eof
      # Like Ctrl+C: the worker must not keep working in the background.
      worker.stop
      throw(:turn_aborted)
    end
  end

  # Commit one input event: route it to the job's inbox (the override rule
  # applies), then ack and record it. Main thread only.
  def commit_input(event)
    registry.route_input(shown_job.id, event)
    commit_note(event[:content])
  end

  # Main thread only.
  def commit_note(note)
    worker.harness.user_note_text = note
    line = worker.renderer.line(
      type: :ack_note,
      content: note,
      origin: "note",
      ack: "got it")
    ui.puts(line)
    shown_job.buffer.put(type: :note, origin: :user_note, content: note)
  end

  def handle_request(msg)
    task = worker
    return task.respond(nil) unless msg[:kind] == :dialog

    dialog = msg[:dialog]
    target = registry.job(msg[:job])
    if registry.denied?(target, dialog)
      task.respond(Job::DENIED_ANSWER)
      return
    end

    task.instance_variable_set(:@dialog_open, true)
    begin
      answer = dialog.perform_direct(ui:)
      task.respond(answer)
    ensure
      task.instance_variable_set(:@dialog_open, false)
    end
  end

  # Store one output event into the shown job's buffer and render it. The buffer
  # keeps the ROLE CONTENT as the emitter stated it; the console line is the
  # renderer's decision.
  def store_and_render(msg)
    type   = msg[:type]
    buffer = shown_job.buffer

    case type
    when :spinner_detail
      origin = msg[:origin] || :task
      buffer.put(type: :spinner_detail, origin:, content: msg[:content])
      payload = buffer.cell(origin, :spinner_detail).content
      payload = payload.is_a?(Hash) ? payload : { message: payload.to_s }
      ensure_spinner_running unless visible_spinner
      visible_spinner&.update_detail(**payload)
    when :text
      line = worker.renderer.line(type:, content: msg[:content], origin: msg[:origin])
      ui.puts(line)
      buffer.put(type: :text, origin: msg[:origin] || :task, content: msg[:content])
      buffer.keep_window
    else
      line = worker.renderer.line(type:, content: msg[:content], origin: msg[:origin])
      ui.puts(line) unless msg[:content].nil?
      buffer.put(type:, origin: msg[:origin] || :task, content: msg[:content])
      buffer.keep_window
    end
  end

  # After :done, drain any remaining events so one pushed in the same window is
  # not lost.
  def drain_remaining
    loop do
      msg = next_shown_event(0)
      break unless msg
      next if msg[:type] == :done || msg[:type] == :error_ctrl

      store_and_render(msg)
    end
  end
end
