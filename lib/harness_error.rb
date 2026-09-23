# frozen_string_literal: true

# -- Custom exceptions ----------------------------------------------------

class HarnessError < StandardError; end
class LLMError < HarnessError; end
class ToolLoopError < HarnessError; end
