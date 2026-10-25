# frozen_string_literal: true

require 'spec_helper'
require 'address_guard'

# The addresses a network tool may not connect to (issue #33). Listed ranges,
# because IPAddr#private? was measured to return FALSE for 127.0.0.1, ::1 and ::
# on this Ruby - trusting it would leave the loopback tier open.
RSpec.describe AddressGuard do
  subject(:guard) { described_class.new }

  describe 'the addresses it refuses' do
    it 'refuses loopback' do
      expect(guard.blocked?('127.0.0.1')).to be true
      expect(guard.blocked?('127.0.0.53')).to be true
      expect(guard.blocked?('::1')).to be true
    end

    it 'refuses the RFC1918 ranges' do
      %w[10.0.0.1 172.16.0.1 172.31.255.255 192.168.1.1].each do |address|
        expect(guard.blocked?(address)).to be true
      end
      # Just OUTSIDE the ranges is not private: 172.32 is not 172.16/12.
      expect(guard.blocked?('172.32.0.1')).to be false
    end

    it 'refuses CGNAT and IPv6 unique-local' do
      expect(guard.blocked?('100.64.0.1')).to be true
      expect(guard.blocked?('fc00::1')).to be true
    end

    # The cloud metadata endpoint lives in this range, so it is the reason the
    # tier exists at all.
    it 'refuses link-local, including the metadata address' do
      expect(guard.blocked?('169.254.169.254')).to be true
      expect(guard.blocked?('fe80::1')).to be true
    end

    it 'refuses multicast' do
      expect(guard.blocked?('224.0.0.1')).to be true
      expect(guard.blocked?('ff02::1')).to be true
    end

    # 0.0.0.0 and :: are not hosts to connect to.
    it 'refuses the unspecified addresses' do
      expect(guard.blocked?('0.0.0.0')).to be true
      expect(guard.blocked?('::')).to be true
    end

    it 'refuses an address that does not parse (it cannot be proven safe)' do
      expect(guard.blocked?('not-an-ip')).to be true
      expect(guard.blocked?('')).to be true
      expect(guard.blocked?(nil)).to be true
    end
  end

  describe 'the addresses it allows' do
    it 'allows ordinary public addresses' do
      %w[8.8.8.8 93.184.216.34 2001:4860:4860::8888].each do |address|
        expect(guard.blocked?(address)).to be false
      end
    end
  end

  describe 'IPv4-mapped IPv6 literals' do
    # Normalized to v4, or "::ffff:127.0.0.1" would slip past every v4 range.
    it 'refuses a loopback address written as IPv6' do
      expect(guard.blocked?('::ffff:127.0.0.1')).to be true
      expect(guard.blocked?('::ffff:10.1.2.3')).to be true
      expect(guard.blocked?('::FFFF:192.168.0.1')).to be true
    end
  end

  describe 'allow_private (the user opt-in for a local endpoint)' do
    subject(:guard) { described_class.new(allow_private: true) }

    it 'lifts the private tier' do
      %w[127.0.0.1 ::1 10.0.0.1 192.168.1.1 100.64.0.1 fc00::1].each do |address|
        expect(guard.blocked?(address)).to be false
      end
    end

    # The opt-in is for a LOCAL endpoint, so it must not become a pass to the
    # cloud metadata range.
    it 'still refuses link-local' do
      expect(guard.blocked?('169.254.169.254')).to be true
      expect(guard.blocked?('fe80::1')).to be true
    end

    it 'still refuses multicast and the unspecified addresses' do
      expect(guard.blocked?('224.0.0.1')).to be true
      expect(guard.blocked?('ff02::1')).to be true
      expect(guard.blocked?('0.0.0.0')).to be true
    end
  end

  describe 'allow_private?' do
    it 'reports the posture it was built with' do
      expect(described_class.new.allow_private?).to be false
      expect(described_class.new(allow_private: true).allow_private?).to be true
      # Anything that is not exactly true is off: a YAML string must not open it.
      expect(described_class.new(allow_private: 'yes').allow_private?).to be false
    end
  end
end
