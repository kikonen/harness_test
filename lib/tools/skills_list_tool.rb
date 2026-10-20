# frozen_string_literal: true

require_relative "../tool"
require_relative "../skills"

# Meta-tool: lists the project's skills (name + one-line description). A skill body
# is never listed here - that is skills.read's job (issue #12).
module Tools
  class SkillsListTool < Tool
    def initialize(skills)
      @skills = skills
      super(
        name: "skills.list",
        description: "Lists the skills this project defines: name and one-line " \
          "description each. A skill is a written-down procedure for a repeatable " \
          "job: list them before improvising a multi-step job, then load the " \
          "matching one with skills.read(name).",
        parameters: {
          type: "object",
          properties: {},
          required: []
        }
      )
    end

    def execute(_args)
      skills = @skills.all
      if skills.empty?
        status(:info, "no skills defined")
        return "no skills defined (#{Skills::DIR}/ does not exist in this project)"
      end

      lines = skills.map { |s| "#{s.name} - #{s.description}" }
      status(:info, "#{lines.size} skill(s)")
      "Skills (#{lines.size}), load one with skills.read:\n#{lines.join("\n")}"
    end
  end
end
