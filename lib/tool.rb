# frozen_string_literal: true

# -- Tool system ----------------------------------------------------------

class Tool
  attr_reader :name, :description, :parameters

  def initialize(name:, description:, parameters:)
    @name        = name
    @description = description
    @parameters  = parameters
  end

  def execute(args_hash)
    raise NotImplementedError, "#{self.class}#execute not implemented"
  end

  def to_openai
    {
      type: 'function',
      function: {
        name: @name,
        description: @description,
        parameters: @parameters
      }
    }
  end
end
