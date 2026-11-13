# frozen_string_literal: true

require_relative "../command"
require_relative "../plans"

module Commands
  # /plans - list the project's stored plans numbered, or print one body.
  #
  # The same data the model sees through plan.list / plan.read: one reader
  # (Plans) behind both sides, so what the owner inspects and what the model
  # reads cannot drift apart (the same shape as /memory and /skills). Issue #359.
  #
  # A body is a MARKDOWN file (issue #416): the command states the RAW text as the
  # :body role and UI::Renderer renders it, so this command owns no renderer of its
  # own (#474). With a palette the headings/bold/code/lists are styled; palette
  # 'none' renders plain marker-free text, and a sink with no palette prints the
  # body as stored.
  class PlansCommand < Command
    HELP = CommandHelp.new(
      usage: "plans [name|N]",
      forms: ["plans", "plans <name>", "plans <N>"],
      summary: "List the project's plans (#{Plans::DIR}/) numbered, " \
        "or print one plan's body by name or by its number",
      group: :session,
      see_also: %w[memory skills session])

    def handle(args)
      arg = args.to_s.strip

      return list_plans if arg.empty?

      show_plan(arg)
    end

    private

    def plans
      @harness.plans
    end

    # The listing IS the numbering: the number printed here is the number
    # "plans N" opens. Plans#all sorts by name, so it is stable between calls,
    # but a plan added or deleted shifts it - which is why a name always works.
    def list_plans
      all = plans.all
      if all.empty?
        # The empty-state guidance is contiguous prose -> ONE note call.
        emit_role(
          :note,
          [
            "No plans stored (#{plans.dir}).",
            "The model saves one with plan.add(name:, text:); " \
              "the file is #{Plans::DIR}/<name>.md."
          ])
        return
      end

      emit_list(
        title: "Plans (#{all.size}/#{Plans::MAX_PLANS} plans, " \
          "#{Plans::MAX_BODY_CHARS} chars max each):",
        kind: :numbered_kv,
        columns: %i[number name description annotation],
        items: listing_items(all),
        footer: ["Show one with: /plans <name>  or  /plans <N>"],
        origin: "plans")
    end

    def listing_items(all)
      all.map.with_index do |plan, i|
        {
          number: i + 1,
          name: plan.name,
          description: plan.description,
          annotation: " (#{plan.chars} chars)"
        }
      end
    end

    def show_plan(requested)
      all   = plans.all
      index = list_index(requested, all.size)

      if index
        plan = all[index]
        return show_body(plan.name, plans.body(plan.name), index)
      end

      name = plans.normalize_name(requested)
      if name.nil?
        emit_status(
          label: "plans",
          verdict: :fail,
          message: "a plan name is one path segment, or a plan number: #{requested}")
        return
      end

      body = plans.body(name)
      if body.nil?
        emit_status(
          label: "plans",
          verdict: :fail,
          message: "no plan named '#{name}' (#{available_hint(all)})")
        return
      end

      # A name lookup prints the header the way it always did - the number is
      # only shown when the user asked WITH a number.
      show_body(name, body, nil)
    end

    # A purely numeric argument indexes the listing (1-based, same order) only
    # while it is IN RANGE: a plan genuinely named "3" stays reachable when
    # there are fewer than three plans.
    def list_index(requested, count)
      return nil unless requested.match?(/\A\d+\z/)

      number = requested.to_i
      number.between?(1, count) ? number - 1 : nil
    end

    def show_body(name, body, index)
      return if body.nil?

      emit_role(:rule, header(name, index))
      emit_role(:body, body)
    end

    def header(name, index)
      # nil-safe on purpose: 0 is a LEGITIMATE index and 0 is truthy, so a
      # plain `index ?` would still be right here but reads like a bug.
      title = index.nil? ? "--- #{name}" : "--- #{index + 1}. #{name}"
      title = "#{title} (#{Plans::DIR})"
      "#{title} #{'-' * [1, 60 - title.length].max}"
    end

    def available_hint(all)
      names = all.map(&:name)
      names.empty? ? "no plans stored" : names.join(", ")
    end
  end
end
