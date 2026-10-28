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

      @ui.puts "Configured models (#{profiles.size}):"
      profiles.each do |p|
        name   = p[:name] || p[:model]
        marks  = []
        marks << "default" if default_name && (name == default_name || p[:model] == default_name)
        marks << "active"  if name == current
        suffix = marks.empty? ? "" : "   [#{marks.join(', ')}]"
        # issue #217: tag the API type so it is obvious which endpoint a
        # profile hits (openai -> /v1-compatible, ollama -> native /api/chat).
        api = p[:api] || "openai"
        @ui.puts "  #{name}  ->  #{p[:model]} @ #{p[:url] || CLIOptions::DEFAULT_BASE_URL} (#{api})#{suffix}"
      end
      @ui.puts
      @ui.puts "Switch with: /model <name>   (current: #{current})"
    end
  end
end
