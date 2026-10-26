# frozen_string_literal: true

require "bundler"

require_relative "tool"
require_relative "command_allowlist"
require_relative "ui/dialog"
require_relative "safety_check"
require_relative "text_normalizer"
require_relative "ui/renderer"

# Shared consent + execution logic for shell commands (issue #129).
#
# Used by both callers of this harness's shell execution:
#   * Tools::RunCommandTool - LLM-driven, runs inside a Task thread. The
#     confirmation dialog is routed through the task to the MAIN THREAD
#     (ui: nil), status lines go over the task's event queue, and the formatted result
#     string is returned to the model.
#   * CommandHandler bang syntax (`! cmd`) - user-typed, runs on the main
#     thread directly. The dialog is served in place (perform_direct on
#     the console) and the output is printed verbatim by the caller.
#
# issue #224: MODEL SELF-CHECK (advisory only, opt-in via the
# 'command_safety_check' config key). When the model requests an unapproved
# command, the harness MAY have already asked the model itself (a forked
# one-shot LLM call, one per batch - see Harness#precheck_batch_safety and
# SafetyCheck) whether the command looks safe; the verdict is shown as a
# "MODEL VERDICT (advisory):" note line in the confirmation dialog. It
# NEVER auto-approves, never widens the allowlist, and never bypasses the
# user's explicit Allow.
#
# CONSENT POSTURES (issue #221, the consent-fatigue fix): three levels of
# how much manual approval a shell command needs. The user chooses the
# posture (config initial value + the live /yolo switch); the model never
# does.
#   MANUAL        - default. Every unapproved command gets the dialog.
#   AUTO-APPROVE  - issue #224: commands the model verdicts "safe:" skip it.
#   YOLO          - /yolo: EVERY run.command call skips the dialog, no model
#                   check at all (issue #238: the check costs an extra LLM
#                   round trip and trashes the local KV cache). Every such
#                   run is status-lined and logged, so nothing is invisible.
# In ALL postures - and even for a stored allowlist grant - a command
# matching CommandAllowlist::DISASTER_PATTERNS (the well-known disasters:
# rm -rf, format C:, sudo, forced push, curl|sh, ...) is refused
# auto-approval and always reaches the dialog for a one-off explicit Allow.
# The denylist is the floor under every posture.
#
# The ONE exception is the owner's own denylist-safe override (issue #389), armed
# by the config key command_safety_auto_approve: denylist: a real model "safe:"
# verdict may auto-approve a DENYLISTED match on the tool path. It fires only on
# a "safe:" verdict and every override is logged. Design + the quote-hole
# measurement: doc/denylist_safe_approve_design.md.
#
# SAFETY MODEL:
#   - The FULL command string is displayed to the user before anything runs;
#     explicit "Allow" required unless the prefix is in the list.
#   - "Always allow <prefix>" saves a grant (issue #69, multi-select
#     per-prefix issue #102). The list is SEPARATE per caller (issue #129):
#     the tool writes .harness/allowed_commands.yml, bang syntax writes
#     .harness/shell_commands.yml - one never auto-approves for the other.
#   - Commands run under a timeout (default 60 s, cap 300 s) so a hung
#     process can never block the session indefinitely (issue #202).
#     The child runs in its OWN process group; on timeout the whole tree is
#     killed (taskkill /T on Windows, SIGKILL to the pgroup elsewhere), so a
#     hung command can never hold the harness' streams open again.
#   - Output is truncated to a line limit (default 200, max 5000); that
#     limit exists because the tool path returns output into the LLM
#     context window - the bang path prints it as-is.
class CommandRunner
  DEFAULT_TIMEOUT = 60    # seconds
  MAX_TIMEOUT     = 300   # hard cap
  DEFAULT_LIMIT   = 200   # output lines
  MAX_LIMIT       = 5000  # hard cap
  # Tokens the outcome line keeps as the command's handle once some earlier
  # line (an auto-approval line, or the denylist refusal line) has already
  # printed the full command.
  HANDLE_TOKENS   = 4
  # Spawn flag that puts the child in its own (process) group so the
  # timeout kill reaches the whole tree. The spelling is platform- and
  # Ruby-version-dependent: :new_pgroup on Windows, :pgroup on POSIX
  # (same effect: pgid == pid). See spawn_in_group.
  PGROUP_SPAWN_KEY = Gem.win_platform? ? :new_pgroup : :pgroup
  # Grace period after the kill before giving up on the wait: by then the
  # whole tree is gone (or nearly), so the subsequent wait cannot hang.
  KILL_GRACE_SECONDS = 5

  TOOL_TITLE = "The model is requesting to run a shell command:\n" \
               "$ %s\ncwd: %s (timeout: %ss)"
  BANG_TITLE = "Run shell command:\n$ %s\ncwd: %s (timeout: %ss)"

  # Which allowlist file this runner consults and writes.
  LISTS = { tool: CommandAllowlist::TOOL_FILENAME,
            shell: CommandAllowlist::SHELL_FILENAME }.freeze

  # Shown as a dialog note when no "Always allow" option is offered because
  # the command contains constructs that can never be auto-approved.
  # Normally replaced by a tailored note naming the specific unsafe
  # construct (issue #102).
  UNSAFETY_NOTE = "UNSAFE: contains shell constructs that cannot be auto-approved."

  # label:     bracket used in status lines ('run.command' or 'shell')
  # title_fmt: sprintf-style dialog title (TOOL_TITLE / BANG_TITLE)
  # ui:        UI::Console for direct main-thread dialogs (nil = Task thread)
  # list:      :tool (default) or :shell - selects the allowlist file
  # force_confirm: true keeps the consent dialog even for a command whose
  #   prefix is already allowlisted. Used by the `!` bang path while bang
  #   confirmation is ON (options[:bang_requires_confirmation], the default
  #   - issue #221). Setting that config key to false passes force_confirm:
  #   false here, so a command the USER typed runs without a dialog (the
  #   disaster denylist still applies: a user-typed rm -rf / is asked for).
  # auto_approve_all: true skips the consent dialog for EVERY command of
  #   this caller (the `!` bang path when the user turned bang confirmation
  #   off, issue #221). The YOLO posture (Harness#yolo?, /yolo) is the same
  #   idea for the model-driven tool path and is read live from the harness
  #   instead of being passed here - see auto_approve_all?. In both cases
  #   the disaster denylist still forces the dialog.
  # harness:   optional Harness (any object with a lazy #logger accessor):
  #            when given, FAILED commands are logged to the session's
  #            harness.log so they leave a trace (issue #185). nil in specs.
  def initialize(file_list, options, label: "run.command", title_fmt: TOOL_TITLE,
                 ui: nil, list: :tool, harness: nil, auto_approve_all: false)
    @file_list = file_list
    @options   = options
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
    # issue #257: the command is model-supplied text that can carry bytes
    # invalid in UTF-8, which makes strip (and the tokenizer) raise.
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

    # DENYLIST FLOOR (issue #221): a well-known disaster command is refused
    # by EVERY auto-approval path - a stored prefix grant, the AUTO-APPROVE
    # model verdict and YOLO alike. It always reaches the dialog below and
    # can only run through an explicit one-off "Allow" (never a standing
    # grant: the "Always allow" options are dropped for it too). Checked
    # FIRST so no later shortcut can skip it.
    disaster = CommandAllowlist.disaster?(command)
    full_shown = false
    # safety_verdict_for is ONE-SHOT for a batch verdict (it deletes the cache
    # entry on first read), so a verdict the override attempt below consumed must
    # not be fetched again: the advisory note would be lost AND a single-command
    # check would pay for a second forked LLM call.
    verdict = nil
    verdict_computed = false

    if disaster
      # DENYLIST-SAFE OVERRIDE (issue #389): a model "safe:" verdict may decide
      # even a denylist match - but ONLY on the tool path (the bang path is
      # consented by the human's typing) and ONLY on a real "safe:" verdict, so a
      # "dangerous:"/missing verdict keeps the floor and disaster? DETECTION is
      # never weakened. Design + the quote-hole measurement:
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
      @harness&.logger&.warn("denylisted command needs an explicit Allow: #{command}")
      # The refusal line above printed the full command BEFORE the dialog, so
      # this run counts as already named, like an auto-approved one.
      full_shown = true
    elsif @allowlist.allowed?(command)
      # Auto-approve when the command prefix is in the user's allowlist.
      status(:ok, "auto-approved (allowlist): #{command}")
      return execute(command, dir, shown, timeout, limit, full_shown: true)
    elsif auto_approve_all?
      # YOLO POSTURE (issue #221) / bang consent off (@auto_approve_all): the
      # command runs with no dialog and deliberately NO model safety check
      # (issue #238). The status line + harness.log entry keep it auditable.
      reason = yolo_active? ? "YOLO" : "bang consent off"
      status(:ok, "auto-approved (#{reason}): #{command}")
      log_auto_approved(command, reason)
      return execute(command, dir, shown, timeout, limit, full_shown: true)
    end

    # issue #224: consume a pre-batched verdict when the harness ran one
    # for this command, otherwise (single run.command call) run the check
    # here. Advisory text only - consent proceeds exactly as before. A disaster
    # command whose verdict the override already consumed is skipped so the note
    # reuses it instead of refetching (verdict_computed).
    verdict = safety_verdict_for(command) unless verdict_computed

    # issue #224 follow-up: AUTO-APPROVE MODE. When the mode is on (and
    # the safety check produced a verdict), a command the model calls
    # "safe:" runs WITHOUT the consent dialog. Anything else - a
    # "dangerous:" verdict, or no verdict at all - still gets the dialog,
    # so the model's own check is what decides. This never touches the
    # allowlist (it is a per-run consent posture, not a stored grant).
    # The denylist wins over the model's opinion (issue #221): a disaster
    # command is never auto-approved just because the model called it safe.
    if !disaster && auto_approve_mode? && verdict
      if auto_approve_safe?(verdict)
        status(:ok, "auto-approved (model verdict: safe): #{command}")
        return execute(command, dir, shown, timeout, limit, full_shown: true)
      end
      # dangerous -> fall through to the dialog with the verdict note.
    end

    # Not in allowlist - ask the user. One "Always allow" option per
    # candidate prefix length of each segment (issue #102); candidates
    # already subsumed by a stored grant are filtered out up front so
    # the dialog only shows prefixes that would actually change
    # behaviour when saved (issue #94).
    all_candidates = CommandAllowlist.extract_prefix_options(command)
    # A denylisted command gets NO "Always allow" option: the dialog is a
    # one-off decision about this exact invocation, not a standing grant.
    prefixes       = disaster ? [] : @allowlist.filter_uncovered(all_candidates)
    options        = [UI::Dialog::Option.new(title: "Allow", value: :allow)]

    prefixes.each do |p|
      options << UI::Dialog::Option.new(
        title: "Always allow '#{p}'",
        # Unique per prefix so a multi-select answer maps back to the
        # exact prefixes chosen (issue #102).
        value: { always_allow: p }
      )
    end

    # UNSAFETY_NOTE only when the command itself contains unsafe
    # constructs (all_candidates empty). If candidates existed but were
    # all filtered out because a stored grant already covers them, the
    # command is fine - no scary note. When unsafe, name the specific
    # construct instead of a generic list (issue #102).
    if all_candidates.empty?
      label = CommandAllowlist.classify_unsafe(command)
      note  = label ? "UNSAFE: #{label} cannot be auto-approved" : UNSAFETY_NOTE
    end

    # DENYLIST note (issue #221) wins over the UNSAFETY line: the reason
    # this one asks even in YOLO / AUTO-APPROVE / with a stored grant is the
    # command itself, so name the matched construct.
    if disaster
      note = "DENYLISTED: #{CommandAllowlist.disaster_label(command)} - " \
             "well-known disaster, auto-approval refused in every posture; " \
             "this Allow is one-off"
    end

    # issue #224: the model's own safety verdict (advisory) leads the note
    # so it is seen first; the deterministic UNSAFETY line (when present)
    # is kept after it. No verdict -> note unchanged.
    note = verdict ? prepend_safety_verdict(note, verdict) : note

    dialog = UI::Dialog.new(
      title: format(@title_fmt, command, shown, timeout),
      options:,
      note:,
      # Multi-select lets the user save several prefixes in one line
      # (e.g. "2 4") - issue #102. Only meaningful when there is at
      # least one grantable prefix.
      multi_select: !prefixes.empty?
    )
    # Route the dialog: within a Task thread use show(ui: nil) so the
    # drain loop services it on the main thread (issue #40); on the
    # main thread (bang syntax) serve it in place on the console.
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

  # Status line for this caller's label ("run.command" / "shell"). Within a
  # Task thread it goes onto the event queue; on the main thread the runner
  # renders the SAME UI::Renderer pattern itself, so a bang command looks like
  # a tool one.
  def status(verdict, msg)
    if defined?(Task) && Task.current
      Tool.push_status(label: @label, verdict:, message: msg)
    elsif @ui
      type = Tool.status_type(verdict)
      @ui.puts(renderer.line(type:, content: msg, origin: @label))
    end
  end

  # NOT memoized: the main thread has no turn boundary, so the palette is
  # re-read per line and a /palette switch shows up in the next bang command.
  def renderer
    palette = @harness.respond_to?(:output_palette) ? @harness.output_palette : nil
    UI::Renderer.new(palette:)
  end

  # Interpret the raw dialog answer. Returns a hash with :denied and
  # :denial (the error string to return) when the user cancelled, and
  # :saved (array of prefixes to persist) when one or more "Always
  # allow" options were picked. A bare :allow - including one mixed
  # into a multi-select line, which is contradictory - runs the command
  # without saving anything.
  def handle_choice(choice)
    # A [:cancelled, 'reason'] pair means the user cancelled with a one-line reason.
    if choice.is_a?(Array) && choice.size == 2 && choice[1].is_a?(String)
      return denial("user denied executing the command", note: choice[1]) \
             if choice[0] == UI::Dialog::CANCEL_VALUE
      return {}
    end

    # Multi-select returns an array of values (e.g. [hash1, hash2]).
    # Single selection returns the bare value.
    values = choice.is_a?(Array) ? choice : [choice]
    return denial("user denied executing the command") \
           if values.include?(UI::Dialog::CANCEL_VALUE)

    # A mix of plain "Allow" with one or more grants is ambiguous: the
    # user wants to run the command now, so we honor the Allow and save
    # nothing (a bare grant selection saves those prefixes). Only
    # hash-valued options carry a prefix to persist.
    if values.include?(:allow)
      return { saved: [] }
    end

    saved = values.select { |v| v.is_a?(Hash) && v[:always_allow] }
                .map { |v| v[:always_allow] }
    { saved: }
  end

  # issue #224: the verdict for THIS command. Priority: a batch pre-check
  # verdict cached on options by the harness (Harness#precheck_batch_safety
  # removes it after first use), else a single-command check right here
  # (a lone run.command in its batch has no pre-check). Returns nil when
  # the check is disabled or produced nothing.
  def safety_verdict_for(command)
    return nil unless @options.is_a?(Hash) && @options[:command_safety_check] == true

    cached = @options[:safety_verdicts]
    if cached.is_a?(Hash)
      @options[:safety_verdicts] = cached.reject { |k, _v| k == command }
      return cached[command]
    end

    # run_safety_check returns nil on failure (degrade: plain dialog).
    verdict = run_safety_check([command])
    verdict && verdict[command]
  end

  # issue #224 follow-up: AUTO-APPROVE MODE (toggled live with Ctrl+A).
  # ON only when the harness has BOTH the safety check enabled and the
  # session's consent posture set to auto-approve (see
  # Harness#command_safety_auto_approve_effective?). No harness (specs
  # that build the runner standalone) means the mode is off, so consent
  # always proceeds via the dialog.
  def auto_approve_mode?
    @harness.respond_to?(:command_safety_auto_approve_effective?) &&
      @harness.command_safety_auto_approve_effective?
  end

  # Issue #221: does THIS caller run without a consent dialog?
  #   * the `!` bang path with bang confirmation disabled (@auto_approve_all,
  #     passed by CommandHandler from options[:bang_requires_confirmation]);
  #   * the run.command tool path while the harness YOLO posture is on.
  # The YOLO flag is re-read on EVERY command (not cached at construction)
  # so a /yolo typed at the idle prompt, or flipped by a mid-turn steering
  # note, applies to the very next command of a running tool loop too.
  def auto_approve_all?
    @auto_approve_all || yolo_active?
  end

  # The harness-side YOLO posture (Harness#yolo?), read live. A runner
  # built without a harness (unit specs) has no posture to consult, so only
  # the explicit @auto_approve_all argument can enable it there.
  # YOLO covers ONLY the model-driven tool path (user decision for issue
  # #221): the bang list is untouched by it, because there the human already
  # typed the command - its consent is controlled by the separate
  # 'bang_requires_confirmation' config key instead.
  def yolo_active?
    @list == :tool &&
      @harness.respond_to?(:yolo?) && @harness.yolo?
  end

  # Issue #221: an auto-approved-without-dialog run MUST leave a trace.
  # The status line covers the console; this covers harness.log, so every
  # command that ran under YOLO (or under bang consent off) is recoverable
  # from the session log - including the posture that let it through.
  def log_auto_approved(command, reason)
    logger = @harness&.logger
    return unless logger

    logger.info("auto-approved (#{reason}): #{command}")
  end

  # Issue #389: is the denylist-safe override armed? Unlike the YOLO posture it is
  # NOT read live - the key is a config value that never changes mid-run, so a
  # relaxed floor cannot appear or disappear inside one tool loop. Rationale:
  # doc/denylist_safe_approve_design.md.
  def denylist_safe_override?
    @options.is_a?(Hash) && @options[:command_safety_denylist_safe_approve] == true
  end

  # An override approval is the most auditable event the runner can produce: a
  # denylist match ran WITHOUT a dialog. The status line names the verdict that
  # allowed it; this line makes the same fact recoverable from harness.log, with
  # the option that armed it, so a session log can always answer "why did a
  # denylisted command run?".
  def log_denylist_override(command, verdict)
    logger = @harness&.logger
    return unless logger

    logger.warn("denylist safe-override auto-approved " \
                "(command_safety_denylist_safe_approve, verdict: #{verdict}): " \
                "#{command}")
  end

  # A verdict auto-approves when it is a non-empty line starting with
  # "safe:" - the exact shape SafetyCheck hands back (its kind is normalized,
  # and a line that is not a verdict never reaches here as a verdict at all).
  # Anything else - "dangerous:", blank, or an unexpected shape - is NOT
  # auto-approved and falls back to the consent dialog.
  def auto_approve_safe?(verdict)
    verdict.to_s.strip.match?(/\Asafe:/)
  end

  # One forked LLM call for the given commands. Returns {command =>
  # verdict-or-nil}; nil on any error (a failed check must NEVER break the
  # consent flow - the dialog just shows without a verdict).
  def run_safety_check(commands)
    # issue #224 follow-up: re-point the spinner so the wait is recognisable
    # as the model safety check (only inside a Task; the bang path runs on
    # the main thread where the dialog is served in place - no spinner).
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
    logger&.info("command safety check failed (#{e.class}: #{e.message}) - no verdict")
    nil
  end

  # The active LLM client (owned by the harness; the runner has no client
  # of its own). nil without a harness - no check possible then.
  def safety_client
    @safety_client ||= @harness&.client
  end

  # nil when the harness cannot report one - a bang runner built without a
  # harness has no tool definitions to mirror, and a missing payload is a
  # cache miss, never a wrong verdict.
  def harness_tools
    @harness.respond_to?(:tools_payload) ? @harness.tools_payload : nil
  end

  # The live conversation chain to fork from (issue #208: the session IS
  # the working chain). At dialog time it ends on the unresolved
  # assistant tool_calls - SafetyCheck#truncate_for_check drops that.
  def session_chain
    @harness&.session&.messages
  end

  # The model's own verdict as the FIRST note line (advisory label keeps
  # it distinct from the deterministic UNSAFETY line, which stays second).
  def prepend_safety_verdict(note, verdict)
    line = "MODEL VERDICT (advisory): #{verdict}"
    note ? "#{line}\n#{note}" : line
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

  # Runs the command (after any required confirmation) and formats the result.
  # A run whose full command was already printed by an earlier line (an
  # auto-approval line, or the denylist refusal line) names it by handle here;
  # a plain dialog-approved run keeps the full text, because this line is its
  # only trace.
  def execute(command, dir, shown, timeout, limit, full_shown: false)
    name = full_shown ? command_handle(command) : command
    announce_run(command)
    started = Time.now
    output, shell_status = run_in_shell(command, dir, timeout)
    # Symbol (not Process::Status) signals the timeout path.
    if shell_status == :timeout
      # The tree was already killed by run_in_shell (issue #202); nothing
      # more can hang here.
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

  # Re-points the spinner for the run itself (issue #362). Waiting on the child
  # process leaves the outbox quiet, so the drain loop animates - and the detail
  # it would otherwise replay is the LLM request that already finished, so a
  # 40-second run reads as if the model were still generating. Only the handle
  # reaches the line: the spinner draws one line and a full command does not fit
  # it. The handle's dropped-token marker is dropped HERE because the spinner
  # appends its own "..." to every message, so the line carries ONE marker.
  def announce_run(command)
    task = defined?(Task) ? Task.current : nil
    return nil unless task

    handle = command_handle(command).sub(/ \.\.\.\z/, "")
    suffix = @harness.respond_to?(:tool_wait_suffix) ? @harness.tool_wait_suffix : nil
    task.push_event(type: :spinner_detail, origin: @label,
                    content: { message: "#{@label}: #{handle}", suffix: })
  end

  # The dropped tail is marked " ...", so a handle can never be read as the
  # whole command.
  def command_handle(command)
    tokens = command.split(/\s+/)
    head   = tokens.first(HANDLE_TOKENS)
    head.join(" ") + (tokens.size > head.size ? " ..." : "")
  end

  # Builds the formatted result string. A FAILED command that produced no
  # output at all leaves only the bare "exit code:" line - exactly the
  # trace-less failure of issue #185 (e.g. a missing binary prints nothing
  # on some platforms). Name it in the result so the model sees WHY there
  # is no output, and log the full raw output to harness.log so the
  # failure is always recoverable from the log.
  def format_result(command, code, elapsed, stdout, out)
    msg = "exit code: #{code} (#{elapsed}s)\n"
    msg += "--- output ---\n#{out}\n" if out.strip != ""
    if !code.zero? && stdout.strip.empty?
      msg += "(the command produced no output - nothing to inspect)\n"
    end
    log_failure(command, "exit #{code}", stdout) unless code.zero?
    msg
  end

  # issue #185: every FAILED command (non-zero exit or timeout) gets an
  # entry in the session's harness.log with the command, its status and the
  # full UNTRUNCATED output - so a failure always leaves a trace even when
  # the returned result had none. Empty streams are labeled "(none)". No-op
  # without a harness (specs construct the runner standalone).
  def log_failure(command, why, stdout = nil)
    logger = @harness&.logger
    return unless logger

    parts = ["command: #{command}", "status: #{why}"]
    if stdout
      parts << "--- output ---\n#{stdout.strip.empty? ? '(none)' : stdout}"
    end
    logger.warn("shell command failed:\n" + parts.join("\n"))
  end

  # Runs the command in a shell with the inherited bundler env stripped
  # (Bundler.with_unbundled_env). The harness may have been started from a
  # shell polluted by ANOTHER project's bundler setup (BUNDLE_GEMFILE,
  # RUBYOPT=-rbundler/setup, GEM_HOME, ...); without this, any `bundle exec`
  # in the command would resolve against the wrong Gemfile and fail with
  # cryptic "can't find executable" errors. Stripped, `bundle exec` falls
  # back to the CWD's Gemfile - which is what callers expect.
  #
  # Result shape: [combined_output, exit_code_or_:timeout]. The child's
  # stderr is merged into stdout (2>&1) - one stream is enough for the LLM
  # context path and halves the plumbing.
  def run_in_shell(command, dir, timeout)
    Bundler.with_unbundled_env do
      read_child_in_group(command, dir, timeout)
    end
  end

  # Runs `command` in `sh -c` in its OWN process group and reads its output
  # until it exits or `timeout` seconds pass. On timeout the whole process
  # tree is killed and :timeout is returned, so this method ALWAYS returns -
  # a hung command can never block the caller (issue #202: Open3.capture3 +
  # Timeout.timeout only raised in the parent and abandoned the child, which
  # then kept the harness' stdin/stdout open forever).
  def read_child_in_group(command, dir, timeout)
    out_r, out_w = IO.pipe
    pid = spawn_in_group("sh", ["-c", command], dir, out_w)
    out_w.close

    # issue #257: the accumulator is BINARY on purpose. Pipe chunks arrive
    # tagged with Encoding.default_external (a Windows code page in practice)
    # and are often byte-invalid; appending one to a UTF-8 accumulator either
    # mutates it to BINARY (so later concatenation with the tool's own UTF-8
    # literals raises Encoding::CompatibilityError) or raises outright. A
    # fixed BINARY accumulator can never raise, and the whole result is
    # normalized once at the end so multi-byte sequences split across chunk
    # boundaries survive intact.
    output = +"".dup.force_encoding(Encoding::BINARY)
    reader = Thread.new do
      Thread.current.report_on_exception = false
      loop { output << out_r.readpartial(64 * 1024).dup.force_encoding(Encoding::BINARY) }
    rescue EOFError, IOError
      # EOF when the whole tree exits; out_r#close below unblocks a
      # read stuck because a surviving grandchild still held the pipe.
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
    # waiter has always been joined here (kill + grace join on timeout),
    # so value never blocks.
    # issue #257: the read boundary. Everything downstream (truncate, JSON
    # for the session save, the console) sees valid UTF-8 from here on.
    [TextNormalizer.normalize(output), timed_out ? :timeout : waiter.value]
  end

  # `sh -c` in its own (process) group: the spawn flag key is
  # platform/version-dependent (:new_pgroup on Windows, :pgroup on POSIX).
  # If the running Ruby rejects it (older versions), retry plain: the
  # timeout kill then reaches only the direct child - still no hang, but
  # grandchild trees would survive.
  def spawn_in_group(cmd, args, dir, out_w)
    Process.spawn(cmd, *args, chdir: dir, in: File::NULL,
                  out: out_w, err: out_w, PGROUP_SPAWN_KEY => true)
  rescue ArgumentError
    status(:warn, "process-group spawn unsupported by this Ruby; " \
                  "a timeout kill may not reach the child tree")
    Process.spawn(cmd, *args, chdir: dir, in: File::NULL,
                  out: out_w, err: out_w)
  end
  # Kills `pid` and EVERYTHING it spawned. Windows: taskkill /T /F walks the
  # tree for us (no process groups to signal). POSIX: the child was spawned
  # in its own pgroup (pgid == pid), so a group signal reaches every
  # descendant. TERM first so well-behaved tools can clean up, KILL after
  # a short grace - by timeout the command is already dead to the user,
  # but an unkillable-in-TERM zombie grandchild would otherwise keep the
  # output pipe open past the wait below.
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

  # Truncate text to `limit` lines (from the top), appending a notice with
  # the number of dropped lines. Returns [text, truncated?].
  def truncate(text, limit)
    # Plain split drops a trailing empty element from a final newline,
    # so line counts match what the user actually sees.
    lines = text.split("\n")
    return [text, false] if lines.size <= limit

    dropped = lines.size - limit
    notice  = "... (output truncated: #{dropped} more line(s) omitted - " \
              "raise 'limit' or narrow the command to see them)"
    [lines.first(limit).join("\n") + "\n" + notice, true]
  end
end
