# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

require_relative 'shared'
require_relative '../keep_alive_http'
require_relative '../harness_error'

module LLM
  # Shared request machinery for the per-backend clients (issue #197):
  # connection setup, the retry loop, verbose logging and response
  # normalisation. A backend implements #endpoint_path (URL to append to
  # the normalized base), #build_body (the request JSON) and
  # #parse_response (raw JSON -> the normalized shape).
  #
  # The normalized shape is what Harness#call_llm consumes, so switching
  # backends never changes the harness logic:
  #   { choices: [{ message: { role:, content:, reasoning:, tool_calls: } }],
  #     usage:   { prompt_tokens:, completion_tokens:, total_tokens: } }
  # (usage is nil when the backend does not report tokens.)
  class BaseBackend
    def initialize(options, logger)
      @options = options
      @logger  = logger
    end

    # Subclasses: the LLM::OPENAI / LLM::OLLAMA type this backend serves.
    def api_type = raise NotImplementedError

    # issue #113: re-point the logger after a session resume swaps in a
    # different session id. KeepAliveHTTP reads it on every request.
    attr_accessor :logger

    def chat(messages, tools: nil, timeout: LLM::DEFAULT_READ_TIMEOUT)
      uri  = URI("#{base_url}#{endpoint_path}")
      http = KeepAliveHTTP.new(uri.host, uri.port)
      http.logger             = @logger
      http.use_ssl            = (uri.scheme == 'https')
      http.open_timeout       = LLM::DEFAULT_OPEN_TIMEOUT
      http.read_timeout       = timeout
      http.keep_alive_timeout = LLM::KEEP_ALIVE_TIMEOUT

      req = Net::HTTP::Post.new(uri.request_uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{@options[:token]}" if @options[:token]
      req.body = JSON.generate(build_body(messages, tools))

      attempts = retry_count
      attempts.times do |attempt|
        begin
          resp = http.request(req)
        rescue *LLM::RETRYABLE_ERRORS => e
          if attempt < attempts - 1
            delay = retry_delay * (2 ** attempt)
            msg = "network error (attempt #{attempt + 1}/#{attempts}): " \
                  "#{e.class}: #{e.message} - retrying in #{delay}s"
            @logger.warn(msg)
            sleep(delay)
            next
          end
          raise LLMError, "LLM request failed after #{attempts} attempts: #{e.message}"
        end

        unless resp.is_a?(Net::HTTPSuccess)
          if resp.code.to_i >= 500 && attempt < attempts - 1
            delay = retry_delay * (2 ** attempt)
            @logger.warn("HTTP #{resp.code} (attempt #{attempt + 1}/" \
                         "#{attempts}) - retrying in #{delay}s")
            sleep(delay)
            next
          end
          raise LLMError, "LLM error (HTTP #{resp.code}):\n#{resp.body}"
        end

        # issue #131: the raw API response body is troubleshooting-only - it
        # goes to harness.log with --verbose, while the parsed reasoning /
        # content sections are ALWAYS logged by SessionManager#log_response.
        if @options[:verbose]
          @logger.info("=" * 50)
          @logger.info(resp.body)
          @logger.info("=" * 50)
        end

        begin
          return parse_response(JSON.parse(resp.body, symbolize_names: true))
        rescue JSON::ParserError => e
          raise LLMError, "LLM returned invalid JSON: #{e.message}"
        end
      end
      nil
    end

    private

    # Subclasses: the path appended to the normalized base URL.
    def endpoint_path = raise NotImplementedError

    # Subclasses: build the request body (a Hash serializable to JSON).
    def build_body(_messages, _tools) = raise NotImplementedError

    # Subclasses: raw parsed JSON -> the normalized response shape.
    def parse_response(_json) = raise NotImplementedError

    # The base_url is the server ROOT (e.g. https://llm.ikari.fi or
    # http://localhost:11434). A legacy trailing '/v1' (from configs written
    # before the backend split) is stripped so both backends can append
    # their own path.
    def base_url
      @options[:base_url].to_s.sub(%r{/v1\z}, '').chomp('/')
    end

    # Sampling parameter with built-in default.
    def sample(key, default)
      @options[key] || default
    end

    def retry_count
      @options[:retry_count] || LLM::RETRY_COUNT
    end

    def retry_delay
      @options[:retry_delay] || LLM::RETRY_DELAY
    end

    # Both backends report tool calls as [{id, function: {name, arguments}}];
    # the native Ollama API sends `arguments` as a JSON object while OpenAI
    # sends a string. The harness (execute_tool_call) always expects a
    # STRING, so stringify objects here.
    def normalize_tool_calls(tool_calls)
      return nil if tool_calls.nil?

      tool_calls.map do |tc|
        fn = tc[:function] || {}
        args = fn[:arguments]
        { id: tc[:id].to_s,
          function: { name: fn[:name],
                      arguments: args.is_a?(String) ? args : JSON.generate(args || {}) } }
      end
    end
  end
end
