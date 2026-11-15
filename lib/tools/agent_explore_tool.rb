# frozen_string_literal: true

require_relative "../tool"
require_relative "../requester"
require_relative "../agent_toolset"

module Tools
  class AgentExploreTool < Tool
    def initialize(harness)
      @harness = harness
      super(
        name: "agent.explore",
        description: "Runs one read-only sub-agent on the registry's flat job list and " \
          "waits for its result. The sub-agent has its own message chain and its own " \
          "read-only tool set (no write, no delete, no shell): it finds code, " \
          "summarises modules and checks how something is used. It returns SHORT " \
          "FINDINGS, not raw file contents, so this turn's context stays small. Use " \
          "it for a piece of reading you would otherwise have to pull into your own " \
          "context. A failure comes back as an error value, never as silence.",
        parameters: {
          type: "object",
          properties: {
            instruction: {
              type: "string",
              description: "What the sub-agent should find out (one focused task)"
            }
          },
          required: ["instruction"]
        }
      )
    end

    def execute(args)
      instruction = args["instruction"].to_s.strip
      return "error: agent.explore needs an instruction" if instruction.empty?
      unless @harness.respond_to?(:registry)
        return "error: no registry - nothing to run a job on"
      end

      requester = Requester.current
      return "error: no requester running this call" if requester.nil?

      toolset = AgentToolset.build(@harness)
      result = requester.request(:sub_agent, instruction:, registry: toolset)
      result.nil? ? "error: the sub agent delivered no result" : result
    end
  end
end
