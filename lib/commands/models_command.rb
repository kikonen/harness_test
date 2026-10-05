# frozen_string_literal: true

require_relative '../command'

module Commands
  # /models - list configured models (marks the default and active one).
  class ModelsCommand < Command
    def handle(_args)
      profiles = @harness.session_manager.model_profiles
      current  = @harness.session_manager.active_model_name

      if profiles.empty?
        puts "No model profiles configured."
        puts "Current model: #{current} (@ #{@options[:base_url]})"
        return
      end

      default_name = @harness.session_manager.default_model_name

      puts "Configured models (#{profiles.size}):"
      profiles.each do |p|
        name   = p[:name] || p[:model]
        marks  = []
        marks << 'default' if default_name && (name == default_name || p[:model] == default_name)
        marks << 'active'  if name == current
        suffix = marks.empty? ? '' : "   [#{marks.join(', ')}]"
        puts "  #{name}  ->  #{p[:model]} @ #{p[:url] || CLI::DEFAULT_BASE_URL}#{suffix}"
      end
      puts
      puts "Switch with: /model <name>   (current: #{current})"
    end
  end
end
