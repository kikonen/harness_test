# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"
require "stringio"
require "uri"
require "zlib"

require_relative "address_guard"
require_relative "text_normalizer"

# Fetches one URL over http(s) and hands back the response as text.
#
# This is the ONLY outbound network I/O in the harness outside the LLM client, so
# every guard such a call needs lives here, once (issue #33). Each rule below was
# measured: analysis/33/repro.rb. Rationale: doc/web_fetch_design.md.
#
# THE GUARDS (none of them is grantable - a HOST grant decides whether a host may
# be asked for, never what this class may do to it):
#   - scheme is http/https, and the URL carries no userinfo (a URL with
#     credentials would echo a secret into the conversation and the saved session).
#   - EVERY address the host resolves to is checked BEFORE connecting, and the
#     checked address is the address actually connected to (Net::HTTP#ipaddr=).
#     Resolving twice - once to check, once to connect - is the classic rebinding
#     pass around an address guard.
#   - redirects are re-validated hop by hop up to a cap, so a 302 to
#     http://127.0.0.1/ never becomes a localhost read.
#   - the body is accumulated chunk by chunk and the transfer STOPS at the byte
#     cap, whatever Content-Length claims.
class WebFetcher
  DEFAULT_TIMEOUT = 15    # seconds
  MAX_TIMEOUT     = 60    # hard cap
  MAX_REDIRECTS   = 5
  MAX_BODY_BYTES  = 2_000_000

  ALLOWED_SCHEMES = %w[http https].freeze
  USER_AGENT = "Mozilla/5.0 (compatible; harness-web.fetch/1.0; " \
    "+https://github.com/kikonen/harness_test)".freeze

  Result = Data.define(:status, :content_type, :body, :final_url, :bytes, :redirects)

  # Raised the moment the accumulator passes the cap, INSIDE the body read, so
  # the transfer itself stops (bandwidth and RAM, not just the returned text).
  class BodyTooLarge < StandardError; end

  attr_reader :guard

  def initialize(guard: AddressGuard.new, max_bytes: MAX_BODY_BYTES)
    @guard     = guard
    @max_bytes = max_bytes
  end

  # Returns a Result, or an "error: ..." string for anything the caller must not
  # retry blindly (refused URL, blocked address, redirect loop, timeout).
  def fetch(url, timeout: DEFAULT_TIMEOUT)
    uri = parse(url)
    return uri if uri.is_a?(String)

    timeout = [[timeout.to_i, 1].max, MAX_TIMEOUT].min
    visited = [uri.to_s]
    hops    = 0

    MAX_REDIRECTS.times do
      outcome = one_request(uri, timeout)
      return outcome if outcome.is_a?(String)

      response, chunks = outcome
      unless redirect?(response)
        body = TextNormalizer.normalize(decode(response, chunks))
        return Result.new(
          status: response.code.to_i,
          content_type: response["content-type"].to_s,
          body:,
          final_url: uri.to_s,
          bytes: body.bytesize,
          redirects: hops)
      end

      target = join_target(uri, response["location"])
      return target if target.is_a?(String)
      if visited.include?(target.to_s)
        return "error: redirect loop (#{target} was already fetched)"
      end

      visited << target.to_s
      uri    = target
      hops  += 1
    end

    "error: redirect chain stopped after #{MAX_REDIRECTS} hops (last host #{uri.host})"
  end

  # A URL is refused BEFORE anything is connected to. The scheme is checked
  # first: URI.parse dispatches by scheme, so a ws:// or ftp:// URL arrives as a
  # non-URI::HTTP object, and naming the scheme rule tells the model what to fix.
  def parse(url)
    uri = URI.parse(url.to_s.strip)
    if uri.scheme && !ALLOWED_SCHEMES.include?(uri.scheme)
      return "error: only http and https URLs can be fetched"
    end
    return "error: 'url' must be a valid absolute http(s) URL" unless uri.is_a?(URI::HTTP)
    return "error: the URL has no host" if uri.host.nil? || uri.host.strip.empty?
    # A URL carrying credentials would be echoed back to the model (and saved in
    # the session) as part of the fetched-URL line.
    if uri.user || uri.password
      return "error: a URL with userinfo (user:pass@host) cannot be fetched"
    end

    uri
  rescue URI::Error
    "error: 'url' must be a valid absolute http(s) URL"
  end

  # A blocked IP LITERAL can be refused BEFORE the user is asked anything,
  # because the decision needs no lookup at all: #fetch resolves, and a resolve
  # is itself a network side effect that must not happen without the user's
  # consent. A HOST NAME is therefore left to the resolve path (consent first).
  # Returns the refusal String, or nil when the decision needs DNS or the
  # literal is fine.
  def literal_block(uri)
    host = parse(uri.to_s)
    return nil unless host.is_a?(URI::HTTP)

    candidate = host.host.to_s.delete_prefix("[").delete_suffix("]")
    return nil unless ip_literal?(candidate)
    return nil unless guard.blocked?(candidate)

    "error: #{host.host} is a blocked address " \
      "(a literal IP, no host name to grant)#{private_hint}"
  end

  # Resolves ONCE and checks EVERY address: a host with one public and one
  # private record is refused, not silently reached through the public one.
  # Returns the checked addresses, or an error string.
  def resolve_and_guard(uri)
    addresses = Resolv.getaddresses(uri.host)
    return "error: could not resolve #{uri.host}" if addresses.empty?

    blocked = addresses.find { |addr| guard.blocked?(addr) }
    if blocked
      return "error: #{uri.host} resolves to #{blocked}, which is blocked#{private_hint}"
    end

    addresses
  rescue Resolv::ResolvError, Resolv::ResolvTimeout
    "error: could not resolve #{uri.host}"
  end

  private

  # A Location header can be relative, absolute, or something that is not a URL
  # at all (file:, javascript:); each case lands on a refusal, not on a crash.
  # A refusal from #parse is about a fetched URL in general, so a redirect target
  # gets its reason in redirect terms, with the header value quoted.
  def join_target(uri, location)
    target = parse(URI.join(uri, location.to_s).to_s)
    return target if target.is_a?(URI::HTTP)

    redirect_reason(location)
  rescue URI::Error
    redirect_reason(location)
  end

  def redirect_reason(location)
    shown = TextNormalizer.normalize(location.to_s)[0, 80]
    "error: the redirect target is not a valid http(s) URL (#{shown})"
  end

  def private_hint
    return "" if guard.allow_private?

    " (web_fetch_allow_private: true allows a local or internal endpoint)"
  end

  def ip_literal?(candidate)
    IPAddr.new(candidate)
    true
  rescue ArgumentError # IPAddr::InvalidAddressError is an ArgumentError
    false
  end

  def redirect?(response)
    response.is_a?(Net::HTTPRedirection) && !response["location"].to_s.strip.empty?
  end

  # Every address was already checked, so trying them in turn is not a way past
  # the guard - it is the dual-stack case (a host with an AAAA record this
  # machine cannot reach) getting its chance instead of failing on .first.
  def one_request(uri, timeout)
    addresses = resolve_and_guard(uri)
    return addresses if addresses.is_a?(String)

    failures = []
    addresses.each do |address|
      outcome = attempt(uri, address, timeout)
      # Success is the [response, chunks] pair; a failure is an error String.
      # (An empty chunk list is still a success - a 204 has no body.)
      return outcome unless outcome.is_a?(String)

      failures << "#{address} (#{outcome})"
    end

    "error: could not connect to #{uri.host}: #{failures.join('; ')}"
  rescue BodyTooLarge
    # The cap is NOT a connection failure and must not be dressed as one: a
    # "could not connect" line invites the model to retry the same URL, while the
    # real reason is that the body is too big (and the transfer already stopped,
    # so a retry would cost the same download again).
    "error: body larger than the #{@max_bytes} byte fetch cap (download stopped)"
  end

  # Net::HTTP#request WITH a block yields the RESPONSE object and does NOT
  # decompress the body - so read_body owns the chunk accumulation (where the cap
  # lives) and #decode owns content-encoding. The block form is also what lets a
  # REDIRECT body stay UNread: only a redirect's Location is ever used, so a
  # server that ships a body with its 302 cannot turn one redirect into a
  # download (measured: an 8 MB redirect body read in full reached the cap and
  # failed the whole fetch before this rule existed).
  def attempt(uri, address, timeout)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == "https"
    http.open_timeout = timeout
    http.read_timeout = timeout
    # Connect to the address that passed the guard, not to a second resolution.
    http.ipaddr = address

    chunks = []
    size   = 0
    response = http.start do |conn|
      conn.request(Net::HTTP::Get.new(uri.request_uri, request_headers)) do |res|
        # A redirect's body is never used, so it is never read.
        unless redirect?(res)
          res.read_body do |chunk|
            size += chunk.bytesize
            raise BodyTooLarge if size > @max_bytes

            chunks << chunk
          end
        end
        res
      end
    end

    # BodyTooLarge is deliberately NOT rescued here: it must reach #one_request,
    # where it becomes its own error instead of being wrapped in a "could not
    # connect" line the model would then retry against.
    [response, chunks]
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::HTTPError, Net::HTTPFatalError,
    SocketError, SystemCallError, IOError, Timeout::Error,
    OpenSSL::SSL::SSLError => e
    reason = TextNormalizer.normalize(e.message.to_s)[0, 160]
    "#{e.class.name.split('::').last}: #{reason}"
  end

  def request_headers
    # identity is asked for, but a server may answer gzip anyway (measured: a
    # server asked for identity still sent content-encoding: gzip), so #decode
    # must handle it whatever the request said.
    { "user-agent" => USER_AGENT, "accept" => "*/*", "accept-encoding" => "identity" }
  end

  def decode(response, chunks)
    raw = chunks.join
    encoding = response["content-encoding"].to_s.downcase
    return raw unless %w[gzip x-gzip].include?(encoding)

    Zlib::GzipReader.new(StringIO.new(raw)).read
  rescue Zlib::Error
    # A body that claims to be gzip and is not: the raw bytes ARE what the
    # server sent, and TextNormalizer turns them into safe text.
    raw
  end
end
