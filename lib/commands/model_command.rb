# frozen_string_literal: true

require_relative "../command"

module Commands
  # /model <name> - switch the active model for this run.
  # /model        - show the currently active model and its parameters
  #                 (issue #219: every parameter plus the session overrides).
  class ModelCommand < Command
    HELP = CommandHelp.new(
      usage: "model [name]",
      summary: "Show the active model (with every parameter and its session " \
               "override), or switch it for this run",
      group: :model,
      forms: ["model", "model <name>"],
      see_also: %w[models param])

    def handle(args)
      name = args.strip
      if name.empty?
        # issue #217: include the API type + endpoint path so the active
        # backend is visible at a glance.
        @ui.puts "Current model: #{@harness.session_manager.active_model_name} " \
                 "(#{@harness.session_manager.target_display} @ #{@options[:base_url]})"
        print_params
        @ui.puts "List models with /models, switch with /model <name>, " \
                 "adjust parameters with /param."
        return
      end

      profile = @harness.session_manager.switch_model(name)
      display = profile[:name] || profile[:model]
      url     = profile[:url] || @options[:base_url]
      # issue #217: the API type can CHANGE with the profile - say it.
      @ui.puts "Switched to model: #{display} (#{profile[:model]} @ #{url}) " \
               "-> #{@harness.session_manager.target_display}"
      print_params
    end

    private

    # issue #219: show every parameter for the active model with its current
    # (effective) value, marking which ones are session-level overrides. The
    # listing is shared with /param (ParamOverrides#list_display) so both
    # commands print the exact same format.
    def print_params
      param = @harness.session_manager.param_overrides
      param.list_display.each { |line| @ui.puts line }
    end
  end
end
