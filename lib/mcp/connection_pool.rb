# frozen_string_literal: true

module Mcp
  # A per-server pool of live connections (issue #548). A tool call borrows a
  # connection for the duration of the call and always returns it, so a second
  # concurrent call to the SAME server blocks until one frees while a call to a
  # DIFFERENT server (a different pool) never waits. The pool is per server on
  # purpose: two job Harnesses reaching different MCP servers must not contend.
  #
  # Size 1 is the whole point today: the gem's stdio transport is not multiplexed
  # (its response read is a single shared pipe matched by request id), so one
  # stdio connection is safe for one caller at a time. Size 1 makes the pool a
  # per-server mutex. Raising the size later hands out N connections to that
  # server so N calls run in parallel - a capacity knob, not a redesign.
  class ConnectionPool
    attr_reader :size

    # The connections this pool owns (a frozen copy), so the owner can close them.
    attr_reader :connections

    def initialize(connections)
      @connections = Array(connections)
      @size = @connections.size
      raise ArgumentError, "pool needs at least one connection" if @size.zero?

      # A Thread::Queue pre-filled with the connections: pop blocks when the pool
      # is fully borrowed, and returns FIFO, so a waiting call gets the next freed
      # connection. push always returns it to the pool.
      @available = Thread::Queue.new(@connections)
    end

    # Borrow a connection for the block, return it no matter how the block ends
    # (a raising tool call must not strand a pooled connection). Blocks until a
    # connection is free.
    def checkout
      connection = @available.pop
      begin
        yield connection
      ensure
        @available << connection
      end
    end
  end
end
