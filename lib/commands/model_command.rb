# frozen_string_literal: true

require_relative "../command"
require_relative "../param_overrides"

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
        # backend is visible at a glance. issue #449: image support is a
        # per-profile fact the parameter list does not cover (it is not a
        # generation parameter). The two facts are contiguous prose -> one note.
        images = @harness.session_manager.vision? ? "inlined to the model" \
                                                  : "files only (no vision declared)"
        emit_role(
          :note,
          [
            "Current model: #{@harness.session_manager.active_model_name} " \
              "(#{@harness.session_manager.target_display} @ #{@options[:base_url]})",
            "Tool-result images: #{images}"
          ])
        emit_params
        emit_role(
          :note,
          "List models with /models, switch with /model <name>, " \
          "adjust parameters with /param.")
        return
      end

      profile = @harness.session_manager.switch_model(name)
      display = profile[:name] || profile[:model]
      url     = profile[:url] || @options[:base_url]
      # issue #217: the API type can CHANGE with the profile - say it.
      emit_role(
        :note,
        "Switched to model: #{display} (#{profile[:model]} @ #{url}) " \
        "-> #{@harness.session_manager.target_display}")
      emit_params
    end

    private

    # issue #219: show every parameter for the active model with its current
    # (effective) value, marking which ones are session-level overrides. The
    # listing is shared with /param (ParamOverrides#list_items) so both
    # commands render the exact same table.
    def emit_params
      param = @harness.session_manager.param_overrides
      emit_list(
        title: ParamOverrides::LIST_TITLE,
        kind: :table,
        columns: %i[key value annotation],
        items: param.list_items,
        origin: "param")
    end
  end
end
