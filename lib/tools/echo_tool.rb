# frozen_string_literal: true

require_relative '../tool'

class EchoTool < Tool
  def initialize
    super(
      name: 'echo',
      description: 'TEST-ONLY tool: returns the input text as-is. Do NOT use this to communicate with the user or send progress messages. Use the "notify" tool instead for any user-facing output.',
      parameters: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Text to echo back' }
        },
        required: ['text']
      }
    )
  end

  def execute(args)
    args['text'] || ''
  end
end