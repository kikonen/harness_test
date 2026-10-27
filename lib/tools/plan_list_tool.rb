# frozen_string_literal: true

require_relative "../tool"
require_relative "../plans"

# Lists the project's stored plans: name, one-line description, and how many of
# the available slots are used. A plan's BODY is never listed here - that is
# plan.read's job (issue #359).
module Tools
  class PlanListTool < Tool
    def initialize(plans)
      @plans = plans
      super(
        name: "plan.list",
        description: "Lists this project's stored plans (name + one-line " \
          "description each) and how many of the available slots are used. " \
          "A plan is the agreed approach for a task, kept durable so it " \
          "survives context compaction and later sessions. List them before " \
          "drafting a new one. Read one with plan.read(name); search with " \
          "plan.search(query).",
        parameters: {
          type: "object",
          properties: {},
          required: []
        }
      )
    end

    def execute(_args)
      plans = @plans.all
      if plans.empty?
        status(:info, "no plans stored")
        return "no plans stored (#{Plans::DIR}/ is empty) - " \
          "save one with plan.add(name:, text:)"
      end

      status(:info, "#{plans.size}/#{Plans::MAX_PLANS} plans")
      lines = plans.map { |p| "#{p.name} - #{p.description}" }
      "Plans (#{plans.size}/#{Plans::MAX_PLANS}), read one with " \
        "plan.read:\n#{lines.join("\n")}"
    end
  end
end
