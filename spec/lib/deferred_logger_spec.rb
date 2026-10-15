# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'logger'
require 'deferred_logger'

# issue #270: the Harness logger is deferred (#123), but the LLM backend
# captures its logger at CONSTRUCTION and logs on the first attempt of every
# request. Handing it the nil placeholder meant the first prompt of a run died
# with "undefined method 'info' for nil". A DeferredLogger is what such a
# consumer gets instead: it resolves the source's #logger at CALL time, so it
# can never hold a nil and never pins a logger that is about to be replaced.
RSpec.describe DeferredLogger do
  # Stand-in for the source object (Harness): its real logger appears only
  # when #logger is first asked for, exactly like the deferred Harness logger.
  class FakeSource
    attr_reader :calls, :real

    def initialize
      @calls = []
      @real  = nil
    end

    def logger
      @calls << :logger
      @real ||= Logger.new(StringIO.new)
    end
  end

  let(:source) { FakeSource.new }
  subject(:deferred) { described_class.new(source) }

  it 'lists the severity methods the harness logs' do
    expect(described_class::SEVERITIES).to include('info', 'warn', 'error', 'debug')
  end

  describe 'forwarding' do
    it 'forwards every severity to the source logger' do
      described_class::SEVERITIES.each do |severity|
        expect { deferred.public_send(severity, "#{severity} line") }
          .not_to raise_error
      end
      expect(source.logger).to be_a(Logger)
    end

    it 'resolves the logger at CALL time, not at construction' do
      described_class.new(source) # construction alone
      expect(source.calls).to be_empty

      deferred.info('first')
      expect(source.calls).to eq([:logger])
    end

    it 'follows a logger the source later swaps out (session resume)' do
      first = source.logger
      deferred.info('into the first logger')

      # Harness#rebind_logger replaces the real logger when a resume swaps in
      # a different session id; the stand-in must follow, not pin the old one.
      swapped = Logger.new(StringIO.new)
      source.instance_variable_set(:@real, swapped)
      deferred.info('into the swapped logger')

      expect(first).not_to equal(swapped)
    end

    it 'passes a block through to the real logger' do
      logged = nil
      real   = Logger.new(StringIO.new)
      # Logger#info takes the message as a block (lazy formatting), so the
      # stand-in must forward the BLOCK and not only the argument.
      real.define_singleton_method(:info) { |_msg, &blk| logged = blk.call }
      source.instance_variable_set(:@real, real)

      deferred.info('lazy message') { 'built only when logged' }
      expect(logged).to eq('built only when logged')
    end

    it 'keeps the severity of the forwarded call' do
      entries = []
      real    = Logger.new(StringIO.new)
      real.formatter = proc { |severity, _d, _p, msg| entries << [severity, msg] }
      source.instance_variable_set(:@real, real)

      deferred.warn('a warning')
      deferred.error('an error')
      expect(entries).to eq([['WARN', 'a warning'], ['ERROR', 'an error']])
    end
  end

  describe '#close' do
    it 'is a no-op - the stand-in does not own the real logger' do
      real = source.logger
      expect(real).to receive(:close).never
      expect { deferred.close }.not_to raise_error
      expect { deferred.info('still alive') }.not_to raise_error
    end
  end

  describe 'what it deliberately does NOT forward' do
    it 'does not configure the real logger through the stand-in' do
      # #level= / #formatter= write to a logger that is about to be replaced;
      # its own owner (Harness#build_logger) configures it.
      expect(deferred).not_to respond_to(:level=)
      expect(deferred).not_to respond_to(:formatter=)
    end
  end
end
