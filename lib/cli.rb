# frozen_string_literal: true

require "fileutils"

require "reline"

require_relative "harness_error"
require_relative "cli_options"
require_relative "harness"
require_relative "file_list"
require_relative "error_text"
require_relative "job_registry"
require_relative "system_saver"
require_relative "history_manager"
require_relative "session_locator"
require_relative "command_handler"
require_relative "prompt_reader"
require_relative "ui"
require_relative "harness_factory"
require_relative "session_logger"

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :settings,
    :registry,
    :file_list,
    :session_id,
    :commands,
    :system_saver,
    :harness_factory,
    :history,
    :ui,
    :saved_jobs

  # Defaults keep the entry point (`CLI.new.run`) unchanged; the tests inject
  # pre-parsed options and a stubbed UI instead. The options hash is resolved
  # into SystemSettings here - the CLI's ONLY run-config holder - so the workdir
  # is available for the file list and the locator built below.
  def initialize(options = nil, ui = nil)
    options ||= CLIOptions.parse
    @settings = SystemSettings.from_options(options)
    # Argument modes / run-selection are the CLI's own state, NOT run config
    # shared with the Harness (#286): which session this run resumes, and the
    # list/delete actions that run without ever building a Harness. They stay
    # here in the CLI, never promoted to SystemSettings accessors.
    @resume         = options[:resume]
    @continue       = options[:continue]
    @list_sessions  = options[:list_sessions]
    @delete_session = options[:delete_session]

    # This console is the single sink every dialog and status line reaches (a
    # Task's drain loop renders to it, and the Poller serves a dialog
    # on it). It is built BEFORE the Harness that resolves the palette, and
    # /palette can change it, so the palette is declared as a live reader
    # (issue #388).
    @ui = ui || UI::Console.new(
      stdout: $stdout, stdin: $stdin,
      palette: -> { @settings.output_palette })

    @file_list = build_file_list
    @locator = SessionLocator.new(@settings.workdir)
  end

  # The run's Harness lives INSIDE the foreground job (#286): the CLI builds it,
  # attaches it to the main job, and reaches it only through that job - so a
  # background/sub-agent harness would be read the same way. nil before #setup
  # (and for --list-sessions / --delete-session, which never build a Harness).
  def foreground_harness
    @registry&.foreground_job&.harness
  end

  # Dispatch the argument-only modes (--list-sessions / --delete-session): run
  # the one that was requested and hand back its exit status, or nil when this
  # is a normal conversation run that still needs #setup.
  def process_args
    return 0 if list_sessions
    return 0 if delete_session

    nil
  end

  # The heavy construction. Identity stays first (#276): the id is resolved
  # BEFORE Harness.new, so a bad --resume id cannot leave a half-built run
  # behind. The only resume this run supports is the STARTUP one (--resume /
  # --continue), whose conversation and grants Harness#restore applies while
  # building the session. There is no mid-run rebuild.
  def setup
    return self if @setup_done

    @setup_done = true

    @session_id ||= @locator.resolve_id(
      resume: @resume,
      newest: !!@continue)
    resume_data = resumed_run? ? @locator.read_session(session_id) : nil

    # SystemSettings was resolved in #initialize (the CLI's single run-config
    # holder) and is handed to the Harness, which delegates to it. The four
    # session-persisted postures are applied over it by the Harness for a
    # resumed run (#221: the saved choice wins over the config). Ownership:
    # doc/harness_job_design.md.
    # The run record and its job list belong to the RUN, not to the single-LLM
    # turn engine (#286): the CLI owns the registry, builds it from the
    # resolved buffer limits, and registers the main turn first (job #0).
    # A resumed run seeds the record from the saved tail and restores which
    # job was foreground.
    @registry = JobRegistry.new(
      # A resumed run continues numbering past its saved jobs, so its next job
      # never reuses a job id already on disk (#548 A). A fresh run starts at 0.
      next_id: resume_data ? resume_data[:next_id].to_i : 0,
      max_memory: @settings.output_tail_memory || OutputBuffer::DEFAULT_MAX_MEMORY,
      max_saved: @settings.resume_replay_entries,
      tasks_kept: @settings.output_tasks_kept,
      settings: @settings)

    # The save side (system.json + per-job job.json + per-job replay.json) and
    # the read side of the SAME layered record belong to the SYSTEM, not the
    # single-LLM turn engine (#286 / #548): the CLI - not the Harness - builds the
    # SystemSaver from its own registry - the registry carries the system settings
    # and reaches the foreground job's own harness for the live MCP summary - so
    # a SessionManager never assembles the system file it does not own and is
    # never handed to the record writer. Built before the resume pass below,
    # which restores job state through it.
    @system_saver = SystemSaver.new(@locator, @registry)

    # The Harness lives INSIDE the main job (#286): commands reach it through
    # registry.foreground_job.harness rather than a CLI-held reference. After
    # this line every read below goes through #foreground_harness, never a
    # @harness ivar.
    # The main turn is built the SAME way a second agent will be: the factory
    # adds the job and gives it its own Harness in one step (#548), wiring the
    # job id onto its save. A run starts with no jobs, so the main add takes
    # id 0. The CLI injects the session logger (keyed by the resolved id) so
    # every job's harness shares one log (#286).
    @harness_factory = HarnessFactory.new(
      registry: @registry,
      locator: @locator,
      settings: @settings,
      file_list: @file_list,
      system_saver: @system_saver,
      logger: SessionLogger.build(@locator.session_log_path(session_id)))
    # #548: resume is the SYSTEM's work, not a foreground special case folded
    # into one flat hash. A fresh run builds the main turn (job 0) as its own
    # agent. A resumed run rebuilds EVERY job the saved system names, each at its
    # saved id and with its OWN saved conversation, and only then sets the
    # foreground - so a resumed run has the same agents it saved, and switching to
    # one of them reaches a real agent with a real chain.
    saved_fg = resume_data ? resume_data[:foreground_job] : nil
    if resume_data
      restore_jobs(resume_data, saved_fg)
    else
      @harness_factory.add_harness_job(kind: :main, session_id:, base_file_list: @file_list)
    end

    @history  = HistoryManager.new(@file_list.workdir, session_id:)
    foreground_harness.history = @history

    @commands = CommandHandler.new(
      registry: @registry,
      file_list: @file_list,
      ui: @ui,
      settings: @settings,
      system_saver: @system_saver,
      harness_factory:,
      session_id:)

    self
  end

  # Render the saved-session list (used by --list-sessions) and return the
  # exit status. issue #276: listing is path + JSON reading, so it runs
  # through the SAME renderer /sessions uses, with harness: nil - the old path
  # constructed a whole Harness (client, logger, tool registry) just to read a
  # few JSON files, minting a fresh random id on the way.
  def list_sessions
    return unless @list_sessions

    Commands::SessionsCommand.new(
      file_list: @file_list,
      ui: @ui).handle("")

    true
  end

  # Delete one saved session (--delete-session, issue #279) and return the
  # exit status. Path-only, like #list_sessions: no Harness, no session dir
  # minted. The whole session directory goes (conversation, log, history) -
  # there is no undo, which is why the flag names the id explicitly. Raises a
  # HarnessError for an unknown or ambiguous id (HarnessError is caught by the
  # entry point, which prints "Error: ..." and exits 1); find_session_file
  # already raises on an ambiguous prefix and returns nil when nothing matches.
  def delete_session
    id = @delete_session.to_s.strip
    return if id.empty?

    path = @locator.find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

    session_dir = File.dirname(path)
    FileUtils.remove_entry(session_dir)
    ui.puts "Deleted session #{File.basename(session_dir)} (#{session_dir})."

    true
  end

  def run
    status = process_args
    return status if status

    setup

    @history.load

    # issue #198: the double-Enter submit switch is process-global and
    # covers every UI::Editor read (idle prompt, notes, dialogs).
    UI::Editor.submit_on_enter = !!@settings.double_enter_submit

    # issue #298: same reasoning for the external editor - the command is
    # resolved once, and every multiline read then honours Ctrl+G. nil (no flag,
    # no config key, no EDITOR/VISUAL) leaves the key exactly as Reline has it.
    UI::Editor.external_editor = @settings.editor

    print_startup_banner

    begin
      # ONE input path for the whole run (issue #286): the idle prompt and a
      # mid-turn note are the same read, so the edit state is a state of the
      # single poll loop. The command handler drains events through it too.
      reader = PromptReader.new(ui: @ui, registry: @registry)
      @commands.input_path = reader.input_path
      @commands.input_path.target = -> { @registry.foreground_job }
      @commands.input_path.registry = -> { @registry }
      # The poll loop dispatches a "/command" submitted mid-turn through this
      # handler (doc/unified_loop_design.md).
      reader.input_path.command_handler = -> { @commands }

      loop do
        input = reader.read
        break if input.nil?

        begin
          commands.handle(input)
        rescue Interrupt
          ui.puts "\n  [interrupted]"
          foreground_harness.logger.info "command interrupted (Ctrl+C)"
        # LLMError and ToolLoopError are subclasses of HarnessError, so they
        # MUST be rescued before it or the HarnessError branch swallows them
        # and their specific hint never prints.
        rescue LLMError => e
          foreground_harness.logger.warn "LLM error: #{e.class.name}: #{e.message}"
          ui.puts "  [LLM error] #{e.message}"
          ui.puts "  (everything up to this point is kept in the session - type /retry"
          ui.puts "   to resume from exactly there, including tool work already done)"
        rescue ToolLoopError => e
          foreground_harness.logger.warn "tool loop: #{e.class.name}: #{e.message}"
          ui.puts "  [tool loop] #{e.message}"
        rescue HarnessError => e
          foreground_harness.logger.warn "command error: #{e.class.name}: #{e.message}"
          ui.puts "  [error] #{e.message}"
        rescue StandardError => e
          # A crash the harness did not expect: full backtrace to the log, the
          # same shape Task logs a raising thread with ("task thread raised").
          foreground_harness.logger.error ErrorText.detailed(e, "unexpected error")
          ui.puts "  [unexpected error] #{ErrorText.label(e)}"
          ui.puts ErrorText.backtrace(e)
          ui.puts "  (harness continues - type /exit to quit)"
        end

        break if commands.exiting?

        ui.puts
        ui.puts "-" * 40
        ui.puts
      end
    rescue Interrupt
      # Ctrl+C at the prompt (or anywhere in the loop is waiting): treat as
      # a normal exit so that history and the session are still saved.
      foreground_harness.logger.info "prompt read interrupted (Ctrl+C)"
      ui.puts "\n  [interrupted]"
    end

    # issue #48: an MCP server is a subprocess this run spawned; closing them
    # here is what stops a server outliving the CLI.
    foreground_harness.close_mcp

    # issue #548 increment 5: the exit decision asks the honest CROSS-JOB
    # question - did ANY retained job accumulate session state? - instead of
    # reading only the foreground conversation's emptiness (#188's bug). A run
    # that changed settings (e.g. /model) WITHOUT building any conversation
    # has no per-job chain to inspect, so the history entry stays the narrow
    # evidence for that settings-only case. Read it BEFORE #save, which clears it.
    settings_only_change = @history.has_pending_entries?
    @history.save
    id = auto_save_session(settings_only_change)
    ui.puts "Goodbye."
    if id
      ui.puts "Session saved as #{id} (#{foreground_harness.session_manager.session_file_path(id)})."
      ui.puts "Resume it later with: #{resume_cli_string(id)}"
    end
    0
  end

  private

  # The startup facts of the run, printed once before the prompt loop: model,
  # endpoint, workdir, session id + log path, any harness.md repair, whether a
  # session was resumed, the shell consent posture, the output palette, the
  # streaming posture, MCP status, and the input/command tips. Each line names
  # something the user cannot learn another way at a glance.
  def print_startup_banner
    ui.puts "Harness ready. Type /help for commands, /exit to quit."

    # issue #217: show WHERE calls go (API type + endpoint path + base url),
    # not just the base url - a profile switch can change the API type.
    ui.puts "Model: #{foreground_harness.session_manager.active_model_name} " \
            "(#{foreground_harness.session_manager.target_display} @ #{foreground_harness.model_config.base_url})"
    # issue #449: name the image posture, but only when the run can actually
    # receive one - MCP servers are the only source of tool-result images, so a
    # run without them has nothing to say about it. The two cases behave
    # completely differently (pixels to the model vs. a path to a file under
    # .harness/content) and nothing else at startup says which one this is.
    if Array(@settings.mcp_servers).any?
      ui.puts "Tool-result images: #{foreground_harness.vision? ? 'inlined to the model' : 'files only (no vision profile)'}"
    end
    ui.puts "Working directory: #{@file_list.workdir}"

    # issue #189: show the session id at startup so the user knows WHERE
    # this session's log is written (.harness/sessions/<id>/harness.log) -
    # and which id a later /save or --resume would refer to.
    ui.puts "Session: #{foreground_harness.session.session_id} (log: #{session_log_path_display})"

    # issue #341: a rules file that is not valid UTF-8 now LOADS (with the bad
    # bytes replaced) instead of crashing the run, so the repair has to be said
    # out loud: the prompt the model got is not byte-for-byte what harness.md holds.
    if foreground_harness.rules_repair_note
      ui.puts "  [harness.md repaired: #{foreground_harness.rules_repair_note}]"
    end

    # issue #276: --resume / --continue now restore the conversation during
    # construction, so the banner is where the user learns WHICH session this
    # run is (the old separate "Resumed session ..." line came from a resume
    # call made after the Harness was already built).
    if resumed_run?
      ui.puts "  (resumed conversation and file list - see /session)"
    end

    # issue #458: redraw the tail of what the user SAW in the previous run so
    # the last topic is visible at a glance, not just the raw conversation.
    print_resume_replay if resumed_run?

    # issue #221 review (bug 2): the shell consent posture is a fact about
    # how this run behaves, so it belongs in the startup banner next to the
    # model and the session - and the disaster floor is named with it so
    # YOLO ON is never mistaken for "nothing asks".
    ui.puts "Command consent: #{consent_posture_display}"
    # issue #384: the same reasoning for file consent. A run that asks for no
    # file inside the project must say so at startup, and name the opt-out -
    # a standing grant that is invisible reads as a run that protects nothing.
    ui.puts "File consent: #{file_access_display}"
    foreground_harness.logger.info "file consent: #{file_access_display}"

    # issue #303: same reasoning - which palette this run renders with is a
    # fact about the run, and /palette is the way to change it mid-session.
    ui.puts "Output palette: #{@settings.output_palette.name} (/palette <name> switches it)"

    # issue #28: same reasoning - whether this run streams responses decides
    # what the user sees while the model is writing, and /stream switches it.
    ui.puts "LLM responses: #{@settings.stream? ? 'streamed (/stream off buffers them)' \
              : 'buffered (/stream on shows each part as it arrives)'}"
    ui.puts "Tip: type a plain message (no /) to send it directly to the model."

    # issue #48: MCP servers the user declared. Each connected server and each
    # problem (a failed start, a name collision) is reported here, so the run
    # never silently pretends its MCP tools are available.
    foreground_harness.mcp_status_notes.each do |note|
      ui.puts "  [mcp] #{note}"
    end

    ui.puts "Tip: Enter adds a newline; paste multiline text directly. The " \
         "submit key sends the whole buffer: Ctrl+Enter (Windows console, or " \
         "to a remote host via Windows Terminal) or Alt/AltGr+Enter (Unix " \
         "terminal). See /help input for details."
    ui.puts "Tip: a line starting with ! runs a shell command locally (not sent " \
         "to the model)."
    ui.puts "Tip: a line starting with / is a command (executed immediately)."

    # issue #36 / #198 phase 1: steer a running turn instead of Ctrl+C -
    # any keypress while the model works opens the note editor (see /help).
    ui.puts "Tip: type a note while the model is working to steer it mid-turn " \
         "(Enter = newline, submit key sends the whole block as one note; " \
         "no Ctrl+C; see /help notes)."
    ui.puts
  end

  # Each run owns its grant list: a startup --resume run builds it the same way
  # as a fresh run, then Harness#restore overlays the grants the session saved.
  #
  # issue #384: the list starts with a STANDING grant on the working directory
  # (config 'grant_workdir:', default on) - every path inside the project is
  # covered for read, write and delete, so per-file consent is no longer the
  # default. The guard survives it because the guard is a NAME rule and this is
  # a path grant: .git, .harness and .env* under the workdir stay blocked, and
  # a path outside the workdir still asks. It is a real stored grant (visible
  # to /grant, saved with the session, removable mid-run with /clear), which is
  # what separates it from the YOLO posture's live coverage (issue #274).
  def build_file_list
    file_list = FileList.new(
      [],
      workdir: @settings.workdir,
      protected_dirs: @settings.protected_dirs)
    seed_standing_grant(file_list)
    file_list
  end

  # Delete is seeded as its own tier because delete is its own mode (issue #92):
  # a :rw grant would leave every file and directory delete still asking, which
  # is half of the fatigue the key exists to end.
  #
  # Seeded BEFORE the Harness restores a session, so a resumed run ends up with
  # exactly the grants its session file saved (Session#restore clears the list
  # first) - a /clear before saving is not silently undone by the resume, the
  # #105 rule that a grant must never come back from nowhere.
  def seed_standing_grant(file_list)
    return unless @settings.grant_workdir?

    workdir = file_list.workdir
    return if file_list.sensitive?(workdir)

    file_list.add_dir(workdir, :rw)
    file_list.add_dir(workdir, :d)
  end

  # issue #189: the log path relative to the workdir (absolute paths would
  # duplicate the Working directory line above).
  def session_log_path_display
    id = foreground_harness.session.session_id
    File.join(SessionLocator::SESSIONS_DIR, id, SessionLocator::SESSION_LOG_FILE)
  end

  # The command line that resumes a saved session in a NEW harness run
  # (--resume is a startup option; there is no mid-run resume command).
  def resume_cli_string(id)
    # -m names the active model PROFILE; the live name (not the original -m)
    # so a session switched with /model resumes on the profile it ended on.
    parts = ["ruby harness.rb", "-m #{foreground_harness.session_manager.active_model_name}", "--resume #{id}"]
    parts << "-d #{@file_list.workdir}" unless @file_list.workdir == Dir.pwd
    parts.join(" ")
  end

  # True when this startup resolved an EXISTING session (--resume / --continue,
  # issue #276): the conversation was restored during construction, so the
  # banner has to say so (there is no separate resume call left to report it).
  def resumed_run?
    !!@continue || !@resume.to_s.strip.empty?
  end

  # issue #458: redraw the saved OutputBuffer tail of the previous run. The
  # buffer is the record of everything that was SHOWN (the user's own lines as
  # :user entries plus the model/tool side), so replaying it through
  # UI::Renderer restores what the last topic looked like - not just the raw
  # conversation a resumed chain would otherwise show. An empty tail (a
  # session saved by an older build, or replay_entries: 0) prints nothing.
  def print_resume_replay
    tail = @registry.foreground_buffer.replay_tail
    return if tail.empty?

    renderer = UI::Renderer.new(
      palette: @settings.output_palette,
      markdown: @settings.markdown?,
      markdown_max_width: @settings.markdown_max_width)
    # The replay sits between this run's startup facts on BOTH sides, so a
    # block-width rule on each side (the same width the render loop uses for a
    # block boundary, and wider than the 40-dash prompt-loop separator) keeps
    # the previous session's exchange a distinct block.
    rule = "-" * UI::Renderer::RULE_WIDTH
    ui.puts
    ui.puts rule
    ui.puts "Resumed output (the last exchange of the previous session):"
    tail.each do |entry|
      ui.puts renderer.line(type: entry.type, content: entry.content, origin: entry.origin)
    end
    ui.puts rule
    ui.puts
  end

  # A saved job whose dir is intact but has no live Job under its id was dropped
  # by the retention rule in the run that saved it (or nothing rebuilt it here).
  # Say which ids those are: a resumed run that silently has fewer jobs than the
  # session recorded reads as a broken resume, and the edges naming a dropped id
  # stay dangling on purpose (doc/session_layers_design.md, the drop rule).
  def report_dropped_jobs
    dropped = @system_saver.dropped_job_ids(session_id)
    return if dropped.empty?

    foreground_harness.logger.info "dropped job ids: #{dropped.join(', ')}"
    ui.puts "  (jobs #{dropped.join(', ')} were dropped from this session - " \
            "their output is not resumed)"
  end

  # Every saved job becomes a live job again: its own id, its own agent, its own
  # conversation (jobs/<id>/session.json) and its own shown tail (replay.json).
  # The foreground is assigned LAST, from the saved id, because no job is
  # foreground while the system is being rebuilt (doc/session_layers_design.md).
  # A job whose conversation file is gone is not rebuilt at all - the drop rule
  # removed it - and is reported rather than silently stubbed.
  def restore_jobs(resume_data, saved_fg)
    @saved_jobs = Array(resume_data[:jobs])
    @system_saver.job_restores(session_id).each do |restore|
      # A job's own saved half is its conversation plus its per-agent model and
      # param state; the SYSTEM half (identity, postures, access grants, digest
      # cache) belongs to the main turn alone - the run has ONE grant state and
      # one log, and the main turn is the job the run already holds them on
      # (@file_list). A saved job is rebuilt at its saved id so it matches the
      # jobs/<id>/ dir its files live under.
      main_turn = restore[:id].zero?
      resume    = main_turn ? resume_data.merge(restore[:session]) : restore[:session]
      job       = @harness_factory.add_harness_job(
        kind: restore[:kind].to_sym,
        session_id:,
        resume_data: resume,
        base_file_list: main_turn ? @file_list : nil,
        id: restore[:id])
      job.restore_status(restore[:status])
    end

    # A #207 flat session has no jobs/ tree, so the per-job read yields nothing
    # and its inline conversation is the whole run: rebuild the main turn from it.
    if @registry.jobs.empty?
      @harness_factory.add_harness_job(
        kind: :main, session_id:, resume_data:, base_file_list: @file_list)
      @registry.restore_replay_tail(resume_data[:replay_tail])
      return report_dropped_jobs
    end

    @registry.foreground = saved_fg if @registry.job(saved_fg)
    @registry.restore_replay_tail(@system_saver.replay_tail_of(session_id, @registry.foreground))
    foreground_harness.logger.info "jobs restored: #{@registry.jobs.map(&:id).join(', ')} " \
                                   "(foreground ##{@registry.foreground})"
    report_dropped_jobs
  end

  # issue #221 review (bug 2): one-line description of the shell consent
  # posture. The /yolo command's own report is the long form; this is the
  # at-a-glance version shown in the startup banner.
  def consent_posture_display
    label = @settings.command_mode_label
    return "n/a" if label.nil?

    base =
      if @settings.yolo?
        "YOLO - unapproved commands run without asking; disaster " \
          "commands still ask"
      elsif label == "AUTO-APPROVE"
        'AUTO-APPROVE - a "safe:" model verdict runs without asking'
      else
        "MANUAL - unapproved commands ask (/yolo status shows the postures)"
      end
    # issue #389: a relaxed floor is named in the banner for the same reason YOLO
    # names it - never mistake a relaxed run for a normal one.
    return base unless @settings.denylist_safe_approve?

    "#{base}; denylist + \"safe:\" also runs without asking " \
      "(command_safety_auto_approve: denylist)"
  end

  # issue #384: the run's starting file consent, in the same at-a-glance form
  # as #consent_posture_display. Both branches name what STILL asks, because
  # "no dialogs for your files" is a claim a user must be able to audit.
  def file_access_display
    unless @settings.grant_workdir?
      return "per-path consent - every file and directory asks " \
             "(grant_workdir: false)"
    end

    "standing grant on #{@file_list.workdir} - read, write and delete inside " \
      "the project run without asking (.git/.harness/.env* and any path " \
      "outside it still ask; /clear removes the grant, /grant shows it)"
  end

  # Auto-save the session on exit (best-effort). Returns the session id,
  # or nil when there was nothing to save or saving failed.
  # issue #548 increment 5: the primary test is the cross-job predicate - does
  # ANY retained job own session state? - not the foreground chain alone.
  # settings_only_change keeps the #188 case (a settings change with no
  # conversation ANYWHERE): no per-job chain exists to inspect, so a fresh
  # history entry is the only evidence such a run is worth saving.
  def auto_save_session(settings_only_change = false)
    return nil unless @registry.any_job_has_session_state? || settings_only_change

    # The SystemSaver (the system's owner-built object) writes every job's own
    # conversation plus system.json + per-job replay.json in one call (issue
    # #548 increment 4b, moved out of the CLI). At exit every job thread is
    # joined (registry.run awaits :done, Task.stop joins), so each chain is
    # quiescent and main may read it.
    @system_saver.save_run(session_id)
  rescue StandardError => e
    foreground_harness.logger.error ErrorText.detailed(e, "auto-save failed")
    ui.puts "  [warning] could not auto-save session: #{e.message}"
    nil
  end
end
