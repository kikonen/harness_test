# frozen_string_literal: true

require_relative '../tool'
require 'time'

class GetTimeTool < Tool
  def initialize
    super(
      name: 'get_current_time',
      description: 'Returns the current date and time in ISO 8601 format.',
      parameters: {
        type: 'object',
        properties: {},
        required: []
      }
    )
  end

  def execute(_args)
    Time.now.iso8601
  end
end
