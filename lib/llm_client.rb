# frozen_string_literal: true

require_relative 'llm/shared'
require_relative 'llm/openai_backend'
require_relative 'llm/ollama_backend'

# Public LLM client (issue #197): a thin dispatcher over the per-backend
# clients in lib/llm/. The backend is selected per model profile via the
# 'api' config key (:openai default / :ollama). Both backends return the
# same normalized response shape, so Harness does not care which one is
# active. Timeouts/retry constants are aliased for harness.rb and
# session_manager.rb; NUM_CTX is the built-in context window (client-side
# accounting when the config sets no num_ctx). Sampling values have no
# alias: the config owns them, and an unset key is not sent (issue #215).
class LLMClient
  DEFAULT_OPEN_TIMEOUT = LLM::DEFAULT_OPEN_TIMEOUT
  DEFAULT_READ_TIMEOUT = LLM::DEFAULT_READ_TIMEOUT
  KEEP_ALIVE_TIMEOUT   = LLM::KEEP_ALIVE_TIMEOUT
  RETRYABLE_ERRORS     = LLM::RETRYABLE_ERRORS
  RETRY_COUNT          = LLM::RETRY_COUNT
  RETRY_DELAY          = LLM::RETRY_DELAY
  NUM_CTX              = LLM::NUM_CTX

  # The backend currently selected for options[:api]. Public so the specs
  # (and /model switching) can observe which API type is active.
  def backend = current_backend

  # options: hash with :base_url (server root), :model, :token, :api
  # ('openai' | 'ollama', default 'openai') and the sampling/retry
  # parameters (read on every request so model switches take effect).
  def initialize(options, logger)
    @options = options
    @backend = build_backend(logger)
  end

  # Sends one chat completion request. Returns the normalized response
  # hash (symbolized keys, {choices: [...], usage: {...}}). Raises LLMError
  # when all attempts fail.
  def chat(*args, **kwargs) = current_backend.chat(*args, **kwargs)

  private

  # A /model switch mutates the shared options hash in place (the same
  # object the backends were built from), so sampling parameters and
  # base_url always apply - but :api selects the backend class and must
  # trigger a rebuild. Checked lazily before every request: cheap (a symbol
  # compare) and keeps the /model wiring untouched.
  def current_backend
    return @backend if LLM.backend_type(@options[:api]) == @backend.api_type

    @backend = build_backend(@backend.logger)
  end

  def build_backend(logger)
    LLM.backend_type(@options[:api]) == LLM::OLLAMA ?
      LLM::OllamaBackend.new(@options, logger) :
      LLM::OpenAIBackend.new(@options, logger)
  end
end
