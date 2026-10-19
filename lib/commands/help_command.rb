# frozen_string_literal: true

require_relative "../command"
require_relative "../help_renderer"
require_relative "../help_topics"

module Commands
  # /help - the help pages, rendered from the dispatch registry and the topic
  # data (issue #323). Bare /help is the command table plus the topic index;
  # /help <command> is one command's forms, /help <topic> one prose topic.
  # The old version was one 182-line heredoc that hand-copied the command list
  # the dispatcher already owns.
  class HelpCommand < Command
    HELP = CommandHelp.new(
      usage: "help [command|topic]",
      summary: "List every command and topic, or read one command's forms or " \
        "one topic (keys, consent postures, multiline input, ...)",
      group: :general,
      forms: [
        "help",
        "help <command>",
        "help <topic>"
      ],
      see_also: %w[tools access consent shell input keys notes saving rules conversation])

    def handle(args)
      raise HarnessError, "HelpCommand needs a help renderer" unless @help_renderer

      render(args.to_s.strip.downcase).each { |line| @ui.puts line }
    end

    private

    # Commands are checked BEFORE topics: a name in both would otherwise be
    # ambiguous, and the registry check keeps that from ever happening.
    def render(arg)
      return @help_renderer.overview if arg.empty?
      return @help_renderer.command_page(arg) if @help_renderer.command?(arg)
      return @help_renderer.topic_page(arg) if @help_renderer.topic?(arg)

      @help_renderer.unknown_page(arg)
    end
  end
end
