# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

require_relative "shared"
require_relative "../keep_alive_http"
require_relative "../harness_error"
require_relative "../text_normalizer"
require_relative "stream_accumulator"
require_relative "stream_decoder"
require_relative "stream_error"

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

    # No setter: a resume builds a NEW backend under the new session's logger
    # (issue #280) rather than re-pointing this one.
    attr_reader :logger

    # Sends one chat completion. The CALLER decides whether the response is
    # streamed: stream: false (the default) is the buffered path unchanged,
    # stream: true consumes the body chunk by chunk and hands each part to
    # on_delta as it arrives. Both return the identical normalized shape, so
    # Harness#call_llm does not care which one ran.
    def chat(messages, tools: nil, timeout: LLM::DEFAULT_READ_TIMEOUT,
             stream: false, on_delta: nil)
      return chat_buffered(messages, tools, timeout) unless stream

      chat_streamed(messages, tools, timeout, on_delta)
    end

    private

    # -- Transport setup (shared by both paths) ------------------------------

    def build_uri
      URI("#{base_url}#{endpoint_path}")
    end

    # The request body is built ONCE: a retry re-sends the identical request.
    # The session's message chain is converted to this endpoint's wire shape
    # here (see #serialize_messages), never mutated.
    def build_request(uri, messages, tools, stream = false)
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@options[:token]}" if @options[:token]
      body = build_body(serialize_messages(messages), tools, stream: stream)
      req.body = JSON.generate(body)
      req
    end

    def build_http(uri, timeout)
      http = KeepAliveHTTP.new(uri.host, uri.port)
      http.logger             = @logger
      http.use_ssl            = (uri.scheme == "https")
      http.open_timeout       = LLM::DEFAULT_OPEN_TIMEOUT
      http.read_timeout       = timeout
      http.keep_alive_timeout = LLM::KEEP_ALIVE_TIMEOUT
      http
    end

    # -- Buffered path (the default: one JSON body, read in full) ------------

    def chat_buffered(messages, tools, timeout)
      uri  = build_uri
      http = build_http(uri, timeout)
      req  = build_request(uri, messages, tools)

      attempts = retry_count
      attempts.times do |attempt|
        @logger.info("REQ: POST #{uri} (#{req.body.bytesize} bytes, " \
                     "attempt #{attempt + 1}/#{attempts})")
        started = Time.now

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

        begin
          parsed = JSON.parse(resp.body, symbolize_names: true)
        rescue JSON::ParserError => e
          raise LLMError, "LLM returned invalid JSON: #{e.message}"
        end

        # issue #257: the response body is text that arrived from OUTSIDE this
        # process, so a string value in it can be byte-invalid in UTF-8. That
        # does not raise at parse time, but it raises at the next
        # JSON.generate - both the request body built from this chain and the
        # session save - and the save that should record the failure dies on
        # the same byte, so the error never reaches the console. Normalize the
        # parsed structure at this read boundary.
        parsed = TextNormalizer.normalize_strings(parsed)

        log_response_stats(resp, parsed, Time.now - started)

        # issue #131: the raw API response body is troubleshooting-only - it
        # goes to harness.log with --verbose, while the parsed reasoning /
        # content sections are ALWAYS logged by SessionManager#log_response.
        if @options[:verbose]
          @logger.info("=" * 50)
          @logger.info(resp.body)
          @logger.info("=" * 50)
        end

        return parse_response(parsed)
      end
      nil
    end

    # -- Streamed path (opt-in: config/profile key 'streaming') --------------
    #
    # Chunks are folded into the SAME normalized response the buffered path
    # returns, and on_delta sees each part as it arrives. A request is retried
    # only while nothing has arrived - after that a re-send would duplicate an
    # answer the caller already saw (LLM::StreamError). Framing, threading and
    # the full retry policy: doc/streaming_design.md.
    def chat_streamed(messages, tools, timeout, on_delta)
      uri  = build_uri
      req  = build_request(uri, messages, tools, true)

      attempts = retry_count
      attempts.times do |attempt|
        @logger.info("REQ: POST #{uri} (#{req.body.bytesize} bytes, " \
                     "attempt #{attempt + 1}/#{attempts}, streaming)")
        started  = Time.now
        acc      = StreamAccumulator.new
        decoder  = StreamDecoder.new
        received = 0

        begin
          # A new transport per attempt: a mid-stream abort closes the
          # connection, so a keep-alive session cannot be reused after one.
          build_http(uri, timeout).start do |http|
            http.request(req) do |resp|
              received = read_streamed_body(resp, decoder, acc, on_delta)
              return finish_streamed(resp, acc, received, Time.now - started)
            end
          end
        rescue StreamStatusError => e
          retry_streamed_status(e, attempt, attempts)
        rescue *LLM::RETRYABLE_ERRORS, Net::HTTPBadResponse => e
          next_attempt_or_raise(acc, attempt, attempts, e, received)
        end
      end
      nil
    end

    # Reads one streamed body. Returns the transport bytes received.
    def read_streamed_body(resp, decoder, acc, on_delta)
      received = 0
      # A non-2xx arrives before any answer: report it the way the buffered
      # path does (a 4xx is terminal, a 5xx may still be retried).
      raise StreamStatusError.new(resp.code.to_i, resp.read_body.to_s) \
        unless resp.is_a?(Net::HTTPSuccess)

      # read_body WITHOUT a block returns the whole body as a String even
      # inside a request block (measured); with a block it yields chunks.
      resp.read_body do |chunk|
        received += chunk.to_s.bytesize
        decoder.push(chunk).each { |payload| forward_delta(acc.feed(payload), on_delta) }
      end
      decoder.finish.each { |payload| forward_delta(acc.feed(payload), on_delta) }
      received + decoder.pending_bytes
    end

    def forward_delta(delta, on_delta)
      return if delta.nil? || delta.empty? || on_delta.nil?

      on_delta.call(delta)
    end

    # Logs the attempt and hands back the normalized response.
    def finish_streamed(resp, acc, received, elapsed)
      response = acc.to_response
      log_streamed_stats(resp, received, elapsed, response[:usage])
      response
    end

    # A status error carries the server's body: a 5xx is retried while no
    # answer has started, a 4xx is terminal for the request (issue #215 - the
    # body goes to harness.log so the failure is not console-only).
    def retry_streamed_status(error, attempt, attempts)
      delay = retry_delay * (2**attempt)
      if error.code >= 500 && attempt < attempts - 1
        @logger.warn("HTTP #{error.code} (attempt #{attempt + 1}/#{attempts}) - " \
                     "retrying in #{delay}s")
        sleep(delay)
        return
      end
      @logger.warn("LLM error (HTTP #{error.code}):\n#{error.body}")
      raise LLMError, "LLM error (HTTP #{error.code}):\n#{error.body}"
    end

    def next_attempt_or_raise(acc, attempt, attempts, error, received)
      delay = retry_delay * (2**attempt)
      if acc.started?
        @logger.warn("stream failed after #{received} bytes with a partial " \
                     "answer (#{error.class}: #{error.message}) - not retrying")
        raise StreamError, "stream lost after #{received} bytes: #{error.message}"
      end
      if attempt < attempts - 1
        msg = "stream error before any answer (attempt #{attempt + 1}/#{attempts}): " \
              "#{error.class}: #{error.message} - retrying in #{delay}s"
        @logger.warn(msg)
        sleep(delay)
        return
      end
      raise LLMError, "LLM request failed after #{attempts} attempts: #{error.message}"
    end

    def log_streamed_stats(resp, received, elapsed, usage)
      @logger.info("RESP: HTTP #{resp.code} (#{received} streamed bytes) " \
                   "in #{format_seconds(elapsed)}s#{usage_note(usage)}")
    end

    # Subclasses: build the request body (a Hash serializable to JSON).
    # stream: whether this request asks for a streamed response (the flag is
    # the CALLER's decision - a backend holds no posture of its own, so an
    # advisory call like the command safety check can stay buffered).
    def build_body(_messages, _tools, stream: false) = raise NotImplementedError

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

    # Request duration for the log line: plain seconds with 2dp (the console
    # stats line in Harness#format_elapsed factors minutes out; the log wants
    # one comparable number per attempt).
    def format_seconds(seconds)
      format("%.2f", seconds.to_f)
    end

    # Token counts for the RESP line (issue #231: prompt-processing speed can
    # be derived from the logged time + tokens). Empty when the backend
    # reports none.
    def usage_note(usage)
      return "" if usage.nil?
      return "" if usage[:prompt_tokens].nil? || usage[:completion_tokens].nil?

      " - #{usage[:prompt_tokens]} -> #{usage[:completion_tokens]} tokens"
    end

    # One line per successful attempt: what was called, how big the answer
    # was, how long it took and the token counts.
    def log_response_stats(resp, parsed, elapsed)
      @logger.info("RESP: HTTP #{resp.code} (#{resp.body.to_s.bytesize} bytes) " \
                   "in #{format_seconds(elapsed)}s#{usage_note(usage_for(parsed))}")
    end

    # The usage of one RAW parsed response, before normalization: the OpenAI
    # shape has a `usage` object, the native Ollama shape reports the counts
    # as top-level fields. BaseBackend cannot know which, so check both.
    def usage_for(json)
      return json[:usage] if json.is_a?(Hash) && json[:usage]
      return nil unless json.is_a?(Hash)
      return nil unless json.key?(:prompt_eval_count) || json.key?(:eval_count)

      prompt     = json[:prompt_eval_count].to_i
      completion = json[:eval_count].to_i
      { prompt_tokens: prompt, completion_tokens: completion,
        total_tokens: prompt + completion }
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
