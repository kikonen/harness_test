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
        @ui.puts "No skills defined (#{skills.dir})."
        @ui.puts "Add one at #{Skills::DIR}/<name>/SKILL.md - a written-down procedure."
        return
      end

      @ui.puts "Skills (#{all.size}):"
      all.each { |s| @ui.puts "  #{s.name} - #{s.description}" }
      @ui.puts "Show one with: /skills <name>"
    end

    def show_skill(skills, requested)
      name = skills.normalize_name(requested)
      if name.nil?
        @ui.puts "[error] a skill name is one path segment: #{requested}"
        return
      end

      body = skills.body(name)
      if body.nil?
        @ui.puts "[error] no skill named '#{name}' (#{available_hint(skills)})"
        return
      end

      rule = "-" * [1, 60 - name.length].max
      @ui.puts "--- #{name} (#{Skills::DIR}) #{rule}"
      body.each_line { |line| @ui.print line }
      @ui.puts unless body.end_with?("\n")
    end

    def available_hint(skills)
      names = skills.names
      names.empty? ? "no skills defined" : names.join(", ")
    end
  end
end
