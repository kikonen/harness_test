# frozen_string_literal: true

require_relative "../command"
require_relative "../plans"
require_relative "../ui/markdown_renderer"

module Commands
  # /plans - list the project's stored plans numbered, or print one body.
  #
  # The same data the model sees through plan.list / plan.read: one reader
  # (Plans) behind both sides, so what the owner inspects and what the model
  # reads cannot drift apart (the same shape as /memory and /skills). Issue #359.
  #
  # A body is a MARKDOWN file (issue #416): it is rendered, not dumped. With a
  # palette the headings/bold/code/lists are styled; palette 'none' (--no-color)
  # renders plain text with no ANSI and no markdown markers. Only a harness that
  # answers no palette at all (a bare console, a spec double) prints the body
  # verbatim, as before this issue.
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
        @ui.puts "No plans stored (#{plans.dir})."
        @ui.puts "The model saves one with plan.add(name:, text:); " \
          "the file is #{Plans::DIR}/<name>.md."
        return
      end

      @ui.puts "Plans (#{all.size}/#{Plans::MAX_PLANS} plans, " \
        "#{Plans::MAX_BODY_CHARS} chars max each):"
      width = all.size.to_s.length
      all.each_with_index do |plan, i|
        @ui.puts "  #{format("%#{width}d", i + 1)}. #{plan.name} " \
          "- #{plan.description} (#{plan.chars} chars)"
      end
      @ui.puts "Show one with: /plans <name>  or  /plans <N>"
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
        @ui.puts "[error] a plan name is one path segment, " \
          "or a plan number: #{requested}"
        return
      end

      body = plans.body(name)
      if body.nil?
        @ui.puts "[error] no plan named '#{name}' (#{available_hint(all)})"
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

      @ui.puts header(name, index)
      rendered = markdown_renderer&.render(body)
      return dump_verbatim(body) if rendered.nil?

      # The gem closes its last block with a blank line; the verbatim path
      # ends with the file's single newline, and the two must match.
      @ui.print rendered.sub(/\n+\z/, "")
      @ui.puts
    end

    def dump_verbatim(body)
      body.each_line { |line| @ui.print line }
      @ui.puts unless body.end_with?("\n")
    end

    def header(name, index)
      # nil-safe on purpose: 0 is a LEGITIMATE index and 0 is truthy, so a
      # plain `index ?` would still be right here but reads like a bug.
      title = index.nil? ? "--- #{name}" : "--- #{index + 1}. #{name}"
      title = "#{title} (#{Plans::DIR})"
      "#{title} #{'-' * [1, 60 - title.length].max}"
    end

    # Harness#output_palette is always a palette in a real run (palette 'none'
    # paints nothing but still renders the markdown structure). The width basis
    # is the configured one, so a plan table is sized like an answer table.
    def markdown_renderer
      return nil unless @harness.respond_to?(:output_palette)

      palette = @harness.output_palette
      return nil if palette.nil?

      width = @harness.respond_to?(:markdown_max_width) ?
        @harness.markdown_max_width : nil
      UI::MarkdownRenderer.new(palette:, max_width: width)
    end

    def available_hint(all)
      names = all.map(&:name)
      names.empty? ? "no plans stored" : names.join(", ")
    end
  end
end
