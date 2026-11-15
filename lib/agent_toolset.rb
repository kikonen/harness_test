# frozen_string_literal: true

require_relative "tool_registry"

# The read-only tool set a sub-agent gets: the read half of the run's registry,
# over the SAME FileList so the run's grant rules still apply. ui.note and
# agent.explore are excluded (state mixing, nesting). Design: doc/task_model_design.md.
module AgentToolset
  READ_ONLY = %w[
    file.list file.read file.search file.info file.image
    git.diff git.show git.status git.log git.grep
    tools.list tools.search skills.list skills.read
    memory.list memory.read plan.list plan.read plan.search
    sessions.search ui.dialog
  ].freeze

  # A registry of the shared tool instances, restricted to READ_ONLY. Reusing the
  # instances keeps the run's single FileList, so the grant rules and the
  # normalization are unchanged.
  def self.build(harness)
    source = harness.respond_to?(:tool_registry) ? harness.tool_registry : nil
    set = ToolRegistry.new
    return set if source.nil?

    READ_ONLY.each do |name|
      tool = source.get(name)
      set.register(tool) if tool
    end
    set
  end
end
