# frozen_string_literal: true

require_relative "../tool"
require_relative "../plans"

# Removes ONE plan (issue #359). Deleting a plan is not a file delete: it takes
# no DELETE grant because the argument is a plan NAME, never a path, and the
# removal is recorded in harness.log by the harness' own tool-call line.
module Tools
  class PlanDeleteTool < Tool
    def initialize(plans)
      @plans = plans
      super(
        name: "plan.delete",
        description: "Removes one stored plan by NAME (not a path). Use it when " \
          "a plan is done or superseded - a stale plan is worse than none, " \
          "because a later session reads it as the agreed approach. Takes no " \
          "DELETE grant; the removal is recorded in harness.log.",
        parameters: {
          type: "object",
          properties: {
            name: { type: "string", description: "Name of the plan to remove" }
          },
          required: ["name"]
        }
      )
    end

    def execute(args)
      raw  = args["name"]
      name = @plans.normalize_name(raw)

      if name.nil?
        status(:fail, "invalid plan name")
        return "error: #{@plans.name_error(raw)}"
      end

      removed = @plans.delete(name)
      if removed.nil?
        status(:fail, "no such plan: #{name}")
        return "error: no plan named '#{name}' (#{@plans.available_hint})"
      end

      status(:ok, "#{removed} removed")
      "ok: removed plan '#{removed}' (#{@plans.count} left)"
    end
  end
end
