# frozen_string_literal: true

require_relative "../command"
require_relative "../skills"

module Commands
  # /skills - list the project's skills, or print one skill's body.
  #
  # The same data the model sees through skills.list / skills.read: one renderer for
  # both sides, so what the user checks and what the model reads cannot drift apart.
  class SkillsCommand < Command
    HELP = CommandHelp.new(
      usage: "skills [name]",
      forms: ["skills", "skills <name>"],
      summary: "List the project's skills (.harness/skills/), or print one skill's body",
      group: :session,
      see_also: %w[reload tools])

    def handle(args)
      skills = @harness.skills
      name   = args.to_s.strip

      return list_skills(skills) if name.empty?

      show_skill(skills, name)
    end

    private

    def list_skills(skills)
      all = skills.all
      if all.empty?
        # The empty-state guidance is contiguous prose -> ONE note call.
        emit_role(
          :note,
          [
            "No skills defined (#{skills.dir}).",
            "Add one at #{Skills::DIR}/<name>/SKILL.md " \
              "- a written-down procedure."
          ])
        return
      end

      emit_list(
        title: "Skills (#{all.size}):",
        kind: :kv,
        columns: %i[name description],
        items: all.map { |s| { name: s.name, description: s.description } },
        footer: ["Show one with: /skills <name>"],
        origin: "skills")
    end

    def show_skill(skills, requested)
      name = skills.normalize_name(requested)
      if name.nil?
        emit_status(
          label: "skills",
          verdict: :fail,
          message: "a skill name is one path segment: #{requested}")
        return
      end

      body = skills.body(name)
      if body.nil?
        emit_status(
          label: "skills",
          verdict: :fail,
          message: "no skill named '#{name}' (#{available_hint(skills)})")
        return
      end

      rule = "-" * [1, 60 - name.length].max
      emit_role(:rule, "--- #{name} (#{Skills::DIR}) #{rule}")
      emit_role(:text, body)
    end

    def available_hint(skills)
      names = skills.names
      names.empty? ? "no skills defined" : names.join(", ")
    end
  end
end
