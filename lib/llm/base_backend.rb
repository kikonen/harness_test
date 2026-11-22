# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

require_relative "shared"
require_relative "../keep_alive_http"
require_relative "../harness_error"
require_relative "../text_normalizer"
require_relative "../error_text"
require_relative "stream_accumulator"
require_relative "stream_decoder"
require_relative "stream_error"
require_relative "usage_stats"

module LLM
  # Shared request machinery for the per-backend clients: connection setup, the retry loop,
  # verbose logging and response normalisation. A backend implements #endpoint_path (URL to
  # append to the base), #build_body (request JSON) and #parse_response (raw JSON -> normalized).
  # The normalized shape is what Harness#call_llm consumes:
  #   { choices: [{ message: { role:, content:, reasoning:, tool_calls: } }],
  #     usage:   { prompt_tokens:, completion_tokens:, total_tokens: },
  #     finish_reason: 'length' }
  # usage is nil when the backend does not report tokens. finish_reason is present only when the
  # server reported one; what the harness does with it: doc/truncation_design.md. A usage may
  # also carry the optional performance keys of LLM::UsageStats (doc/llm_stats.md).
  class BaseBackend
    # config: this Harness' own ModelConfig - the per-connection live model / endpoint / sampling
    # / transport values. Read on every request.
    def initialize(config, logger)
      @config  = config
      @logger  = logger
    end

    # Subclasses: the LLM::OPENAI / LLM::OLLAMA type this backend serves.
    def api_type = raise NotImplementedError

    # Subclasses: the path appended to the base URL. Public together with #base_url so the UI can
    # show the ACTUAL call target - after a /model switch between API types nothing else says
    # which endpoint a call went to.
    def endpoint_path = raise NotImplementedError

    # The base URL this backend sends to, used as-is (no rewriting) with #endpoint_path appended:
    # what is configured is what gets called.
    def base_url = @config.base_url

    # No setter: a resume builds a NEW backend under the new session's logger rather than
    # re-pointing this one.
    attr_reader :logger

    # Sends one chat completion. The CALLER decides whether to stream: stream: false is the
    # buffered path unchanged, stream: true consumes the body chunk by chunk and hands each part
    # to on_delta as it arrives. Both return the identical normalized shape.
    def chat(messages, tools: nil, timeout: LLM::DEFAULT_READ_TIMEOUT,
             stream: false, on_delta: nil)
      return chat_buffered(messages, tools, timeout) unless stream

      chat_streamed(messages, tools, timeout, on_delta)
    end

    private

    # -- Transport setup (shared by both paths) ------------------------------

    # A relative URI is never a request target: URI() answers URI::Generic for a bare path, and
    # only a scheme/host URI has #request_uri / #host. Without this guard a missing base_url dies
    # as NoMethodError inside build_request and the run looked stuck rather than mis-configured.
    def build_uri
      if base_url.nil? || base_url.strip.empty?
        raise HarnessError,
          "no endpoint configured for model '#{@config.active_profile_id}' - " \
            "a model needs a url (set 'url:' on its profile under 'models:')"
      end

      uri = URI("#{base_url}#{endpoint_path}")
      raise HarnessError,
        "model url '#{base_url}' is not a full endpoint (it needs http:// or https://)" unless uri.host

      uri
    end

    # The request body is built ONCE: a retry re-sends the identical request. The session's message
    # chain is converted to this endpoint's wire shape here (see #serialize_messages), never mutated.
    def build_request(uri, messages, tools, stream = false)
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@config.token}" if @config.token
      body = build_body(serialize_messages(messages), tools, stream:)
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
        @logger.info "REQ: POST #{uri} (#{req.body.bytesize} bytes, " \
          "attempt #{attempt + 1}/#{attempts})"
        started = Time.now

        begin
          resp = http.request(req)
        rescue *LLM::RETRYABLE_ERRORS => e
          if attempt < attempts - 1
            delay = retry_delay * (2 ** attempt)
            msg = "network error (attempt #{attempt + 1}/#{attempts}): " \
                  "#{ErrorText.label(e)} - retrying in #{delay}s"
            @logger.warn msg
            sleep(delay)
            next
          end
          raise LLMError, "LLM request failed after #{attempts} attempts: #{e.message}"
        end

        unless resp.is_a?(Net::HTTPSuccess)
          if resp.code.to_i >= 500 && attempt < attempts - 1
            delay = retry_delay * (2 ** attempt)
            @logger.warn "HTTP #{resp.code} (attempt #{attempt + 1}/" \
              "#{attempts}) - retrying in #{delay}s"
            sleep(delay)
            next
          end
          # A client error (4xx) is terminal for the request - log the server's body before
          # raising so the failure is in harness.log, not only on the console.
          @logger.warn "LLM error (HTTP #{resp.code}):\n#{resp.body}"
          raise LLMError, "LLM error (HTTP #{resp.code}):\n#{resp.body}"
        end

        begin
          parsed = JSON.parse(resp.body, symbolize_names: true)
        rescue JSON::ParserError => e
          raise LLMError, "LLM returned invalid JSON: #{e.message}"
        end

        # The response body is text from OUTSIDE this process, so a string value in it can be
        # byte-invalid in UTF-8. That does not raise at parse time, but it raises at the next
        # JSON.generate - both the request body built from this chain and the session save - so the
        # save that should record the failure dies on the same byte and the error never reaches the
        # console. Normalize the parsed structure at this read boundary.
        parsed = TextNormalizer.normalize_strings(parsed)

        log_response_stats(resp, parsed, Time.now - started)

        # The raw API response body is troubleshooting-only: it goes to harness.log with --verbose,
        # while the parsed reasoning/content sections are ALWAYS logged by SessionManager#log_response.
        if @config.verbose
          @logger.info "=" * 50
          @logger.info resp.body
          @logger.info "=" * 50
        end

        return parse_response(parsed)
      end
      nil
    end

    # -- Streamed path (opt-in: config/profile key 'streaming') --------------
    #
    # Chunks are folded into the SAME normalized response the buffered path returns, and on_delta
    # sees each part as it arrives. A request is retried only while nothing has arrived - after that
    # a re-send would duplicate an answer the caller already saw (LLM::StreamError). Framing,
    # threading and the full retry policy: doc/streaming_design.md.
    def chat_streamed(messages, tools, timeout, on_delta)
      uri  = build_uri
      req  = build_request(uri, messages, tools, true)

      attempts = retry_count
      attempts.times do |attempt|
        @logger.info "REQ: POST #{uri} (#{req.body.bytesize} bytes, " \
          "attempt #{attempt + 1}/#{attempts}, streaming)"
        started  = Time.now
        acc      = StreamAccumulator.new
        decoder  = StreamDecoder.new
        received = 0

        begin
          # A new transport per attempt: a mid-stream abort closes the connection, so a
          # keep-alive session cannot be reused after one.
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
      # A non-2xx arrives before any answer: report it the way the buffered path does (a 4xx is
      # terminal, a 5xx may still be retried).
      raise StreamStatusError.new(resp.code.to_i, resp.read_body.to_s) \
        unless resp.is_a?(Net::HTTPSuccess)

      # read_body WITHOUT a block returns the whole body as a String even inside a request block
      # (measured); with a block it yields chunks.
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

    # A status error carries the server's body: a 5xx is retried while no answer has started, a
    # 4xx is terminal for the request (the body goes to harness.log so it is not console-only).
    def retry_streamed_status(error, attempt, attempts)
      delay = retry_delay * (2**attempt)
      if error.code >= 500 && attempt < attempts - 1
        @logger.warn "HTTP #{error.code} (attempt #{attempt + 1}/#{attempts}) - " \
          "retrying in #{delay}s"
        sleep(delay)
        return
      end
      @logger.warn "LLM error (HTTP #{error.code}):\n#{error.body}"
      raise LLMError, "LLM error (HTTP #{error.code}):\n#{error.body}"
    end

    def next_attempt_or_raise(acc, attempt, attempts, error, received)
      delay = retry_delay * (2**attempt)
      if acc.started?
        @logger.warn "stream failed after #{received} bytes with a partial " \
          "answer (#{error.class}: #{error.message}) - not retrying"
        raise StreamError, "stream lost after #{received} bytes: #{error.message}"
      end
      if attempt < attempts - 1
        msg = "stream error before any answer (attempt #{attempt + 1}/#{attempts}): " \
              "#{error.class}: #{error.message} - retrying in #{delay}s"
        @logger.warn msg
        sleep(delay)
        return
      end
      raise LLMError, "LLM request failed after #{attempts} attempts: #{error.message}"
    end

    def log_streamed_stats(resp, received, elapsed, usage)
      @logger.info "RESP: HTTP #{resp.code} (#{received} streamed bytes) " \
        "in #{format_seconds(elapsed)}s#{usage_note(usage)}"
    end

    # Subclasses: build the request body (a Hash serializable to JSON).
    # stream: whether this request asks for a streamed response (the flag is the CALLER's decision
    # - a backend holds no posture of its own, so an advisory call like the safety check stays buffered).
    def build_body(_messages, _tools, stream: false) = raise NotImplementedError

    # Wire shape for one tool-call's arguments. Default: the OpenAI schema wants a JSON string (what
    # the session already stores). OllamaBackend overrides this to return an object.
    def serialize_args(args) = args.is_a?(String) ? args : JSON.generate(args || {})

    # The session history is backend-agnostic and stores tool-call arguments as STRINGS. Each endpoint
    # wants a DIFFERENT shape, so convert on the wire instead of mutating the session:
    #   OpenAI -> string (kept as-is); Ollama -> JSON object. Re-sending string args to /api/chat after
    #   a /model switch is what made the native endpoint reject the whole request with a parse error.
    # Messages are plain hashes; they return unchanged, so this is safe for both backends.
    def serialize_messages(messages) = messages

    # The tool-call arguments of one message, converted to this endpoint's expected shape (nil when
    # the message carries none). Shared by the backend overrides of #serialize_messages.
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

    # -- Tool-result images on the wire ---------------------------------------
    #
    # The canonical chain shape carries them as images: [{ mime_type:, base64: }] beside the text
    # content. Each endpoint wants a DIFFERENT wire shape (OpenAI: a content array of text +
    # image_url parts; native /api/chat: a top-level images list of bare base64 strings), so the
    # conversion happens here and the chain stays backend-agnostic.
    #
    # vision: gates it: a profile that does not declare image support never receives an image payload,
    # even if one somehow reached the chain. Defense in depth - ImageDelivery already only inlines for
    # a vision profile - and it keeps a stray payload from being sent to a text model as a megabyte URI.
    def images_supported?
      @config.vision == true
    end

    # The image payloads of one message, normalized and filtered, or nil when the message has none
    # or this backend may not send them.
    def image_payloads(message)
      return nil unless images_supported?

      payloads = Array(message[:images]).filter_map do |img|
        base64 = img[:base64] || img["base64"]
        next if base64.nil? || base64.to_s.empty?

        { mime_type: (img[:mime_type] || img["mime_type"] || "image/png").to_s,
          base64: base64.to_s }
      end
      payloads.empty? ? nil : payloads
    end

    # A config-owned option value. Returns nil when unset: the caller OMITS the key from the request
    # so the server's own default applies (no hidden code-side defaults).
    def cfg(key) = @config.public_send(key)

    # Keep num_ctx sent on the native path even when unset (see NUM_CTX).
    def ctx_window = cfg(:num_ctx) || LLM::NUM_CTX

    def retry_count
      @config.retry_count || LLM::RETRY_COUNT
    end

    def retry_delay
      @config.retry_delay || LLM::RETRY_DELAY
    end

    # Request duration for the log line: plain seconds with 2dp (the console stats line factors
    # minutes out; the log wants one comparable number per attempt).
    def format_seconds(seconds)
      format("%.2f", seconds.to_f)
    end

    # Token counts for the RESP line (prompt-processing speed can be derived from logged time +
    # tokens) plus whatever server-side performance the response reported. Empty when neither.
    def usage_note(usage)
      return "" if usage.nil?

      parts = []
      unless usage[:prompt_tokens].nil? || usage[:completion_tokens].nil?
        parts << "#{usage[:prompt_tokens]} -> #{usage[:completion_tokens]} tokens"
      end
      parts.concat(UsageStats.performance_parts(usage))
      return "" if parts.empty?

      " - " + parts.join(" | ")
    end

    # One line per successful attempt: what was called, how big the answer was, how long it took, tokens.
    def log_response_stats(resp, parsed, elapsed)
      @logger.info "RESP: HTTP #{resp.code} (#{resp.body.to_s.bytesize} bytes) " \
        "in #{format_seconds(elapsed)}s#{usage_note(usage_for(parsed))}"
    end

    # The usage of one RAW parsed response, before normalization: the OpenAI shape has a usage object,
    # the native Ollama shape reports the counts as top-level fields. BaseBackend cannot know which,
    # so check both.
    def usage_for(json)
      return nil unless json.is_a?(Hash)

      usage = core_usage_for(json)
      return nil if usage.nil?

      usage.merge(UsageStats.extended_usage(json))
    end

    def core_usage_for(json)
      return json[:usage] if json[:usage]
      return nil unless json.key?(:prompt_eval_count) || json.key?(:eval_count)

      prompt     = json[:prompt_eval_count].to_i
      completion = json[:eval_count].to_i
      { prompt_tokens: prompt, completion_tokens: completion,
        total_tokens: prompt + completion }
    end

    # Both backends report tool calls as [{id, function: {name, arguments}}]; the native Ollama API
    # sends arguments as a JSON object while OpenAI sends a string. The harness (execute_tool_call)
    # always expects a STRING, so stringify objects here.
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
