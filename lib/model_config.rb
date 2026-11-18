# frozen_string_literal: true

# -- ModelConfig ----------------------------------------------------------

# Per-Harness live model + connection state (#286).
#
# SystemSettings is the run-wide resolved config the whole process shares; a
# Harness manages ONE LLM connection, so the model it talks to, its endpoint,
# token, API type and the live sampling/context parameters must be THIS
# Harness' own. A #286 sub-agent is built from the SAME settings object, so
# writing the model into settings would flip the model of every agent at once
# - the exact bug this class removes. A /model switch or a /param tweak
# therefore reaches only this Harness' connection.
#
# Seeded from settings at construction (settings is the single source of the
# resolved CLI/config values); the model CATALOGUE (profiles, default_model,
# find_profile) stays run-wide in settings because it is fixed config shared
# by every agent, not live per-connection state.
class ModelConfig
  # The live per-connection keys the backends, LLMClient, SessionManager and
  # ParamOverrides read every request, so a /model switch takes effect without
  # rebuilding the client. Read AND written here.
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

  # Transport knobs a backend reads from the SAME object so it holds one
  # config source. Seeded from settings; not switched per-model, but held here
  # because the backend has no settings reference of its own.
  TRANSPORT_KEYS = %i[verbose retry_count retry_delay].freeze

  # The adjustable parameters /param overrides, and how their values are
  # parsed. A subset of MODEL_KEYS (each already has a reader/writer). The
  # strings 'default' (reset) and 'off' (reasoning_effort: server default)
  # are handled before numeric parsing, by ParamOverrides.
  PARAM_KEYS = {
    reasoning_effort: :string,
    num_ctx: :int,
    max_tokens: :int,
    num_predict: :int,
    temperature: :float,
    top_p: :float,
    top_k: :int,
    min_p: :float,
    presence_penalty: :float,
    repeat_penalty: :float
  }.freeze

  MODEL_KEYS.each do |name|
    define_method(name) { @values[name] }
    define_method("#{name}=") { |value| @values[name] = value }
  end

  TRANSPORT_KEYS.each { |name| define_method(name) { @values[name] } }

  # Seed every live key from the run-wide settings (the resolved config). A
  # hand-built hash (specs, a fresh profile-less run) works the same way.
  def self.from_settings(settings)
    new(
      MODEL_KEYS.to_h { |k| [k, settings.public_send(k)] }
                .merge(TRANSPORT_KEYS.to_h { |k| [k, settings.public_send(k)] }))
  end

  # Specs and non-CLI builders pass the raw values hash directly.
  def initialize(values)
    @values = values
  end

  # Name (or id) of the model THIS connection is using, or nil. Live state:
  # a /model switch writes active_model / model on this object.
  def active_model_name
    active_model || model
  end

  # Apply a resolved profile's parameters in place, leaving keys the profile
  # does not declare untouched. The profile hash comes from the run-wide
  # catalogue (SystemSettings#find_profile); only the live per-connection
  # values it declares are written here. A profile with no 'mcp_images:' block
  # says nothing, so it must not clobber the seeded budget (apply_profile only
  # writes one the profile actually declares).
  def apply_profile(profile)
    @values[:base_url]         = profile[:url] if profile[:url]
    @values[:api]              = profile[:api]
    @values[:model]            = profile[:model]
    @values[:token]            = profile[:token]
    @values[:num_ctx]          = profile[:num_ctx]
    @values[:max_tokens]       = profile[:max_tokens]
    @values[:num_predict]      = profile[:num_predict]
    @values[:reasoning_effort] = profile[:reasoning_effort]
    @values[:temperature]      = profile[:temperature]
    @values[:top_p]            = profile[:top_p]
    @values[:top_k]            = profile[:top_k]
    @values[:min_p]            = profile[:min_p]
    @values[:presence_penalty] = profile[:presence_penalty]
    @values[:repeat_penalty]   = profile[:repeat_penalty]
    @values[:active_model]     = profile[:name] || profile[:model]
    @values[:vision]           = profile[:vision] == true
    @values[:mcp_image_limits] = profile[:mcp_images] if profile[:mcp_images]
  end

  # The effective value of an adjustable parameter, or nil when unset (the
  # server's default applies). param_set writes it (used by ParamOverrides).
  def param(key)
    @values[key.to_sym]
  end

  def param_set(key, value)
    @values[key.to_sym] = value
  end

  def param_overrideable?(key)
    PARAM_KEYS.key?(key.to_sym)
  end
end
