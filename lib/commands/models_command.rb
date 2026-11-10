# frozen_string_literal: true

require_relative "../command"
require_relative "../cli_options"

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
      profiles = @harness.session_manager.model_profiles
      current  = @harness.session_manager.active_model_name

      if profiles.empty?
        @ui.puts "No model profiles configured."
        @ui.puts "Current model: #{current} (@ #{@options[:base_url]})"
        return
      end

      default_name = @harness.session_manager.default_model_name

      # issue #474: emit the listing as STRUCTURE (title + per-profile fields),
      # not a fused row string, so the run record and a future remote sink carry
      # the fields themselves. UI::Renderer#arrow_row reproduces the old
      # `  name -> model @ url` line byte-for-byte. The note field is the tag +
      # mark suffix exactly as the old line appended them.
      items = profiles.map do |p|
        name   = p[:name] || p[:model]
        marks  = []
        marks << "default" if default_name && (name == default_name || p[:model] == default_name)
        marks << "active"  if name == current
        suffix = marks.empty? ? "" : "   [#{marks.join(', ')}]"
        # issue #217: tag the API type so it is obvious which endpoint a
        # profile hits (openai -> /v1-compatible, ollama -> native /api/chat).
        api = p[:api] || "openai"
        # issue #449: vision is a per-profile fact, so the listing says which
        # models a tool-result image could actually be sent to.
        url  = p[:url] || CLIOptions::DEFAULT_BASE_URL
        tags = p[:vision] ? " (#{api}) [vision]" : " (#{api})"
        { name:, model: p[:model], location: url, note: "#{tags}#{suffix}" }
      end
      emit_list(
        title: "Configured models (#{profiles.size}):",
        kind: :arrow,
        columns: %i[name model location note],
        items:,
        gap: true,
        footer: ["Switch with: /model <name>   (current: #{current})"],
        origin: "models")
    end
  end
end
