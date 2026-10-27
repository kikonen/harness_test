# frozen_string_literal: true

require "yaml"
require "fileutils"

require_relative "harness_error"

# -- HarnessConfig --------------------------------------------------------
#
# Central configuration, loaded from a YAML config file. This replaces the
# old per-value ENV-based configuration (HARNESS_MODEL, HARNESS_BASE_URL,
# HARNESS_TOKEN, HARNESS_NUM_CTX, ...) which had become unmanageable.
#
# Precedence for every setting is:
#   CLI flag  >  config file  >  built-in default (constants in harness.rb)
#
# Config file schema (every key is optional). Sampling / generation values
# are OWNED BY THE CONFIG: a missing key is NOT sent to the API, so the
# server's own default applies (issue #215).
#
#   models:                     # one or more named model profiles
#     - name: local             # selection key (used by -m / default_model)
#       url: http://localhost:11434/v1
#       api: openai             # endpoint type: openai (default) | ollama (issue #197).
#                               # url is the base for the endpoint's path:
#                               # openai -> .../v1, ollama -> server root.
#       model: qwen2.5-coder:32b
#       token: sk-...           # optional bearer token
#       num_predict: -1         # same, native ollama name - omit = server default
#       num_ctx: 65536          # optional context window size (tokens)
#       reasoning_effort: medium
#       temperature: 0.6
#       top_p: 0.95
#       top_k: 20
#       min_p: 0
#       presence_penalty: 1.0
#       repeat_penalty: 1.05
#   default_model: local        # model used when -m is not given
#   compact:
#     recent_messages: 6        # messages retained verbatim after /compact
#     auto_threshold: 88        # auto-compact when context usage reaches this % of the window
#     max_size: 500             # max length (words) of the compaction summary
#     reserved_tokens: 8192     # absolute headroom (tokens) kept free before auto-compact (issue #151)
#   auto_save: true             # auto-save the session at every prompt boundary (issue #107)
#   max_tool_iterations: 200    # max tool-loop iterations for one turn (issue #226)
#   retry:
#     count: 3                  # total attempts for transient network errors
#     delay: 2                  # base delay (seconds) between retries
#   streaming: false            # consume the LLM response chunk by chunk and
#                               # show each part as it arrives (default off).
#                               # A model profile's own key overrides this one.
#   markdown: false             # render the assistant's answer as markdown with
#                               # ANSI styling (issue #106, default off).
#   double_enter_submit: false # Enter on an empty last line submits the multiline buffer (issue #198)
#   system_prompt_file: prompts/my.txt  # file with the full system prompt (issue #223)
#                                       # overrides the built-in config/system_prompt.txt
#   command_safety_check: true  # model self-check for unapproved shell commands
#                                       # (advisory note in the consent dialog, issue #224)
#   command_safety_auto_approve: safe  # with the check on, the consent posture as
#                                       # an enum: manual | safe | denylist |
#                                       # safe_denylist (a legacy true/false reads
#                                       # as safe/manual). safe: a "safe:" verdict
#                                       # skips the dialog (toggled live with Ctrl+A,
#                                       # issue #224 follow-up). denylist: a "safe:"
#                                       # verdict may also auto-approve a DENYLISTED
#                                       # command - config-only, never Ctrl+A
#                                       # (issue #389).
#   command_safety_denylist_safe_approve: true  # that same half on its own, if you
#                                       # prefer two boolean keys (ORed into the enum)
#   yolo: false  # shell consent OFF for the run.command tool: every command
#                # runs without a dialog and with no model safety check
#                # (issue #221). Toggled live with /yolo and persisted with the
#                # session. Well-known disaster commands (rm -rf, format C:,
#                # sudo, git push -f, curl|sh, ...) ALWAYS keep the dialog.
#   bang_requires_confirmation: true  # the `! cmd` bang syntax also asks for
#                # confirmation (default, issue #221). Set false and a
#                # user-typed bang command runs immediately - it is already
#   editor: nvim -R   # command Ctrl+G hands the buffer being typed to
#                     # (issue #298). Split into argv words, never run through a
#                     # shell. Resolution order: --editor, $HARNESS_EDITOR, this
#                     # key, $EDITOR, $VISUAL. Absent = the key is not taken.
#                # explicit intent. The disaster denylist still applies.
#
class HarnessConfig
  HARNESS_DIR = ".harness"

  # issue #260: the user home is the default place for configuration - a repo
  # .harness/config.yml is only an override for that one project. The old
  # install-dir tier is deliberately NOT part of the lookup: HARNESS_CONFIG
  # (or -c) already covers that special case.
  HOME_CONFIG_DIR = File.join(".config", "harness")

  # The user-home config file. Computed per call rather than baked into a
  # constant so the home directory can be resolved (and stubbed) at run time.
  def self.home_config_path
    File.join(Dir.home, HOME_CONFIG_DIR, "config.yml")
  end

  # The config template lives in the repo (config/config.example.yml), not
  # embedded in this file: it is the single source for both the committed
  # example and what a first run writes to the user home config (issue #260).
  TEMPLATE_FILE = File.expand_path("../config/config.example.yml", __dir__)

  # command_safety_auto_approve as an enum (issue #389): ONE key for both
  # relaxations of the consent flow. They stay orthogonal - 'denylist' fires only
  # on a real "safe:" verdict, so it is a legal mode with AUTO-APPROVE off. A
  # legacy boolean maps to safe/manual. Rationale:
  # doc/denylist_safe_approve_design.md.
  SAFETY_MODES = {
    "manual"        => { approve: false, denylist: false },
    "safe"          => { approve: true,  denylist: false },
    "denylist"      => { approve: false, denylist: true },
    "safe_denylist" => { approve: true,  denylist: true }
  }.freeze

  attr_reader :models, :default_model, :system_prompt_file

  def initialize(data = {})
    data          = {} if data.nil?
    @raw          = data
    @models       = normalize_models(Array(data[:models]))
    @default_model = nonblank(data[:default_model])
    @system_prompt_file = nonblank(data[:system_prompt_file])
    @auto_save = data[:auto_save].nil? ? true : data[:auto_save]
    @command_safety_check = data[:command_safety_check] == true
    # issue #389: the two safety relaxations fold into ONE enum key; the separate
    # denylist boolean ORs in when both keys are given. Rationale:
    # doc/denylist_safe_approve_design.md.
    mode = command_safety_mode(data[:command_safety_auto_approve])
    @command_safety_auto_approve = mode[:approve]
    @command_safety_denylist_safe_approve =
      mode[:denylist] || data[:command_safety_denylist_safe_approve] == true
    @double_enter_submit = data[:double_enter_submit] == true
    @max_tool_iterations = int_or_nil(data[:max_tool_iterations])
    # Opt-in streamed LLM responses (default off: a profile or global key
    # that does not ask for it gets the buffered request unchanged).
    @streaming = data[:streaming] == true
    # Opt-in markdown rendering of the assistant answer (issue #106, default off).
    @markdown = data[:markdown] == true
    # issue #303: rendered-output palette name (nil = the default palette).
    # Validated by UI::Palette.validate! in the CLI, not here: this class does
    # not know the palette list and must not start requiring the UI layer.
    @output_palette = nonblank(data[:output_palette])
    # issue #221: YOLO is opt-in (default off) - the harness never assumes
    # the user wants consent removed. Bang confirmation defaults to ON
    # (today's behavior): the user has to explicitly turn it off.
    @yolo = data[:yolo] == true
    @bang_requires_confirmation = data[:bang_requires_confirmation].nil? ?
                                  true : data[:bang_requires_confirmation] == true
    # issue #33: web.fetch private-address opt-in. Default OFF: fetching a
    # loopback / private / link-local address is the SSRF-shaped case, so it is
    # never allowed unless the user asked for it. Like yolo, a USER-side
    # posture: the model cannot set it.
    @web_fetch_allow_private = data[:web_fetch_allow_private] == true
    # issue #298: the editor command (nil = Ctrl+G is not taken at all).
    @editor = nonblank(data[:editor])
    @compact = {
      recent_messages: int_or_nil(data.dig(:compact, :recent_messages)),
      auto_threshold:  float_or_nil(data.dig(:compact, :auto_threshold)),
      max_size:        int_or_nil(data.dig(:compact, :max_size)),
      reserved_tokens: int_or_nil(data.dig(:compact, :reserved_tokens))
    }
    @retry = {
      count: int_or_nil(data.dig(:retry, :count)),
      delay: float_or_nil(data.dig(:retry, :delay))
    }
  end

  # Load the config from the first existing file among the candidates.
  # When no config file exists anywhere, a default template is written to the
  # user home config (issue #260): the project's .harness dir holds session
  # state only, so a per-project config is an override the user creates
  # deliberately, not something the harness drops there on its own.
  # Best-effort: if that location cannot be written (read-only home, ...),
  # loading simply continues with built-in defaults. An explicitly given
  # config path (-c) that does not exist is NOT auto-created - that is a
  # user error, not a first run.
  def self.load(cli_path, workdir)
    path = find_file(cli_path, workdir)
    if path.nil?
      # Only auto-create when the user did not explicitly point at a file.
      write_default_template(home_config_path) if cli_path.nil?
      return new({})
    end

    new(parse(path))
  end

  # Write the default template to path (creating parent directories).
  # Never overwrites an existing file. Returns true when written.
  def self.write_default_template(path)
    return false unless File.file?(TEMPLATE_FILE)

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(TEMPLATE_FILE))
    true
  rescue Errno::ENOENT => e
    warn "  [config] template #{TEMPLATE_FILE} is missing - no config written"
    false
  rescue SystemCallError => e
    warn "  [config] could not write default config to #{path}: #{e.message}"
    false
  end

  # Candidate config file paths, in priority order. The first existing one wins.
  def self.default_paths(workdir)
    paths = []
    paths << ENV["HARNESS_CONFIG"] if ENV["HARNESS_CONFIG"]
    paths << File.join(workdir, HARNESS_DIR, "config.yml") if workdir
    paths << home_config_path
    paths
  end

  # Find the first existing config file among cli_path + the default paths.
  def self.find_file(cli_path, workdir)
    candidates = []
    candidates << cli_path if cli_path
    candidates.concat(default_paths(workdir))
    candidates.each do |p|
      return p if File.file?(p)
    end
    nil
  end

  # Parse a YAML config file into a plain hash with symbol keys. Symbolizing
  # here (once, at parse time) means every accessor below works with symbol
  # keys at every nesting level - no per-key symbolize/aliasing.
  def self.parse(path)
    YAML.safe_load(File.read(path), symbolize_names: true) || {}
  rescue Psych::SyntaxError => e
    raise HarnessError, "invalid config file #{path}: #{e.message}"
  end

  # True when at least one model profile is configured.
  def models_configured?
    !@models.empty?
  end

  # Whether the session is auto-saved at every prompt boundary (default true).
  def auto_save_enabled
    @auto_save == true
  end

  # Opt-in double-Enter submit for the multiline editor (issue #198):
  # Enter on an empty last line submits the buffer. Default false - plain
  # Enter always inserts a newline.
  def double_enter_submit_enabled
    @double_enter_submit == true
  end

  # issue #224: opt-in model self-check for unapproved shell commands -
  # an advisory verdict in the consent dialog, never an auto-approval.
  def command_safety_check_enabled
    @command_safety_check == true
  end

  # issue #224 follow-up: the initial command consent posture for the
  # safety check (MANUAL or AUTO-APPROVE; toggled live with Ctrl+A during
  # a session). Only meaningful with command_safety_check on.
  def command_safety_auto_approve_enabled
    @command_safety_auto_approve == true
  end

  # issue #389: the denylist half of command_safety_auto_approve (the 'denylist' /
  # 'safe_denylist' modes). Config-derived for the whole run: no live toggle.
  # Meaningless unless command_safety_check is on (no check, no verdict).
  def command_safety_denylist_safe_approve_enabled
    @command_safety_denylist_safe_approve == true
  end

  # issue #221: initial YOLO posture for shell consent (issue #221). Off by
  # default: consent removal is always the user's explicit choice. During a
  # session it is toggled with /yolo and persisted with the session.
  def yolo_enabled?
    @yolo == true
  end

  # issue #221: whether the `! cmd` bang syntax keeps its confirmation
  # dialog. Defaults to true (the historic behavior). False means a
  # user-typed bang command runs without asking - the disaster denylist
  # still gates it.
  def bang_requires_confirmation?
    @bang_requires_confirmation != false
  end

  # issue #33: may web.fetch connect to a private / loopback / CGNAT address?
  # Default OFF. It lifts the PRIVATE tier of AddressGuard only - link-local
  # (the cloud metadata range) and multicast stay refused whatever this says.
  def web_fetch_allow_private?
    @web_fetch_allow_private == true
  end

  # Max tool-loop iterations for one turn (or nil; the built-in default then applies).
  def max_tool_iterations
    @max_tool_iterations
  end

  # Opt-in streamed LLM responses (global key). Default false; a model
  # profile's own 'streaming' key overrides it for that profile.
  def streaming_enabled?
    @streaming == true
  end

  # Opt-in markdown rendering of the assistant answer (issue #106). Default false.
  def markdown_enabled?
    @markdown == true
  end

  # Rendered-output palette name (issue #303), or nil for the default one.
  def output_palette_name
    @output_palette
  end

  # The external-editor command for Ctrl+G (issue #298), or nil when the config
  # does not set one - the ENV tiers are applied by UI::ExternalEditor.command.
  def editor_command
    @editor
  end

  # Number of recent messages retained verbatim after compaction (or nil).
  def compact_recent_messages
    @compact[:recent_messages]
  end

  # Auto-compact threshold as a percentage of the context window (or nil).
  def compact_auto_threshold
    @compact[:auto_threshold]
  end

  # Max length (words) of the compaction summary (or nil).
  def compact_max_size
    @compact[:max_size]
  end

  # Absolute headroom (tokens) reserved for the compaction summary call
  # before auto-compact fires (or nil; the built-in default then applies).
  def compact_reserved_tokens
    @compact[:reserved_tokens]
  end

  # Total retry attempts for transient network errors (or nil).
  def retry_count
    @retry[:count]
  end

  # Base delay (seconds) between retries (or nil).
  def retry_delay
    @retry[:delay]
  end

  # Resolve the active model profile. selection is the value of -m (or nil).
  # Returns a normalized hash { name:, url:, model:, token:, num_ctx:, ... }
  # when model profiles are configured, or nil when none are (so the caller
  # can fall back to treating -m as a raw model id).
  def resolve_model(selection)
    return nil unless models_configured?

    key = nonblank(selection) || @default_model
    raise HarnessError, "no model selected and no default_model configured" if key.nil?

    match = @models.find { |m| m[:name] == key || m[:model] == key }
    raise HarnessError, "unknown model '#{key}'. Available: #{@models.map { |m| m[:name] || m[:model] }.join(', ')}" unless match

    match
  end

  # The raw (parsed) config hash.
  def to_h
    @raw
  end

  private

  def normalize_models(list)
    list.map do |m|
      raise HarnessError, "each entry in 'models' must be a mapping" unless m.is_a?(Hash)

      {
        name:             nonblank(m[:name]),
        url:              nonblank(m[:url]),
        api:              nonblank(m[:api]),
        model:            nonblank(m[:model]),
        token:            nonblank(m[:token]),
        num_ctx:          int_or_nil(m[:num_ctx]),
        max_tokens:       int_or_nil(m[:max_tokens]),
        num_predict:      int_or_nil(m[:num_predict]),
        reasoning_effort: nonblank(m[:reasoning_effort]),
        temperature:      float_or_nil(m[:temperature]),
        top_p:            float_or_nil(m[:top_p]),
        top_k:            int_or_nil(m[:top_k]),
        min_p:            float_or_nil(m[:min_p]),
        presence_penalty: float_or_nil(m[:presence_penalty]),
        repeat_penalty:   float_or_nil(m[:repeat_penalty]),
        streaming:        bool_or_nil(m[:streaming])
      }
    end
  end

  # A string is "present" when it is non-nil and not blank.
  def nonblank(val)
    val = val.to_s.strip
    val.empty? ? nil : val
  end

  def int_or_nil(val)
    return nil if val.nil?

    Integer(val)
  rescue ArgumentError, TypeError
    raise HarnessError, "expected an integer, got: #{val.inspect}"
  end

  def float_or_nil(val)
    return nil if val.nil?

    Float(val)
  rescue ArgumentError, TypeError
    raise HarnessError, "expected a number, got: #{val.inspect}"
  end

  # A tri-state flag: true, false, or nil for "not configured" (so a profile
  # can leave the decision to the global key instead of overriding it).
  def bool_or_nil(val)
    return nil if val.nil?

    val == true
  end

  # command_safety_auto_approve accepts the enum or a legacy boolean. An
  # unrecognised value is a config error rather than a silent fallback: a
  # posture that quietly became manual would read as "my relaxation is on", and
  # the reverse would quietly relax the disaster floor.
  def command_safety_mode(val)
    return SAFETY_MODES["manual"] if val.nil? || val == false
    return SAFETY_MODES["safe"] if val == true

    mode = SAFETY_MODES[val.to_s.strip.downcase]
    return mode if mode

    raise HarnessError,
      "command_safety_auto_approve must be one of " \
        "#{SAFETY_MODES.keys.join(', ')} (or true/false), got: #{val.inspect}"
  end
end
