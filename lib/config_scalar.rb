# frozen_string_literal: true

require_relative "harness_error"

# -- ConfigScalar ---------------------------------------------------------
#
# The scalar coercions config reading shares (HarnessConfig's other keys and a
# ModelProfile both need them): a config value is raw data, so each coercion
# raises a HarnessError on a bad value rather than silently coercing it.
module ConfigScalar
  # issue #422: a ${NAME} in a config string is the ENV of that name; a missing
  # reference is a config error (naming the var), never a silent empty.
  ENV_REF = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/
  # The keys that read as floats; every other numeric key reads as an integer.
  FLOAT_KEYS = %i[
    temperature top_p min_p presence_penalty repeat_penalty auto_threshold
  ].freeze

  module_function

  def nonblank(val)
    val = val.to_s.strip
    val.empty? ? nil : val
  end

  # Read a numeric config key as a float when key is one of FLOAT_KEYS, else an
  # integer - the one place int-vs-float is decided by key name.
  def number_or_nil(key, val)
    return nil if val.nil?

    FLOAT_KEYS.include?(key) ? float_or_nil(val) : int_or_nil(val)
  end

  def int_or_nil(val)
    return nil if val.nil?

    Integer(val)
  rescue ArgumentError, TypeError
    raise HarnessError, "expected an integer, got: #{val.inspect}"
  end

  def width_or_nil(val)
    return nil if val.nil?

    text = val.to_s
    return text if text.match?(/\A\d+%\z/)

    int_or_nil(val)
  end

  def float_or_nil(val)
    return nil if val.nil?

    Float(val)
  rescue ArgumentError, TypeError
    raise HarnessError, "expected a number, got: #{val.inspect}"
  end

  # A tri-state flag: true, false, or nil for "not configured" (so a profile
  # can leave the decision to a global key instead of overriding it).
  def bool_or_nil(val)
    return nil if val.nil?

    val == true
  end

  # Both outbound transports speak HTTP(S): a bad scheme fails deep inside
  # connect and reads as a broken server rather than a bad config. label names
  # the config entry the value came from.
  def http_url?(url)
    !url.nil? && url.start_with?("http://", "https://")
  end

  def require_http_url(label, url)
    if url && !http_url?(url)
      raise HarnessError, "#{label} url must start with http:// or https:// (got: #{url})"
    end
    raise HarnessError,
      "#{label} needs a 'url' (there is no built-in endpoint default)" if url.nil?

    url
  end

  # issue #422: replace every ${NAME} in a config string with the ENV of that
  # name. A missing reference is a config error (naming the var), never a silent
  # empty: an unset bearer token / MCP credential that quietly became "" would
  # only fail later as an opaque auth error. The lookup is ENV[name] - never
  # eval / ERB - so a config value cannot run code.
  def expand_env(val, label)
    return val unless val.is_a?(String) && ENV_REF.match?(val)

    val.gsub(ENV_REF) do
      name = Regexp.last_match(1)
      unless ENV.key?(name)
        raise HarnessError,
          "#{label} references \${#{name}} but #{name} is not set in the environment"
      end
      ENV[name]
    end
  end

  # The tool-result image limits (issue #449), as a hash of integers. An absent
  # key, a non-mapping, or an individual absent key all fall back to defaults:
  # the limits are a budget, so a half-typed block must not silently mean "no
  # budget". defaults names the built-in values (HarnessConfig owns them).
  def normalize_mcp_images(val, defaults)
    val = {} unless val.is_a?(Hash)

    defaults.to_h do |key, fallback|
      value = val[key]
      [key, value.nil? ? fallback : positive_int!(value)]
    end
  end

  # A limit is a budget: 0 or a negative value is not "no budget", it is a typo.
  def positive_int!(val)
    n = int_or_nil(val)
    unless n&.positive?
      raise HarnessError,
        "an mcp_images limit must be a positive integer, got: #{val.inspect}"
    end

    n
  end
end
