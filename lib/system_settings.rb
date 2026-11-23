# frozen_string_literal: true

require_relative "ui/palette"
require_relative "model_profile"
require_relative "session"

# -- SystemSettings -------------------------------------------------------
# Typed view + behavior layer over the resolved CLI options hash it OWNS;
# one access route (named accessors only) and posture rationale: doc/system_settings_design.md
class SystemSettings
  # How many entries of the run record a session saves and a resumed run
  # redraws. 0 disables the run record entirely.
  DEFAULT_RESUME_REPLAY_ENTRIES = 30

  # Built-ins for config keys that stay nil when nothing is configured;
  # a harness.md turn can read these values as-is.
  DEFAULT_MAX_TOOL_ITERATIONS = 200
  DEFAULT_COMPACT_MAX_SIZE    = 500

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
    default_profile_id
    mcp_image_limits
    output_tail_memory
    output_tasks_kept
    output_result_bytes
    markdown_max_width
    workdir
    editor
    double_enter_submit
    protected_dirs
  ].freeze

  # The model SELECTION: the PROFILE ID the CLI chose with -m/--model
  # (nil = use the config default profile). A profile id, never a model.
  SELECTION_KEYS = %i[
    active_profile_id
  ].freeze

  STATIC_KEYS.each do |name|
    define_method(name) { @options[name] }
  end

  SELECTION_KEYS.each do |name|
    define_method(name) { @options[name] }
  end

  # A hand-built hash (specs, library users) works the same way a CLI-resolved one does.
  def self.from_options(options)
    new(options)
  end

  def initialize(options)
    @options = options
    # The palette is the one value resolved (not just passed through): it is
    # validated here so every route (CLI, /palette, resume) shares the name check.
    @output_palette = UI::Palette.fetch(options[:output_palette])
  end

  # -- Static config with a resolved default -------------------------------

  def resume_replay_entries
    entries = @options[:resume_replay_entries]
    entries.nil? ? DEFAULT_RESUME_REPLAY_ENTRIES : entries.to_i
  end

  # Whether a resumed run redraws the saved tail at startup (config
  # resume.replay_on_startup, default ON). Only an explicit false turns the
  # automatic redraw off; /replay still shows the record whatever this says.
  def resume_replay_on_startup?
    @options.fetch(:resume_replay_on_startup, true) != false
  end

  def max_tool_iterations
    value = @options[:max_tool_iterations]
    value.nil? ? DEFAULT_MAX_TOOL_ITERATIONS : value.to_i
  end

  def compact_recent_messages
    value = @options[:compact_recent]
    value.nil? ? Session::COMPACT_RECENT_MESSAGES : value.to_i
  end

  def compact_auto_threshold
    value = @options[:compact_auto_threshold]
    value.nil? ? Session::AUTO_COMPACT_THRESHOLD : value.to_i
  end

  def compact_reserved_tokens
    value = @options[:compact_reserved]
    value.nil? ? Session::COMPACT_RESERVED_TOKENS : value.to_i
  end

  def compact_max_size
    value = @options[:compact_max_size]
    value.nil? ? DEFAULT_COMPACT_MAX_SIZE : value.to_i
  end

  # A hand-built options hash gets the same default the config would: an
  # explicit false is the only thing that turns the standing grant off.
  def grant_workdir?
    @options.fetch(:grant_workdir, true) != false
  end

  # -- Shared model catalogue ----------------------------------------------

  def model_profiles
    # The catalogue is normalized to ModelProfile here (the one boundary raw
    # profile hashes cross), so every consumer reads a strict value object.
    @model_profiles ||= Array(@options[:model_profiles]).map do |entry|
      next entry if entry.is_a?(ModelProfile)

      ModelProfile.new(entry)
    end
  end

  # The catalogue is run-wide; applying a profile to one agent's ModelConfig is
  # that Harness' job, not a settings mutation.
  def find_profile(id)
    model_profiles.find { |p| p.id == id }
  end

  # The declared MCP servers (config 'mcp_servers:'), or nil when none.
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

  # Config-only (no live toggle), not a third posture, meaningful only while the
  # safety check is on. Rationale: doc/denylist_safe_approve_design.md.
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
  # CommandRunner reads. A named store (not a key both sides reach through the
  # raw hash) so the two consent consumers share one place.
  def safety_verdicts
    @options[:safety_verdicts]
  end

  def safety_verdicts=(val)
    @options[:safety_verdicts] = val
  end

  # -- Streaming posture ---------------------------------------------------

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

  # -- Markdown rendering posture ------------------------------------------

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

  # The config seed for Harness' per-conversation planning posture: read once
  # when the Harness is built, never mutated here (settings carries no mutable
  # plan state - doc/system_settings_design.md).
  def plan_seed?
    @options[:plan] == true
  end

  # -- Output palette ------------------------------------------------------

  attr_reader :output_palette

  # Resolved and validated HERE so every route (CLI, /palette, resume) goes
  # through the same name check. 'none' paints nothing; nil resolves to default.
  def output_palette=(name)
    @output_palette = UI::Palette.fetch(name)
  end

  # -- Model catalogue/selection helpers (live params live in ModelConfig) --

  # The profile ID this RUN resolves to: what -m/--model chose, or the config
  # default when nothing was chosen. nil only when neither is set.
  def resolved_profile_id
    active_profile_id || default_profile_id
  end

  # Display only: the spinner, the modeline and the startup banner show a name,
  # never a bare id.
  def resolved_profile_name
    active_profile&.name || resolved_profile_id
  end

  # The profile the selection resolves to (nil when no model is selected or no
  # profile matches). Harness reads its per-connection values from here.
  def active_profile
    find_profile(resolved_profile_id)
  end

  # Restore the session-persisted postures a resumed run saved; only the keys
  # the session carries are applied. Config-only postures are not touched.
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
