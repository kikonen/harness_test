# frozen_string_literal: true

require_relative "../command"
require_relative "../plans"
require_relative "store_listing"

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
  #
  # The listing is a :table with its own number column (#474, increment 20) and the
  # row/selector/rule shape comes from StoreListing, shared with /memory. The
  # renderer's :numbered_kv kind is gone: inside a kramdown table the gem owns the
  # column width, so the ordinal alignment the flat kind provided has no job left.
  class PlansCommand < Command
    include StoreListing

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
        kind: :table,
        columns: %i[number name description chars],
        items: listing_rows(all),
        footer: ["Show one with: /plans <name>  or  /plans <N>"],
        origin: "plans")
    end

    def show_plan(requested)
      all   = plans.all
      index = list_index(requested, all.size)

      if index
        plan = all[index]
        return show_body(store_rule(Plans::DIR, plan.name, index), plans.body(plan.name))
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

      show_body(store_rule(Plans::DIR, name, nil), body)
    end

    def available_hint(all)
      names = all.map(&:name)
      names.empty? ? "no plans stored" : names.join(", ")
    end
  end
end
