# frozen_string_literal: true

require_relative "../command"

module Commands
  # /models - list configured models (marks the default and active one).
  class ModelsCommand < Command
    HELP = CommandHelp.new(
      usage: "models",
      summary: "List the configured model profiles (model, endpoint, API " \
        "type), marking the default and the active one",
      group: :model,
      see_also: %w[model param])

    def handle(_args)
      # Every model fact - the catalogue and the resolved profile - is run-wide
      # state read straight from the settings (#286), not routed through Harness.
      profiles = @settings.model_profiles
      current  = @settings.resolved_profile_id

      if profiles.empty?
        # Contiguous prose -> ONE note call, two paragraphs (the renderer owns
        # the wrap, not the emitter - #470).
        emit_role(
          :note,
          [
            "No model profiles configured.",
            "Current model: #{current} (no endpoint configured)"
          ])
        return
      end

      default_id = @settings.default_profile_id

      # issue #474: the listing is STRUCTURE (title + per-profile fields). It is
      # a :table, not the old :arrow row: that template read item[:name] as the
      # left column and item[:model] as the arrow target, which mixed the
      # profile's display name up with the id sent to the endpoint (#556
      # vocabulary). Each fact is its own named column - the column names say
      # what each cell is.
      items = profiles.map do |p|
        id = p[:id] || p[:name]
        display = p[:name] || id
        marks  = []
        marks << "default" if default_id && id == default_id
        marks << "active"  if id == current
        # issue #217: tag the API type so it is obvious which endpoint a
        # profile hits (openai -> /v1-compatible, ollama -> native /api/chat);
        # issue #449: vision is a per-profile fact, so the listing says which
        # models a tool-result image could actually be sent to. Both are their
        # own cells of the flags column rather than a fused suffix on the row.
        api = p[:api] || "openai"
        flags = marks.dup
        flags << "vision" if p[:vision]
        { name: display, id:, model: p[:model], url: p[:url], api:, flags: flags.join(", ") }
      end
      emit_list(
        title: "Configured models (#{profiles.size}):",
        kind: :table,
        columns: %i[name id model url api flags],
        items:,
        gap: true,
        footer: ["Switch with: /model <id>   (current: #{current})"],
        origin: "models")
    end
  end
end
