# frozen_string_literal: true

require_relative "ui/palette"

# -- SystemSettings -------------------------------------------------------

# The run's single source of resolved CONFIG: a typed view + behavior layer over
# the resolved CLI options hash, which it OWNS. Owned by the CLI and handed to
# every Harness (sub-agents included) as the one settings object, so no other
# object carries or reads a raw options hash.
#
# Settings carries the run config and the shared model CATALOGUE; it does NOT
# carry mutable per-connection state. A #286 sub-agent shares this one object,
# so the live model / endpoint / sampling values are seeded from settings into
# each Harness' own ModelConfig and mutated there - /model and /param never
# write back here, or one switch would change every agent at once.
#
# Two access routes, deliberately distinct (#286):
#   * Harness and its collaborators read NAMED accessors - compact_*, retry_*,
#     yolo?, and the model SEED values ModelConfig clones. These are read-only
#     here.
#   * "Others" (the tools, CommandRunner) read a single key through the
#     designated [] reader. [] is the single-key reader/writer; there is no
#     full options accessor, because re-exposing the whole mutable hash is what
#     smuggling the bag back under a new name would be.
class SystemSettings
  # How many entries of the run record a session saves and a resumed run
  # redraws (issue #458). 0 disables the run record entirely.
  DEFAULT_RESUME_REPLAY_ENTRIES = 30

  # Config read once and never rewritten: the run's owner (CLI) and Harness
  # access these by name; nothing else needs them.
  STATIC_KEYS = %i[
    system_file
    step_display
    max_tool_iterations
    compact_recent
    compact_auto_threshold
    compact_reserved
    compact_max_size
    auto_save
    mcp_images_dir
    verbose
    web_fetch_allow_private
    bang_requires_confirmation
    retry_count
    retry_delay
    max_memories
    default_model
    output_tail_memory
    output_tasks_kept
    markdown_max_width
  ].freeze

  # The model SEED values: read-only here. Each Harness clones them into its
  # own ModelConfig, which is where /model and /param mutate them.
  MODEL_KEYS = %i[
    model
    active_model
    base_url
    api
    token
    vision
    num_ctx
    max_tokens
    num_predict
    reasoning_effort
    temperature
    top_p
    top_k
    min_p
    presence_penalty
    repeat_penalty
    mcp_image_limits
  ].freeze

  STATIC_KEYS.each do |name|
    define_method(name) { @options[name] }
  end

  MODEL_KEYS.each do |name|
    define_method(name) { @options[name] }
  end

  # Read the run-wide values out of the resolved CLI options hash. A hand-built
  # hash (specs, library users) works the same way a CLI-resolved one does.
  def self.from_options(options)
    new(options)
  end

  def initialize(options)
    @options = options
    # The palette is the one value resolved (not just passed through): it is
    # validated here so every route (CLI, /palette, resume) shares the name check.
    @output_palette = UI::Palette.fetch(options[:output_palette])
  end

  # Designated single-key reader/writer for consumers that are not Harness or its
  # collaborators (the tools, CommandRunner). Hands back one key, not the hash.
  def [](key)
    @options[key]
  end

  def []=(key, value)
    @options[key] = value
  end

  # -- Static config with a resolved default -------------------------------

  # The run-record saved-window size; the built-in default applies when absent.
  def resume_replay_entries
    entries = @options[:resume_replay_entries]
    entries.nil? ? DEFAULT_RESUME_REPLAY_ENTRIES : entries.to_i
  end

  # -- Shared model catalogue (fixed config, issue #286) -------------------

  # All configured profiles (array of hashes), or [] when none.
  def model_profiles
    Array(@options[:model_profiles])
  end

  # A configured profile by its label (:name) or raw model id (:model), or nil
  # when absent. The catalogue is run-wide; applying a profile to one agent's
  # ModelConfig is that Harness' job, not a settings mutation.
  def find_profile(name)
    model_profiles.find { |p| p[:name] == name || p[:model] == name }
  end

  # The declared MCP servers (config 'mcp_servers:'), or nil when none. The
  # tool-registry builder hands these to Mcp::Manager#load.
  def mcp_servers
    @options[:mcp_servers]
  end

  # -- Consent posture -----------------------------------------------------

  def command_safety_check
    @options.fetch(:command_safety_check, false)
  end

  def command_safety_auto_approve
    @options.fetch(:command_safety_auto_approve, false)
  end

  def command_safety_auto_approve=(val)
    @options[:command_safety_auto_approve] = (val == true)
  end

  def command_safety_auto_approve_effective?
    command_safety_check && command_safety_auto_approve
  end

  # issue #389: the denylist-safe override (config-only, no live toggle). It is
  # NOT part of command_mode_label: it is not a third posture, it changes what a
  # "safe:" verdict may decide for a DENYLISTED command, and it is only
  # meaningful while the safety check is on. Rationale:
  # doc/denylist_safe_approve_design.md.
  def denylist_safe_approve?
    @options[:command_safety_denylist_safe_approve] == true
  end

  def denylist_safe_approve=(val)
    @options[:command_safety_denylist_safe_approve] = (val == true)
  end

  def yolo?
    @options[:yolo] == true
  end

  def yolo=(val)
    @options[:yolo] = (val == true)
  end

  def toggle_yolo
    self.yolo = !yolo?
    yolo_mode_label
  end

  def yolo_mode_label
    yolo? ? "YOLO ON" : "YOLO OFF"
  end

  def command_mode_label
    return "YOLO" if yolo?
    return "AUTO-APPROVE" if command_safety_auto_approve_effective?

    "MANUAL"
  end

  # The {command => verdict} cache #precheck_batch_safety writes and
  # CommandRunner reads. A named store on the settings (not a key both sides
  # reach through the raw hash) so the two consent consumers share one place.
  def safety_verdicts
    @options[:safety_verdicts]
  end

  def safety_verdicts=(val)
    @options[:safety_verdicts] = val
  end

  # -- Streaming posture (issue #28) ---------------------------------------

  def stream?
    @options[:stream] == true
  end

  def stream=(val)
    @options[:stream] = (val == true)
  end

  def toggle_stream
    self.stream = !stream?
    stream_mode_label
  end

  # Badge label only when streaming is ON: the badge names a NON-default
  # posture (the same rule as YOLO / AUTO-APPROVE), and buffered is the default.
  def stream_mode_label
    stream? ? "STREAM" : nil
  end

  # -- Markdown rendering posture (issue #106) -----------------------------

  def markdown?
    @options[:markdown] == true
  end

  def markdown=(val)
    @options[:markdown] = (val == true)
  end

  def toggle_markdown
    self.markdown = !markdown?
    markdown? ? "MARKDOWN ON" : "MARKDOWN OFF"
  end

  # NOTE: the planning posture (issue #359) is deliberately NOT here. It is
  # per-conversation Harness state - settings is run-wide and shared with every
  # agent, so a mutable [PLAN] toggle here would force every sub-agent into
  # planning mode at once. Harness owns it, seeded from the config value.

  # -- Output palette (issue #303) -----------------------------------------

  attr_reader :output_palette

  # Resolved and validated HERE so every route (CLI, /palette, resume) goes
  # through the same name check. 'none' paints nothing; nil resolves to default.
  def output_palette=(name)
    @output_palette = UI::Palette.fetch(name)
  end

  # -- Model SEED helpers (read-only; live mutation lives in ModelConfig) --

  # The seed active-model name (active_model || model), used by the catalogue
  # display when no per-Harness ModelConfig is in play.
  def active_model_name
    active_model || model
  end

  # The seed value of a model parameter (nil when unset). ModelConfig#param
  # reads the live per-connection value.
  def param(key)
    @options[key.to_sym]
  end

  # Restore the session-persisted postures a resumed run saved. Called with the
  # parsed session data; only the keys the session carries are applied, so a
  # session saved before a posture existed keeps the config value. The saved
  # choice wins over config (#221). command_safety_auto_approve, the denylist
  # flag and plan are config-only (never saved), so they are not touched here.
  def restore_persisted(data)
    self.yolo    = data[:yolo] == true if data.key?(:yolo)
    self.stream  = data[:stream] == true if data.key?(:stream)
    self.markdown = data[:markdown] == true if data.key?(:markdown)
    # A stored palette name only has to be usable (a session saved by another
    # build may name a palette this one lacks) -> fall back to default.
    return unless data.key?(:output_palette)

    stored = data[:output_palette].to_s
    self.output_palette = UI::Palette.names.include?(stored) ? data[:output_palette] : nil
  end
end
