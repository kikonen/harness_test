# frozen_string_literal: true

require "optparse"

require_relative "harness_error"
require_relative "harness_config"
require_relative "ui"

# -- CLIOptions -----------------------------------------------------------

# Resolves the run's options from ARGV: parse the CLI flags, then merge the
# config file and the active model profile over them. Precedence for every
# setting is: CLI flag > config file > built-in. Extracted from CLI so CLI
# stays about running a session and this class owns argument parsing.
class CLIOptions
  DEFAULT_BASE_URL = "http://localhost:11434/v1"

  def self.parse
    new.parse
  end

  def parse
    opts = parse_argv
    resolve_workdir(opts)

    # Load the YAML config file (models, default_model, compact, system).
    config = HarnessConfig.load(opts[:config_path], opts[:workdir])

    profile = resolve_profile(opts, config)
    apply_profile(opts, profile)
    apply_model_tracking(opts, profile, config)
    apply_config(opts, config, profile)
    validate!(opts)

    opts
  end

  private

  # The CLI flag table. Each flag writes straight into opts; the config merge
  # happens later so a flag can win over the config file.
  def parse_argv
    opts = {}

    parser = OptionParser.new do |o|
      o.banner = "Usage: harness.rb [options]"
      o.separator("")
      o.on(
        "-c FILE",
        "--config FILE",
        "Path to the YAML config file. Lookup order: -c, $HARNESS_CONFIG, " \
          "<workdir>/.harness/config.yml, ~/.config/harness/config.yml " \
          "(issue #260). On first run the template is written to the user " \
          "home config when no config file exists yet.") do |v|
        opts[:config_path] = v
      end
      o.on("-m MODEL", "--model MODEL", "Model name (required)") { |v| opts[:model] = v }
      o.on(
        "--system-file FILE",
        "Use this file as the system prompt (overrides config / built-in)") do |v|
        opts[:system_file] = v
      end
      o.on(
        "-d DIR",
        "--workdir DIR",
        "Working directory; all file paths are relative to it") do |v|
        opts[:workdir] = v
      end
      o.on(
        "-r ID",
        "--resume ID",
        "Resume a saved session by id (see /sessions)") { |v| opts[:resume] = v }
      o.on(
        "--continue",
        "Resume the newest saved session for this workdir (issue #107). " \
          "Equivalent to --resume <id> with the most recent id.") do
        opts[:continue] = true
      end
      o.on(
        "--list-sessions",
        "List saved sessions and exit (no model needed)") { |v| opts[:list_sessions] = v }
      o.on(
        "--no-auto-save",
        "Disable periodic auto-save of the session at prompt boundaries " \
          "(issue #107). Overrides the config 'auto_save' key.") do
        opts[:no_auto_save] = true
      end
      o.on(
        "-v",
        "--verbose",
        "Show full prompt and raw response") { |v| opts[:verbose] = v }
      o.on(
        "-p NAME",
        "--palette NAME",
        "Output palette for rendered lines (issue #303): " \
          "#{UI::Palette.names.join(', ')}. 'none' is the same as --no-color.") do |v|
        opts[:output_palette] = v
      end
      o.on(
        "--no-color",
        "Render every line in the terminal's own color (palette 'none').") do
        opts[:output_palette] = "none"
      end
      o.on(
        "--markdown",
        "Render the assistant's answer as markdown (issue #106): headings, " \
          "bold/italic, inline code and tables get ANSI styling. Off by default.") do
        opts[:markdown] = true
      end
      o.on(
        "--markdown-width N",
        "Column basis for markdown tables (issue #106): a table is sized to " \
          "fit N columns (clamped to the terminal width). Without it the basis " \
          "is 80% of the detected terminal width. Only meaningful with " \
          "--markdown / 'markdown:' in the config.") do |v|
        opts[:markdown_max_width] = Integer(v)
      rescue ArgumentError, TypeError
        raise HarnessError, "--markdown-width needs an integer column count, got: #{v}"
      end
      o.on(
        "--editor CMD",
        "Command that opens an external editor for the buffer being typed " \
          "(Ctrl+G at the prompt, issue #298). Overrides the config 'editor' " \
          "key, $HARNESS_EDITOR and $EDITOR/$VISUAL.") do |v|
        opts[:editor_cli] = v
      end
      o.on("-h", "--help") { puts o; exit }
    end
    parser.parse!

    opts
  end

  # Resolve the working directory first (config discovery depends on it).
  def resolve_workdir(opts)
    opts[:workdir] ||= Dir.pwd
    opts[:workdir] = File.expand_path(opts[:workdir])

    unless File.directory?(opts[:workdir])
      raise HarnessError, "working directory does not exist: #{opts[:workdir]}"
    end
  end

  # Resolve the active model profile from the config. When no models are
  # configured, -m is treated as a raw model id (backward compatible).
  def resolve_profile(opts, config)
    return nil unless config.models_configured? && !opts[:list_sessions]

    config.resolve_model(opts[:model])
  end

  # A profile carries the endpoint and generation parameters; without one the
  # base url falls back to the built-in default.
  def apply_profile(opts, profile)
    if profile
      opts[:base_url] = profile[:url] || DEFAULT_BASE_URL
      opts[:model] ||= profile[:model]
      opts[:api] = profile[:api]
      opts[:token] = profile[:token]
      opts[:num_ctx] = profile[:num_ctx]
      opts[:max_tokens] = profile[:max_tokens]
      opts[:num_predict] = profile[:num_predict]
      opts[:reasoning_effort] = profile[:reasoning_effort]
      opts[:temperature] = profile[:temperature]
      opts[:top_p] = profile[:top_p]
    else
      opts[:base_url] ||= DEFAULT_BASE_URL
    end
  end

  # Expose the configured model profiles so /models can list them and
  # /model can switch between them at runtime. The active model name is
  # tracked separately (options[:active_model]) for display and persistence.
  # It is stored as nil when the config default is active: a null value in
  # the session means "use whatever the config default is", so sessions
  # keep working even if the default model changes later.
  def apply_model_tracking(opts, profile, config)
    opts[:model_profiles] = config.models
    opts[:default_model]  = config.default_model
    explicit_model = !opts[:model].nil? && !opts[:model].to_s.strip.empty?
    default_key    = config.default_model
    using_default = profile && !explicit_model &&
      (default_key.nil? ||
       profile[:name] == default_key ||
       profile[:model] == default_key)
    opts[:active_model] =
      using_default ? nil : (profile ? (profile[:name] || profile[:model]) : opts[:model])
  end

  # The config-derived defaults. A CLI flag already in opts wins (each line
  # only fills a value the flag left unset); a config-only setting has no flag.
  def apply_config(opts, config, profile)
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

    # issue #389: the denylist half of command_safety_auto_approve. Config-only:
    # no live toggle and no session persistence (unlike the yolo posture).
    opts[:command_safety_denylist_safe_approve] =
      config.command_safety_denylist_safe_approve_enabled

    # issue #221: initial YOLO posture (shell consent OFF for run.command)
    # and whether the `!` bang syntax keeps its confirmation. Both default
    # to the conservative value (YOLO off, bang confirmation on).
    opts[:yolo] = config.yolo_enabled?
    opts[:bang_requires_confirmation] = config.bang_requires_confirmation?

    # issue #33: web.fetch private-address opt-in (default off). A user-side
    # posture only - the model cannot set it and no tool argument can.
    opts[:web_fetch_allow_private] = config.web_fetch_allow_private?

    # issue #28: initial streaming posture. A profile's own 'streaming' key
    # wins over the global one (a server or proxy that mishandles a streamed
    # response can be opted out of per profile); /stream switches it live.
    opts[:stream] = if profile && !profile[:streaming].nil?
                      profile[:streaming]
                    else
                      config.streaming_enabled?
                    end

    # issue #106: markdown rendering of the assistant answer. The --markdown flag
    # already set it true; otherwise the config 'markdown' key decides (default off).
    opts[:markdown] = config.markdown_enabled? if opts[:markdown].nil?

    # The table-width basis: --markdown-width N > config 'markdown_max_width' >
    # nil (the renderer's default, 80% of the detected terminal).
    opts[:markdown_max_width] =
      config.markdown_max_width if opts[:markdown_max_width].nil?

    # issue #48: external MCP servers. Config-only (no CLI flag - a server is a
    # declared, persistent setup, not a one-run toggle). An empty list means the
    # MCP code path never runs (the gem is not even loaded).
    opts[:mcp_servers] = config.mcp_servers

    # issue #385: dirs the YOLO posture never auto-covers. Config-only. nil (key
    # absent) = FileList's default (local/); an explicit list replaces it.
    opts[:protected_dirs] = config.protected_dirs

    opts[:compact_recent] ||= config.compact_recent_messages
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

    # issue #298: the command Ctrl+G hands the buffer being typed to. Resolved
    # ONCE here so the precedence is stated in one place: CLI flag >
    # $HARNESS_EDITOR > config 'editor' > $EDITOR > $VISUAL.
    env_editor = UI::ExternalEditor.command(config.editor_command)
    opts[:editor] = opts[:editor_cli] || env_editor
  end

  def validate!(opts)
    return if opts[:model] || opts[:list_sessions]

    raise HarnessError, "-m / --model is required (or set default_model in the config)"
  end
end
