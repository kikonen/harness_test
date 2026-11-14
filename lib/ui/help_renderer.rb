# frozen_string_literal: true

require_relative "../command_help"
require_relative "../help_topics"
require_relative "renderer"
require_relative "text_wrap"
require_relative "width"

module UI
  # Renders the /help pages from structured data (issue #323): the command table
  # from the dispatch registry, one page per command, one page per topic. Every
  # shape here is DATA handed to UI::Renderer, so no column is padded by hand
  # (issue #474): a table is a markdown table the gem lays out, the blank line
  # between blocks is the :gap role, and prose is wrapped by UI::TextWrap. It
  # returns LINES and prints nothing - the command that owns the console decides
  # how they land (the issue #146 split: data -> renderer -> sink).
  class HelpRenderer
    INDENT = UI::Renderer::INDENT

    # width: nil (the default) means FOLLOW THE TERMINAL this page is written to,
    # through UI::Width (chars or a percentage, capped for prose). An explicit
    # value - a count or "85%" - pins it, which is what a spec needs to be
    # deterministic. A sink that cannot report a terminal (a spec StringIO, a
    # pipe) gets the renderer's fallback.
    def initialize(
      registry:,
      topics: HelpTopics::TOPICS,
      ui: nil,
      harness: nil,
      width: nil
    )
      @registry = registry
      @topics   = topics
      @ui       = ui
      @harness  = harness
      @width    = width
    end

    def command?(name)
      @registry.key?(name.to_s)
    end

    def topic?(name)
      @topics.key?(name.to_s)
    end

    # Bare /help: the command table grouped by KIND, then the topic index. The
    # prose lives behind /help <topic> so the default view stays glanceable.
    def overview
      lines = ["Commands:"]

      CommandHelp::GROUPS.each do |group, heading|
        rows = group_rows(group)
        next if rows.empty?

        lines << gap
        lines.concat(list(heading, %i[name summary], rows, gap: true))
      end

      lines << gap
      lines.concat(
        list("Topics (read one with /help <topic>):", %i[name title], topic_rows))
      lines
    end

    def command_page(name)
      help = @registry.fetch(name.to_s).help
      lines = ["/#{help.usage} - #{help.summary}", gap, "#{INDENT}forms:"]
      help.forms.each { |form| lines << "#{INDENT * 2}/#{form}" }
      lines << gap
      lines << "#{INDENT}group: #{help.group_label}"
      lines << refs_line("see also", help.see_also)
      lines
    end

    def topic_page(name)
      topic = @topics.fetch(name.to_s)
      lines = [topic.title, "#{INDENT}(/help #{topic.name})", gap]
      topic.paragraphs.each do |paragraph|
        lines.concat(TextWrap.paragraphs(paragraph, renderer.note_width, INDENT))
        lines << gap
      end
      lines.pop
      lines << gap
      lines << refs_line("see also", topic.see_also)
      lines
    end

    # An unknown argument is usually a typo, so name the closest registered names
    # instead of repeating "type /help".
    def unknown_page(arg)
      lines = ["Unknown help: /#{arg}"]
      suggested = CommandHelp.suggestions(arg, @registry.keys)
      topics    = CommandHelp.suggestions(arg, @topics.keys)

      unless suggested.empty?
        lines << "#{INDENT}Did you mean #{suggested.map { |c| "/#{c}" }.join(', ')}?"
      end
      unless topics.empty?
        lines << "#{INDENT}Or a topic: #{topics.map { |t| "/help #{t}" }.join(', ')}?"
      end
      lines << "#{INDENT}/help on its own lists every command and topic."
      lines
    end

    def command_suggestions(name)
      CommandHelp.suggestions(name, @registry.keys)
    end

    # The compact usage a command prints when it gets a bad argument (issue #471):
    # the SAME help the command declares (usage + forms + form_notes), as a
    # two-column table rather than a block this class aligns by hand.
    # Registry-independent (takes the help object), so a command can render its own
    # usage without a full /help registry.
    def render_inline(help)
      rows = help.forms.map { |form| { form: "/#{form}", note: help.form_notes[form] } }
      list("usage: /#{help.usage}", %i[form note], rows)
    end

    # The width this page lays out to. It is UI::Renderer's resolved number, so a
    # help page's prose wrap and its table basis can never disagree (they read the
    # same value).
    def page_width
      renderer.width
    end

    private

    def help_entries
      @registry.map do |name, klass|
        help = klass.help
        # The table prints the usage form in the command's slot, so a usage whose
        # first word is not the registered name would advertise a form the
        # dispatcher does not accept (issue #323).
        unless help.usage.start_with?(name)
          raise HarnessError, "#{name}: help usage #{help.usage.inspect} is not /#{name}"
        end

        [name, help]
      end
    end

    def group_rows(group)
      help_entries.filter_map do |_name, help|
        { name: "/#{help.usage}", summary: help.summary } if help.group == group
      end
    end

    def topic_rows
      @topics.map { |name, topic| { name:, title: topic.title } }
    end

    # One block of data to the pattern owner, as LINES.
    def list(title, columns, rows, gap: false)
      renderer.line(
        type: :list,
        content: {
          title:,
          kind: :table,
          columns:,
          items: rows,
          gap:
        }).split("\n")
    end

    # The blank line between blocks is the renderer's role, not a line written
    # here (issue #474, increment 23).
    def gap
      renderer.line(type: :gap, content: "")
    end

    def renderer
      @renderer ||= UI::Renderer.new(
        palette: UI::Renderer.palette_for(ui: @ui, harness: @harness),
        ui: @ui,
        markdown_max_width: @width)
    end

    def refs_line(label, names)
      refs = names.map { |name| @topics.key?(name) ? "/help #{name}" : "/#{name}" }
      refs.empty? ? "" : "#{INDENT}#{label}: #{refs.join(', ')}"
    end
  end
end
