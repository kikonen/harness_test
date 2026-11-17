# frozen_string_literal: true

require_relative "ui/palette"

# -- SystemSettings -------------------------------------------------------

# The run-wide state the harness and its commands share: the consent/posture
# flags (and the toggle + label logic that used to live on Harness), plus the
# resolved config values a consumer reads once at startup. Owned by the CLI and
# passed around; it is the single home of this state, replacing both the
# `options` bag and the scattered HarnessConfig getter reads.
#
# Static config is resolved once (from CLIOptions) and never rewritten here.
# The postures ARE live state: a /yolo flip changes them in place and the next
# reader sees it (the FileList posture lambda reads yolo? live). The model
# parameters are still resolved into @options here for now; moving them to a
# dedicated mutable object is a later step of this refactor
# (doc/harness_job_design.md).
class SystemSettings
  # How many entries of the run record a session saves and a resumed run
  # redraws (issue #458). 0 disables the run record entirely. Overridden by
  # the config 'resume: replay_entries:' key.
  DEFAULT_RESUME_REPLAY_ENTRIES = 30

  # The posture + consent state. Output palette is always a UI::Palette.
  # markdown_max_width is static config (read once, never toggled live) but
  # lives here so a posture command that reports it (markdown) needs no
  # Harness. The three output-buffer limits are static config too (issue #286):
  # the run's owner (CLI) builds the JobRegistry from them.
  attr_reader :output_palette,
    :markdown_max_width,
    :output_tail_memory,
    :output_tasks_kept,
    :resume_replay_entries

  # Read the run-wide values out of the resolved CLI options hash. A hand-built
  # hash (specs, library users) works the same way a CLI-resolved one does.
  def self.from_options(options)
    new(options)
  end

  def initialize(options)
    @options = options

    @yolo      = options[:yolo] == true
    @stream    = options[:stream] == true
    @markdown  = options[:markdown] == true
    @plan      = options[:plan] == true
    @output_palette = UI::Palette.fetch(options[:output_palette])
    @markdown_max_width = options[:markdown_max_width]

    # Buffer limits pass through UNresolved (nil = the buffer/registry's own
    # built-in default) except resume_replay_entries, whose default is the
    # saved-window semantics stated above.
    @output_tail_memory = options[:output_tail_memory]
    @output_tasks_kept = options[:output_tasks_kept]
    entries = options[:resume_replay_entries]
    @resume_replay_entries = entries.nil? ? DEFAULT_RESUME_REPLAY_ENTRIES : entries.to_i

    @command_safety_check             = options[:command_safety_check] == true
    @command_safety_auto_approve      = options[:command_safety_auto_approve] == true
    @command_safety_denylist_safe_approve =
      options[:command_safety_denylist_safe_approve] == true
  end

  # -- Consent posture -----------------------------------------------------

  def command_safety_check
    @command_safety_check
  end

  def command_safety_auto_approve
    @command_safety_auto_approve
  end

  def command_safety_auto_approve=(val)
    @command_safety_auto_approve = (val == true)
  end

  def command_safety_auto_approve_effective?
    command_safety_check && command_safety_auto_approve
  end

  def yolo?
    @yolo
  end

  def yolo=(val)
    @yolo = (val == true)
  end

  def toggle_yolo
    @yolo = !@yolo
    yolo_mode_label
  end

  def command_mode_label
    return "YOLO" if @yolo
    return "AUTO-APPROVE" if command_safety_auto_approve_effective?

    "MANUAL"
  end

  # -- Model catalogue (static config, issue #286) -------------------------

  # All configured profiles (array of hashes), or [] when none. Read live off
  # @options (the catalogue is fixed config, but @options is the one hash the
  # whole run shares and a profile switch may touch it after construction).
  def model_profiles
    Array(@options[:model_profiles])
  end

  # Name (or id) of the configured default model, or nil.
  def default_model
    @options[:default_model]
  end

  # A configured profile by its label (:name) or raw model id (:model), or nil
  # when absent. Lookup over the fixed catalogue; the active-model pointer that
  # feeds it is runtime state owned by SessionManager.
  def find_profile(name)
    model_profiles.find { |p| p[:name] == name || p[:model] == name }
  end

  def yolo_mode_label
    @yolo ? "YOLO ON" : "YOLO OFF"
  end

  # issue #389: the denylist-safe override (config-only, no live toggle). It is
  # NOT part of command_mode_label: it is not a third posture, it changes what a
  # "safe:" verdict may decide for a DENYLISTED command, and it is only
  # meaningful while the safety check is on. Rationale:
  # doc/denylist_safe_approve_design.md.
  def denylist_safe_approve?
    @command_safety_denylist_safe_approve
  end

  def denylist_safe_approve=(val)
    @command_safety_denylist_safe_approve = (val == true)
  end

  # -- Streaming posture (issue #28) ---------------------------------------

  def stream?
    @stream
  end

  def stream=(val)
    @stream = (val == true)
  end

  def toggle_stream
    @stream = !@stream
    stream_mode_label
  end

  # Badge label only when streaming is ON: the badge names a NON-default
  # posture (the same rule as YOLO / AUTO-APPROVE), and buffered is the default.
  def stream_mode_label
    @stream ? "STREAM" : nil
  end

  # -- Markdown rendering posture (issue #106) -----------------------------

  def markdown?
    @markdown
  end

  def markdown=(val)
    @markdown = (val == true)
  end

  def toggle_markdown
    self.markdown = !@markdown
    markdown? ? "MARKDOWN ON" : "MARKDOWN OFF"
  end

  # -- Planning posture (issue #359) ---------------------------------------

  def plan?
    @plan
  end

  def plan=(val)
    @plan = (val == true)
  end

  def toggle_plan
    @plan = !@plan
    plan_mode_label
  end

  def plan_mode_label
    @plan ? "PLAN" : nil
  end

  # -- Output palette (issue #303) -----------------------------------------

  # Resolved and validated HERE so every route (CLI, /palette, resume) goes
  # through the same name check. 'none' paints nothing; nil resolves to default.
  def output_palette=(name)
    @output_palette = UI::Palette.fetch(name)
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
