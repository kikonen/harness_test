# frozen_string_literal: true

require "yaml"

require_relative "harness_error"

# Which tools an agent of a given kind is GIVEN (issue #286).
module ToolManifest
  DEFAULT_FILE = File.expand_path("../config/tool_manifests.yml", __dir__)

  # The YAML value that means "every tool the run built".
  FULL = "full"

  class << self
    attr_accessor :file

    def names_for(kind, registry)
      return registry.names if kind.nil? || kind == FULL

      names = manifests[kind.to_sym]
      raise HarnessError, "no tool manifest for job kind #{kind} in #{path}" if names.nil?
      return registry.names if names == FULL

      missing = names.reject { |name| registry.get(name) }
      msg = "tool manifest #{kind} names tools the run does not have: " \
        "#{missing.join(', ')}"
      raise HarnessError, msg if missing.any?

      names
    end

    def manifests
      @manifests ||= load
    end

    def path
      file || DEFAULT_FILE
    end

    private

    def load
      return {} unless File.file?(path)

      data = YAML.safe_load(File.read(path), symbolize_names: true) || {}
      data.each_with_object({}) do |(kind, entry), out|
        out[kind.to_sym] =
          if entry == FULL
            FULL
          elsif entry.is_a?(Array)
            entry.map(&:to_s)
          else
            msg = "tool manifest #{kind} in #{path} is neither '#{FULL}' nor a list"
            raise HarnessError, msg
          end
      end
    rescue Psych::SyntaxError => e
      raise HarnessError, "invalid tool manifest file #{path}: #{e.message}"
    end
  end
end
