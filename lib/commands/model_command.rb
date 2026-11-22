# frozen_string_literal: true

require_relative "../command"
require_relative "../param_overrides"

module Commands
  # /model <id> - switch this run's connection to a configured profile by id.
  # /model      - show the currently active model and its parameters
  #                 (issue #219: every parameter plus the session overrides).
  class ModelCommand < Command
    HELP = CommandHelp.new(
      usage: "model [id]",
      summary: "Show the active model (with every parameter and its session " \
               "override), or switch it for this run",
      group: :model,
      forms: ["model", "model <id>"],
      see_also: %w[models param])

    def handle(args)
      name = args.strip
      if name.empty?
        # issue #217: include the API type + endpoint path so the active
        # backend is visible at a glance. issue #449: image support is a
        # per-profile fact the parameter list does not cover (it is not a
        # generation parameter). The two facts are contiguous prose -> one note.
        images = foreground_harness.session_manager.vision? ? "inlined to the model" \
                                                  : "files only (no vision declared)"
        emit_role(
          :note,
          [
            "Current model: #{foreground_harness.session_manager.active_profile_name} " \
              "(#{foreground_harness.session_manager.target_display} " \
              "@ #{foreground_harness.model_config.base_url})",
            "Tool-result images: #{images}"
          ])
        emit_params
        emit_role(
          :note,
          "List models with /models, switch with /model <id>, " \
          "adjust parameters with /param.")
        return
      end

      profile = foreground_harness.session_manager.switch_profile(name)
      # The name is the profile's display label; its model: is what the endpoint gets asked for.
      id      = profile[:id]
      display = profile[:name] || id
      url     = profile[:url] || foreground_harness.model_config.base_url
      # issue #217: the API type can CHANGE with the profile - say it.
      emit_role(
        :note,
        "Switched to model: #{display} (#{id} @ #{url}) " \
        "-> #{foreground_harness.session_manager.target_display}")
      emit_params
    end

    private

    # issue #219: show every parameter for the active model with its current
    # (effective) value, marking which ones are session-level overrides. The
    # listing is shared with /param (ParamOverrides#list_items) so both
    # commands render the exact same table.
    def emit_params
      param = foreground_harness.session_manager.param_overrides
      emit_list(
        title: ParamOverrides::LIST_TITLE,
        kind: :table,
        columns: %i[key value annotation],
        items: param.list_items,
        origin: "param")
    end
  end
end
