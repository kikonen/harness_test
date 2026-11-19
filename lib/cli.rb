# frozen_string_literal: true

require "fileutils"

require "reline"

require_relative "harness_error"
require_relative "cli_options"
require_relative "harness"
require_relative "file_list"
require_relative "error_text"
require_relative "job_registry"
require_relative "history_manager"
require_relative "session_locator"
require_relative "command_handler"
require_relative "prompt_reader"
require_relative "ui"
require_relative "session_logger"

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :settings,
    :registry,
    :file_list,
    :session_id,
    :commands,
    :history,
    :ui

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

    # The log path is keyed by the session id the CLI resolved above, so the
    # CLI builds the per-session logger here and injects it (with the settings)
    # rather than letting the Harness mint its own (#286).
    logger   = SessionLogger.build(@locator.session_log_path(session_id))
    harness = Harness.new(
      @file_list,
      settings: @settings,
      session_id:,
      resume_data:,
      logger:)

    # The run record and its job list belong to the RUN, not to the single-LLM
    # turn engine (#286): the CLI owns the registry, builds it from the
    # resolved buffer limits, and registers the main turn first (job #0).
    # A resumed run seeds the record from the saved tail and restores which
    # job was foreground.
    @registry = JobRegistry.new(
      max_memory: @settings.output_tail_memory || OutputBuffer::DEFAULT_MAX_MEMORY,
      max_saved: @settings.resume_replay_entries,
      tasks_kept: @settings.output_tasks_kept)

    # The Harness lives INSIDE the main job (#286): commands reach it through
    # registry.foreground_job.harness rather than a CLI-held reference. After
    # this line every read below goes through #foreground_harness, never a
    # @harness ivar.
    @registry.add_job(kind: :main, harness:)

    if resume_data
      @registry.restore_replay_tail(resume_data[:replay_tail])
      saved_fg = resume_data[:foreground_job]
      if saved_fg
        @registry.restore_foreground(saved_fg)
        foreground_harness.logger.info "foreground job restored: ##{@registry.foreground}"
      end
    end

    # The save side records from the registry the RUN owns (#286): SessionManager
    # is built by Harness, which holds no registry, so its owner injects it.
    foreground_harness.session_manager.registry = @registry

    @history  = HistoryManager.new(@file_list.workdir, session_id:)
    foreground_harness.history = @history

    @commands = CommandHandler.new(
      registry: @registry,
      file_list: @file_list,
      ui: @ui,
      settings: @settings)

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

    # issue #188: a run that changed settings (e.g. /model) but sent no
    # prompt still has session-worthy state. The new history entry is the
    # evidence - read it BEFORE #save, which clears it.
    state_changed = @history.has_pending_entries?
    @history.save
    id = auto_save_session(state_changed)
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
    ui.puts "LLM responses: #{foreground_harness.stream? ? 'streamed (/stream off buffers them)' \
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
      palette: foreground_harness.output_palette,
      markdown: foreground_harness.markdown?,
      markdown_max_width: foreground_harness.markdown_max_width)
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

  # issue #221 review (bug 2): one-line description of the shell consent
  # posture. The /yolo command's own report is the long form; this is the
  # at-a-glance version shown in the startup banner.
  def consent_posture_display
    label = foreground_harness.command_mode_label
    return "n/a" if label.nil?

    base =
      if foreground_harness.yolo?
        "YOLO - unapproved commands run without asking; disaster " \
          "commands still ask"
      elsif label == "AUTO-APPROVE"
        'AUTO-APPROVE - a "safe:" model verdict runs without asking'
      else
        "MANUAL - unapproved commands ask (/yolo status shows the postures)"
      end
    # issue #389: a relaxed floor is named in the banner for the same reason YOLO
    # names it - never mistake a relaxed run for a normal one.
    return base unless foreground_harness.denylist_safe_approve?

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
  # state_changed: the run submitted a command but built no conversation
  # (issue #188) - settings like /model then still deserve a saved session.
  def auto_save_session(state_changed = false)
    return nil if foreground_harness.session.empty? && !state_changed

    foreground_harness.session_manager.save_session
  rescue StandardError => e
    foreground_harness.logger.error ErrorText.detailed(e, "auto-save failed")
    ui.puts "  [warning] could not auto-save session: #{e.message}"
    nil
  end
end
