# frozen_string_literal: true

require "reline"

require_relative "harness_error"
require_relative "cli_options"
require_relative "harness"
require_relative "file_list"
require_relative "error_text"
require_relative "history_manager"
require_relative "session_locator"
require_relative "command_handler"
require_relative "prompt_reader"
require_relative "ui"

# -- CLI ------------------------------------------------------------------

class CLI
  attr_reader :options,
    :harness,
    :file_list,
    :session_id,
    :commands,
    :history,
    :ui

  # Defaults keep the entry point (`CLI.new.run`) unchanged; the tests inject
  # pre-parsed options and a stubbed UI instead.
  def initialize(options = nil, ui = nil)
    @options   = options || CLIOptions.parse

    # This console is the single sink every dialog and status line reaches (a
    # Task's drain loop renders to it, and Task.handle_request serves a dialog
    # on it). It is built BEFORE the Harness that resolves the palette, and
    # /palette + a mid-run Harness rebuild can change it, so the palette is
    # declared as a live reader (issue #388).
    @ui = ui || UI::Console.new(
      stdout: $stdout, stdin: $stdin,
      palette: -> { @harness&.output_palette })

    @file_list = build_file_list
    @locator = SessionLocator.new(@options[:workdir])

    # --list-sessions renders the saved-session list and stops: it needs no
    # Harness and no session dir (issue #276). The mode is recorded here and
    # dispatched by #run, so initialize never calls exit (issue #299).
    @listing = !!@options[:list_sessions]
    return if @listing

    setup
  end

  # The heavy construction, split out so it can be RUN AGAIN: a mid-run
  # /resume (#280) re-runs this with a resume_id and gets a FRESH Harness
  # instead of mutating the live one. Identity stays first (#276) and a
  # re-run keeps the id this run owns - it never mints a throwaway one.
  def setup(resume_id: nil)
    @session_id = if resume_id
                    @locator.resolve_id(resume: resume_id)
                  else
                    @session_id ||
                      @locator.resolve_id(resume: @options[:resume],
                                          newest: !!@options[:continue])
                  end
    resume_data = (resume_id || resumed_run?) ? @locator.read_session(session_id) : nil

    # A resumed run takes its grants from the session file onto an object of
    # its own: the tools of the run being replaced keep their own list.
    @file_list = build_file_list if resume_id

    replaced = @harness
    @harness  = Harness.new(@options, @file_list,
                            session_id:, resume_data:)
    @history  = HistoryManager.new(@file_list.workdir, session_id:)
    @harness.history = @history

    @commands = CommandHandler.new(
      harness: @harness,
      file_list: @file_list,
      options: @options,
      ui: @ui,
      on_resume: ->(id) { setup(resume_id: id) })

    if resume_id
      @harness.logger.info "session resumed: #{session_id}"
      replaced&.logger&.close

      # issue #48: the run being replaced owns its own MCP subprocesses; close
      # them so a mid-run /resume does not leak the old server processes.
      replaced&.close_mcp
    end
    @harness
  end

  # Render the saved-session list (used by --list-sessions) and return the
  # exit status. issue #276: listing is path + JSON reading, so it runs
  # through the SAME renderer /sessions uses, with harness: nil - the old path
  # constructed a whole Harness (client, logger, tool registry) just to read a
  # few JSON files, minting a fresh random id on the way.
  def list_sessions
    Commands::SessionsCommand.new(
      harness: nil,
      file_list: @file_list,
      options: @options,
      ui: @ui).handle("")
    0
  end

  def run
    return list_sessions if @listing

    @history.load

    # issue #198: the double-Enter submit switch is process-global and
    # covers every UI::Editor read (idle prompt, notes, dialogs).
    UI::Editor.submit_on_enter = !!@options[:double_enter_submit]

    # issue #298: same reasoning for the external editor - the command is
    # resolved once, and every multiline read then honours Ctrl+G. nil (no flag,
    # no config key, no EDITOR/VISUAL) leaves the key exactly as Reline has it.
    UI::Editor.external_editor = @options[:editor]

    print_startup_banner

    begin
      reader = PromptReader.new(ui: @ui, harness: -> { @harness })
      loop do
        input = reader.read
        break if input.nil?

        begin
          commands.handle(input)
        rescue Interrupt
          ui.puts "\n  [interrupted]"
          @harness.logger.info "command interrupted (Ctrl+C)"
        # LLMError and ToolLoopError are subclasses of HarnessError, so they
        # MUST be rescued before it or the HarnessError branch swallows them
        # and their specific hint never prints.
        rescue LLMError => e
          @harness.logger.warn "LLM error: #{e.class.name}: #{e.message}"
          ui.puts "  [LLM error] #{e.message}"
          ui.puts "  (everything up to this point is kept in the session - type /retry"
          ui.puts "   to resume from exactly there, including tool work already done)"
        rescue ToolLoopError => e
          @harness.logger.warn "tool loop: #{e.class.name}: #{e.message}"
          ui.puts "  [tool loop] #{e.message}"
        rescue HarnessError => e
          @harness.logger.warn "command error: #{e.class.name}: #{e.message}"
          ui.puts "  [error] #{e.message}"
        rescue StandardError => e
          # A crash the harness did not expect: full backtrace to the log, the
          # same shape Task logs a raising thread with ("task thread raised").
          @harness.logger.error ErrorText.detailed(e, "unexpected error")
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
      @harness.logger.info "prompt read interrupted (Ctrl+C)"
      ui.puts "\n  [interrupted]"
    end

    # issue #48: an MCP server is a subprocess this run spawned; closing them
    # here is what stops a server outliving the CLI.
    @harness.close_mcp

    @history.save
    id = auto_save_session
    ui.puts "Goodbye."
    if id
      ui.puts "Session saved as #{id} (#{harness.session_manager.session_file_path(id)})."
      ui.puts "Resume it later with: #{commands.resume_command(id)}"
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
    ui.puts "Model: #{harness.session_manager.active_model_name} " \
            "(#{harness.session_manager.target_display} @ #{@options[:base_url]})"
    ui.puts "Working directory: #{@file_list.workdir}"

    # issue #189: show the session id at startup so the user knows WHERE
    # this session's log is written (.harness/sessions/<id>/harness.log) -
    # and which id a later /save or --resume would refer to.
    ui.puts "Session: #{harness.session.session_id} (log: #{session_log_path_display})"

    # issue #341: a rules file that is not valid UTF-8 now LOADS (with the bad
    # bytes replaced) instead of crashing the run, so the repair has to be said
    # out loud: the prompt the model got is not byte-for-byte what harness.md holds.
    if harness.rules_repair_note
      ui.puts "  [harness.md repaired: #{harness.rules_repair_note}]"
    end

    # issue #276: --resume / --continue now restore the conversation during
    # construction, so the banner is where the user learns WHICH session this
    # run is (the old separate "Resumed session ..." line came from a resume
    # call made after the Harness was already built).
    if resumed_run?
      ui.puts "  (resumed conversation and file list - see /session)"
    end

    # issue #221 review (bug 2): the shell consent posture is a fact about
    # how this run behaves, so it belongs in the startup banner next to the
    # model and the session - and the disaster floor is named with it so
    # YOLO ON is never mistaken for "nothing asks".
    ui.puts "Command consent: #{consent_posture_display}"

    # issue #303: same reasoning - which palette this run renders with is a
    # fact about the run, and /palette is the way to change it mid-session.
    ui.puts "Output palette: #{@harness.output_palette.name} (/palette <name> switches it)"

    # issue #28: same reasoning - whether this run streams responses decides
    # what the user sees while the model is writing, and /stream switches it.
    ui.puts "LLM responses: #{@harness.stream? ? 'streamed (/stream off buffers them)' \
              : 'buffered (/stream on shows each part as it arrives)'}"
    ui.puts "Tip: type a plain message (no /) to send it directly to the model."

    # issue #48: MCP servers the user declared. Each connected server and each
    # problem (a failed start, a name collision) is reported here, so the run
    # never silently pretends its MCP tools are available.
    @harness.mcp_status_notes.each do |note|
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

  # Each run owns its grant list: startup and a mid-run /resume build it the
  # same way (one expression of the empty state a session file fills in).
  def build_file_list
    FileList.new(
      [],
      workdir: @options[:workdir],
      protected_dirs: @options[:protected_dirs])
  end

  # issue #189: the log path relative to the workdir (absolute paths would
  # duplicate the Working directory line above).
  def session_log_path_display
    id = harness.session.session_id
    File.join(SessionLocator::SESSIONS_DIR, id, SessionLocator::SESSION_LOG_FILE)
  end

  # True when this startup resolved an EXISTING session (--resume / --continue,
  # issue #276): the conversation was restored during construction, so the
  # banner has to say so (there is no separate resume call left to report it).
  def resumed_run?
    !!@options[:continue] || !@options[:resume].to_s.strip.empty?
  end

  # issue #221 review (bug 2): one-line description of the shell consent
  # posture. The /yolo command's own report is the long form; this is the
  # at-a-glance version shown in the startup banner.
  def consent_posture_display
    label = @harness.command_mode_label
    return "n/a" if label.nil?

    base =
      if @harness.yolo?
        "YOLO - unapproved commands run without asking; disaster " \
          "commands still ask"
      elsif label == "AUTO-APPROVE"
        'AUTO-APPROVE - a "safe:" model verdict runs without asking'
      else
        "MANUAL - unapproved commands ask (/yolo status shows the postures)"
      end
    # issue #389: a relaxed floor is named in the banner for the same reason YOLO
    # names it - never mistake a relaxed run for a normal one.
    return base unless @harness.denylist_safe_approve?

    "#{base}; denylist + \"safe:\" also runs without asking " \
      "(command_safety_auto_approve: denylist)"
  end

  # Auto-save the session on exit (best-effort). Returns the session id,
  # or nil when there was nothing to save or saving failed.
  def auto_save_session
    return nil if @harness.session.empty?

    @harness.session_manager.save_session
  rescue StandardError => e
    @harness.logger.error ErrorText.detailed(e, "auto-save failed")
    ui.puts "  [warning] could not auto-save session: #{e.message}"
    nil
  end
end
