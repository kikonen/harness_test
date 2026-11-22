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

      # issue #474: emit the listing as STRUCTURE (title + per-profile fields),
      # not a fused row string, so the run record and a future remote sink carry
      # the fields themselves. UI::Renderer#row_for draws the arrow row: a
      # profile's id is what the endpoint is asked for, so the row reads
      # `display name  ->  profile id @ url`. The note field is the tag + mark
      # suffix exactly as the old line appended them.
      items = profiles.map do |p|
        id = p[:id] || p[:name]
        display = p[:name] || id
        marks  = []
        marks << "default" if default_id && id == default_id
        marks << "active"  if id == current
        suffix = marks.empty? ? "" : "   [#{marks.join(', ')}]"
        # issue #217: tag the API type so it is obvious which endpoint a
        # profile hits (openai -> /v1-compatible, ollama -> native /api/chat).
        api = p[:api] || "openai"
        # issue #449: vision is a per-profile fact, so the listing says which
        # models a tool-result image could actually be sent to.
        url  = p[:url]
        tags = p[:vision] ? " (#{api}) [vision]" : " (#{api})"
        { name: display, model: id, location: url, note: "#{tags}#{suffix}" }
      end
      emit_list(
        title: "Configured models (#{profiles.size}):",
        kind: :arrow,
        columns: %i[name model location note],
        items:,
        gap: true,
        footer: ["Switch with: /model <id>   (current: #{current})"],
        origin: "models")
    end
  end
end
