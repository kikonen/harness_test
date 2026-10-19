# frozen_string_literal: true

require_relative "command_help"
require_relative "help_topics"

# Renders the /help pages from structured data (issue #323): the command table
# from the dispatch registry, one page per command, one page per topic. It
# returns LINES and prints nothing - the command that owns the console decides
# how they land (the issue #146 split: data -> renderer -> sink).
class HelpRenderer
  INDENT   = "  "
  CONTINUE = "    "
  MIN_COLUMN = 12
  MAX_COLUMN = 30
  # 78, not 80: a wrapped page has to survive a terminal that reserves columns
  # for its own chrome, and every non-wrapped help line stays inside 80.
  DEFAULT_WIDTH = 78

  def initialize(registry:, topics: HelpTopics::TOPICS, width: DEFAULT_WIDTH)
    @registry = registry
    @topics   = topics
    @width    = width
  end

  def command?(name)
    @registry.key?(name.to_s)
  end

  def topic?(name)
    @topics.key?(name.to_s)
  end

  # Bare /help: the command table grouped by KIND, then the topic index. The
  # The prose lives behind /help <topic> so the default view stays glanceable.
  def overview
    lines = ["Commands:"]
    CommandHelp::GROUPS.each do |group, heading|
      entries = help_entries.select { |(_name, help)| help.group == group }
      next if entries.empty?

      lines << ""
      lines << "#{INDENT}#{heading}"
      lines.concat(table(entries, column))
    end
    lines << "" unless lines.last.empty?
    lines << "Topics (read one with /help <topic>):"
    lines.concat(topic_index)
    lines
  end

  def command_page(name)
    help = @registry.fetch(name.to_s).help
    lines = ["/#{help.usage} - #{help.summary}", "", "#{INDENT}forms:"]
    help.forms.each { |form| lines << "#{CONTINUE}/#{form}" }
    lines << ""
    lines << "#{INDENT}group: #{help.group_label}"
    lines << refs_line("see also", help.see_also)
    lines
  end

  def topic_page(name)
    topic = @topics.fetch(name.to_s)
    lines = [topic.title, "#{INDENT}(/help #{topic.name})", ""]
    topic.paragraphs.each do |paragraph|
      lines.concat(wrap(paragraph, indent: INDENT).map { |line| "#{INDENT}#{line}" })
      lines << ""
    end
    lines.pop
    lines << ""
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

  # The summary column comes from the entries, so adding a command cannot
  # misalign the table the way hand-padded columns do.
  def table(entries, column)
    entries.flat_map do |(_name, help)|
      head = "#{INDENT}#{"/#{help.usage}".ljust(column)} "
      pad  = " " * head.length
      first, *rest = wrap(help.summary, indent: pad)
      ["#{head}#{first}"] + rest.map { |line| "#{pad}#{line}" }
    end
  end

  # ONE width for the WHOLE table: groups that each picked one read as ragged.
  def column
    usage_width = help_entries.map { |(_name, help)| "/#{help.usage}".length }.max
    [[usage_width + 1, MIN_COLUMN].max, MAX_COLUMN].min
  end

  def topic_index
    width = @topics.keys.map(&:length).max
    @topics.map { |name, topic| "#{INDENT}#{name.ljust(width)}  #{topic.title}" }
  end

  def refs_line(label, names)
    refs = names.map do |name|
      @topics.key?(name) ? "/help #{name}" : "/#{name}"
    end
    refs.empty? ? "" : "#{INDENT}#{label}: #{refs.join(', ')}"
  end

  def wrap(text, indent:)
    limit = @width - indent.length
    lines = []

    text.split(/\s+/).each do |word|
      lines << "" if lines.empty? || lines.last.length + 1 + word.length > limit
      lines[-1] = lines[-1].to_s.empty? ? word : "#{lines[-1]} #{word}"
    end
    lines
  end
end
