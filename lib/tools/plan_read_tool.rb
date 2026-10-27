# frozen_string_literal: true

require_relative "../tool"
require_relative "../plans"

# Loads ONE plan's body (markdown) so the model can act on the agreed approach.
# The store is harness-owned - like a memory or a skill body - so reading it
# needs no FileList grant. doc/planning_mode_design.md.
module Tools
  class PlanReadTool < Tool
    def initialize(plans)
      @plans = plans
      super(
        name: "plan.read",
        description: "Loads the full body of one stored plan (markdown) and " \
          "returns it as background for the current task. Call plan.list or " \
          "plan.search first if you do not know the name. A name is one path " \
          "segment: one carrying a separator or '..' is refused, so this reads " \
          "plans, not arbitrary files.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Plan name (as listed by plan.list)"
            }
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

      body = @plans.body(name)
      if body.nil?
        status(:fail, "no such plan: #{name}")
        return "error: no plan named '#{name}' (#{@plans.available_hint})"
      end

      status(:ok, "#{name} (#{body.lines.size} lines)")
      body
    end
  end
end
