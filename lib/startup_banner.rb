# frozen_string_literal: true

require_relative "session_locator"
require_relative "ui"

# -- StartupBanner --------------------------------------------------------
# The startup facts a run prints before its prompt loop. It reads the run's own
# state and writes only through the injected UI; the resumed tail is drawn
# BEFORE the banner so the facts stay one block. Rationale: doc/startup_banner_design.md
class StartupBanner
  def initialize(ui:, settings:, file_list:, harness:, registry:, resumed:)
    @ui       = ui
    @settings = settings
    @file_list = file_list
    @harness  = harness
    @registry = registry
    @resumed  = resumed
  end

  # The previous exchange first, then the banner: the replay used to sit in the
  # middle of the facts, forcing a scroll to find them. resume.replay_on_startup
  # (default on) gates the automatic redraw; /replay still shows it when off.
  def print
    print_resume_replay if @resumed && @settings.resume_replay_on_startup?
    print_banner
  end

  private

  def print_banner
    @ui.puts "Harness ready. Type /help for commands, /exit to quit."

    # Show WHERE calls go (API type + endpoint + base url), not just the base url - a
    # profile switch can change the API type.
    @ui.puts "Model: #{@harness.session_manager.active_profile_name} " \
      "(#{@harness.session_manager.target_display} @ #{@harness.model_config.base_url})"
    # Name the image posture only when the run can receive one: MCP servers are the
    # only source of tool-result images. The two cases (inlined pixels vs. a file path)
    # behave completely differently and nothing else at startup says which this is.
    if Array(@settings.mcp_servers).any?
      image_mode =
        if @harness.vision?
          "inlined to the model"
        else
          "files only (no vision profile)"
        end
      @ui.puts "Tool-result images: #{image_mode}"
    end
    @ui.puts "Working directory: #{@file_list.workdir}"

    # Show the session id so the user knows where its log is written and which id a
    # later /save or --resume refers to.
    @ui.puts "Session: #{@harness.session.session_id} (log: #{session_log_path_display})"

    # A rules file that is not valid UTF-8 now LOADS (bad bytes replaced) instead of
    # crashing, so the repair must be said out loud: the prompt the model got is not
    # byte-for-byte what harness.md holds.
    if @harness.rules_repair_note
      @ui.puts "  [harness.md repaired: #{@harness.rules_repair_note}]"
    end

    # --resume / --continue restore the conversation during construction, so the
    # banner is where the user learns WHICH session this run is.
    @ui.puts "  (resumed conversation and file list - see /session)" if @resumed

    # The shell consent posture is a fact about how this run behaves, so it belongs
    # here - and the disaster floor is named with it so YOLO ON is never mistaken for "nothing asks".
    @ui.puts "Command consent: #{consent_posture_display}"
    # The same for file consent: a run that asks for no file inside the project must
    # say so, and name the opt-out - an invisible standing grant reads as a run that protects nothing.
    @ui.puts "File consent: #{file_access_display}"
    @harness.logger.info "file consent: #{file_access_display}"

    # Which palette this run renders with is a fact about the run; /palette changes it.
    palette_name = @settings.output_palette.name
    @ui.puts "Output palette: #{palette_name} (/palette <name> switches it)"

    # Whether this run streams decides what the user sees while the model writes; /stream switches it.
    @ui.puts "LLM responses: #{@settings.stream? ? 'streamed (/stream off buffers them)' \
               : 'buffered (/stream on shows each part as it arrives)'}"
    @ui.puts "Tip: type a plain message (no /) to send it directly to the model."

    # MCP servers the user declared. Each connected server and each problem is reported
    # here, so the run never silently pretends its MCP tools are available.
    @harness.mcp_status_notes.each do |note|
      @ui.puts "  [mcp] #{note}"
    end

    @ui.puts "Tip: Enter adds a newline; paste multiline text directly. The " \
      "submit key sends the whole buffer: Ctrl+Enter (Windows console, or " \
      "to a remote host via Windows Terminal) or Alt/AltGr+Enter (Unix " \
      "terminal). See /help input for details."
    @ui.puts "Tip: a line starting with ! runs a shell command locally (not sent " \
      "to the model)."
    @ui.puts "Tip: a line starting with / is a command (executed immediately)."

    # Steer a running turn instead of Ctrl+C - any keypress while the model works opens the note editor.
    @ui.puts "Tip: type a note while the model is working to steer it mid-turn " \
      "(Enter = newline, submit key sends the whole block as one note; " \
      "no Ctrl+C; see /help notes)."
    @ui.puts
  end

  # Redraw the saved OutputBuffer tail of the previous run. The buffer records what was
  # SHOWN, so replaying it through UI::Renderer restores how the last topic looked, not
  # just the raw conversation. An empty tail prints nothing.
  def print_resume_replay
    tail = @registry.foreground_buffer.replay_tail
    return if tail.empty?

    renderer = UI::Renderer.new(
      palette: @settings.output_palette,
      markdown: @settings.markdown?,
      markdown_max_width: @settings.markdown_max_width)
    # A block-width rule on each side keeps the previous exchange a distinct block,
    # separate from the run facts that follow it.
    rule = "-" * UI::Renderer::RULE_WIDTH
    @ui.puts
    @ui.puts rule
    @ui.puts "Resumed output (the last exchange of the previous session):"
    tail.each do |entry|
      @ui.puts renderer.line(
        type: entry.type,
        content: entry.content,
        origin: entry.origin)
    end
    @ui.puts rule
    @ui.puts
  end

  # The log path relative to the workdir (an absolute path would duplicate the
  # Working directory line above).
  def session_log_path_display
    id = @harness.session.session_id
    File.join(SessionLocator::SESSIONS_DIR, id, SessionLocator::SESSION_LOG_FILE)
  end

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
    # A relaxed floor is named for the same reason YOLO names it: never mistake a
    # relaxed run for a normal one.
    return base unless @settings.denylist_safe_approve?

    "#{base}; denylist + \"safe:\" also runs without asking " \
      "(command_safety_auto_approve: denylist)"
  end

  # The run's starting file consent, in the same at-a-glance form. Both branches name
  # what STILL asks, because "no dialogs for your files" is a claim a user must audit.
  def file_access_display
    unless @settings.grant_workdir?
      return "per-path consent - every file and directory asks " \
        "(grant_workdir: false)"
    end

    "standing grant on #{@file_list.workdir} - read, write and delete inside " \
      "the project run without asking (.git/.harness/.env* and any path " \
      "outside it still ask; /clear removes the grant, /grant shows it)"
  end
end
