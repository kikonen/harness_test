# frozen_string_literal: true

require 'yaml'
require 'fileutils'

require_relative 'harness_error'

# -- HarnessConfig --------------------------------------------------------
#
# Central configuration, loaded from a YAML config file. This replaces the
# old per-value ENV-based configuration (HARNESS_MODEL, HARNESS_BASE_URL,
# HARNESS_TOKEN, HARNESS_NUM_CTX, ...) which had become unmanageable.
#
# Precedence for every setting is:
#   CLI flag  >  config file  >  built-in default (constants in harness.rb)
#
# Config file schema (every key is optional; missing keys fall back to the
# built-in defaults):
#
#   models:                     # one or more named model profiles
#     - name: local             # selection key (used by -m / default_model)
#       url: http://localhost:11434/v1
#       model: qwen2.5-coder:32b
#       token: sk-...           # optional bearer token
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
#     recent_messages: 3        # messages retained verbatim after /compact
#     max_size: 500             # max length (words) of the compaction summary
#   retry:
#     count: 3                  # total attempts for transient network errors
#     delay: 2                  # base delay (seconds) between retries
#   system: |                   # full system prompt (overrides the built-in)
#     You are a precise code editor...
#
class HarnessConfig
  HARNESS_DIR = '.harness'

  # Template written to the default config location on first run (when no
  # config file is found anywhere), so the user has something concrete to
  # edit instead of discovering the schema from the docs. Values mirror the
  # built-in defaults in harness.rb, so auto-creation changes nothing.
  DEFAULT_TEMPLATE = <<~YAML
    # Harness configuration (YAML).
    #
    # Precedence for every setting: CLI flag > this file > built-in default.
    # Every key is optional - missing keys fall back to built-in defaults.

    # One or more named model profiles.
    models:
      - name: local            # selection key (used by -m / default_model)
        url: http://localhost:11434/v1
        model: qwen2.5-coder:32b
        # token: sk-...        # optional bearer token
        num_ctx: 65536         # context window size (tokens)
        reasoning_effort: medium
        temperature: 0.6
        top_p: 0.95
        top_k: 20              # sampling top-k (integer)
        min_p: 0               # minimum probability threshold
        presence_penalty: 1.0  # penalty for already-present tokens
        repeat_penalty: 1.05   # penalty for repeated tokens

    # Model used when -m is not given on the command line.
    default_model: local

    # Session compaction (/compact).
    compact:
      recent_messages: 6       # messages retained verbatim after /compact
      max_size: 500            # max length (words) of the compaction summary

    # Automatic retries for transient network errors.
    retry:
      count: 3                 # total attempts (1 initial + N-1 retries)
      delay: 2                 # base delay in seconds (exponential backoff)

    # Full system prompt override (uncomment to use).
    # --system-file still takes precedence.
    # system: |
    #   You are a precise code editor...
  YAML

  attr_reader :models, :default_model, :system

  def initialize(data = {})
    data          = {} if data.nil?
    @raw          = data
    @models       = normalize_models(Array(data['models']))
    @default_model = nonblank(data['default_model'])
    @system       = nonblank(data['system'])
    @compact      = {
      recent_messages: int_or_nil(data.dig('compact', 'recent_messages')),
      max_size:        int_or_nil(data.dig('compact', 'max_size'))
    }
    @retry        = {
      count: int_or_nil(data.dig('retry', 'count')),
      delay: float_or_nil(data.dig('retry', 'delay'))
    }
  end

  # Load the config from the first existing file among the candidates.
  # When no config file exists anywhere, a default template is written to
  # .harness/config.yml (inside the working directory) so the user has a
  # concrete starting point to edit. Best-effort: if that location cannot
  # be written (read-only workdir, ...), loading simply continues with
  # built-in defaults. An explicitly given config path (-c) that does not
  # exist is NOT auto-created - that is a user error, not a first run.
  def self.load(cli_path, workdir)
    path = find_file(cli_path, workdir)
    if path.nil?
      target = File.join(workdir, HARNESS_DIR, 'config.yml') if workdir
      # Only auto-create when the user did not explicitly point at a file.
      write_default_template(target) if target && cli_path.nil?
      return new({})
    end

    new(parse(path))
  end

  # Write the default template to path (creating parent directories).
  # Never overwrites an existing file. Returns true when written.
  def self.write_default_template(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, DEFAULT_TEMPLATE)
    true
  rescue SystemCallError => e
    warn "  [config] could not write default config to #{path}: #{e.message}"
    false
  end

  # Candidate config file paths, in priority order. The first existing one wins.
  def self.default_paths(workdir)
    paths = []
    paths << ENV['HARNESS_CONFIG'] if ENV['HARNESS_CONFIG']
    paths << File.join(workdir, HARNESS_DIR, 'config.yml') if workdir
    paths << File.join(Dir.home, '.config', 'harness', 'config.yml')
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

  # Parse a YAML config file into a plain hash.
  def self.parse(path)
    YAML.safe_load(File.read(path)) || {}
  rescue Psych::SyntaxError => e
    raise HarnessError, "invalid config file #{path}: #{e.message}"
  end

  # True when at least one model profile is configured.
  def models_configured?
    !@models.empty?
  end

  # Number of recent messages retained verbatim after compaction (or nil).
  def compact_recent_messages
    @compact[:recent_messages]
  end

  # Max length (words) of the compaction summary (or nil).
  def compact_max_size
    @compact[:max_size]
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
    raise HarnessError, 'no model selected and no default_model configured' if key.nil?

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
        name:             nonblank(m['name']),
        url:              nonblank(m['url']),
        model:            nonblank(m['model']),
        token:            nonblank(m['token']),
        num_ctx:          int_or_nil(m['num_ctx']),
        reasoning_effort: nonblank(m['reasoning_effort']),
        temperature:      float_or_nil(m['temperature']),
        top_p:            float_or_nil(m['top_p']),
        top_k:            int_or_nil(m['top_k']),
        min_p:            float_or_nil(m['min_p']),
        presence_penalty: float_or_nil(m['presence_penalty']),
        repeat_penalty:   float_or_nil(m['repeat_penalty'])
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
end