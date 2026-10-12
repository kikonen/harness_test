# frozen_string_literal: true

require_relative 'harness_error'

# Session-level overrides for the adjustable LLM parameters (issue #219).
#
# A model profile (the config) fixes a starting set of LLM parameters, but a
# single run often wants to nudge one of them without editing the config -
# lower the reasoning effort on a fast model, shrink the context window to
# test compaction, etc. Those tweaks are SESSION-level: they live here for
# the duration of the session, are re-applied whenever the underlying profile
# changes (a /model switch or /resume) so they keep winning, and are
# persisted in the session JSON like the active model. "default" resets one
# back to the profile value.
#
# Kept as its own object (rather than inlined in SessionManager) so the
# parameter-override logic has a single, testable home.
class ParamOverrides
  # The adjustable parameters and how their values are parsed. The two
  # strings 'default' (reset) and 'off' (reasoning_effort: use the server's
  # built-in / no reasoning) are handled before numeric parsing.
  PARAM_KEYS = {
    reasoning_effort: :string,
    num_ctx:          :int,
    max_tokens:       :int,
    num_predict:      :int,
    temperature:      :float,
    top_p:            :float,
    top_k:            :int,
    min_p:            :float,
    presence_penalty: :float,
    repeat_penalty:   :float
  }.freeze

  attr_reader :options

  # options: the shared options hash - mutated in place so the LLM call and
  # the compact trigger (which both read options) see changes immediately.
  # profile: a callable returning the active profile's value hash (or nil when
  # no profile is configured) - the source of the "default" value.
  def initialize(options, profile:)
    @options   = options
    @profile   = profile
    @overrides = {}
  end

  def keys
    PARAM_KEYS.keys
  end

  # The full parameter listing (a header line plus one line per parameter),
  # shared by the /param and /model commands so their output is identical
  # (issue #219). Each line shows the parameter, its effective value (a
  # session override when one is set, else the config/profile value), and an
  # "(override)" mark when a session-level override is in place.
  def list_display
    lines = ["Model parameters (adjust with /param <key> <value>, reset with 'default'):"]
    keys.each do |key|
      mark   = overridden?(key) ? ' (override)' : ''
      lines << "  #{key.to_s.ljust(16)} #{display_value(effective(key))}#{mark}"
    end
    lines
  end

  def overrideable?(key)
    PARAM_KEYS.key?(key.to_sym)
  end

  # The stored override record for key ({ value:, raw: }) or nil.
  def override_for(key)
    @overrides[key.to_sym]
  end

  def overridden?(key)
    !override_for(key).nil?
  end

  # The value a /param command gives a parameter: 'default' (reset to the
  # profile value) and 'off' (reasoning_effort = server default) are kept
  # verbatim; everything else is parsed to the parameter's type.
  def parse_value(key, value)
    key   = key.to_sym
    value = value.to_s.strip
    return value if value.downcase == 'default'
    return 'off' if key == :reasoning_effort && value.downcase == 'off'

    case PARAM_KEYS[key]
    when :string then value
    when :int    then Integer(value)
    when :float  then Float(value)
    end
  rescue ArgumentError, TypeError
    raise HarnessError, "invalid value for #{key}: #{value.inspect}"
  end

  # Set (or, with the 'default' value, reset) an override and make it take
  # effect immediately. Returns a human-readable confirmation line.
  def set(key, value)
    key = key.to_sym
    unless overrideable?(key)
      raise HarnessError, "unknown parameter '#{key}'. Adjustable: #{keys.join(', ')}"
    end

    parsed    = parse_value(key, value)
    resetting = parsed.to_s.downcase == 'default'

    if resetting
      @overrides.delete(key)
      @options[key] = profile_value(key)
      return "#{key}: reset to #{display_value(profile_value(key))} (profile default)"
    end

    @overrides[key] = { value: parsed, raw: value.to_s }
    @options[key]   = parsed
    "#{key}: #{display_value(parsed)} (session override)"
  end

  # The effective value of a parameter (override first, then the active
  # profile). Returns nil when neither sets it (server default applies).
  def effective(key)
    key = key.to_sym
    ov  = @overrides[key]
    return ov[:value] if ov

    profile_value(key)
  end

  # The active profile's own value for key (nil when the profile leaves it
  # unset, so the server default applies).
  def profile_value(key)
    prof = @profile.call
    prof ? prof[key.to_sym] : @options[key.to_sym]
  end

  # The reasoning effort to show in the status line (issue #219): the
  # effective value, or 'off' when nothing sets it.
  def reasoning_effort_display
    effective(:reasoning_effort) || 'off'
  end

  # The value shown for a parameter: 'off' for an explicitly-unset reasoning
  # effort, 'default' when unset, else the value.
  def display_value(value)
    return 'off' if value == 'off'
    value.nil? ? 'default' : value.to_s
  end

  # Re-apply every override into options (after a profile change / resume)
  # so the overrides keep winning over the newly-applied profile values.
  def restore!
    @overrides.each { |key, rec| apply_one(key, rec[:value]) }
  end

  # Replace the stored overrides from a persisted hash (string-keyed, from a
  # JSON round trip). Call restore! afterwards to re-apply them.
  def load(data)
    @overrides = {}
    return if data.nil? || !data.is_a?(Hash)

    data.each do |key, rec|
      rec = rec.is_a?(Hash) ? rec : { value: rec }
      rec = rec.transform_keys(&:to_sym)
      @overrides[key.to_sym] = { value: rec[:value], raw: rec[:raw].to_s }
    end
  end

  # The stored overrides as a plain hash (symbol keys, JSON-safe).
  def to_h
    @overrides.dup
  end

  private

  def apply_one(key, value)
    return unless overrideable?(key)
    return if value.nil?

    @options[key.to_sym] = value
  end
end
