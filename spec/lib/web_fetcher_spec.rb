# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'web_fetcher'

# The helpers are at TOP LEVEL (house pattern, see base_backend_streaming_spec.rb):
# a class written inside a block still lands in the enclosing scope.

# A scripted HTTP server: it answers each incoming connection with the next
# response in the list, so a spec controls exactly what the client reads - and a
# redirect test can script the WHOLE chain. Chunked responses are what make the
# byte-cap behavior visible (the client sees the body piece by piece).
class ScriptedHTTPServer
  Response = Data.define(:status, :headers, :body, :chunked)

  attr_reader :port
  # Each served connection's request line and headers, so a spec can assert what
  # the client ACTUALLY sent (a Host header is not visible from the client side).
  attr_reader :requests

  def initialize(*responses)
    @responses = responses.map do |r|
      r.is_a?(Response) ? r : Response.new(status: '200 OK', headers: {}, body: r.to_s, chunked: false)
    end
    @requests = []
    @served = 0
    @server = TCPServer.new('127.0.0.1', 0)
    @port   = @server.addr[1]
    @thread = Thread.new { serve_all }
  end

  def self.response(status: '200 OK', headers: {}, body: '', chunked: false)
    Response.new(status:, headers:, body:, chunked:)
  end

  def url(path = '/') = "http://127.0.0.1:#{@port}#{path}"

  def close
    @server.close
  rescue IOError
    nil
  ensure
    @thread&.join(2)
  end

  private

  def serve_all
    @responses.each do |response|
      conn = @server.accept
      write_response(conn, response)
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      # The client stopped reading (that is the byte cap working: the transfer
      # itself ends, the server notices). A spec asserts the CLIENT's outcome.
      break
    ensure
      conn&.close rescue nil
      @served += 1
    end
  end

  def write_response(conn, response)
    # Drain the request headers before answering.
    request_line = conn.gets.to_s
    headers = []
    headers << conn.gets while (line = conn.gets) && line.strip != ''
    @requests << { request_line: request_line, headers: headers.join }

    if response.chunked
      conn.print("HTTP/1.1 #{response.status}\r\nTransfer-Encoding: chunked\r\n\r\n")
      response.body.scan(/.{1,4096}/m).each do |part|
        conn.print("#{part.bytesize.to_s(16)}\r\n#{part}\r\n")
        conn.flush
      end
      conn.print("0\r\n\r\n")
    else
      conn.print("HTTP/1.1 #{response.status}\r\n")
      response.headers.each { |k, v| conn.print("#{k}: #{v}\r\n") }
      conn.print("Content-Length: #{response.body.bytesize}\r\n\r\n#{response.body}")
    end
    conn.flush
  end
end

# Every guard rule below is exercised against a LOCAL server, which the default
# guard refuses - so the guard tests assert the refusal, and the transport tests
# run with an explicitly allow_private guard (the same opt-in a user would set
# for a local endpoint). No spec touches the real network.
RSpec.describe WebFetcher do
  # The guard lifted on purpose, for the transport behavior only.
  def local_fetcher(**kwargs)
    described_class.new(guard: AddressGuard.new(allow_private: true), **kwargs)
  end

  describe 'URL rules (refused before anything is connected to)' do
    subject(:fetcher) { described_class.new }

    it 'accepts an absolute http or https URL' do
      expect(fetcher.parse('http://example.com/a')).to be_a(URI::HTTP)
      expect(fetcher.parse('https://example.com/a')).to be_a(URI::HTTP)
    end

    it 'refuses any other scheme' do
      expect(fetcher.parse('ftp://example.com/a')).to eq('error: only http and https URLs can be fetched')
      expect(fetcher.parse('file:///etc/passwd')).to include('only http and https')
      # A scheme-carrying non-http URL is refused for its scheme, not as a
      # malformed URL; a scheme-less one (below, a relative path) is malformed.
      expect(fetcher.parse('javascript:alert(1)')).to include('only http and https')
      expect(fetcher.parse('mailto:a@b.com')).to include('only http and https')
    end

    it 'refuses a relative URL' do
      expect(fetcher.parse('/just/a/path')).to include('must be a valid absolute')
    end

    it 'refuses a URL with no host' do
      expect(fetcher.parse('http:///no-host')).to eq('error: the URL has no host')
    end

    # A URL carrying credentials would be echoed back to the model (and saved in
    # the session) as part of the fetched-URL line.
    it 'refuses a URL with userinfo' do
      expect(fetcher.parse('http://user:secret@example.com/'))
        .to eq('error: a URL with userinfo (user:pass@host) cannot be fetched')
    end
  end

  describe 'the address guard (SSRF)' do
    # The server IS running, and it is still refused: the guard decides before
    # connecting, on the resolved address, not on whether something is listening.
    it 'refuses a host that resolves to loopback' do
      server = ScriptedHTTPServer.new('body')
      begin
        result = described_class.new.fetch(server.url)
        expect(result).to include('which is blocked')
        expect(result).not_to include('body')
      ensure
        server.close
      end
    end

    it 'names the blocked address and points at the opt-in' do
      server = ScriptedHTTPServer.new('body')
      begin
        result = described_class.new.fetch(server.url)
        expect(result).to include('127.0.0.1')
        expect(result).to include('web_fetch_allow_private')
      ensure
        server.close
      end
    end

    it 'mentions the cloud metadata range as the reason link-local is refused' do
      expect(described_class.new.parse('http://169.254.169.254/latest/meta-data/')).to be_a(URI::HTTP)
      # parse only checks the URL shape; the ADDRESS is what the guard refuses.
      expect(AddressGuard.new.blocked?('169.254.169.254')).to be true
    end

    # #literal_block is the pre-consent half of the guard: it decides a host from
    # the URL STRING ALONE, so a caller can refuse before asking the user and
    # before any lookup (a resolve is itself a network side effect).
    describe '#literal_block (a refusal that needs no lookup)' do
      subject(:fetcher) { described_class.new }

      it 'refuses a blocked IP literal and names the opt-in' do
        uri = fetcher.parse('http://127.0.0.1:8080/x')
        out = fetcher.literal_block(uri)

        expect(out).to include('127.0.0.1 is a blocked address')
        expect(out).to include('web_fetch_allow_private')
      end

      # The invariant: refusing must not resolve, or the pre-consent path would
      # itself be a network side effect.
      it 'performs no lookup at all' do
        expect(Resolv).not_to receive(:getaddresses)
        expect(fetcher.literal_block(fetcher.parse('http://169.254.169.254/'))).to include('blocked')
      end

      it 'refuses an IPv6 literal written with brackets' do
        expect(fetcher.literal_block(fetcher.parse('http://[::1]:8080/'))).to include('blocked address')
      end

      it 'says nothing about a public literal (the fetch may go on asking)' do
        expect(fetcher.literal_block(fetcher.parse('http://8.8.8.8/'))).to be_nil
      end

      # A host NAME is not this method's decision: only DNS can tell what it is.
      it 'leaves a host name to the resolve path' do
        expect(fetcher.literal_block(fetcher.parse('http://example.com/'))).to be_nil
        expect(fetcher.literal_block(fetcher.parse('http://localhost:8080/'))).to be_nil
      end

      it 'lifts a private literal when the guard was built with allow_private' do
        lifted = described_class.new(guard: AddressGuard.new(allow_private: true))

        expect(lifted.literal_block(lifted.parse('http://127.0.0.1:8080/'))).to be_nil
        # Link-local stays refused even lifted: the opt-in is for a local
        # endpoint, not a pass to the cloud metadata range.
        expect(lifted.literal_block(lifted.parse('http://169.254.169.254/'))).to include('blocked')
      end

      it 'says nothing for a URL it would refuse anyway' do
        expect(fetcher.literal_block('ftp://127.0.0.1/')).to be_nil
      end
    end

    # The dual-stack trap: a host whose records include a private one is refused
    # outright, not connected to via its public record.
    it 'refuses when ANY resolved address is blocked' do
      server = ScriptedHTTPServer.new('body')
      begin
        fetcher = described_class.new
        uri = fetcher.parse(server.url)
        allow(Resolv).to receive(:getaddresses).with(uri.host)
                                               .and_return(['8.8.8.8', '127.0.0.1'])
        expect(fetcher.resolve_and_guard(uri)).to include('which is blocked')
      ensure
        server.close
      end
    end

    it 'lets a local endpoint through when the guard was built with allow_private' do
      server = ScriptedHTTPServer.new('local body')
      begin
        result = local_fetcher.fetch(server.url)
        expect(result).to be_a(WebFetcher::Result)
        expect(result.body).to eq('local body')
      ensure
        server.close
      end
    end
  end

  describe 'reading a response' do
    it 'returns the status, content type, body and final URL' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '200 OK',
                                    headers: { 'Content-Type' => 'application/json' },
                                    body: '{"ok":true}')
      )
      begin
        result = local_fetcher.fetch(server.url('/api'))
        expect(result.status).to eq(200)
        expect(result.content_type).to eq('application/json')
        expect(result.body).to eq('{"ok":true}')
        expect(result.final_url).to eq(server.url('/api'))
        expect(result.redirects).to eq(0)
      ensure
        server.close
      end
    end

    # A 404 is an ANSWER, not a failure: the model must see the status and the
    # body (an API error message usually lives in the body).
    it 'reports a non-2xx status as a result, not an error' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '404 Not Found', body: 'no such page')
      )
      begin
        result = local_fetcher.fetch(server.url)
        expect(result).to be_a(WebFetcher::Result)
        expect(result.status).to eq(404)
        expect(result.body).to eq('no such page')
      ensure
        server.close
      end
    end

    it 'decompresses a gzip body (a server may gzip even when asked for identity)' do
      require 'zlib'
      gzipped = Zlib.gzip('the real text')
      server  = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(headers: { 'Content-Type' => 'text/plain',
                                               'Content-Encoding' => 'gzip' },
                                    body: gzipped)
      )
      begin
        result = local_fetcher.fetch(server.url)
        expect(result.body).to eq('the real text')
      ensure
        server.close
      end
    end

    it 'leaves a body alone when the gzip claim is false' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(headers: { 'Content-Encoding' => 'gzip' }, body: 'plain text')
      )
      begin
        expect(local_fetcher.fetch(server.url).body).to eq('plain text')
      ensure
        server.close
      end
    end

    # The address the guard checked IS the address connected to: the URL names a
    # host that resolves (here, by stub) to 127.0.0.1, and the request line and
    # Host header still carry the URL's own host. This is what closes the
    # rebinding hole - the client cannot be pointed at one address while asking
    # for another, and the guard sees the address it will actually connect to.
    it 'connects to the guarded address while asking for the URL host' do
      server = ScriptedHTTPServer.new('ok')
      begin
        fetcher = local_fetcher
        url  = "http://local.test:#{server.port}/page"
        allow(Resolv).to receive(:getaddresses).with('local.test').and_return(['127.0.0.1'])

        result = fetcher.fetch(url)
        expect(result).to be_a(WebFetcher::Result)
        expect(result.final_url).to eq(url)

        request = server.requests.first
        expect(request[:request_line]).to include('GET /page')
        expect(request[:headers]).to include('Host: local.test')
      ensure
        server.close
      end
    end

    it 'normalizes a body that is not valid UTF-8' do
      bad = [0xE2, 0x90].pack('C*')
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(body: bad)
      )
      begin
        result = local_fetcher.fetch(server.url)
        expect(result.body.valid_encoding?).to be true
        # The session save (JSON.generate) must not raise on the result.
        expect { JSON.generate(result.body) }.not_to raise_error
      ensure
        server.close
      end
    end
  end

  describe 'the byte cap' do
    # The cap is not a truncation of the text: the TRANSFER stops (the server
    # sees the connection reset mid-body). A page is not trusted to be the size
    # its Content-Length claims.
    it 'refuses a body larger than the cap and says the download stopped' do
      big = 'y' * 300_000
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(body: big, chunked: true)
      )
      begin
        result = local_fetcher(max_bytes: 50_000).fetch(server.url)
        expect(result).to be_a(String)
        expect(result).to include('50000 byte fetch cap')
        expect(result).to include('download stopped')
      ensure
        server.close
      end
    end

    it 'keeps a body under the cap intact' do
      body = 'y' * 10_000
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(body:, chunked: true)
      )
      begin
        result = local_fetcher(max_bytes: 50_000).fetch(server.url)
        expect(result).to be_a(WebFetcher::Result)
        expect(result.bytes).to eq(10_000)
      ensure
        server.close
      end
    end
  end

  describe 'redirects' do
    it 'follows a relative Location and counts the hops' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '302 Found',
                                    headers: { 'Location' => '/final' }, body: ''),
        'after the redirect'
      )
      begin
        result = local_fetcher.fetch(server.url('/start'))
        expect(result).to be_a(WebFetcher::Result)
        expect(result.body).to eq('after the redirect')
        expect(result.final_url).to eq(server.url('/final'))
        expect(result.redirects).to eq(1)
      ensure
        server.close
      end
    end

    # Only the Location of a redirect is used, so its body is never read: a
    # server that ships a large body with its 302 must not turn one redirect
    # into a download (measured: an 8 MB redirect body used to reach the cap and
    # fail the whole fetch).
    it 'does not read a redirect body, however large it is' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '302 Found',
                                    headers: { 'Location' => '/final' },
                                    body: 'b' * 8_000_000),
        'small final body'
      )
      begin
        result = local_fetcher(max_bytes: 100_000).fetch(server.url('/start'))
        expect(result).to be_a(WebFetcher::Result)
        expect(result.body).to eq('small final body')
      ensure
        server.close
      end
    end

    # THE guard test: a granted host redirecting to loopback must not become a
    # localhost read. Here the FIRST host is the local server, and the redirect
    # target is the cloud metadata address.
    it 'refuses a redirect that targets a blocked address' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '302 Found',
                                    headers: { 'Location' => 'http://169.254.169.254/latest/meta-data/' },
                                    body: '')
      )
      begin
        fetcher = local_fetcher
        result  = fetcher.fetch(server.url('/start'))
        expect(result).to be_a(String)
        expect(result).to include('169.254.169.254')
        expect(result).to include('blocked')
      ensure
        server.close
      end
    end

    it 'refuses a redirect target that is not an http(s) URL' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '302 Found',
                                    headers: { 'Location' => 'javascript:alert(1)' }, body: '')
      )
      begin
        result = local_fetcher.fetch(server.url('/start'))
        expect(result).to be_a(String)
        expect(result).to include('not a valid http(s) URL')
      ensure
        server.close
      end
    end

    it 'stops on a redirect loop instead of following forever' do
      server = ScriptedHTTPServer.new(
        ScriptedHTTPServer.response(status: '302 Found',
                                    headers: { 'Location' => '/start' }, body: '')
      )
      begin
        result = local_fetcher.fetch(server.url('/start'))
        expect(result).to be_a(String)
        expect(result).to include('redirect loop')
      ensure
        server.close
      end
    end

    it 'caps the redirect chain' do
      # Each hop points at a distinct path, so it is a chain, not a loop.
      hops = (0..5).map do |i|
        ScriptedHTTPServer.response(status: '302 Found',
                                    headers: { 'Location' => "/h#{i + 1}" }, body: '')
      end
      server = ScriptedHTTPServer.new(*hops)
      begin
        result = local_fetcher.fetch(server.url('/h0'))
        expect(result).to be_a(String)
        expect(result).to include('redirect chain stopped after 5 hops')
      ensure
        server.close
      end
    end
  end

  describe 'a failed connection' do
    # An address that is reachable in form but has nothing listening: the error
    # must name the host, so the model can see WHY rather than retry blindly.
    it 'reports the host when no connection can be made' do
      dead = TCPServer.new('127.0.0.1', 0)
      port = dead.addr[1]
      dead.close # nothing is listening on this port any more

      result = local_fetcher.fetch("http://127.0.0.1:#{port}/", timeout: 2)
      expect(result).to be_a(String)
      expect(result).to include('could not connect to 127.0.0.1')
    end

    it 'reports a host that does not resolve' do
      result = described_class.new.fetch('http://no-such-host.invalid/')
      expect(result).to be_a(String)
      expect(result).to include('could not resolve')
    end
  end
end
