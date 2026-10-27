# frozen_string_literal: true

require_relative "../tool"
require_relative "../plans"

# Saves ONE plan: the agreed approach for a task, kept durable so it outlives
# the session that produced it and survives context compaction (issue #359).
# Writes go to the fixed store path the harness owns - no FileList grant is
# asked for, because a plan call can name ONLY one plan of the store and never
# a path. The write itself is recorded in harness.log by the harness' own
# tool-call line. Design and the open decisions: doc/planning_mode_design.md.
module Tools
  class PlanAddTool < Tool
    def initialize(plans)
      @plans = plans
      super(
        name: "plan.add",
        description: "Saves one plan: the agreed approach for a task (the goal, " \
          "the steps, the key decisions), kept durable so it survives context " \
          "compaction and later sessions in this project. Name it for the task " \
          "it covers; omit the name and a mnemonic one is generated. Text is " \
          "the plan itself (markdown), max #{Plans::MAX_BODY_CHARS} chars. At " \
          "most #{Plans::MAX_PLANS} plans exist: when the store is full this " \
          "refuses and you must delete plans that are done or superseded " \
          "(plan.list, plan.delete) before adding.",
        parameters: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Name of the plan (one path segment, e.g. " \
                "refactor-auth-flow). Omit it and a mnemonic name is generated."
            },
            text: {
              type: "string",
              description: "The plan itself (markdown, max " \
                "#{Plans::MAX_BODY_CHARS} chars)"
            },
            overwrite: {
              type: "boolean",
              description: "Replace an existing plan of this name (default " \
                "false: an existing name is refused so a plan is never lost by " \
                "accident)"
            }
          },
          required: %w[text]
        }
      )
    end

    def execute(args)
      plan = @plans.add(
        args["name"],
        args["text"],
        overwrite: args["overwrite"] == true)
      status(:ok, "#{plan.name} (#{plan.chars} chars)")
      "ok: saved plan '#{plan.name}' (#{plan.chars} chars) in #{Plans::DIR}/"
    rescue HarnessError => e
      # A refusal is returned, not raised: the message names the limit and the
      # way out, because re-sending the same call shape would fail identically.
      status(:fail, e.message[0, 80])
      "error: #{e.message}"
    end
  end
end
