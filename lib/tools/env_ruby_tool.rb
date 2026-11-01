# frozen_string_literal: true

require_relative "../tool"
require_relative "../env_ruby"

# env.ruby - the model's one question about gems answered by MEASURING the child
# ruby, not by listing a bundle that does not apply to it (issue #340;
# doc/env_ruby_design.md). Report only: it installs nothing.
module Tools
  class EnvRubyTool < Tool
    def initialize(env_ruby)
      @env_ruby = env_ruby
      super(
        name: "env.ruby",
        description: "Report the Ruby + gems a run.command script can actually " \
          "use: the CHILD ruby the harness spawns for shell commands, which is " \
          "NOT this harness' own bundle (the harness' bundler is hidden from " \
          "those commands). With no arguments it prints a full alphabetized scan " \
          "of installed gems grouped by kind (stdlib = ships with Ruby, ruby = " \
          "this Ruby's gem home, user = user-installed, other = GEM_PATH). With " \
          "gems: [names] it reports, per name, the installed match(es) and their " \
          "versions. Use it BEFORE hand-writing a parser/serializer a well-known " \
          "gem would do, to check that gem is actually available.",
        parameters: {
          type: "object",
          properties: {
            gems: {
              type: "array",
              items: { type: "string" },
              description: "Optional gem name(s) or substrings to look for " \
                "(e.g. [\"csv\", \"pdf\", \"nokogiri\"]). Empty/omitted = full scan."
            }
          },
          required: []
        }
      )
    end

    def execute(args)
      query = Array(args["gems"])
      report = @env_ruby.probe

      if report[:error]
        status(:warn, "ruby env probe failed")
        return "error: could not probe the child ruby (#{@env_ruby.class}): " \
          "#{report[:error]}"
      end

      status(:info, "probed the child ruby (#{report[:count]} installed specs)")
      @env_ruby.format(report, query:)
    end
  end
end
