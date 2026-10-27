# frozen_string_literal: true

require_relative "../command"
require_relative "../plans"

module Commands
  # /plans - list the project's stored plans, or print one plan's body.
  #
  # The same data the model sees through plan.list / plan.read: one reader
  # (Plans) behind both sides, so what the owner inspects and what the model
  # reads cannot drift apart (the same shape as /memory and /skills). Issue #359.
  class PlansCommand < Command
    HELP = CommandHelp.new(
      usage: "plans [name]",
      forms: ["plans", "plans <name>"],
      summary: "List the project's plans (#{Plans::DIR}/), " \
        "or print one plan's body",
      group: :session,
      see_also: %w[memory skills session])

    def handle(args)
      name = args.to_s.strip

      return list_plans if name.empty?

      show_plan(name)
    end

    private

    def plans
      @harness.plans
    end

    def list_plans
      all = plans.all
      if all.empty?
        @ui.puts "No plans stored (#{plans.dir})."
        @ui.puts "The model saves one with plan.add(name:, text:); " \
          "the file is #{Plans::DIR}/<name>.md."
        return
      end

      @ui.puts "Plans (#{all.size}/#{Plans::MAX_PLANS} plans, " \
        "#{Plans::MAX_BODY_CHARS} chars max each):"
      all.each { |p| @ui.puts "  #{p.name} - #{p.description} (#{p.chars} chars)" }
      @ui.puts "Show one with: /plans <name>"
    end

    def show_plan(requested)
      name = plans.normalize_name(requested)
      if name.nil?
        @ui.puts "[error] a plan name is one path segment: #{requested}"
        return
      end

      body = plans.body(name)
      if body.nil?
        @ui.puts "[error] no plan named '#{name}' (#{available_hint})"
        return
      end

      rule = "-" * [1, 60 - name.length].max
      @ui.puts "--- #{name} (#{Plans::DIR}) #{rule}"
      body.each_line { |line| @ui.print line }
      @ui.puts unless body.end_with?("\n")
    end

    def available_hint
      names = plans.names
      names.empty? ? "no plans stored" : names.join(", ")
    end
  end
end
