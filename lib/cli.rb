# frozen_string_literal: true

require "optparse"
require "reline"

require_relative "harness_error"
require_relative "harness_config"
require_relative "harness"
require_relative "file_list"
require_relative "history_manager"
require_relative "session_locator"
require_relative "command_handler"
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

  DEFAULT_BASE_URL = "http://localhost:11434/v1"

  # Defaults keep the entry point (`CLI.new.run`) unchanged; the tests inject
  # pre-parsed options and a stubbed UI instead.
  def initialize(options = nil, ui = nil)
    @options   = options || parse_options
    @ui        = ui || UI::Console.new(stdout: $stdout, stdin: $stdin)
    @file_list = build_file_list
    @locator = SessionLocator.new(@options[:workdir])
    list_sessions_and_exit if @options[:list_sessions]

    # issue #198 phase 3: draft of an Esc-cancelled idle-prompt read (the
    # buffer is prefilled at the next prompt instead of being dropped).
    @idle_draft = nil

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
    @commands = CommandHandler.new(harness: @harness, file_list: @file_list,
                                   options: @options, ui: @ui,
                                   on_resume: ->(id) { setup(resume_id: id) })
    if resume_id
      @harness.logger.info("session resumed: #{session_id}")
      replaced&.logger&.close
    end
    @harness
  end

  def parse_options
    opts = {}

    parser = OptionParser.new do |o|
      o.banner  = "Usage: harness.rb [options]"
      o.separator ""
      o.on("-c FILE", "--config FILE",
           "Path to the YAML config file. Lookup order: -c, $HARNESS_CONFIG, " \
           "<workdir>/.harness/config.yml, ~/.config/harness/config.yml " \
           "(issue #260). On first run the template is written to the user " \
           "home config when no config file exists yet.") do |v|
        opts[:config_path] = v
      end
      o.on("-m MODEL", "--model MODEL", "Model name (required)") { |v| opts[:model] = v }
      o.on("--system-file FILE",
           "Use this file as the system prompt (overrides config / built-in)") do |v|
        opts[:system_file] = v
      end
      o.on("-d DIR", "--workdir DIR",
           "Working directory; all file paths are relative to it") do |v|
        opts[:workdir] = v
      end
      o.on("-r ID", "--resume ID",
           "Resume a saved session by id (see /sessions)") { |v| opts[:resume] = v }
      o.on("--continue",
           "Resume the newest saved session for this workdir (issue #107). " \
           "Equivalent to --resume <id> with the most recent id.") do
        opts[:continue] = true
      end
      o.on("--list-sessions",
           "List saved sessions and exit (no model needed)") { |v| opts[:list_sessions] = v }
      o.on("--no-auto-save",
           "Disable periodic auto-save of the session at prompt boundaries " \
           "(issue #107). Overrides the config 'auto_save' key.") do
        opts[:no_auto_save] = true
      end
      o.on("-v", "--verbose",
           "Show full prompt and raw response") { |v| opts[:verbose] = v }
      o.on("-p NAME", "--palette NAME",
           "Output palette for rendered lines (issue #303): " \
           "#{UI::Palette.names.join(', ')}. 'none' is the same as --no-color.") do |v|
        opts[:output_palette] = v
      end
      o.on("--no-color",
           "Render every line in the terminal's own color (palette 'none').") do
        opts[:output_palette] = "none"
      end
      o.on("-h", "--help") { puts o; exit }
    end
    parser.parse!

    # Resolve the working directory first (config discovery depends on it).
    opts[:workdir] ||= Dir.pwd
    opts[:workdir] = File.expand_path(opts[:workdir])
    unless File.directory?(opts[:workdir])
      raise HarnessError, "working directory does not exist: #{opts[:workdir]}"
    end

    # Load the YAML config file (models, default_model, compact, system).
    # Precedence for every setting is: CLI flag > config file > built-in.
    config = HarnessConfig.load(opts[:config_path], opts[:workdir])

    # Resolve the active model profile from the config. When no models are
    # configured, -m is treated as a raw model id (backward compatible).
    profile = nil
    if config.models_configured? && !opts[:list_sessions]
      profile = config.resolve_model(opts[:model])
    end

    if profile
      opts[:base_url]         = profile[:url] || DEFAULT_BASE_URL
      opts[:model]           ||= profile[:model]
      opts[:api]              = profile[:api]
      opts[:token]            = profile[:token]
      opts[:num_ctx]          = profile[:num_ctx]
      opts[:max_tokens]       = profile[:max_tokens]
      opts[:num_predict]      = profile[:num_predict]
      opts[:reasoning_effort] = profile[:reasoning_effort]
      opts[:temperature]      = profile[:temperature]
      opts[:top_p]            = profile[:top_p]
    else
      opts[:base_url] ||= DEFAULT_BASE_URL
    end

    # Expose the configured model profiles so /models can list them and
    # /model can switch between them at runtime. The active model name is
    # tracked separately (options[:active_model]) for display and persistence.
    # It is stored as nil when the config default is active: a null value in
    # the session means "use whatever the config default is", so sessions
    # keep working even if the default model changes later.
    opts[:model_profiles] = config.models
    opts[:default_model]  = config.default_model
    explicit_model = !opts[:model].nil? && !opts[:model].to_s.strip.empty?
    default_key    = config.default_model
    using_default  = profile && !explicit_model && (default_key.nil? || (profile[:name] == default_key || profile[:model] == default_key))
    opts[:active_model]   = using_default ? nil : (profile ? (profile[:name] || profile[:model]) : opts[:model])

    # System prompt file: --system-file > config system_prompt_file >
    # built-in default (config/system_prompt.txt). issue #223: the config
    # references a FILE, it does not embed the prompt text in YAML.
    # The file is read on demand by Harness#build_system_prompt so a
    # /reload after editing it takes effect without a restart.
    opts[:system_file] ||= config.system_prompt_file

    # issue #224: opt-in model self-check for unapproved shell commands
    # (advisory verdict in the consent dialog; never auto-approves).
    opts[:command_safety_check] = config.command_safety_check_enabled

    # issue #224 follow-up: initial command consent posture for the safety
    # check (MANUAL / AUTO-APPROVE; toggled live with Ctrl+A during a run).
    # Only effective with command_safety_check on.
    opts[:command_safety_auto_approve] = config.command_safety_auto_approve_enabled

    # issue #221: initial YOLO posture (shell consent OFF for run.command)
    # and whether the `!` bang syntax keeps its confirmation. Both default
    # to the conservative value (YOLO off, bang confirmation on).
    opts[:yolo] = config.yolo_enabled?
    opts[:bang_requires_confirmation] = config.bang_requires_confirmation?

    opts[:compact_recent]   ||= config.compact_recent_messages
    opts[:compact_auto_threshold] = config.compact_auto_threshold
    opts[:compact_max_size] = config.compact_max_size
    opts[:compact_reserved] = config.compact_reserved_tokens

    # issue #107: auto-save at every prompt boundary. Default true; the
    # --no-auto-save flag or config 'auto_save: false' disables it.
    opts[:auto_save] = !opts[:no_auto_save] && config.auto_save_enabled

    # Retry settings come from the config file (retry: count/delay).
    # Missing values fall back to the built-in defaults in harness.rb.
    opts[:retry_count] = config.retry_count
    opts[:retry_delay] = config.retry_delay

    # issue #226: max tool-loop iterations for a turn (config key).
    # nil here lets Harness fall back to its built-in default.
    opts[:max_tool_iterations] = config.max_tool_iterations

    # issue #303: rendered-output palette. CLI flag > config > default palette.
    # Validated HERE rather than when the Harness builds the palette, so a typo
    # is reported before the model is contacted (and --list-sessions, which
    # never builds a Harness, validates too).
    opts[:output_palette] ||= config.output_palette_name
    UI::Palette.validate!(opts[:output_palette]) unless opts[:output_palette].nil?

    # issue #198: opt-in double-Enter submit for the multiline editor
    # (remote setups where no submit key reaches the terminal). Applied
    # to the shared UI::Editor switch so idle prompt AND mid-turn notes
    # honour it. Default off - Enter always inserts a newline.
    opts[:double_enter_submit] = config.double_enter_submit_enabled

    unless opts[:model] || opts[:list_sessions]
      raise HarnessError, "-m / --model is required (or set default_model in the config)"
    end

    opts
  end

  # List saved sessions and exit (used by --list-sessions).
  # issue #276: listing is path + JSON reading, so it runs through the SAME
  # renderer /sessions uses, with harness: nil - the old path constructed a
  # whole Harness (client, logger, tool registry) just to read a few JSON
  # files, minting a fresh random id on the way.
  def list_sessions_and_exit
    Commands::SessionsCommand.new(harness: nil, file_list: @file_list,
                                  options: @options, ui: @ui).handle("")
    exit 0
  end

  def run
    @history.load

    # issue #198: the double-Enter submit switch is process-global and
    # covers every UI::Editor read (idle prompt, notes, dialogs).
    UI::Editor.submit_on_enter = !!@options[:double_enter_submit]

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
    ui.puts "Tip: type a plain message (no /) to send it directly to the model."
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

    begin
      loop do
        input = get_command
        break if input.nil?

        begin
          commands.handle(input)
        rescue Interrupt
          ui.puts "\n  [interrupted]"
        rescue HarnessError => e
          ui.puts "  [error] #{e.message}"
        rescue LLMError => e
          ui.puts "  [LLM error] #{e.message}"
          ui.puts "  (everything up to this point is kept in the session - type /retry"
          ui.puts "   to resume from exactly there, including tool work already done)"
        rescue ToolLoopError => e
          ui.puts "  [tool loop] #{e.message}"
        rescue StandardError => e
          ui.puts "  [unexpected error] #{e.class}: #{e.message}"
          ui.puts e.backtrace.join("\n")
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
      ui.puts "\n  [interrupted]"
    end

    @history.save
    id = auto_save_session
    ui.puts "Goodbye."
    if id
      ui.puts "Session saved as #{id} (#{harness.session_manager.session_file_path(id)})."
      ui.puts "Resume it later with: #{commands.resume_command(id)}"
    end
  end

  private

  # Each run owns its grant list: startup and a mid-run /resume build it the
  # same way (one expression of the empty state a session file fills in).
  def build_file_list
    FileList.new([], workdir: @options[:workdir])
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
    return "YOLO - unapproved commands run without asking; disaster " \
           "commands still ask" if @harness.yolo?

    label == "AUTO-APPROVE" \
      ? 'AUTO-APPROVE - a "safe:" model verdict runs without asking' \
      : "MANUAL - unapproved commands ask (/yolo status shows the postures)"
  end

  # Auto-save the session on exit (best-effort). Returns the session id,
  # or nil when there was nothing to save or saving failed.
  def auto_save_session
    return nil if @harness.session.empty?

    @harness.session_manager.save_session
  rescue StandardError => e
    ui.puts "  [warning] could not auto-save session: #{e.message}"
    nil
  end

  # Reads a full command from stdin through UI::Editor (issue #198 phase 3:
  # the idle prompt is the editor's third user, sharing ONE code path with
  # steering notes and dialog choice lines). On a tty that is Reline
  # multiline mode; on a pipe (specs) it is a plain line read (a pipe has no
  # submit key, so one line per read).
  #
  # Key model (robust base - no paste heuristics, no backslash continuation):
  #   Enter      inserts a newline (typed or pasted - always a real newline)
  #   submit key SUBMITS the whole buffer (Reline's ed_force_submit on the
  #              [27,13] binding, bound by UI::Editor.install_esc!):
  #              Ctrl+Enter / Shift+Enter on Windows, Alt+Enter on most Unix
  #              terminals, CSI 13 from kcm/kitty-protocol terminals such as
  #              a remote host seen through Windows Terminal (see doc/
  #              reline_cursor_and_enter_handling.md)
  #   Esc        cancels the read; the buffer is kept as a DRAFT and prefilled
  #              at the next prompt (instead of being dropped as before)
  #   Ctrl+C     raises Interrupt (rescued in the run loop); the draft is
  #              cleared so a fresh prompt starts clean
  #   Ctrl+D on an empty buffer returns nil (EOF => quit)
  #
  # Re-prompts on :cancelled and :empty instead of returning, so the run
  # loop only ever sees a submitted command or nil (quit). The draft lives
  # in @idle_draft for the life of the process.
  def get_command
    loop do
      # issue #156: show the active model in the modeline so the current
      # profile is visible at a glance (e.g. after a /model switch).
      # The ctx indicator (issue #63) is merged into the SAME line to save a
      # line of vertical space every turn; it is omitted until there is a
      # conversation (nothing to measure yet). The old "harness:" label is
      # dropped - with the model name on the line it adds no information.
      model  = @harness.session_manager.active_model_name
      # issue #219: the effective reasoning effort is visible in the modeline
      # so a /param tweak (or the profile default) is visible at a glance.
      effort = @harness.session_manager.param_overrides.reasoning_effort_display
      # issue #221 review (bug 2): the shell consent posture lives in the
      # prompt line too, so it is visible on EVERY turn (the spinner only
      # appears while the model works, and slash commands answer instantly -
      # neither shows the posture while the user is idle at the prompt).
      mode = @harness.command_mode_label
      # Bracketed model name keeps the prompt visually distinct from replies.
      # issue #221 review (bug 2): the posture bracket follows the model
      # bracket, e.g. "[qwen (medium)] [YOLO] >" - the bare label is the
      # tag, a "cmd:" prefix would only be noise inside the brackets.
      tags   = ["[#{model ? "#{model} (#{effort})" : effort}]"]
      tags  << "[#{mode}]" if mode
      prefix = "#{tags.join(' ')} > "
      ctx = @harness.context_indicator
      ui.puts ctx ? "#{ctx} #{prefix}" : prefix
      ui.flush

      result = UI::Editor.new(ui.stdin)
                         .read_multiline(prompt: "  ", prefill: @idle_draft)

      # Ctrl+A toggled the command-consent mode while the prompt was open:
      # ack it and re-prompt (no command was typed). The spinner badge for
      # the next turn shows the new mode (issue #224 follow-up).
      if UI::Editor::CtrlAState.fired
        label = UI::Editor::CtrlAState.label
        UI::Editor::CtrlAState.reset!
        ui.puts label.nil? ? "  (command mode toggle unavailable - safety check off)" \
                            : "  [mode is now #{label}]"
        next
      end

      case result.status
      when :eof
        return nil                     # Ctrl-D on an empty buffer => quit
      when :cancelled
        @idle_draft = result.text.to_s # Esc: keep the buffer, prefill next
        ui.puts "  (cancelled - draft kept; press the submit key to send)"
        next
      when :empty
        next                           # bare Enter: re-prompt, draft untouched
      end

      @idle_draft = nil
      return result.text.to_s.gsub("\r\n", "\n")
    end
  end
end
