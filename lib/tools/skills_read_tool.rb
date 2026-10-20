# frozen_string_literal: true

require_relative "../tool"

# Meta-tool: loads ONE skill's body (markdown, front matter stripped) so the model
# can follow the procedure it names. The body is harness-owned instruction content -
# like harness.md and the base prompt file - so reading it needs no FileList grant;
# writing a skill still goes through the normal file tools. doc/skills_design.md.
module Tools
  class SkillsReadTool < Tool
    def initialize(skills)
      @skills = skills
      super(
        name: "skills.read",
        description: "Loads the full body of one named skill (markdown) and returns it " \
          "as instructions to follow for the current task. Call skills.list first if " \
          "you do not know the name. A name is one path segment: one carrying a " \
          "separator or '..' is refused, so this reads skills, not arbitrary files.",
        parameters: {
          type: "object",
          properties: {
            name: { type: "string", description: "Skill name (as listed by skills.list)" }
          },
          required: ["name"]
        }
      )
    end

    def execute(args)
      raw  = args["name"]
      name = @skills.normalize_name(raw)

      if name.nil?
        status(:fail, "invalid skill name")
        return "error: 'name' must be one path segment " \
          "(no separator, no '..'): #{raw.inspect}"
      end

      body = @skills.body(name)
      if body.nil?
        status(:fail, "no such skill: #{name}")
        return "error: no skill named '#{name}' (#{available_hint})"
      end

      status(:ok, "#{name} (#{body.lines.size} lines)")
      body
    end

    private

    # The failure line names what IS available, so the model can pick a real name
    # instead of guessing again.
    def available_hint
      names = @skills.names
      names.empty? ? "no skills defined" : "available: #{names.join(', ')}"
    end
  end
end
