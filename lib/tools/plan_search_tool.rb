# frozen_string_literal: true

require_relative "../tool"
require_relative "../plans"

# Searches the project's stored plans by substring (issue #359: the model can
# search plans - the capability memory.list deliberately omits, because a plan
# store is expected to outgrow a listable one). Matches names AND bodies,
# case-insensitively. No ranking: every match is returned, the model reads what
# it finds.
module Tools
  class PlanSearchTool < Tool
    def initialize(plans)
      @plans = plans
      super(
        name: "plan.search",
        description: "Searches the project's stored plans by a query " \
          "(case-insensitive substring over plan names and bodies). Returns the " \
          "matching plans' index lines (name + description). Use it to find a " \
          "plan before drafting a duplicate. Read a match with plan.read(name).",
        parameters: {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Substring to match against plan names and bodies"
            }
          },
          required: ["query"]
        }
      )
    end

    def execute(args)
      query = args["query"].to_s.strip
      if query.empty?
        status(:fail, "empty query")
        return "error: plan.search needs a non-empty query (plan.list shows every plan)"
      end

      matches = @plans.search(query)
      if matches.empty?
        status(:info, "no plans match #{query.inspect}")
        return "no plans match #{query.inspect} (#{@plans.count} stored)"
      end

      status(:info, "#{matches.size} plan(s) match #{query.inspect}")
      lines = matches.map { |p| "#{p.name} - #{p.description}" }
      "Plans matching #{query.inspect} (#{matches.size}), read one with " \
        "plan.read:\n#{lines.join("\n")}"
    end
  end
end
