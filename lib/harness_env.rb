# frozen_string_literal: true

# -- HarnessEnv -----------------------------------------------------------
#
# Centralised ENV access for the harness. In Ruby, "" is truthy, so a plain
# ENV[key] || default would let an empty export (e.g. `export HARNESS_TOKEN=`)
# slip through as a valid value. This module returns nil for unset OR
# empty/whitespace-only values, so callers can safely use `||` fallbacks.
module HarnessEnv
  def self.get(key)
    val = ENV[key]
    val.nil? || val.strip.empty? ? nil : val
  end
end
