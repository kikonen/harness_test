# frozen_string_literal: true

require_relative '../command'

module Commands
  # /model <name> - switch the active model for this run.
  # /model        - show the currently active model.
  class ModelCommand < Command
    def handle(args)
      name = args.strip
      if name.empty?
        # issue #217: include the API type + endpoint path so the active
        # backend is visible at a glance.
        @ui.puts "Current model: #{@harness.session_manager.active_model_name} " \
                 "(#{@harness.session_manager.target_display} @ #{@options[:base_url]})"
        @ui.puts "List models with /models, switch with /model <name>."
        return
      end

      profile = @harness.session_manager.switch_model(name)
      display = profile[:name] || profile[:model]
      url     = profile[:url] || @options[:base_url]
      # issue #217: the API type can CHANGE with the profile - say it.
      @ui.puts "Switched to model: #{display} (#{profile[:model]} @ #{url}) " \
               "-> #{@harness.session_manager.target_display}"
    end
  end
end
