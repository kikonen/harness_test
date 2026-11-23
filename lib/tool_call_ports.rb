# frozen_string_literal: true

require_relative "spill_reader"

# The narrow view ToolCallRunner is allowed to see of a run (issue #582):
# built by Harness from its own state, so the tool-call half depends on these
# ports and never on Harness itself. State that can change mid-run (the client
# after a model switch, the spill file set) arrives as a callable so a port
# reads the live value.
class ToolCallPorts
  attr_reader :logger,
    :settings,
    :tool_registry,
    :session,
    :client,
    :model_config,
    :file_list,
    :spill_reader,
    :result_spill,
    :text_tool_call_parser,
    :tool_wait_suffix

  def initialize(logger:, settings:, tool_registry:, session:,
                 client:, model_config:, file_list:, spill_reader:, result_spill:,
                 text_tool_call_parser:, tool_wait_suffix:)
    @logger                 = logger
    @settings               = settings
    @tool_registry          = tool_registry
    @session                = session
    @client                 = client
    @model_config           = model_config
    @file_list              = file_list
    @spill_reader           = spill_reader
    @result_spill           = result_spill
    @text_tool_call_parser  = text_tool_call_parser
    @tool_wait_suffix       = tool_wait_suffix
  end

  def output_result_bytes
    @settings.output_result_bytes || OutputBudget::DEFAULT_RESULT_BYTES
  end
end
