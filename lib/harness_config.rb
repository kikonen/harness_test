# frozen_string_literal: true

require "yaml"
require "fileutils"

require_relative "harness_error"
require_relative "image_store"
require_relative "model_profile"
require_relative "config_scalar"

# Central configuration loaded from a YAML file. Precedence for every setting is
# CLI flag > config file > built-in default. Sampling/generation values are owned
# by the config: a missing key is not sent to the API, so the server's default applies.
class HarnessConfig
  include ConfigScalar

  HARNESS_DIR = ".harness"

  # The user home is the default place for configuration; a repo .harness/config.yml is
  # only an override for that project. The old install-dir tier is not part of the lookup
  # (HARNESS_CONFIG or -c covers that special case).
  HOME_CONFIG_DIR = File.join(".config", "harness")

  # The user-home config file. Computed per call rather than a constant so the home
  # directory can be resolved (and stubbed) at run time.
  def self.home_config_path
    File.join(Dir.home, HOME_CONFIG_DIR, "config.yml")
  end

  # The config template lives in the repo (config/config.example.yml), not embedded here:
  # single source for both the committed example and what a first run writes to the home config.
  TEMPLATE_FILE = File.expand_path("../config/config.example.yml", __dir__)

  # command_safety_auto_approve as an enum: ONE key for both relaxations of the consent
  # flow. They stay orthogonal - 'denylist' fires only on a real "safe:" verdict, so it is a
  # legal mode with AUTO-APPROVE off. A legacy boolean maps to safe/manual. Rationale:
  # doc/denylist_safe_approve_design.md.
  SAFETY_MODES = {
    "manual"        => { approve: false, denylist: false },
    "safe"          => { approve: true,  denylist: false },
    "denylist"      => { approve: false, denylist: true },
    "safe_denylist" => { approve: true,  denylist: true }
  }.freeze

  # Tool-result image inline budget: the built-in the harness enforces when neither the
  # config nor a profile names one. A profile may override it; a run with no vision profile
  # never inlines anything, so these values are read whatever the active model is.
  MCP_IMAGE_LIMIT_DEFAULTS = {
    inline_max_bytes:  1_500_000,
    inline_max_images: 4,
    inline_max_tokens: 40_000
  }.freeze

  attr_reader :models, :default_profile_id, :system_prompt_file

  def initialize(data = {})
    data          = {} if data.nil?
    @raw          = data
    @models       = normalize_models(Array(data[:models]))
    # 'default_profile_id' names what it is: the profile a new run uses. 'default_model:'
    # is the historical key and is still read.
    @default_profile_id = nonblank(data[:default_profile_id]) || nonblank(data[:default_model])
    raise HarnessError, "'default_profile_id' must name a configured model profile" if
      @default_profile_id && @models.none? { |m| m[:id] == @default_profile_id }

    @system_prompt_file = nonblank(data[:system_prompt_file])
    @auto_save = data[:auto_save].nil? ? true : data[:auto_save]
    @command_safety_check = data[:command_safety_check] == true

    # The two safety relaxations fold into ONE enum key; the separate denylist boolean ORs
    # in when both keys are given.
    mode = command_safety_mode(data[:command_safety_auto_approve])

    @command_safety_auto_approve = mode[:approve]
    @command_safety_denylist_safe_approve =
      mode[:denylist] || data[:command_safety_denylist_safe_approve] == true

    @double_enter_submit = data[:double_enter_submit] == true
    @max_tool_iterations = int_or_nil(data[:max_tool_iterations])
    @output_result_bytes = int_or_nil(data[:output_result_bytes])
    @output_spill_keep   = int_or_nil(data[:output_spill_keep])
    @max_memories = int_or_nil(data[:max_memories])

    # Opt-in streamed LLM responses (default off: a profile or global key that does not ask
    # for it gets the buffered request unchanged).
    @streaming = data[:streaming] == true

    # Opt-in markdown rendering of the assistant answer (default off).
    @markdown = data[:markdown] == true

    # Table-width basis for markdown rendering. nil = the renderer's default (80% of the
    # terminal, capped for prose); an explicit column count is used as-is, and a percentage
    # ("85%") is stored RAW because it is the only form a sink with no column count of its
    # own can lay out from.
    @markdown_max_width = width_or_nil(data[:markdown_max_width])

    # External MCP servers. Opt-in: an empty list means no MCP code path runs at all. Each
    # entry is normalized to { name:, command:, args:, env: }.
    @mcp_servers = normalize_mcp_servers(Array(data[:mcp_servers]))

    # Tool-result image limits. Read whether or not a vision profile exists: the values
    # describe the rule. nil = the built-in default.
    @mcp_image_limits = normalize_mcp_images(data[:mcp_images])
    @mcp_images_dir   = nonblank(data.dig(:mcp_images, :dir)) || ImageStore::DEFAULT_DIR

    # Workdir-relative dirs the YOLO posture never auto-covers. nil (key absent) = FileList's
    # default (the owner's space, local/); an explicit list replaces it, an empty list protects nothing.
    @protected_dirs =
      if data.key?(:protected_dirs)
        normalize_protected_dirs(Array(data[:protected_dirs]))
      end

    # Rendered-output palette name (nil = the default). Validated by UI::Palette.validate!
    # in the CLI, not here: this class must not start requiring the UI layer.
    @output_palette = nonblank(data[:output_palette])

    # YOLO is opt-in (default off) - the harness never assumes the user wants consent removed.
    # Bang confirmation defaults to ON: the user has to explicitly turn it off.
    @yolo = data[:yolo] == true

    @bang_requires_confirmation =
      data[:bang_requires_confirmation].nil? ?
      true :
      data[:bang_requires_confirmation] == true

    # web.fetch private-address opt-in. Default OFF: fetching a loopback/private/link-local
    # address is the SSRF-shaped case. Like yolo, a USER-side posture the model cannot set.
    @web_fetch_allow_private = data[:web_fetch_allow_private] == true

    # The editor command (nil = Ctrl+G is not taken at all).
    @editor = nonblank(data[:editor])

    # Standing file-access grant on the working directory. Default ON (key absent = true): a
    # run starts covering every path inside the workdir for read/write/delete. Sensitive names
    # (.git, .harness, .env*) stay blocked - FileList#sensitive? runs BEFORE any grant lookup.
    # Set false for the old per-file consent back.
    @grant_workdir = data[:grant_workdir].nil? ? true : data[:grant_workdir]

    @compact = {
      recent_messages: int_or_nil(data.dig(:compact, :recent_messages)),
      auto_threshold:  float_or_nil(data.dig(:compact, :auto_threshold)),
      max_size:        int_or_nil(data.dig(:compact, :max_size)),
      reserved_tokens: int_or_nil(data.dig(:compact, :reserved_tokens))
    }

    @resume = {
      replay_entries:    int_or_nil(data.dig(:resume, :replay_entries)),
      replay_on_startup: data.dig(:resume, :replay_on_startup)
    }

    # Two OutputBuffer tail limits per task: tail_memory bounds how much of a buffer's tail
    # lives in RAM, tasks_kept how many recent finished jobs the registry retains. The SAVED
    # limit is 'resume: replay_entries' above (it is already the window a save writes).
    @output = {
      tail_memory: int_or_nil(data.dig(:output, :tail_memory)),
      tasks_kept:    int_or_nil(data.dig(:output, :tasks_kept))
    }

    @retry = {
      count: int_or_nil(data.dig(:retry, :count)),
      delay: float_or_nil(data.dig(:retry, :delay))
    }
  end

  # Load from the first existing file among the candidates. When none exists, a default
  # template is written to the user home config: the project's .harness dir holds session
  # state only, so a per-project config is an override the user creates deliberately.
  # Best-effort: if that location cannot be written, loading continues with built-in defaults.
  # An explicitly given config path (-c) that does not exist is NOT auto-created - a user error.
  def self.load(cli_path, workdir)
    path = find_file(cli_path, workdir)
    if path.nil?
      # Only auto-create when the user did not explicitly point at a file.
      write_default_template(home_config_path) if cli_path.nil?
      return new({})
    end

    new(parse(path))
  end

  # Write the default template to path (creating parent directories). Never overwrites an
  # existing file. Returns true when written.
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

  # Parse a YAML config file into a plain hash with symbol keys. Symbolizing once at parse
  # time means every accessor works with symbol keys at every nesting level.
  def self.parse(path)
    YAML.safe_load(File.read(path), symbolize_names: true) || {}
  rescue Psych::SyntaxError => e
    raise HarnessError, "invalid config file #{path}: #{e.message}"
  end

  def models_configured?
    !@models.empty?
  end

  def auto_save_enabled
    @auto_save == true
  end

  def double_enter_submit_enabled
    @double_enter_submit == true
  end

  def command_safety_check_enabled
    @command_safety_check == true
  end

  def command_safety_auto_approve_enabled
    @command_safety_auto_approve == true
  end

  def command_safety_denylist_safe_approve_enabled
    @command_safety_denylist_safe_approve == true
  end

  def yolo_enabled?
    @yolo == true
  end

  def bang_requires_confirmation?
    @bang_requires_confirmation != false
  end

  def web_fetch_allow_private?
    @web_fetch_allow_private == true
  end

  # Max tool-loop iterations for one turn (or nil; the built-in default then applies).
  def max_tool_iterations
    @max_tool_iterations
  end

  # Byte budget for one tool result in the conversation (nil = the built-in default).
  # Config-only: a run whose result overflows the backend's context window cannot be repaired
  # from inside that run, so the size a project allows is persistent policy, not a per-run flag.
  def output_result_bytes
    @output_result_bytes
  end

  # How many spill files one job's results dir keeps (nil = the built-in default).
  # Config-only like output_result_bytes: it bounds harness state a run writes as it
  # goes, not something the model should be able to widen mid-turn.
  def output_spill_keep
    @output_spill_keep
  end

  # Max memory notes for one store (or nil; the built-in default applies).
  def max_memories
    @max_memories
  end

  # Opt-in streamed LLM responses (global key). Default false; a model profile's own
  # 'streaming' key overrides it for that profile.
  def streaming_enabled?
    @streaming == true
  end

  # Opt-in markdown rendering of the assistant answer. Default false.
  def markdown_enabled?
    @markdown == true
  end

  # Table-width basis for markdown rendering, or nil for the renderer's default. A percentage
  # is returned as the raw "N%" string, never as a resolved number.
  def markdown_max_width
    @markdown_max_width
  end

  def mcp_servers
    @mcp_servers
  end

  # The tool-result image budget: the three integers (inline_max_bytes / inline_max_images /
  # inline_max_tokens) this run enforces.
  def mcp_image_limits
    @mcp_image_limits
  end

  # Workdir-relative dir the spilled tool-result images are written to.
  def mcp_images_dir
    @mcp_images_dir
  end

  # Workdir-relative dirs the YOLO posture never auto-covers. nil when the key is absent
  # (FileList applies its default, local/); an array (possibly empty) when the config names one.
  def protected_dirs
    @protected_dirs
  end

  # True when the run starts with a standing grant on the working directory. Decided here, in
  # the user's config, so FileList keeps its own constructor default (no standing grant) and
  # every caller that builds a list directly is untouched.
  def grant_workdir?
    @grant_workdir == true
  end

  # Rendered-output palette name, or nil for the default one.
  def output_palette_name
    @output_palette
  end

  # The external-editor command for Ctrl+G, or nil when the config does not set one - the
  # ENV tiers are applied by UI::ExternalEditor.command.
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

  # Absolute headroom (tokens) reserved for the compaction summary call before auto-compact
  # fires (or nil; the built-in default then applies).
  def compact_reserved_tokens
    @compact[:reserved_tokens]
  end

  # How many OutputBuffer entries a resumed session redraws at startup. nil = the built-in
  # default; 0 disables the replay.
  def resume_replay_entries
    @resume[:replay_entries]
  end

  # Whether a resumed run redraws the saved tail AT ALL at startup. Default ON
  # (key absent = true); only an explicit false turns the automatic redraw off.
  # When off, the record is still saved and /replay still shows it on demand.
  def resume_replay_on_startup?
    @resume[:replay_on_startup] != false
  end

  # How much of a per-task OutputBuffer tail lives in RAM. nil = the buffer's built-in default.
  # This gates the consumed-front trim, never a pending entry, so a renderer that polls later
  # still sees everything it has not read.
  def output_tail_memory
    @output[:tail_memory]
  end

  # How many finished jobs the registry retains for review. nil = the default (nothing dropped).
  # Read here, enforced by JobRegistry#retain, the first consumer of the key.
  def output_tasks_kept
    @output[:tasks_kept]
  end

  # Total retry attempts for transient network errors (or nil).
  def retry_count
    @retry[:count]
  end

  # Base delay (seconds) between retries (or nil).
  def retry_delay
    @retry[:delay]
  end

  # Resolve the selected model profile: selection is the value of -m (a profile id) or nil (the
  # config default). Raises unless a configured profile matches - a model is selected from
  # 'models:' only, with no raw-id fallback.
  def resolve_profile(selection)
    return nil if selection.nil? && @default_profile_id.nil?

    key = nonblank(selection) || @default_profile_id
    raise HarnessError, "no model profiles configured to select one from" if @models.empty?

    match = @models.find { |m| m[:id] == key }
    raise HarnessError,
      "unknown profile '#{key}'. Available: #{@models.map { |m| m[:id] }.join(', ')}" unless match

    match
  end

  # The raw (parsed) config hash.
  def to_h
    @raw
  end

  private

  # Each entry becomes a ModelProfile (which validates its own fields); the only cross-entry
  # rule is that ids are unique - a duplicate makes a selection and a resumed run silently ambiguous.
  def normalize_models(list)
    profiles = list.map { |entry| ModelProfile.new(entry) }
    # Each profile answers its own validity; a config error names the profile.
    profiles.each(&:valid!)
    # A profile that declares an mcp_images: block owns a full budget (the same defaults fill
    # a half-typed block as the global key uses).
    profiles.each { |p| p.normalize_image_limits(MCP_IMAGE_LIMIT_DEFAULTS) }

    duplicate = profiles.map(&:id).tally.find { |_, count| count > 1 }&.first
    raise HarnessError,
      "model profile id '#{duplicate}' is used by more than one entry " \
        "(an id selects exactly one profile)" if duplicate

    profiles
  end

  # Normalize each mcp_servers entry. A server needs a name (the tool namespace) and exactly
  # ONE way to reach it: a command to spawn (stdio) or a url to connect to (HTTP/SSE). args/env
  # belong to a command entry, headers to a url entry; both optional. Every mismatch is a config
  # error rather than a silently degraded server: a server that quietly did not load reads as
  # "my MCP tools are there" when they are not. An entry with BOTH transports is refused too -
  # they reach different trust boundaries (a local program vs. a remote host).
  def normalize_mcp_servers(list)
    list.map do |entry|
      raise HarnessError, "each entry in 'mcp_servers' must be a mapping" unless entry.is_a?(Hash)

      name    = require_name(entry)
      command = nonblank(entry[:command])
      url     = nonblank(entry[:url])

      if command.nil? && url.nil?
        raise HarnessError,
          "an mcp_servers entry needs a 'name' and one of 'command' or 'url' " \
            "(got: #{entry.keys.inspect})"
      end
      raise HarnessError, "mcp_servers entry '#{name}' has both 'command' and 'url'" if command && url

      if command
        # An env value must be a string when it reaches the subprocess spawn.
        {
          name:,
          command:,
          args: Array(entry[:args]).map(&:to_s),
          env: stringified(entry[:env])
        }
      else
        {
          name:,
          url: ConfigScalar.require_http_url("mcp_servers entry '#{name}'", url),
          headers: stringified(entry[:headers])
        }
      end
    end
  end

  def normalize_mcp_images(val)
    ConfigScalar.normalize_mcp_images(val, MCP_IMAGE_LIMIT_DEFAULTS)
  end

  def require_name(entry)
    name = nonblank(entry[:name])
    raise HarnessError, "an mcp_servers entry needs a 'name'" if name.nil?

    name
  end

  # A non-Hash is treated as empty; keys and values are stringified because they reach HTTP
  # headers / the subprocess environment, which hold strings.
  def stringified(val)
    return {} unless val.is_a?(Hash)

    val.transform_keys(&:to_s).transform_values { |v| expand_env(v.to_s, "an mcp_servers value") }
  end

  # Normalize each protected_dirs entry to a workdir-relative dir. A blank entry is dropped;
  # a trailing slash is trimmed so a config 'local/' still matches the exact-prefix shape FileList applies.
  def normalize_protected_dirs(list)
    list.map { |entry| nonblank(entry)&.sub(%r{/\z}, "") }.compact
  end

  # command_safety_auto_approve accepts the enum or a legacy boolean. An unrecognised value is
  # a config error rather than a silent fallback: a posture that quietly became manual would
  # read as "my relaxation is on", and the reverse would quietly relax the disaster floor.
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
