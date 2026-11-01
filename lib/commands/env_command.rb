# frozen_string_literal: true

require_relative "../command"

module Commands
  # /env - the human mirror of env.ruby over the SAME EnvRuby object, so the two
  # cannot disagree about what exists (issue #340; doc/env_ruby_design.md). It is
  # a report: it installs nothing and changes nothing.
  class EnvCommand < Command
    HELP = CommandHelp.new(
      usage: "env [gems...]",
      summary: "Report the child Ruby a run.command script runs under and the " \
        "gems it can require (NOT the harness' own bundle); name gems to check them",
      group: :general,
      see_also: %w[tools])

    def handle(args)
      report = @harness.env_ruby.probe
      message = "Could not probe the child ruby: #{report[:error]}"
      return @ui.puts(message) if report[:error]

      query = args.to_s.split(/\s+/).reject(&:empty?)
      @ui.puts @harness.env_ruby.format(report, query:)
    end
  end
end
