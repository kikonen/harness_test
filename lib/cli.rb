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
require_relative "startup_banner"

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :settings,
    :registry,
    :file_list,
    :locator,
    :commands,
    :system_saver,
    :harness_factory,
    :history,
    :ui,
    :saved_jobs

  # Defaults keep the entry point (CLI.new.run) unchanged; tests inject pre-parsed
  # options and a stubbed UI. The options hash resolves into SystemSettings here -
  # the CLI's ONLY run-config holder - so the workdir is available below.
  def initialize(options = nil, ui = nil)
    options ||= CLIOptions.parse
    @settings = SystemSettings.from_options(options)
    # Argument modes / run-selection are the CLI's own state, not run config shared
    # with the Harness: which session this run resumes, and the list/delete actions
    # that run without ever building a Harness. They stay here, never promoted to
    # SystemSettings accessors.
    @resume         = options[:resume]
    @continue       = options[:continue]
    @list_sessions  = options[:list_sessions]
    @delete_session = options[:delete_session]

    # This console is the single sink every dialog and status line reaches. It is
    # built before the Harness that resolves the palette and /palette can change it,
    # so the palette is a live reader.
    @ui = ui || UI::Console.new(
      stdout: $stdout, stdin: $stdin,
      palette: -> { @settings.output_palette })

    @file_list = build_file_list
    # Built here so the argument-only modes below have one before any id is resolved.
    @locator = SessionLocator.new(@settings.workdir)
  end

  # The run's Harness lives inside the foreground job: the CLI builds it, attaches
  # it to the main job, and reaches it only through that job. nil before #setup (and
  # for --list-sessions / --delete-session, which never build a Harness).
  def foreground_harness
    @registry&.foreground_job&.harness
  end

  # Dispatch the argument-only modes (--list-sessions / --delete-session): run the
  # one requested and hand back its exit status, or nil when a conversation run still
  # needs #setup.
  def process_args
    return 0 if list_sessions
    return 0 if delete_session

    nil
  end

  # The heavy construction. Identity stays first: the id is resolved BEFORE
  # Harness.new, so a bad --resume id cannot leave a half-built run behind. The only
  # resume supported is the startup one, whose conversation and grants Harness#restore
  # applies while building the session. There is no mid-run rebuild.
  def setup
    return self if @setup_done

    @setup_done = true

    @locator.session_id = @locator.resolve_id(
      resume: @resume,
      newest: !!@continue)
    resume_data = resumed_run? ? @locator.read_session : nil

    # SystemSettings (resolved in #initialize) is handed to the Harness, which
    # delegates to it. The four session-persisted postures are applied over it for a
    # resumed run (the saved choice wins over the config). Ownership: doc/harness_job_design.md.
    # The run record and its job list belong to the run, not the single-LLM turn
    # engine: the CLI owns the registry, builds it from the resolved buffer limits,
    # and registers the main turn first (job #0). A resumed run seeds from the saved
    # tail and restores which job was foreground.
    @registry = JobRegistry.new(
      # A resumed run continues numbering past its saved jobs so its next job never
      # reuses a job id already on disk. A fresh run starts at 0.
      next_id: resume_data ? resume_data[:next_id].to_i : 0,
      max_memory: @settings.output_tail_memory || OutputBuffer::DEFAULT_MAX_MEMORY,
      max_saved: @settings.resume_replay_entries,
      tasks_kept: @settings.output_tasks_kept,
      settings: @settings)

    # The save side (system.json + per-job job.json + replay.json) and the read side
    # of the same layered record belong to the system, not the turn engine: the CLI -
    # not the Harness - builds the SystemSaver from its own registry, so a
    # SessionManager never assembles the system file it does not own. Built before
    # the resume pass below, which restores job state through it.
    @system_saver = SystemSaver.new(@locator, @registry)

    # The Harness lives inside the main job: commands reach it through
    # registry.foreground_job.harness, never a @harness ivar. The main turn is built
    # the same way a second agent will be: the factory adds the job and gives it its
    # own Harness in one step. A run starts with no jobs, so the main add takes id 0.
    # The CLI injects the session logger (keyed by the resolved id) so every job's
    # harness shares one log.
    @harness_factory = HarnessFactory.new(
      registry: @registry,
      locator: @locator,
      settings: @settings,
      file_list: @file_list,
      system_saver: @system_saver,
      logger: SessionLogger.build(@locator.session_log_path))
    # Resume is the system's work, not a foreground special case. A fresh run builds
    # the main turn (job 0) as its own agent. A resumed run rebuilds every job the
    # saved system names, each at its saved id with its own conversation, and only
    # then sets the foreground - so switching to a job reaches a real agent/chain.
    saved_fg = resume_data ? resume_data[:foreground_job] : nil
    if resume_data
      restore_jobs(resume_data, saved_fg)
    else
      @harness_factory.add_harness_job(kind: :main, base_file_list: @file_list)
    end

    @history  = HistoryManager.new(@file_list.workdir, session_id: @locator.session_id)
    foreground_harness.history = @history

    @commands = CommandHandler.new(
      registry: @registry,
      file_list: @file_list,
      ui: @ui,
      settings: @settings,
      system_saver: @system_saver,
      harness_factory:,
      locator: @locator)

    self
  end

  # Render the saved-session list (--list-sessions) and return the exit status.
  # Listing is path + JSON reading, so it uses the same renderer /sessions uses, with
  # harness: nil - the old path built a whole Harness just to read a few JSON files.
  def list_sessions
    return unless @list_sessions

    Commands::SessionsCommand.new(
      file_list: @file_list,
      ui: @ui).handle("")

    true
  end

  # Delete one saved session (--delete-session) and return the exit status.
  # Path-only, like #list_sessions: no Harness, no session dir minted. The whole
  # session directory goes - no undo, hence the flag names the id explicitly. Raises
  # HarnessError for an unknown or ambiguous id; find_session_file already raises on
  # an ambiguous prefix and returns nil for no match.
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

    # The double-Enter submit switch is process-global and covers every UI::Editor read.
    UI::Editor.submit_on_enter = !!@settings.double_enter_submit

    # The external editor command is resolved once, and every multiline read then
    # honours Ctrl+G. nil (no flag/key/EDITOR) leaves the key as Reline has it.
    UI::Editor.external_editor = @settings.editor

    # The previous exchange is drawn before this run's own facts (issue #553) so the
    # banner reads as one contiguous block; StartupBanner owns that ordering.
    startup_banner.print

    begin
      # ONE input path for the whole run: the idle prompt and a mid-turn note are the
      # same read, so edit state is a state of the single poll loop, which the command
      # handler also drains events through.
      reader = PromptReader.new(ui: @ui, registry: @registry)
      @commands.input_path = reader.input_path
      @commands.input_path.target = -> { @registry.foreground_job }
      @commands.input_path.registry = -> { @registry }
      # The poll loop dispatches a "/command" submitted mid-turn through this handler.
      reader.input_path.command_handler = -> { @commands }

      loop do
        input = reader.read
        break if input.nil?

        begin
          commands.handle(input)
        rescue Interrupt
          ui.puts "\n  [interrupted]"
          foreground_harness.logger.info "command interrupted (Ctrl+C)"
        # LLMError and ToolLoopError subclass HarnessError, so they MUST be rescued
        # before it or the HarnessError branch swallows them and their hint never prints.
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
          # A crash the harness did not expect: full backtrace to the log.
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
      # Ctrl+C at the prompt: treat as a normal exit so history and the session save.
      foreground_harness.logger.info "prompt read interrupted (Ctrl+C)"
      ui.puts "\n  [interrupted]"
    end

    # An MCP server is a subprocess this run spawned; closing them stops a server
    # outliving the CLI.
    foreground_harness.close_mcp

    # The exit decision asks the cross-job question - did ANY retained job accumulate
    # session state? - not just the foreground's emptiness. A run that only changed
    # settings has no per-job chain to inspect, so history stays the evidence for that
    # case. Read it BEFORE #save, which clears it.
    settings_only_change = @history.has_pending_entries?
    @history.save
    id = auto_save_session(settings_only_change)
    ui.puts "Goodbye."
    if id
      ui.puts "Session saved as #{id} (#{@locator.relative_path(@locator.system_file_path)})."
      ui.puts "Resume it later with: #{resume_cli_string(id)}"
    end
    0
  end

  private

  # The run's startup display object, built after #setup so the foreground Harness
  # it reads exists. The replay-before-banner ordering lives in StartupBanner.
  def startup_banner
    StartupBanner.new(
      ui: @ui, settings: @settings, file_list: @file_list,
      harness: foreground_harness, registry: @registry, resumed: resumed_run?,
      locator: @locator)
  end

  # Each run owns its grant list: a startup --resume run builds it the same way as a
  # fresh run, then Harness#restore overlays the grants the session saved. The list
  # starts with a standing grant on the working directory (config grant_workdir:,
  # default on): every path inside the project is covered for read/write/delete. The
  # guard survives it because the guard is a NAME rule and this is a path grant: .git,
  # .harness and .env* under the workdir stay blocked, a path outside still asks. It
  # is a real stored grant (visible to /grant, saved with the session, removable with
  # /clear), unlike the YOLO posture's live coverage.
  def build_file_list
    file_list = FileList.new(
      [],
      workdir: @settings.workdir,
      protected_dirs: @settings.protected_dirs)
    seed_standing_grant(file_list)
    file_list
  end

  # Delete is seeded as its own tier because delete is its own mode: a :rw grant would
  # leave every file and directory delete still asking. Seeded before the Harness
  # restores a session, so a resumed run ends with exactly the grants its session file
  # saved (Session#restore clears the list first) - a /clear before saving is not
  # silently undone by the resume.
  def seed_standing_grant(file_list)
    return unless @settings.grant_workdir?

    workdir = file_list.workdir
    return if file_list.sensitive?(workdir)

    file_list.add_dir(workdir, :rw)
    file_list.add_dir(workdir, :d)
  end

  # The command line that resumes a saved session in a new run (no mid-run resume command).
  def resume_cli_string(id)
    # No -m: a resumed run restores the session's OWN model profile, so naming one
    # here would let the printed line contradict the session it names.
    parts = ["bin/harness", "--resume #{id}"]
    parts << "-d #{@file_list.workdir}" unless @file_list.workdir == Dir.pwd
    parts.join(" ")
  end

  # True when this startup resolved an existing session (--resume / --continue): the
  # conversation was restored during construction, so the banner has to say so.
  def resumed_run?
    !!@continue || !@resume.to_s.strip.empty?
  end

  # A saved job whose dir is intact but has no live Job under its id was dropped by the
  # retention rule (or nothing rebuilt it here). Name those ids: a resumed run silently
  # having fewer jobs reads as broken (doc/session_layers_design.md, the drop rule).
  def report_dropped_jobs
    dropped = @system_saver.dropped_job_ids
    return if dropped.empty?

    foreground_harness.logger.info "dropped job ids: #{dropped.join(', ')}"
    ui.puts "  (jobs #{dropped.join(', ')} were dropped from this session - " \
            "their output is not resumed)"
  end

  # Every saved job becomes a live job again: its own id, agent, conversation
  # (jobs/<id>/session.json) and shown tail (replay.json). The foreground is assigned
  # LAST, from the saved id, because no job is foreground while the system is rebuilt.
  # A job whose conversation file is gone is not rebuilt - the drop rule removed it -
  # and is reported rather than silently stubbed.
  def restore_jobs(resume_data, saved_fg)
    @saved_jobs = Array(resume_data[:jobs])
    @system_saver.job_restores.each do |restore|
      # A job's own saved half is its conversation plus its per-agent model/param state;
      # the system half (identity, postures, grants, digest cache) belongs to the main
      # turn alone - the run has ONE grant state and log, on the job it already holds
      # them on (@file_list). A saved job is rebuilt at its saved id so it matches the
      # jobs/<id>/ dir its files live under.
      main_turn = restore[:id].zero?
      resume    = main_turn ? resume_data.merge(restore[:session]) : restore[:session]
      job       = @harness_factory.add_harness_job(
        kind: restore[:kind].to_sym,
        resume_data: resume,
        base_file_list: main_turn ? @file_list : nil,
        id: restore[:id])
      job.restore_status(restore[:status])
      # Seed EVERY retained job with its own shown tail, not just the foreground one: a
      # save writes what a buffer holds, so a job whose tail was never read back saves an
      # empty replay.json next save. Only the foreground tail is redrawn in the banner -
      # that is the exchange the user last saw.
      @registry.restore_replay_tail(restore[:replay_tail], job: job.id)
    end

    # A flat session has no jobs/ tree, so the per-job read yields nothing and its inline
    # conversation is the whole run: rebuild the main turn from it.
    if @registry.jobs.empty?
      @harness_factory.add_harness_job(
        kind: :main, resume_data:, base_file_list: @file_list)
      @registry.restore_replay_tail(resume_data[:replay_tail])
      return report_dropped_jobs
    end

    @registry.foreground = saved_fg if @registry.job(saved_fg)
    @registry.restore_replay_tail(@system_saver.replay_tail_of(@registry.foreground))
    foreground_harness.logger.info "jobs restored: #{@registry.jobs.map(&:id).join(', ')} " \
                                   "(foreground ##{@registry.foreground})"
    report_dropped_jobs
  end

  # Auto-save on exit (best-effort). Returns the session id, or nil when nothing to
  # save or saving failed. The primary test is the cross-job predicate - does ANY
  # retained job own session state? settings_only_change keeps the settings-only case:
  # no per-job chain exists to inspect, so a history entry is the only evidence.
  def auto_save_session(settings_only_change = false)
    return nil unless @registry.any_job_has_session_state? || settings_only_change

    # The SystemSaver (the system's owner-built object) writes every job's conversation
    # plus system.json + per-job replay.json in one call. At exit every job thread is
    # joined, so each chain is quiescent and main may read it.
    @system_saver.save_run
  rescue StandardError => e
    foreground_harness.logger.error ErrorText.detailed(e, "auto-save failed")
    ui.puts "  [warning] could not auto-save session: #{e.message}"
    nil
  end
end
