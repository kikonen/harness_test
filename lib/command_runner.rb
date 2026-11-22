# frozen_string_literal: true

require "bundler"

require_relative "tool"
require_relative "command_allowlist"
require_relative "ui/dialog"
require_relative "safety_check"
require_relative "text_normalizer"
require_relative "error_text"
require_relative "ui/renderer"
require_relative "output_budget"

# Consent + execution for shell commands, serving both the model tool path and
# bang syntax. The denylist is the floor under every posture. Postures, the
# model safety check and the execution guarantees: doc/consent_postures_design.md.
class CommandRunner
  DEFAULT_TIMEOUT = 60    # seconds
  MAX_TIMEOUT     = 300   # hard cap
  DEFAULT_LIMIT   = 500   # output lines
  MAX_LIMIT       = 5000  # hard cap
  # Keep this many leading tokens as a command's handle once an earlier line
  # already printed the full command.
  HANDLE_TOKENS   = 4
  # The child's own process group, so a timeout kill reaches the whole tree.
  PGROUP_SPAWN_KEY = Gem.win_platform? ? :new_pgroup : :pgroup
  # After the kill the tree is gone, so the following wait cannot hang.
  KILL_GRACE_SECONDS = 5

  TOOL_TITLE = "The model is requesting to run a shell command:\n" \
               "$ %s\ncwd: %s (timeout: %ss)"
  BANG_TITLE = "Run shell command:\n$ %s\ncwd: %s (timeout: %ss)"

  # Which allowlist file this runner consults and writes.
  LISTS = { tool: CommandAllowlist::TOOL_FILENAME,
            shell: CommandAllowlist::SHELL_FILENAME }.freeze

  # Fallback when no tailored note names the specific unsafe construct.
  UNSAFETY_NOTE = "UNSAFE: contains shell constructs that cannot be auto-approved."

  # auto_approve_all skips the dialog for every command of this caller (bang
  # path with confirmation off); the YOLO tool path is read live instead, see
  # auto_approve_all?. The denylist always forces the dialog. harness logs
  # failed commands to harness.log.
  def initialize(file_list, settings, label: "run.command", title_fmt: TOOL_TITLE,
                 ui: nil, list: :tool, harness: nil, auto_approve_all: false)
    @file_list = file_list
    @settings  = settings
    @label     = label
    @title_fmt = title_fmt
    @ui        = ui
    @list      = list.to_sym
    @safety_client = nil
    @harness = harness
    @auto_approve_all = auto_approve_all
    @allowlist = CommandAllowlist.new(file_list.workdir,
                                      file: LISTS.fetch(list.to_sym))
  end

  # Run a command after any required user consent. Returns the formatted
  # result string: "exit code: N (Xs)" + output section, or an
  # "error: ..." string on denial / timeout.
  def run(command, cwd: nil, timeout: DEFAULT_TIMEOUT, limit: DEFAULT_LIMIT)
    # Model-supplied text can carry bytes that make strip (and the tokenizer) raise.
    command = TextNormalizer.normalize(command).strip
    return "error: 'command' must be a non-empty shell command" if command.empty?

    dir   = cwd ? @file_list.resolve(cwd) : @file_list.workdir
    shown = @file_list.display_path(dir)
    unless File.directory?(dir)
      return "error: directory '#{shown}' does not exist"
    end

    timeout = [timeout.to_i, DEFAULT_TIMEOUT].max
    timeout = [timeout, MAX_TIMEOUT].min
    limit   = limit.to_i
    limit   = DEFAULT_LIMIT if limit <= 0
    limit   = [limit, MAX_LIMIT].min

    # Checked first: no later auto-approval path (grant, verdict, YOLO) may skip
    # the denylist, which always reaches a one-off dialog.
    disaster = CommandAllowlist.disaster?(command)
    full_shown = false
    # safety_verdict_for is one-shot (deletes the cache on first read), so a
    # verdict the override consumed is not refetched: that would pay a second
    # forked LLM call and drop the advisory note.
    verdict = nil
    verdict_computed = false

    if disaster
      # Tool path only, real "safe:" verdict only - detection is never weakened.
      # doc/denylist_safe_approve_design.md.
      if denylist_safe_override? && @list == :tool
        verdict = safety_verdict_for(command)
        verdict_computed = true
        if auto_approve_safe?(verdict)
          status(:warn, "auto-approved (denylist safe-override, model verdict: " \
                        "#{verdict}): #{command}")
          log_denylist_override(command, verdict)
          return execute(command, dir, shown, timeout, limit, full_shown: true)
        end
      end
      status(:warn, "denylisted (auto-approval refused in every posture): #{command}")
      @harness&.logger&.warn "denylisted command needs an explicit Allow: #{command}"
      # The refusal already printed the full command, so this run counts as named.
      full_shown = true
    elsif @allowlist.allowed?(command)
      # Auto-approve when the command prefix is in the user's allowlist.
      status(:ok, "auto-approved (allowlist): #{command}")
      return execute(command, dir, shown, timeout, limit, full_shown: true)
    elsif auto_approve_all?
      # No dialog and deliberately no model check; status + log keep it auditable.
      reason = yolo_active? ? "YOLO" : "bang consent off"
      status(:ok, "auto-approved (#{reason}): #{command}")
      log_auto_approved(command, reason)
      return execute(command, dir, shown, timeout, limit, full_shown: true)
    end

    # Advisory only; a verdict the override already consumed is not refetched.
    verdict = safety_verdict_for(command) unless verdict_computed

    # AUTO-APPROVE mode: a model "safe:" verdict skips the dialog; "dangerous:"
    # or no verdict still asks. It never touches the allowlist, and a disaster
    # command is never auto-approved just because the model called it safe.
    if !disaster && auto_approve_mode? && verdict
      if auto_approve_safe?(verdict)
        status(:ok, "auto-approved (model verdict: safe): #{command}")
        return execute(command, dir, shown, timeout, limit, full_shown: true)
      end
      # dangerous -> fall through to the dialog with the verdict note.
    end

    # Offer one "Always allow" per candidate prefix, filtered so only prefixes
    # that would actually change behaviour when saved are shown. A denylisted
    # command gets none: this is a one-off decision, not a standing grant.
    all_candidates = CommandAllowlist.extract_prefix_options(command)
    prefixes       = disaster ? [] : @allowlist.filter_uncovered(all_candidates)
    options        = [UI::Dialog::Option.new(title: "Allow", value: :allow)]

    prefixes.each do |p|
      options << UI::Dialog::Option.new(
        title: "Always allow '#{p}'",
        # A unique per-prefix value lets a multi-select answer map back exactly.
        value: { always_allow: p },
        # Each offer names the scope it saves; none is unlabeled.
        description: CommandAllowlist.grant_scope_note(p)
      )
    end

    # The harness's own note, with its KIND so the console colors it. UNSAFE is
    # only for a command that genuinely cannot be auto-approved (a named
    # construct or a parse failure) - never inferred from "no candidate prefix".
    deterministic = nil
    label  = CommandAllowlist.classify_unsafe(command)
    unsafe = label || parse_failed?(command)
    if unsafe
      text = label ? "UNSAFE: #{label} cannot be auto-approved" : UNSAFETY_NOTE
      deterministic = UI::Dialog::Note.new(text, kind: "warn")
    end

    # The denylist note wins over UNSAFETY: it asks even in YOLO/grant, so name
    # the matched construct.
    if disaster
      deterministic = UI::Dialog::Note.new(
        "DENYLISTED: #{CommandAllowlist.disaster_label(command)} - " \
        "well-known disaster, auto-approval refused in every posture; " \
        "this Allow is one-off",
        kind: "alert"
      )
    end

    # The advisory verdict leads; the deterministic line follows. Colored by kind
    # so a "safe:" line and a "dangerous:" one read differently.
    notes = [verdict_note(verdict), deterministic].compact

    dialog = UI::Dialog.new(
      title: format(@title_fmt, command, shown, timeout),
      options:,
      note: notes,
      multi_select: !prefixes.empty?
    )
    # In a Task thread, show(ui: nil) routes the dialog to the drain loop's main
    # thread; on the main thread (bang) serve it in place.
    choice = @ui ? dialog.perform_direct(ui: @ui) : dialog.show(ui: nil)

    result = handle_choice(choice)
    return result[:denial] if result[:denied]

    if result[:saved] && !result[:saved].empty?
      result[:saved].each { |p| @allowlist.add(p) }
      status(:ok, "always-allowed: #{result[:saved].join(', ')} (saved to allowlist)")
    end

    execute(command, dir, shown, timeout, limit, full_shown:)
  end

  private

  # A command ShellParser cannot decompose. Distinct from "no candidate prefix":
  # a plain command is not a parse failure.
  def parse_failed?(command)
    !command.empty? && CommandAllowlist.split_segments(command).empty?
  end

  # In a Task thread it goes onto the event queue; on the main thread the runner
  # renders the same pattern, so a bang command looks like a tool one.
  def status(verdict, msg)
    if defined?(Task) && Task.current
      Tool.push_status(label: @label, verdict:, message: msg)
    elsif @ui
      type = Tool.status_type(verdict)
      @ui.puts(renderer.line(type:, content: msg, origin: @label))
    end
  end

  # Not memoized: the main thread has no turn boundary, so a /palette switch
  # shows up in the next bang command.
  def renderer
    palette = UI::Renderer.palette_for(ui: @ui, settings: @settings)
    UI::Renderer.new(palette:)
  end

  # Returns :denied/:denial on cancel, or :saved (prefixes to persist). A bare
  # :allow, even mixed into a multi-select line, runs without saving.
  def handle_choice(choice)
    # A [:cancelled, 'reason'] pair is a cancel with a one-line reason.
    if choice.is_a?(Array) && choice.size == 2 && choice[1].is_a?(String)
      return denial("user denied executing the command", note: choice[1]) \
             if choice[0] == UI::Dialog::CANCEL_VALUE
      return {}
    end

    values = choice.is_a?(Array) ? choice : [choice]
    return denial("user denied executing the command") \
           if values.include?(UI::Dialog::CANCEL_VALUE)

    # Allowing alongside grants is ambiguous: honor the Allow, save nothing.
    if values.include?(:allow)
      return { saved: [] }
    end

    saved = values.select { |v| v.is_a?(Hash) && v[:always_allow] }
                .map { |v| v[:always_allow] }
    { saved: }
  end

  # Prefer a batch pre-check verdict cached on settings, else check this command
  # now. nil when the check is off or produced nothing.
  def safety_verdict_for(command)
    return nil unless @settings.command_safety_check == true

    cached = @settings.safety_verdicts
    if cached.is_a?(Hash)
      @settings.safety_verdicts = cached.reject { |k, _v| k == command }
      return cached[command]
    end

    # nil on failure: degrade to a plain dialog
    verdict = run_safety_check([command])
    verdict && verdict[command]
  end

  # ON only when the safety check is enabled AND the posture is auto-approve.
  def auto_approve_mode?
    !!@settings.command_safety_auto_approve_effective?
  end

  # Bang path with confirmation off, or the tool path while YOLO is on. YOLO is
  # re-read every command so a mid-run /yolo applies to the next command.
  def auto_approve_all?
    @auto_approve_all || yolo_active?
  end

  # YOLO covers only the model-driven tool path; bang consent is a separate key.
  def yolo_active?
    @list == :tool && @settings.yolo? == true
  end

  # An auto-approved run must leave a trace; the status line covers the console,
  # this covers harness.log.
  def log_auto_approved(command, reason)
    logger = @harness&.logger
    return unless logger

    logger.info "auto-approved (#{reason}): #{command}"
  end

  # A config value, not read live, so a relaxed floor cannot shift mid-loop.
  def denylist_safe_override?
    @settings.denylist_safe_approve?
  end

  # A denylist match ran without a dialog; log the verdict and option so the
  # session log answers "why did a denylisted command run?".
  def log_denylist_override(command, verdict)
    logger = @harness&.logger
    return unless logger

    logger.warn "denylist safe-override auto-approved " \
      "(command_safety_denylist_safe_approve, verdict: #{verdict}): " \
      "#{command}"
  end

  # Only a line starting with "safe:" auto-approves; anything else asks again.
  def auto_approve_safe?(verdict)
    verdict.to_s.strip.match?(/\Asafe:/)
  end

  # Returns {command => verdict-or-nil}; nil on any error - a failed check must
  # never break the consent flow.
  def run_safety_check(commands)
    Task.emit(:spinner_detail, origin: :command_runner,
              content: { message: "Model safety check (1 command)" }) if Task.current
    results  = SafetyCheck.run(safety_client, session_chain, commands,
                               tools: harness_tools, logger: @harness&.logger)
    verdicts = results.values.compact
    if verdicts.any?
      status(:ok, "model verdict: #{verdicts.join(' | ')}")
    end
    results
  rescue StandardError => e
    logger = @harness&.logger
    logger&.info "command safety check failed (#{ErrorText.label(e)}) - no verdict"
    nil
  end

  def safety_client
    @safety_client ||= @harness&.client
  end

  def harness_tools
    @harness&.tools_payload
  end

  def session_chain
    @harness&.session&.messages
  end

  def verdict_note(verdict)
    return nil if verdict.nil?

    UI::Dialog::Note.new("MODEL VERDICT (advisory): #{verdict}",
                         kind: verdict_kind(verdict))
  end

  def verdict_kind(verdict)
    auto_approve_safe?(verdict) ? "safe" : "alert"
  end

  def denial(message, note: nil)
    if note
      status(:fail, "denied by user (note: \"#{note}\")")
    else
      status(:fail, "denied by user")
    end
    { denied: true,
      denial: Tool.denial_error("error: #{message}", note ? { note: } : nil) }
  end

  # A run whose command was already printed earlier names it by handle; a plain
  # dialog-approved run keeps the full text - this line is its only trace.
  def execute(command, dir, shown, timeout, limit, full_shown: false)
    name = full_shown ? command_handle(command) : command
    announce_run(command)
    started = Time.now
    output, shell_status = run_in_shell(command, dir, timeout)
    if shell_status == :timeout
      status(:fail, "#{name} (timed out after #{timeout}s)")
      log_failure(command, "TIMED OUT after #{timeout}s", output)
      return "error: command timed out after #{timeout}s"
    end
    elapsed = (Time.now - started).round(2)
    code    = shell_status.exitstatus

    out = truncate(output, limit)[0]

    if code.zero?
      status(:ok, "#{name} (exit 0, #{elapsed}s)")
    else
      status(:fail, "#{name} (exit #{code}, #{elapsed}s)")
    end

    format_result(command, code, elapsed, output, out)
  end

  # A wait on the child leaves the outbox quiet, so the drain loop would replay
  # the finished LLM request - a long run reads as if the model were still
  # generating. Only the handle (no "...", the spinner adds its own) reaches it.
  def announce_run(command)
    task = defined?(Task) ? Task.current : nil
    return nil unless task

    handle = command_handle(command).sub(/ \.\.\.\z/, "")
    suffix = @harness&.tool_wait_suffix
    task.push_event(type: :spinner_detail, origin: @label,
                    content: { message: "#{@label}: #{handle}", suffix: })
  end

  def command_handle(command)
    tokens = command.split(/\s+/)
    head   = tokens.first(HANDLE_TOKENS)
    head.join(" ") + (tokens.size > head.size ? " ..." : "")
  end

  # A failed command that produced no output names why, so the model sees it;
  # the full raw output still goes to harness.log.
  def format_result(command, code, elapsed, stdout, out)
    msg = "exit code: #{code} (#{elapsed}s)\n"
    msg += "--- output ---\n#{out}\n" if out.strip != ""
    if !code.zero? && stdout.strip.empty?
      msg += "(the command produced no output - nothing to inspect)\n"
    end
    log_failure(command, "exit #{code}", stdout) unless code.zero?
    msg
  end

  # A failed command logs the full untruncated output so the failure always
  # leaves a trace, even when the returned result had none.
  def log_failure(command, why, stdout = nil)
    logger = @harness&.logger
    return unless logger

    parts = ["command: #{command}", "status: #{why}"]
    if stdout
      parts << "--- output ---\n#{stdout.strip.empty? ? '(none)' : stdout}"
    end
    logger.warn "shell command failed:\n" + parts.join("\n")
  end

  # Strips inherited bundler env: the harness may run from a shell polluted by
  # another project's BUNDLE_GEMFILE, which would make `bundle exec` resolve
  # against the wrong Gemfile. Result: [combined_output, exit_code_or_:timeout].
  def run_in_shell(command, dir, timeout)
    Bundler.with_unbundled_env do
      read_child_in_group(command, dir, timeout)
    end
  end

  # Always returns: on timeout the whole tree is killed and :timeout returned, so
  # a hung command can never block the caller (Open3+Timeout would abandon the
  # child and leave its streams open).
  def read_child_in_group(command, dir, timeout)
    out_r, out_w = IO.pipe
    pid = spawn_in_group("sh", ["-c", command], dir, out_w)
    out_w.close

    # BINARY on purpose: pipe chunks arrive byte-invalid under a Windows code
    # page; a UTF-8 accumulator would raise or silently mutate. The result is
    # normalized once at the end so sequences split across chunks survive.
    output = +"".dup.force_encoding(Encoding::BINARY)
    reader = Thread.new do
      Thread.current.report_on_exception = false
      loop { output << out_r.readpartial(64 * 1024).dup.force_encoding(Encoding::BINARY) }
    rescue EOFError, IOError
      # EOF when the tree exits; out_r#close unblocks a read a grandchild held.
    end

    waiter = Process.detach(pid)
    deadline = Time.now + timeout
    timed_out = false
    until waiter.join(0.1)
      if Time.now >= deadline
        timed_out = true
        kill_process_tree(pid)
        waiter.join(KILL_GRACE_SECONDS) # the tree is gone, or nearly
        break
      end
    end

    out_r.close # unblocks the reader if a grandchild kept the pipe open
    reader.join
    # Read boundary: everything downstream sees valid UTF-8 from here on.
    [TextNormalizer.normalize(output), timed_out ? :timeout : waiter.value]
  end

  # Retry plain if this Ruby rejects the group spawn flag: the timeout kill then
  # reaches only the direct child (still no hang, but grandchildren survive).
  def spawn_in_group(cmd, args, dir, out_w)
    Process.spawn(cmd, *args, chdir: dir, in: File::NULL,
                  out: out_w, err: out_w, PGROUP_SPAWN_KEY => true)
  rescue ArgumentError
    status(:warn, "process-group spawn unsupported by this Ruby; " \
                  "a timeout kill may not reach the child tree")
    Process.spawn(cmd, *args, chdir: dir, in: File::NULL,
                  out: out_w, err: out_w)
  end
  # TERM first (tools can clean up), KILL after. Windows walks the tree via
  # taskkill /T; POSIX signals the own pgroup so every descendant is reached.
  def kill_process_tree(pid)
    if Gem.win_platform?
      system("taskkill", "/T", "/F", "/PID", pid.to_s,
             out: File::NULL, err: File::NULL)
    else
      Process.kill(:TERM, -pid) rescue nil
      sleep 1
      Process.kill(:KILL, -pid) rescue nil
    end
  end

  # Head + tail, middle named. A line count is not a size limit, so OutputBudget
  # also bounds the kept window in bytes. Returns [text, truncated?].
  def truncate(text, limit, bytes: output_result_bytes)
    budget = OutputBudget.fit(text, limit: bytes, limit_lines: limit)
    [budget.text + line_notice(budget), budget.truncated?]
  end

  # Names the dropped line count too; 'limit' is the knob for that half.
  def line_notice(budget)
    return "" if budget.lines_dropped.zero?

    "\n... (output truncated: #{budget.lines_dropped} line(s) omitted from the " \
      "middle - raise 'limit' or narrow the command to see them)"
  end

  def output_result_bytes
    @settings&.output_result_bytes || OutputBudget::DEFAULT_RESULT_BYTES
  end
end
