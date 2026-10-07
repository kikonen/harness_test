# frozen_string_literal: true

require_relative '../tool'
require_relative '../command_runner'

# Executes a shell command in the harness working directory.
#
# The consent + execution logic lives in CommandRunner (issue #129),
# shared with the `!` bang syntax in the CLI. This tool only carries the
# LLM-facing metadata (name, description, parameters) and delegates.
#
# SAFETY MODEL (see CommandRunner):
#   - The FULL command string is displayed to the user before anything runs;
#     explicit "Allow" required unless the prefix is in the allowlist.
#   - "Always allow <prefix>" saves a grant to .harness/allowed_commands.yml
#     (issue #69, multi-select per-prefix issue #102).
#   - Commands run under a timeout (default 60 s, cap 300 s); output is
#     truncated to a line limit (default 200, max 5000) because it goes
#     into the LLM context window.
module Tools

  class RunCommandTool < Tool
    def initialize(file_list, options)
      @runner = CommandRunner.new(file_list, options)
      super(
        name: 'run.command',
        description: 'Executes a shell command in the harness working directory. ' \
                     'Most commands require explicit user confirmation ("Allow") ' \
                     'before they run; previously approved command prefixes are ' \
                     'auto-approved. Use this for tasks no dedicated tool covers ' \
                     '(running tests, build steps, one-off scripts). Output is ' \
                     'captured and returned with the exit code.',
        parameters: {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'The full shell command to execute (e.g. "bundle exec rspec spec/foo_spec.rb"). ' \
                           'Shown verbatim to the user for confirmation unless its prefix is already approved.'
            },
            cwd: {
              type: 'string',
              description: 'Optional working directory for the command (relative to the harness ' \
                           'working directory). Defaults to the working directory itself.'
            },
            timeout: {
              type: 'integer',
              description: "Optional timeout in seconds (default #{CommandRunner::DEFAULT_TIMEOUT}, " \
                           "max #{CommandRunner::MAX_TIMEOUT})."
            },
            limit: {
              type: 'integer',
              description: "Optional maximum number of output lines returned (default " \
                           "#{CommandRunner::DEFAULT_LIMIT}, max #{CommandRunner::MAX_LIMIT})."
            }
          },
          required: ['command']
        }
      )
    end

    def execute(args)
      @runner.run(
        args['command'].to_s,
        cwd: args['cwd'],
        timeout: args['timeout'].to_i,
        limit: args['limit'].to_i)
    end
  end
end
