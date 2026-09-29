# frozen_string_literal: true

require 'yaml'
require 'fileutils'

# -- CommandAllowlist -----------------------------------------------------
#
# Persists user-approved command prefixes in .harness/allowed_commands.yml.
# When the user picks "Always allow" in the run.command dialog, the
# extracted prefix(es) are saved here. Subsequent commands whose leading
# tokens match a stored prefix are auto-approved without a dialog.
#
# File format is a simple YAML array of strings:
#   - ls
#   - git status
#   - bundle exec rspec
#
# SECURITY MODEL:
#   A command may be auto-approved only if it is a PIPELINE of SIMPLE
#   commands: segments separated by `|`, each of which contains no shell
#   operators, substitutions, redirects, or subshells. Rationale:
#     - Pipes only connect stdout -> stdin; they do not execute extra code.
#       `A | B` is safe iff A and B are both safe.
#     - Chaining (`&&`, `||`, `;`), redirects (`<`/`>`), substitutions
#       (`$(...)`, backticks), subshells (`(...)`) can run arbitrary extra
#       commands or read/write files, so they are NEVER auto-approved and
#       can never be saved as a prefix.
#   Quotes are NOT in the blocklist: they only affect argument splitting,
#   not what runs (e.g. `ls "my dir"` is still just `ls`).
#
class CommandAllowlist
  FILENAME = 'allowed_commands.yml'

  # Maximum number of tokens considered for a single command's prefix.
  # Capped at 3 so we never accidentally allow an entire command family
  # (e.g. saving "bundle exec" would auto-approve "bundle exec rake deploy").
  MAX_PREFIX_TOKENS = 3

  # A token that "looks like a subcommand": lowercase alphanumeric, starts
  # with a letter. Distinguishes subcommands (status, log, exec, pr, view)
  # from arguments (-la, --oneline, main, 68, spec/foo_spec.rb).
  SUBCOMMAND_TOKEN = /\A[a-z][a-z0-9]*\z/

  # Shell metacharacters that make a SINGLE command unsafe to auto-approve:
  # chaining (`&`, `;`), redirects (`<`, `>`), substitutions (`$`, backtick),
  # subshells (`(`, `)`), escaped chars (backslash), newlines.
  # NOTE: pipe `|` is deliberately NOT here - it is treated as a safe
  # pipeline separator and each segment is validated on its own.
  UNSAFE_METACHARS = /[&;<>()`$\\\n]/

  # fd-to-fd redirects like `2>&1`, `1>&2`, `3>&1` are harmless: they only
  # swap stderr/stdout within the same process, no file I/O. Stripped
  # before the metachar check so pipelines like
  # `bundle exec rspec 2>&1 | grep x` can be auto-approved.
  FD_REDIRECT = /\b\d+>&\d+\b/

  # True when the command, after removing harmless fd-to-fd redirects,
  # contains no unsafe metacharacters.
  def self.simple_command?(command)
    cleaned = command.to_s.gsub(FD_REDIRECT, '')
    !UNSAFE_METACHARS.match?(cleaned)
  end

  # Extract the command prefix from a single simple command string.
  # The prefix is the leading sequence of subcommand-looking tokens, up to
  # MAX_PREFIX_TOKENS. Stops at the first argument-looking token (flag,
  # path, number, etc.).
  #
  # Examples:
  #   "ls -la lib"              => "ls"
  #   "git status"              => "git status"
  #   "git log --oneline -5"    => "git log"
  #   "bundle exec rspec spec/" => "bundle exec rspec"
  #   "gh pr view 68"           => "gh pr view"
  def self.extract_prefix(command)
    command = command.to_s.strip
    return '' unless simple_command?(command)

    # Strip harmless fd-to-fd redirects so they don't break the prefix.
    cleaned = command.gsub(FD_REDIRECT, '')
    tokens  = cleaned.split(/\s+/).reject(&:empty?)
    prefix = []
    tokens.each do |tok|
      break if prefix.size >= MAX_PREFIX_TOKENS
      break unless SUBCOMMAND_TOKEN.match?(tok)
      prefix << tok
    end
    prefix.join(' ')
  end

  # Extract the set of command prefixes that make up a command, treating
  # pipes as safe separators. Returns [] when ANY segment is not a simple
  # command (chaining, redirects, substitutions, subshells) or when no
  # segment yields a prefix.
  #
  # Examples:
  #   "bundle exec rspec | grep -B2 x | head -30" => ["bundle exec rspec", "grep", "head"]
  #   "ls -la"                                    => ["ls"]
  #   "echo hi && rm -rf /"                       => []
  def self.extract_all_prefixes(command)
    segments = command.to_s.strip.split('|')
    return [] unless segments.all? do |seg|
      seg = seg.strip
      !seg.empty? && simple_command?(seg)
    end

    segments.map { |seg| extract_prefix(seg) }
           .uniq
           .select { |p| !p.empty? }
  end

  attr_reader :prefixes

  def initialize(workdir)
    @workdir  = workdir
    @path     = File.join(workdir, '.harness', FILENAME)
    @prefixes = load
  end

  # True when every pipe-segment of the command matches a stored prefix.
  # Commands containing unsafe metacharacters (chaining, redirects,
  # substitutions, subshells) are never auto-approved.
  def allowed?(command)
    return false if @prefixes.empty?
    return false if command.to_s.strip.empty?

    segments = command.to_s.strip.split('|')
    segments.all? { |seg| segment_allowed?(seg) }
  end

  # Add a new prefix (if not already present) and persist to disk.
  def add(prefix)
    prefix = prefix.to_s.strip
    return if prefix.empty?
    return if @prefixes.include?(prefix)

    @prefixes << prefix
    save
  end

  # Remove a previously saved prefix and persist.
  def remove(prefix)
    before = @prefixes.dup
    @prefixes.reject! { |p| p == prefix }
    save if @prefixes.size != before.size
  end

  private

  # A single pipeline segment is allowed when it is a simple command AND
  # its leading tokens match one of the stored prefixes.
  def segment_allowed?(segment)
    segment = segment.strip
    return false if segment.empty?
    return false unless CommandAllowlist.simple_command?(segment)

    # Strip harmless fd-to-fd redirects so they don't break token matching.
    cleaned = segment.gsub(FD_REDIRECT, '')
    tokens  = cleaned.split(/\s+/).reject(&:empty?)
    @prefixes.any? do |prefix|
      p_tokens = prefix.split(/\s+/)
      p_tokens.size <= tokens.size &&
        (0...p_tokens.size).all? { |i| tokens[i] == p_tokens[i] }
    end
  end

  def load
    return [] unless File.file?(@path)

    data = YAML.safe_load(File.read(@path))
    Array(data).select { |e| e.is_a?(String) && !e.strip.empty? }
  rescue Psych::SyntaxError
    []
  end

  def save
    dir = File.dirname(@path)
    FileUtils.mkdir_p(dir)
    File.write(@path, YAML.dump(@prefixes))
  end
end
