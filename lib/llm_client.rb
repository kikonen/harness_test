# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

require_relative 'keep_alive_http'
require_relative 'harness_error'

# HTTP client for the LLM API: builds the request, manages the connection
# (timeouts, keep-alive), retries transient network errors, and parses
# the response. Extracted from Harness to keep the LLM-call logic focused.
class LLMClient
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
  # RETRY_DELAY: base delay in seconds (exponential backoff: 2s, 4s, 8s, ...).
  RETRY_COUNT = 3
  RETRY_DELAY = 2

  # Ollama generation limits. -1 means "no limit" (generate until the model
  # stops on its own). num_ctx is the context window size (65K tokens).
  NUM_PREDICT = -1
  NUM_CTX     = 65536

  # Default reasoning effort (NOTE KI default for qwen is xhigh)
  REASONING_EFFORT = "medium"

  # Sampling parameters (defaults). temperature controls randomness
  # (lower = more deterministic); top_p is nucleus sampling.
  TEMPERATURE      = 0.2
  TOP_P            = 0.9
  TOP_K            = 20
  MIN_P            = 0
  PRESENCE_PENALTY = 1.0
  REPEAT_PENALTY   = 1.05

  # options: hash with :base_url, :model, :token and the sampling/retry
  # parameters (read on every request so model switches take effect).
  def initialize(options, logger)
    @options = options
    @logger  = logger
  end

  # Sends one chat completion request. Returns the parsed response hash
  # (symbolized keys). Raises LLMError when all attempts fail.
  def chat(messages, tools: nil, timeout: DEFAULT_READ_TIMEOUT)
    base_url = @options[:base_url]
    model    = @options[:model]

    uri  = URI("#{base_url}/chat/completions")
    http = KeepAliveHTTP.new(uri.host, uri.port)
    http.logger       = @logger
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = DEFAULT_OPEN_TIMEOUT
    http.read_timeout = timeout
    http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT

    body = build_body(messages, tools)

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{@options[:token]}" if @options[:token]
    req.body = JSON.generate(body)

    attempts = retry_count
    attempts.times do |attempt|
      begin
        resp = http.request(req)
      rescue *RETRYABLE_ERRORS => e
        if attempt < attempts - 1
          delay = retry_delay * (2 ** attempt)
          @logger.warn("network error (attempt #{attempt + 1}/#{attempts}): #{e.class}: #{e.message} - retrying in #{delay}s")
          sleep(delay)
          next
        end
        raise LLMError, "LLM request failed after #{attempts} attempts: #{e.message}"
      end

      unless resp.is_a?(Net::HTTPSuccess)
        if resp.code.to_i >= 500 && attempt < attempts - 1
          delay = retry_delay * (2 ** attempt)
          @logger.warn("HTTP #{resp.code} (attempt #{attempt + 1}/#{attempts}) - retrying in #{delay}s")
          sleep(delay)
          next
        end
        raise LLMError, "LLM error (HTTP #{resp.code}):\n#{resp.body}"
      end

      @logger.info("=" * 50)
      @logger.info(resp.body)
      @logger.info("=" * 50)

      begin
        return JSON.parse(resp.body, symbolize_names: true)
      rescue JSON::ParserError => e
        raise LLMError, "LLM returned invalid JSON: #{e.message}"
      end
    end
    nil
  end

  private

  def build_body(messages, tools)
    body = {
      model: @options[:model],
      messages: messages,
      temperature: sample(:temperature, TEMPERATURE),
      top_p: sample(:top_p, TOP_P),
      top_k: sample(:top_k, TOP_K),
      min_p: sample(:min_p, MIN_P),
      presence_penalty: sample(:presence_penalty, PRESENCE_PENALTY),
      repeat_penalty: sample(:repeat_penalty, REPEAT_PENALTY),
      max_tokens: NUM_PREDICT,
      reasoning_effort: @options[:reasoning_effort] || REASONING_EFFORT,
      options: {
        num_predict: NUM_PREDICT,
        num_ctx: @options[:num_ctx] || NUM_CTX
      }
    }
    body[:tools] = tools if tools && !tools.empty?
    body
  end

  def sample(key, default)
    @options[key] || default
  end

  def retry_count
    @options[:retry_count] || RETRY_COUNT
  end

  def retry_delay
    @options[:retry_delay] || RETRY_DELAY
  end
end
