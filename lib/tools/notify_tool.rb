# frozen_string_literal: true

require_relative '../tool'

class NotifyTool < Tool
  def initialize
    super(
      name: 'notify',
      description: 'Sends a progress or status message directly to the user\'s console. Use this to inform the user about what you are doing (e.g., "Analyzing file...", "Applying changes..."). This is the ONLY tool for communicating with the user.',
      parameters: {
        type: 'object',
        properties: {
          message: { type: 'string', description: 'The message to display to the user' }
        },
        required: ['message']
      }
    )
  end

  def execute(args)
    msg = args['message'] || ''
    puts "  [notify] #{msg}"
    $stdout.flush
    'ok'
  end
end
