# frozen_string_literal: true

require "net/http"
require "logger"

# Net::HTTP with TCP keepalive enabled on the underlying socket, so that
# long-running LLM generations are not cut off by idle-connection timeouts
# (NATs, proxies, or the server itself dropping quiet connections).
class KeepAliveHTTP < Net::HTTP
  # TCP keepalive settings: prevent idle connections from being cut off
  # by NATs/proxies/servers during long generations.
  KEEPALIVE_IDLE     = 60   # seconds of idle before the first keepalive probe
  KEEPALIVE_INTERVAL = 10   # seconds between keepalive probes
  KEEPALIVE_COUNT    = 6    # unanswered probes before the connection is dropped

  # Optional logger for diagnostics (e.g. unsupported keepalive options).
  attr_writer :logger

  def logger
    @logger || Logger.new(File::NULL)
  end

  def connect
    super
    # Since Ruby 4.0 the @socket ivar is a Net::BufferedIO wrapping the real
    # socket, not the socket itself; BufferedIO#io (public) unwraps it - an
    # SSLSocket for https, whose setsockopt delegates to the TCP socket. The
    # ternary keeps the older shape where @socket is already a socket.
    socket = @socket.respond_to?(:io) ? @socket.io : @socket
    apply_keepalive(socket)
  end

  private

  def apply_keepalive(socket)
    return unless socket.respond_to?(:setsockopt)

    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, 1)
    begin
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE,  KEEPALIVE_IDLE)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL, KEEPALIVE_INTERVAL)
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT,   KEEPALIVE_COUNT)
    rescue StandardError => e
      # TCP_KEEP* options are not available on all platforms (e.g. Windows)
      logger.debug("TCP_KEEP* keepalive options not applied: #{e.class}: #{e.message}")
    end
  end
end
