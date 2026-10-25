# frozen_string_literal: true

require "fileutils"
require "yaml"

require_relative "text_normalizer"

# The persisted host grants for web.fetch (issue #33) - the network equivalent of
# the command allowlist, and deliberately NOT the same shape.
#
# Matching is EXACT host, never a prefix or a domain suffix: a grant for
# "example.com" must not cover "evil.example.com" or "example.com.attacker.tld".
# Shell prefixes compose (git -> git log -> git log --oneline) because they name a
# command tree; a hostname does not compose the same way, and the tempting
# "subdomain of" rule is exactly how a granted domain gets abused. If the user
# wants several hosts, they save several hosts.
#
# A grant says only WHETHER this host may be asked for. It never widens what
# WebFetcher is allowed to do (scheme, address guard, redirect and byte caps are
# unconditional) - see doc/web_fetch_design.md.
class WebHostAllowlist
  FILENAME = "allowed_hosts.yml"

  def initialize(workdir, file: FILENAME)
    @workdir  = workdir
    @path     = File.join(workdir, ".harness", file)
    @hosts    = load
  end

  # True when this exact host was granted. The host is normalized the same way
  # in both directions (stored and looked up) so "Example.COM " and
  # "example.com." cannot dodge a grant or miss one.
  def allowed?(host)
    host = self.class.normalize(host)
    return false if host.empty?

    @hosts.include?(host)
  end

  def add(host)
    host = self.class.normalize(host)
    return if host.empty? || @hosts.include?(host)

    @hosts << host
    save
  end

  def remove(host)
    host = self.class.normalize(host)
    before = @hosts.dup
    @hosts.reject! { |h| h == host }
    save if @hosts.size != before.size
  end

  # Nothing to filter: matching is exact, so an already-granted host is simply
  # not offered again (the dialog would save a duplicate).
  def candidates(host)
    host = self.class.normalize(host)
    return [] if host.empty? || allowed?(host)

    [host]
  end

  def hosts
    @hosts.dup
  end

  # Display-only normalization shared by the grant, the lookup and the dialog, so
  # the host the user reads is the host that gets saved.
  def self.normalize(host)
    # issue #257: a model-supplied host can carry bytes invalid in UTF-8, and
    # the string methods below would raise on them.
    TextNormalizer.normalize(host.to_s).strip.downcase.sub(/\Ahttps?:\/\//, "").sub(
      %r{/\z}, "")
  end

  # A host is only worth saving when it can be a real host: no scheme, no path,
  # no port, no userinfo, no whitespace.
  def self.grantable?(host)
    host = normalize(host)
    return false if host.empty?
    return false if host.match?(%r{[\s/?@:]})
    return false unless host.include?(".")

    true
  end

  private

  def load
    return [] unless File.file?(@path)

    # Only a String can be a host: a hand-edited file may hold a mapping, a
    # nested list or a number, and Psych raises (not just returns) on a tag it
    # refuses. Either way the answer is "no grants", never a crash of the fetch.
    data = YAML.safe_load(File.read(@path))
    Array(data).select { |e|
      e.is_a?(String)
    }.map { |e| self.class.normalize(e) }.reject(&:empty?).uniq
  rescue Psych::Exception
    []
  end

  def save
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, YAML.dump(@hosts))
  end
end
