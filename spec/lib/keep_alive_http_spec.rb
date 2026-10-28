# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'logger'
require 'keep_alive_http'

# Issue #334: KeepAliveHTTP must actually set the keepalive options on the real
# socket. Since Ruby 4.0 the @socket ivar is a Net::BufferedIO wrapping the
# socket, so the class has to unwrap it (BufferedIO#io) before setsockopt.
# These specs are real, not mocked: a local TCPServer, then the options are read
# back off the socket the class reached.
RSpec.describe KeepAliveHTTP do
  let(:logger) { Logger.new(File::NULL) }

  # A listening socket that accepts one connection and drops it; enough for
  # Net::HTTP#start to complete its TCP connect.
  def with_connected_http
    server = TCPServer.new('127.0.0.1', 0)
    port   = server.addr[1]
    thread = Thread.new { conn = server.accept; conn.close }
    http = described_class.new('127.0.0.1', port)
    http.logger = logger
    begin
      http.start { yield http }
    ensure
      thread.join(1)
    end
  end

  # The socket the class reached: @socket is a BufferedIO, #io is the real socket.
  def reached_socket(http)
    buf = http.instance_variable_get(:@socket)
    buf.respond_to?(:io) ? buf.io : buf
  end

  describe 'keepalive on the real socket (issue #334)' do
    it 'reaches the real socket, not the BufferedIO wrapper' do
      with_connected_http do |http|
        buf = http.instance_variable_get(:@socket)
        # The bug's shape: the ivar is a BufferedIO with no setsockopt.
        expect(buf).to be_a(Net::BufferedIO)
        expect(buf).not_to respond_to(:setsockopt)
        # The class must have unwrapped it to a socket that answers setsockopt.
        expect(reached_socket(http)).to respond_to(:setsockopt)
      end
    end

    it 'sets SO_KEEPALIVE on the socket' do
      with_connected_http do |http|
        byte = reached_socket(http).getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE).to_s
        # SO_KEEPALIVE reads back as 1 byte, not a 4-byte word.
        expect(byte.unpack1('C')).to eq(1)
      end
    end

    it 'sets the TCP_KEEP* options to the class constants' do
      with_connected_http do |http|
        sock = reached_socket(http)
        # The TCP_* options read back as 4-byte little-endian words; a uniform
        # 1-byte unpack would silently read garbage.
        idle = sock.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPIDLE).to_s.unpack1('L<')
        intv = sock.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL).to_s.unpack1('L<')
        cnt  = sock.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT).to_s.unpack1('L<')

        expect(idle).to eq(KeepAliveHTTP::KEEPALIVE_IDLE)
        expect(intv).to eq(KeepAliveHTTP::KEEPALIVE_INTERVAL)
        expect(cnt).to  eq(KeepAliveHTTP::KEEPALIVE_COUNT)
      end
    end
  end

  describe 'unsupported-option path' do
    # The debug line was unreachable before the fix (the whole block was skipped).
    # A stand-in socket that raises on the TCP_KEEP* calls makes it reachable and
    # pins it: SO_KEEPALIVE lands, the TCP_* attempt fails, the failure is logged.
    it 'logs a debug line when the TCP_KEEP* options are not supported' do
      raising = Class.new do
        def setsockopt(_level, name, _val)
          raise Errno::ENOPROTOOPT, 'TCP_KEEP* unsupported' unless name == Socket::SO_KEEPALIVE
        end
      end.new
      allow(logger).to receive(:debug)
      http = described_class.new('127.0.0.1', 1)
      http.logger = logger

      http.send(:apply_keepalive, raising)

      expect(logger).to have_received(:debug)
        .with(a_string_including('TCP_KEEP* keepalive options not applied'))
    end

    it 'does nothing when the reached object has no setsockopt' do
      allow(logger).to receive(:debug)
      http = described_class.new('127.0.0.1', 1)
      http.logger = logger

      http.send(:apply_keepalive, Object.new)

      expect(logger).not_to have_received(:debug)
    end
  end
end
