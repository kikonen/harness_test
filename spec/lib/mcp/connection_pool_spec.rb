# frozen_string_literal: true

require 'spec_helper'
require 'mcp/connection_pool'

RSpec.describe Mcp::ConnectionPool do
  def fake_connection(label)
    conn = double("conn-#{label}")
    allow(conn).to receive(:close)
    conn
  end

  describe '#initialize' do
    it 'reports its size as the number of connections it owns' do
      pool = described_class.new([fake_connection(1), fake_connection(2)])

      expect(pool.size).to eq(2)
    end

    it 'exposes the connections it owns so the owner can close them' do
      conns = [fake_connection(1), fake_connection(2)]
      pool  = described_class.new(conns)

      expect(pool.connections).to eq(conns)
    end

    it 'rejects an empty pool (nothing could ever be borrowed)' do
      expect { described_class.new([]) }.to raise_error(ArgumentError)
    end
  end

  describe '#checkout' do
    it 'yields a connection and returns it, so the same one is reusable' do
      conn = fake_connection(1)
      pool = described_class.new([conn])

      seen = pool.checkout { |c| c }

      expect(seen).to be(conn)
      # The connection was returned, so a second checkout gets it again.
      expect(pool.checkout { |c| c }).to be(conn)
    end

    it 'always returns the connection, even when the block raises (no stranding)' do
      conn = fake_connection(1)
      pool = described_class.new([conn])

      expect { pool.checkout { |_c| raise 'boom' } }.to raise_error('boom')

      # Not stranded: the next borrower still gets it rather than blocking forever.
      expect(pool.checkout { |c| c }).to be(conn)
    end

    it 'blocks a second borrower on a size-1 pool until the first returns' do
      conn  = fake_connection(1)
      pool  = described_class.new([conn])
      first_inside  = Queue.new
      first_release = Queue.new

      t1 = Thread.new do
        pool.checkout do
          first_inside << :inside
          first_release.pop # hold the connection until the test releases it
        end
      end

      first_inside.pop # t1 now holds the only connection

      second_done = Queue.new
      t2 = Thread.new { second_done << pool.checkout { :second } }

      # t2 must still be blocked - it cannot have completed while t1 holds the only one.
      expect { second_done.pop(true) }.to raise_error(ThreadError)

      first_release << :go
      t1.join
      expect(second_done.pop).to eq(:second) # now it got a connection
      t2.join
    end

    it 'lets two borrowers run concurrently on a size-2 pool' do
      pool = described_class.new([fake_connection(1), fake_connection(2)])
      inside = 0
      both_inside = Queue.new
      release    = Queue.new
      guard = Mutex.new

      t1 = Thread.new do
        pool.checkout do
          guard.synchronize { inside += 1 }
          both_inside << :in if guard.synchronize { inside == 2 }
          release.pop
        end
      end
      t2 = Thread.new do
        pool.checkout do
          guard.synchronize { inside += 1 }
          both_inside << :in if guard.synchronize { inside == 2 }
          release.pop
        end
      end

      # Both threads are inside their checkout at once => the pool served two.
      expect(both_inside.pop).to eq(:in)

      release << :go
      release << :go
      t1.join
      t2.join
    end
  end
end
