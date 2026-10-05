# frozen_string_literal: true

require_relative '../command'

module Commands
  # /model <name> - switch the active model for this run.
  # /model        - show the currently active model.
  class ModelCommand < Command
    def handle(args)
      name = args.strip
      if name.empty?
        puts "Current model: #{@harness.session_manager.active_model_name} (@ #{@options[:base_url]})"
        puts "List models with /models, switch with /model <name>."
        return
      end

      profile = @harness.session_manager.switch_model(name)
      display = profile[:name] || profile[:model]
      url     = profile[:url] || @options[:base_url]
      puts "Switched to model: #{display} (#{profile[:model]} @ #{url})"
    end
  end
end
