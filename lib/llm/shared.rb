# frozen_string_literal: true

require "net/http"
require "openssl"

require_relative "../harness_error"

# -- LLM ------------------------------------------------------------------
#
# Shared constants for the LLM backends (issue #197): the client is split
# per backend API type (OpenAI-compatible vs Ollama native) so that each can
# send exactly the parameters its endpoint understands. These values are
# backend-agnostic (window size, sampling defaults, retry policy).

module LLM
  # Generous HTTP timeouts for local / slow model servers.
  # open_timeout: how long to wait for the TCP connection to establish.
  # read_timeout: how long to wait between bytes of the response (per read).
  DEFAULT_OPEN_TIMEOUT = 120
  DEFAULT_READ_TIMEOUT = 1800

  # How long (seconds) an idle keep-alive connection may sit unused before
  # Net::HTTP closes it and re-establishes a new one. The default is only
  # 2 seconds, which is too short for the tool loop (tool execution between
  # requests easily exceeds it), so we raise it.
  KEEP_ALIVE_TIMEOUT = 60

  # Transient network errors that are safe to retry (the request was never
  # completed, so re-sending it is idempotent from the server's perspective).
  RETRYABLE_ERRORS = [
    Errno::ECONNRESET,
    Errno::EPIPE,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    OpenSSL::SSL::SSLError,
    IOError,
    Net::OpenTimeout,
    Net::ReadTimeout
  ].freeze

  # Automatic retry settings for transient network errors.
  # RETRY_COUNT: total number of attempts (1 initial + N-1 retries).
  # RETRY_DELAY: base delay (seconds) between retries (exponential backoff:
  # 2s, 4s, 8s, ...).
  RETRY_COUNT = 3
  RETRY_DELAY = 2

  # Default context window size (tokens) when the config does not set one.
  # Honoured by the native Ollama endpoint; for the OpenAI-compatible
  # endpoint it drives the client-side context accounting only
  # (issue #197: that schema has no num_ctx field).
  NUM_CTX = 65536

  # Sampling parameters (temperature, top_p, ...), max_tokens/num_predict
  # and reasoning_effort are NOT constants: the config file owns their
  # values. When a key is absent (nil) it is NOT sent to the API, so the
  # server's own default applies.

  # Backend API types selectable per model profile ('api' config key).
  OPENAI  = :openai   # default: /v1/chat/completions (OpenAI-compatible)
  OLLAMA  = :ollama   # native:     /api/chat (honours num_ctx)

  def self.backend_type(value)
    case value.to_s.strip
    when "ollama" then OLLAMA
    else               OPENAI   # default and fallback: OpenAI-compatible
    end
  end
end
