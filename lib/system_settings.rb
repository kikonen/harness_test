# frozen_string_literal: true

require_relative "ui/palette"
require_relative "model_profile"

# -- SystemSettings -------------------------------------------------------

# The run's single source of resolved CONFIG: a typed view + behavior layer over
# the resolved CLI options hash, which it OWNS. Owned by the CLI and handed to
# every Harness (sub-agents included) as the one settings object, so no other
# object carries or reads a raw options hash.
#
# Settings carries the run config and the shared model CATALOGUE (profiles,
# default, the selected model name); it carries NO per-connection model fields.
# The live model / endpoint / sampling values live only in each Harness' own
# ModelConfig, seeded from the resolved profile - a #286 sub-agent shares this
# one settings object, so putting a per-connection field here would couple every
# agent to it.
#
# One access route: NAMED accessors only. Harness, its collaborators, the tools
# and CommandRunner all read config by name (compact_*, retry_*, yolo?, the model
# catalogue/selection, the consent postures). The raw options hash is never
# re-exposed - there is no single-key [] reader/writer, because handing a key
# back through the raw hash is how the whole mutable bag would slip back in.
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
  # (nil = use the config default profile). A profile id, never a model;
  # settings holds no per-connection params - Harness keeps those in its own
  # ModelConfig.
  SELECTION_KEYS = %i[
    active_profile_id
  ].freeze

  STATIC_KEYS.each do |name|
    define_method(name) { @options[name] }
  end

  SELECTION_KEYS.each do |name|
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

  # -- Static config with a resolved default -------------------------------

  # The run-record saved-window size; the built-in default applies when absent.
  def resume_replay_entries
    entries = @options[:resume_replay_entries]
    entries.nil? ? DEFAULT_RESUME_REPLAY_ENTRIES : entries.to_i
  end

  # The standing grant on the working directory (issue #384, config 'grant_workdir:').
  # A hand-built options hash (specs, library users) gets the same default the config
  # would: an explicit false is the only thing that turns it off.
  def grant_workdir?
    @options.fetch(:grant_workdir, true) != false
  end

  # -- Shared model catalogue (fixed config, issue #286) -------------------

  # All configured profiles (array of hashes), or [] when none.
  def model_profiles
    # The catalogue is normalized to ModelProfile here (the one boundary raw
    # profile hashes cross), so every consumer reads a strict value object
    # instead of re-deriving fields from each other. HarnessConfig already hands
    # ModelProfile objects; a hand-built catalogue (specs, library users) is
    # normalized the same way.
    @model_profiles ||= Array(@options[:model_profiles]).map do |entry|
      next entry if entry.is_a?(ModelProfile)

      ModelProfile.new(entry)
    end
  end

  # A configured profile by its id, or nil when absent. The catalogue is
  # run-wide; applying a profile to one agent's ModelConfig is that Harness'
  # job, not a settings mutation.
  def find_profile(id)
    model_profiles.find { |p| p.id == id }
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

  # The config seed for Harness' per-conversation planning posture: read once
  # when the Harness is built (Harness#initialize), never mutated here. It is
  # the one run-wide key Harness reads to SEED its own live #plan toggle -
  # settings carries no mutable plan state (the NOTE above).
  def plan_seed?
    @options[:plan] == true
  end

  # -- Output palette (issue #303) -----------------------------------------

  attr_reader :output_palette

  # Resolved and validated HERE so every route (CLI, /palette, resume) goes
  # through the same name check. 'none' paints nothing; nil resolves to default.
  def output_palette=(name)
    @output_palette = UI::Palette.fetch(name)
  end

  # -- Model catalogue/selection helpers (live params live in ModelConfig) --

  # The profile ID this RUN resolves to: what -m/--model chose, or the config
  # default when nothing was chosen (active_profile_id nil). nil only when
  # neither is set.
  def resolved_profile_id
    active_profile_id || default_profile_id
  end

  # Both names read the same @options hash this object owns (and, through it,
  # what the CLI resolved), so they cannot disagree. resolved_* is the pair
  # every consumer uses: the id to look a profile up with, the name to display.

  # The display name of that profile (its own name: key, else its id). Display
  # only: the spinner, the modeline and the startup banner show a name, never a
  # bare id.
  def resolved_profile_name
    active_profile&.name || resolved_profile_id
  end

  # The profile the selection resolves to (nil when no model is selected or no
  # profile matches). Harness reads its per-connection values from here, and so
  # does the display above: the two can never disagree.
  def active_profile
    find_profile(resolved_profile_id)
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
