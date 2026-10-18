# frozen_string_literal: true

require_relative "../harness_error"

# Named SGR palettes for rendered output lines. A palette maps an output ROLE
# to SGR parameters (nil = the terminal's own color); the renderer decides the
# label, the palette decides the color, and neither is consulted by an emitter.
# Why these colors and which ones this terminal rejected:
# doc/output_rendering_design.md.
module UI
  class Palette
    # Dark 16-color band hues (30..36) plus two extended-ramp entries the
    # owner's light-background terminal measured as readable: a real dark gray
    # for recessive lines (SGR 90 reads as light gray there) and a brown for
    # warnings (plain yellow is too close to the rejected bright yellow).
    GRAY  = "38;5;240"
    BROWN = "38;5;130"

    PALETTES = {
      "default" => {
        step_label: GRAY,
        plan: "34",
        interstitial: "35",
        tool_plan: "32",
        response: nil,
        warn: BROWN,
        error: "31",
        system: GRAY,
        stats: GRAY,
        compact: BROWN,
        text: nil
      },
      # No 256-color or truecolor dependency: recessive roles fall back to the
      # terminal's own color, so this works on a terminal with a 16-color
      # palette only. Warning moves to the dark yellow of the 16-color band.
      "basic16" => {
        step_label: nil,
        plan: "34",
        interstitial: "35",
        tool_plan: "32",
        response: nil,
        warn: "33",
        error: "31",
        system: nil,
        stats: nil,
        compact: "33",
        text: nil
      },
      # Every role uncolored: what --no-color selects.
      "none" => {}.freeze
    }.freeze

    DEFAULT_NAME = "default"

    attr_reader :name

    def self.names
      PALETTES.keys
    end

    # No name means the DEFAULT palette (colors on), not a plain renderer:
    # "colored by default" is what issue #303 asks for. An unknown name raises
    # rather than rendering plain, so a typo in a flag or a config key is
    # reported at startup instead of looking like a broken terminal.
    def self.fetch(name)
      return new(DEFAULT_NAME) if name.nil? || name.to_s.strip.empty?

      new(validate!(name))
    end

    def self.validate!(name)
      key = name.to_s.strip
      return key if PALETTES.key?(key)

      raise HarnessError,
        "unknown output palette #{name.inspect} (available: #{names.join(', ')})"
    end

    def initialize(name)
      key = name.to_s
      raise HarnessError, "unknown palette #{name.inspect}" unless PALETTES.key?(key)

      @name   = key
      @colors = PALETTES[key]
    end

    def color_for(type)
      @colors[type.to_sym]
    end

    # Wraps the WHOLE line and resets at the end, so a color can never bleed
    # into the next line (a partial wrap survives a terminal line wrap).
    def paint(type, text)
      code = color_for(type)
      return text if code.nil? || code.empty?

      "\e[#{code}m#{text}\e[0m"
    end
  end
end
