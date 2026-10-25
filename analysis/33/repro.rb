# frozen_string_literal: true

# Issue #33 (web.fetch): the transport facts the guards are built on, measured
# against a REAL local HTTP server. Run from the repo root: ruby analysis/33/repro.rb
#
# Each section plays the NAIVE approach first (what a fetch would do without the
# rule) and then the shipped class, so the numbers are the difference between the
# two rather than a claim. Rationale: doc/web_fetch_design.md.
require "ipaddr"
require "net/http"
require "resolv"
require "socket"

require_relative "../../lib/address_guard"
require_relative "../../lib/web_fetcher"

# Answers one incoming connection with `lines` (the raw HTTP response). The
# server thread RETURNS how many body bytes it managed to write, so a section can
# compare what the server pushed with what the client actually took.
def with_server(*lines)
  server = TCPServer.new("127.0.0.1", 0)
  port   = server.addr[1]
  wrote  = 0
  thread = Thread.new do
    Thread.current.report_on_exception = false
    conn = nil
    begin
      conn = server.accept
      conn.gets
      conn.gets while (line = conn.gets) && line.strip != ""
      lines.each do |line|
        conn.print(line)
        conn.flush
        wrote += line.bytesize
      end
    rescue StandardError
      # The client stopped reading - that IS the byte cap working.
      nil
    ensure
      conn&.close rescue nil
    end
  end
  outcome = yield(port)
  thread.join(5)
  server.close rescue nil
  puts "    server wrote #{wrote} bytes; client outcome follows"
  outcome
end

def chunked_parts(total)
  parts = ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"]
  while total > 0
    chunk   = "y" * [total, 4096].min
    total  -= chunk.bytesize
    parts << "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n"
  end
  parts << "0\r\n\r\n"
  parts
end

def redirect_with_body(size, location)
  body = "b" * size
  [
    "HTTP/1.1 302 Found\r\nLocation: #{location}\r\n",
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  ]
end

def local_fetcher(**kwargs)
  WebFetcher.new(guard: AddressGuard.new(allow_private: true), **kwargs)
end

puts "== 1. the byte cap STOPS the transfer (it is not a truncation of the text) =="
cap = 50_000
big = chunked_parts(4_000_000)

naive = with_server(*big) do |port|
  read = 0
  http = Net::HTTP.new("127.0.0.1", port)
  http.open_timeout = 8
  http.read_timeout = 8
  http.start do |conn|
    conn.request(Net::HTTP::Get.new("/")) { |res| res.read_body { |c| read += c.bytesize } }
  end
  read
end
puts "    naive (no cap): read #{naive} bytes"

capped = with_server(*big) do |port|
  local_fetcher(max_bytes: cap).fetch("http://127.0.0.1:#{port}/big", timeout: 8)
end
puts "    web.fetch with a #{cap} byte cap: #{capped}"

puts "\n== 2. a redirect body must never be read =="
# Net::HTTP pulls a redirect body when the response is taken without a block, so
# a large one reaches the cap and fails the WHOLE fetch.
naive_redirect = with_server(*redirect_with_body(8_000_000, "/target")) do |port|
  read  = 0
  http  = Net::HTTP.new("127.0.0.1", port)
  http.open_timeout = 8
  http.read_timeout = 8
  begin
    http.start do |conn|
      conn.request(Net::HTTP::Get.new("/start")) do |res|
        res.read_body { |c| read += c.bytesize }
        res
      end
    end
  rescue StandardError
    nil
  end
  read
end
puts "    naive read of a 302 carrying 8 MB: #{naive_redirect} bytes read"

# Two connections: the 8 MB redirect, then the small final answer.
server = TCPServer.new("127.0.0.1", 0)
port   = server.addr[1]
thread = Thread.new do
  Thread.current.report_on_exception = false
  2.times do |hop|
    conn = server.accept
    conn.gets
    conn.gets while (line = conn.gets) && line.strip != ""
    lines = hop.zero? ? redirect_with_body(8_000_000, "/final") :
                        ["HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nfinal!!!"]
    lines.each { |line| conn.print(line) }
    conn.flush
    conn.close
  rescue StandardError
    nil
  end
end
start_url = "http://127.0.0.1:#{port}/start"
through = local_fetcher(max_bytes: 100_000).fetch(start_url, timeout: 8)
thread.join(5)
server.close rescue nil
puts "    web.fetch through the same 8 MB redirect: #{through}"

puts "\n== 3. the checked address IS the address connected to (the rebinding hole) =="
# The URL names a host that is not this server; the address the guard checked is
# what the client connects to. This is exactly the shape #attempt uses.
server  = TCPServer.new("127.0.0.1", 0)
port    = server.addr[1]
saw     = nil
thread  = Thread.new do
  Thread.current.report_on_exception = false
  begin
    conn = server.accept
    request_line = conn.gets.to_s.strip
    headers      = []
    headers << conn.gets while (line = conn.gets) && line.strip != ""
    host = headers.grep(/host/i).first.to_s.strip
    saw  = "#{request_line} #{host}"
    conn.print("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    conn.flush
    conn.close
  rescue StandardError
    nil
  end
end
http = Net::HTTP.new("example.invalid", port)
http.ipaddr = "127.0.0.1" # the address the guard checked, not a second resolution
res = http.start { |conn| conn.request(Net::HTTP::Get.new("/")) { |r| r.read_body; r } }
thread.join(4)
server.close rescue nil
puts "    server saw #{saw.inspect} while the client connected to 127.0.0.1"
puts "    (the header names ANOTHER host, and the body arrived: #{res.body.inspect})"

puts "\n== 4. IPAddr#private? is not a guard on this Ruby (Ruby #{RUBY_VERSION}) =="
%w[127.0.0.1 ::1 :: 100.64.0.1 169.254.169.254 8.8.8.8].each do |addr|
  default = AddressGuard.new.blocked?(addr)
  lifted  = AddressGuard.new(allow_private: true).blocked?(addr)
  puts "    #{addr.ljust(16)} private?=#{IPAddr.new(addr).private?} " \
    "blocked?=#{default} still_blocked_with_opt-in=#{lifted}"
end
puts "    (loopback/CGNAT lift with the opt-in; link-local and :: never do)"

puts "\n== 5. a blocked IP literal is refused BEFORE consent, with no lookup =="
lookups = 0
Resolv.singleton_class.prepend(
  Module.new do
    def getaddresses(host)
      @lookups = (@lookups || 0) + 1
      super
    end
  end)
fetcher = WebFetcher.new
puts "    #{fetcher.literal_block(fetcher.parse("http://127.0.0.1:8080/x"))}"
puts "    #{fetcher.literal_block(fetcher.parse("http://[::1]:8080/"))}"
# A host NAME is not this method's decision: only DNS can tell what it points at.
example = fetcher.literal_block(fetcher.parse("http://example.com/")).inspect
localhost = fetcher.literal_block(fetcher.parse("http://localhost:8080/")).inspect
puts "    host names are left to the resolve path: #{example} #{localhost}"
puts "    Resolv lookups the pre-consent refusals performed: #{lookups}"
