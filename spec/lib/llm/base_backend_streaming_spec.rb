# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'socket'
require 'llm/base_backend'

# The helpers are defined at TOP LEVEL, not inside the example group: a class
# written inside a block still lands in the enclosing scope, so defining it
# there only hides where it lands (Lint/ConstantDefinitionInBlock).

# A concrete backend over the shared machinery (BaseBackend is abstract).
class StreamingBackend < LLM::BaseBackend
  def api_type = LLM::OPENAI
  def endpoint_path = '/chat/completions'

  private

  def build_body(messages, _tools, stream: false)
    { model: @options[:model], messages: messages, stream: stream }
  end

  def parse_response(json) = json
end

# Minimal chunked-response server. Each part is flushed separately so the
# client sees them as separate chunks (the condition the reader exists for).
class ChunkedServer
  attr_reader :port, :requests, :bodies

  def initialize(status: "200 OK", parts:, chunked: true, close_early: false)
    @status      = status
    @parts       = parts
    @chunked     = chunked
    @close_early = close_early
    @requests    = []
    @bodies      = []
    @server      = TCPServer.new("127.0.0.1", 0)
    @port        = @server.addr[1]
    @thread      = Thread.new { serve }
  end

  # Closing the listening socket makes the blocked accept raise, which ends
  # the server thread: joining first would wait out a timeout per example.
  def close
    @server.close
  rescue IOError
    nil
  ensure
    @thread&.join(1)
  end

  private

  def serve
    loop do
      conn = @server.accept
      @requests << read_headers(conn)
      if @chunked
        conn.print("HTTP/1.1 #{@status}\r\nTransfer-Encoding: chunked\r\n\r\n")
        @parts.each do |part|
          conn.print("#{part.bytesize.to_s(16)}\r\n#{part}\r\n")
          conn.flush
        end
        conn.print("0\r\n\r\n") unless @close_early
      else
        body = @parts.join
        conn.print("HTTP/1.1 #{@status}\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      end
      conn.flush
      conn.close
    end
  rescue IOError, Errno::ECONNRESET
    nil
  end

  # Reads the request headers AND the body they declare, so a spec can
  # assert what the client actually sent rather than poking the builder.
  def read_headers(conn)
    lines = []
    while (line = conn.gets)
      break if line.strip.empty?

      lines << line
    end
    length = lines.map { |l| l[/Content-Length: (\d+)/i, 1] }.compact.first.to_i
    @bodies << (length.positive? ? conn.read(length) : "")
    lines.join
  end
end

# The streamed request path, exercised against a REAL chunked HTTP server: the
# behavior under test is transport behavior (chunk boundaries, the retry
# boundary, status handling), which a stubbed response object cannot show.
RSpec.describe "BaseBackend streaming" do
  let(:log)    { StringIO.new }
  let(:logger) { Logger.new(log) }
  let(:options) do
    { base_url: 'http://127.0.0.1', model: 'test-model', api: 'openai',
      retry_count: 2, retry_delay: 0 }
  end

  def backend_for(port, opts = {})
    StreamingBackend.new(options.merge(base_url: "http://127.0.0.1:#{port}").merge(opts), logger)
  end

  def logged_lines = log.string.lines.map(&:chomp).reject(&:empty?)

  def sse(payload) = "data: #{payload}\n\n"

  describe 'reading a streamed OpenAI-style body' do
    it 'reassembles content deltas into one answer' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}'),
        sse('{"choices":[{"delta":{"content":"lo there"}}]}'),
        sse('{"choices":[{"delta":{},"finish_reason":"stop"}]}'),
        "data: [DONE]\n\n"
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        message = result[:choices][0][:message]
        expect(message[:role]).to eq('assistant')
        expect(message[:content]).to eq('Hello there')
        expect(message[:tool_calls]).to be_nil
      ensure
        server.close
      end
    end

    it 'hands every part to on_delta as it arrives' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"content":"one"}}]}'),
        sse('{"choices":[{"delta":{"content":" two"}}]}')
      ])
      deltas = []
      begin
        backend_for(server.port).chat([{ role: 'user', content: 'hi' }],
                                      stream: true,
                                      on_delta: ->(d) { deltas << d })

        expect(deltas).to eq([{ content: "one" }, { content: " two" }])
      ensure
        server.close
      end
    end

    # The transport hands chunks wherever it likes: one SSE line can be split
    # across chunks, and one chunk can carry several lines.
    it 'reassembles a line that arrived in pieces' do
      server = ChunkedServer.new(parts: [
        "data: {\"choices\":[{\"del",
        "ta\":{\"content\":\"split\"}}]}\n\n"
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(result[:choices][0][:message][:content]).to eq('split')
      ensure
        server.close
      end
    end

    it 'reads several lines carried by one chunk' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"content":"a"}}]}') +
        sse('{"choices":[{"delta":{"content":"b"}}]}')
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(result[:choices][0][:message][:content]).to eq('ab')
      ensure
        server.close
      end
    end

    it 'keeps a multi-byte character whole when its bytes span chunks' do
      whole  = sse('{"choices":[{"delta":{"content":"café"}}]}')
      bytes  = whole.dup.force_encoding(Encoding::BINARY)
      server = ChunkedServer.new(parts: [bytes[0, 30], bytes[30..]])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(result[:choices][0][:message][:content]).to eq('café')
      ensure
        server.close
      end
    end

    it 'reads the usage block a streamed request reports' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"content":"hi"}}]}'),
        sse('{"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}')
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(result[:usage]).to eq(
          { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16 }
        )
      ensure
        server.close
      end
    end

    # issue #251: llama.cpp attaches timings to the LAST delta and Ollama
    # reports its Metrics on the done line - both must land in the usage the
    # accumulator hands back (and therefore in the RESP line).
    it 'carries the timings the final chunk reports' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"content":"hi"}}]}'),
        sse('{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":50,' \
            '"prompt_tokens_details":{"cached_tokens":768}},' \
            '"timings":{"prompt_ms":410.5,"predicted_ms":1310.2}}')
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(result[:usage]).to include(
          prompt_tokens: 1000, completion_tokens: 50, total_tokens: 1050,
          cached_tokens: 768, prompt_eval_ms: 410.5, eval_ms: 1310.2
        )
        expect(logged_lines.grep(/RESP:/).first).to include('768 cached')
      ensure
        server.close
      end
    end

    it 'reassembles fragmented tool-call arguments into one call' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",' \
            '"function":{"name":"file.read","arguments":""}}]}}]}'),
        sse('{"choices":[{"delta":{"tool_calls":[{"index":0,' \
            '"function":{"arguments":"{\"path\":\"a.rb\"}"}}]}}]}'),
        sse('{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}')
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        call = result[:choices][0][:message][:tool_calls].first
        expect(call[:id]).to eq('c1')
        expect(call[:function][:name]).to eq('file.read')
        expect(call[:function][:arguments]).to eq('{"path":"a.rb"}')
      ensure
        server.close
      end
    end

    # issue #345: the streamed path had the reason in hand and dropped it, so a
    # cut-off answer reached the harness looking like a bad one.
    it 'reports a length finish_reason from the streamed body' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",' \
            '"function":{"name":"file.write","arguments":"{\"content\":"}}]}}]}'),
        sse('{"choices":[{"delta":{},"finish_reason":"length"}]}')
      ])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(result[:finish_reason]).to eq('length')
      ensure
        server.close
      end
    end

    # issue #368: BaseBackend#forward_delta skips an EMPTY delta, so a chunk that
    # carried only tool-call fragments used to reach the caller as nothing - the
    # spinner never learned a tool call was being written. The accumulator now
    # reports the names, so the delta is not empty and the phase arrives.
    it 'hands a tool-call-only chunk to on_delta with its names' do
      server = ChunkedServer.new(parts: [
        sse('{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",' \
            '"function":{"name":"file.write","arguments":""}}]}}]}'),
        sse('{"choices":[{"delta":{"tool_calls":[{"index":0,' \
            '"function":{"arguments":"{\"content\":\"body\"}"}}]}}]}')
      ])
      begin
        deltas = []
        backend_for(server.port).chat([{ role: 'user', content: 'hi' }],
                                      stream: true,
                                      on_delta: ->(d) { deltas << d })

        expect(deltas.map { |d| d[:tool_call_names] }).to eq([['file.write'], ['file.write']])
        expect(deltas).not_to include({})
      ensure
        server.close
      end
    end

    it 'logs one REQ line marked streaming and one RESP line with streamed bytes' do
      server = ChunkedServer.new(parts: [sse('{"choices":[{"delta":{"content":"hi"}}]}')])
      begin
        backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        req  = logged_lines.grep(/REQ:/).first
        resp = logged_lines.grep(/RESP:/).first
        expect(req).to include('streaming')
        expect(resp).to include('streamed bytes')
        expect(resp).to match(/ in \d+\.\d\ds/)
      ensure
        server.close
      end
    end
  end

  describe 'the request asks for a stream' do
    # Asserted on the body the server actually received: the CALLER's choice
    # is what reaches the endpoint (the per-backend flag itself is covered in
    # the openai/ollama backend specs).
    it 'sends stream: true when the caller requests it' do
      server = ChunkedServer.new(parts: [sse('{"choices":[{"delta":{"content":"x"}}]}')])
      begin
        backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)

        expect(server.requests.first).to include('POST /chat/completions')
        expect(JSON.parse(server.bodies.first)['stream']).to be true
      ensure
        server.close
      end
    end

    it 'sends stream: false when the caller does not ask' do
      server = ChunkedServer.new(chunked: false,
                                 parts: ['{"choices":[{"message":{"content":"x"}}]}'])
      begin
        backend_for(server.port).chat([{ role: 'user', content: 'hi' }])

        expect(JSON.parse(server.bodies.first)['stream']).to be false
      ensure
        server.close
      end
    end
  end

  describe 'status handling on the streamed path' do
    it 'raises LLMError with the server body on a 4xx (terminal, no retry)' do
      server = ChunkedServer.new(status: '400 Bad Request',
                                 parts: ['{"error":"bad request"}'])
      begin
        expect {
          backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)
        }.to raise_error(LLMError, /HTTP 400/)

        expect(logged_lines.grep(/REQ:/).size).to eq(1)
        # Logger writes a multi-line message as separate lines, so the server
        # body lands on the line after the status one.
        index = logged_lines.index { |l| l.include?('LLM error (HTTP 400)') }
        expect(logged_lines[index + 1]).to include('bad request')
      ensure
        server.close
      end
    end

    # A 5xx is retried while nothing has arrived; the LAST attempt's status is
    # what the caller sees, so the message names the status, not the attempt
    # count (that wording belongs to a transport failure).
    it 'retries a 5xx while no answer has arrived, then reports the status' do
      server = ChunkedServer.new(status: '500 Server Error', parts: ['{"error":"boom"}'])
      begin
        expect {
          backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)
        }.to raise_error(LLMError, /HTTP 500/)

        expect(logged_lines.grep(/REQ:/).size).to eq(2)
        expect(logged_lines.grep(/HTTP 500 \(attempt 1\/2\)/).size).to eq(1)
      ensure
        server.close
      end
    end
  end

  describe 'the retry boundary (the cost of streaming)' do
    # A stream cut off BEFORE any answer: nothing was shown to the user, so a
    # re-send is safe and the harness retries.
    it 'retries when the stream died before any part arrived' do
      server = ChunkedServer.new(parts: [], close_early: true)
      begin
        expect {
          backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)
        }.to raise_error(LLMError, /after 2 attempts/)

        expect(logged_lines.grep(/REQ:/).size).to eq(2)
        expect(logged_lines.grep(/before any answer/).size).to eq(1)
      ensure
        server.close
      end
    end

    # A stream cut off AFTER an answer had started: the user already saw part
    # of it, so re-sending would duplicate. The turn fails instead.
    it 'does not retry once part of the answer reached the caller' do
      server = ChunkedServer.new(parts: [sse('{"choices":[{"delta":{"content":"partial"}}]}')],
                                 close_early: true)
      begin
        expect {
          backend_for(server.port).chat([{ role: 'user', content: 'hi' }], stream: true)
        }.to raise_error(LLM::StreamError, /stream lost/)

        expect(logged_lines.grep(/REQ:/).size).to eq(1)
        expect(logged_lines.grep(/not retrying/).size).to eq(1)
      ensure
        server.close
      end
    end

    it 'raises StreamError (an LLMError) so the harness reports a lost turn' do
      expect(LLM::StreamError.ancestors).to include(LLMError)
    end

    it 'keeps the partial answer it did receive in the raised error context' do
      server = ChunkedServer.new(parts: [sse('{"choices":[{"delta":{"content":"shown"}}]}')],
                                 close_early: true)
      begin
        deltas = []
        expect {
          backend_for(server.port).chat([{ role: 'user', content: 'hi' }],
                                        stream: true, on_delta: ->(d) { deltas << d })
        }.to raise_error(LLM::StreamError)

        expect(deltas).to eq([{ content: "shown" }])
      ensure
        server.close
      end
    end
  end

  describe 'the buffered path is unchanged' do
    it 'reads a non-streamed body without a stream flag in the request' do
      server = ChunkedServer.new(chunked: false,
                                 parts: ['{"choices":[{"message":{"content":"whole"}}]}'])
      begin
        result = backend_for(server.port).chat([{ role: 'user', content: 'hi' }])

        expect(result[:choices][0][:message][:content]).to eq('whole')
        expect(logged_lines.grep(/REQ:/).first).not_to include('streaming')
      ensure
        server.close
      end
    end
  end
end
