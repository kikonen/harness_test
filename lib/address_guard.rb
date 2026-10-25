# frozen_string_literal: true

require "ipaddr"

# The addresses a network tool may not connect to. Two tiers, because the
# allow_private opt-in is meant for a LOCAL endpoint and must not become a
# pass to the cloud metadata range:
#
#   BLOCKED_ALWAYS  - link-local (169.254.0.0/16 holds 169.254.169.254, the
#                     cloud metadata endpoint) and multicast. No opt-in lifts
#                     these; a harness fetch has no legitimate reason to reach
#                     them.
#   PRIVATE_NETS    - loopback, RFC1918, CGNAT, IPv6 unique-local. Refused by
#                     default; lifted only by the USER's own config key
#                     (web_fetch_allow_private), never by a host grant.
#
# IPAddr#private? is not enough on its own: measured on Ruby 4.0.7 it returns
# false for 127.0.0.1, for ::1 and for :: - so the ranges are listed explicitly.
# Design: doc/web_fetch_design.md.
class AddressGuard
  BLOCKED_ALWAYS = [
    "169.254.0.0/16", "fe80::/10", "224.0.0.0/4", "ff00::/8",
    # 0.0.0.0 and :: are not hosts to connect to.
    "0.0.0.0/32", "::/128"
  ].freeze

  PRIVATE_NETS = [
    "127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "100.64.0.0/10", "fc00::/7"
  ].freeze

  ALWAYS_NETS  = BLOCKED_ALWAYS.map { |c| IPAddr.new(c) }.freeze
  PRIVATE_LIST = PRIVATE_NETS.map { |c| IPAddr.new(c) }.freeze

  # allow_private lifts the PRIVATE tier only (see the tiers above).
  def initialize(allow_private: false)
    @allow_private = allow_private == true
  end

  # True when a connection to `address` must be refused. An address that does
  # not parse is refused: the guard cannot prove it is safe.
  def blocked?(address)
    ip = to_ip(address)
    return true if ip.nil?
    return false if private_tier?(ip) && !always_tier?(ip) && allow_private?

    private_tier?(ip) || always_tier?(ip)
  end

  def allow_private?
    @allow_private
  end

  private

  # An IPv4-mapped IPv6 literal ("::ffff:127.0.0.1") is normalized to its IPv4
  # form, or it would slip past every v4 range.
  def to_ip(address)
    ip = IPAddr.new(address.to_s)
    return ip unless ip.family == Socket::AF_INET6
    return IPAddr.new(ip.to_s.sub(/\A::ffff:/i, "")) if ip.to_s.start_with?("::ffff:")

    ip
  rescue ArgumentError # InvalidAddressError is an ArgumentError
    nil
  end

  def private_tier?(address)
    PRIVATE_LIST.any? { |net| net.include?(address) }
  end

  def always_tier?(address)
    ALWAYS_NETS.any? { |net| net.include?(address) }
  end
end
