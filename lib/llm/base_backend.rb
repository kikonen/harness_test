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

    # Subclasses: the path appended to the base URL (issue #217: public
    # together with #base_url so the UI can show the ACTUAL call target,
    # e.g. "openai /v1/chat/completions" vs "ollama /api/chat" - after a
    # /model switch between API types nothing in the console or the log
    # said which endpoint a call went to).
    def endpoint_path = raise NotImplementedError

    # The base URL this backend sends to, used as-is (no rewriting) with
    # #endpoint_path appended: what is configured is what gets called
    # (openai profiles -> .../v1 base, ollama profiles -> server root).
    def base_url = @options[:base_url]

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
      # Convert the backend-agnostic message chain to this endpoint's wire
      # shape before building the body (see #serialize_messages).
      req.body = JSON.generate(build_body(serialize_messages(messages), tools))

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
          # issue #215: a client error (4xx) is terminal for the request -
          # log the server's body before raising so the failure is in
          # harness.log, not only on the console.
          @logger.warn("LLM error (HTTP #{resp.code}):\n#{resp.body}")
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

    # Subclasses: build the request body (a Hash serializable to JSON).
    def build_body(_messages, _tools) = raise NotImplementedError

    # Wire shape for one tool-call's arguments. Default: the OpenAI schema
    # wants a JSON string (what the session already stores). OllamaBackend
    # overrides this to return an object.
    def serialize_args(args) = args.is_a?(String) ? args : JSON.generate(args || {})

    # issue #215: the session history is backend-agnostic and stores tool-call
    # arguments as STRINGS (what the OpenAI schema sends and what
    # execute_tool_call parses). Each endpoint wants a DIFFERENT shape for
    # them, so convert on the wire instead of mutating the session:
    #   OpenAI  -> string (kept as-is)
    #   Ollama  -> JSON object (ToolCallFunctionArguments unmarshals into a map)
    # Re-sending string args to /api/chat after a /model switch is what made
    # the native endpoint reject the whole request with a JSON parse error.
    # Messages are plain hashes; they return unchanged, so this is safe for
    # both backends and needs no changes in Harness.
    def serialize_messages(messages) = messages

    # The tool-call arguments of one message, converted to this endpoint's
    # expected shape (nil when the message carries none). Shared by the
    # backend overrides of #serialize_messages.
    def tool_call_args(message)
      tcs = message[:tool_calls]
      return nil if tcs.nil?

      tcs.map do |tc|
        fn = tc[:function] || {}
        { id: tc[:id].to_s, function: { name: fn[:name], arguments: serialize_args(fn[:arguments]) } }
      end
    end

    # Subclasses: raw parsed JSON -> the normalized response shape.
    def parse_response(_json) = raise NotImplementedError

    # A config-owned option value. Returns nil when unset: the caller
    # OMITS the key from the request so the server's own default applies
    # (issue #215: no hidden code-side defaults).
    def cfg(key) = @options[key]

    # Keep num_ctx sent on the native path even when unset (see NUM_CTX).
    def ctx_window = cfg(:num_ctx) || LLM::NUM_CTX

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
