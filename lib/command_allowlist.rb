# frozen_string_literal: true

require 'yaml'
require 'fileutils'

# -- CommandAllowlist -----------------------------------------------------
#
# Persists user-approved command prefixes in .harness/allowed_commands.yml.
# When the user picks "Always allow" in the run.command dialog, the
# extracted prefix is saved here. Subsequent commands whose leading tokens
# match a stored prefix are auto-approved without a dialog.
#
# The file format is a simple YAML array of strings:
#   - ls
#   - git status
#   - bundle exec rspec
#
# SECURITY:
#   Only SIMPLE single commands may be auto-approved. Commands containing
#   shell operators or substitutions (&&, ||, ;, |, redirects, $(...),
#   backticks, subshells) are NEVER matched against the allowlist - they
#   always require an explicit "Allow". This prevents e.g. approving
#   "echo" and later auto-approving `echo hi && rm -rf /`.
#   The same rule is enforced at extraction time, so such commands can
#   never be saved as a prefix either.
#   Quotes are NOT in the blocklist: they do not change what runs, only
#   how arguments are split (e.g. `ls "my dir"` is still just `ls`).
#
class CommandAllowlist
  FILENAME = 'allowed_commands.yml'

  # Maximum number of tokens considered for the command prefix. Capped at
  # 3 so we never accidentally allow an entire command family (e.g. saving
  # "bundle exec" would auto-approve "bundle exec rake deploy").
  MAX_PREFIX_TOKENS = 3

  # A token that "looks like a subcommand": lowercase alphanumeric,
  # starts with a letter. This distinguishes subcommands (status, log,
  # exec, rspec, pr, view) from arguments (-la, --oneline, main, 68,
  # spec/foo_spec.rb).
  SUBCOMMAND_TOKEN = /\A[a-z][a-z0-9]*\z/

  # Extract the command prefix from a full command string. The prefix
  # is the leading sequence of tokens that look like subcommands (up to
  # MAX_PREFIX_TOKENS). Stops at the first token that looks like an
  # argument (flag, path, number, etc.).
  # Shell metacharacters that turn a single command into a compound one
  # (chaining, piping, redirection, substitution, subshell) or make the
  # trailing arguments uninterpretable (quotes). A command containing any
  # of these is never auto-approved and can never be saved as a prefix.
  SHELL_METACHARS = /[;&|<>`$\\]/

  def self.simple_command?(command)
    !SHELL_METACHARS.match?(command.to_s)
  end

  #
  # Examples:
  #   "ls -la lib"              => "ls"
  #   "git status"              => "git status"
  #   "git log --oneline -5"    => "git log"
  #   "bundle exec rspec spec/" => "bundle exec rspec"
  #   "gh pr view 68"           => "gh pr view"
  # Compound commands (operators, substitutions, quotes) return '' -
  # they can never be saved as an allowlist prefix.
  def self.extract_prefix(command)
    command = command.to_s.strip
    return '' unless simple_command?(command)

    tokens = command.to_s.strip.split(/\s+/)
    prefix = []
    tokens.each do |tok|
      break if prefix.size >= MAX_PREFIX_TOKENS
      break unless SUBCOMMAND_TOKEN.match?(tok)
      prefix << tok
    end
    prefix.join(' ')
  end

  attr_reader :prefixes

  def initialize(workdir)
    @workdir  = workdir
    @path     = File.join(workdir, '.harness', FILENAME)
    @prefixes = load
  end

  # True when the command's leading tokens match a stored prefix.
  # Matching is case-sensitive and token-based: the command must START
  # with the same sequence of whitespace-separated tokens as the prefix.
  # Compound commands (shell operators, substitutions, quotes) are never
  # matched - they always require explicit user approval (see SECURITY
  # note above).
  def allowed?(command)
    return false if @prefixes.empty?

    # SECURITY: compound commands are never auto-approved.
    return false unless CommandAllowlist.simple_command?(command)

    tokens = command.to_s.strip.split(/\s+/)
    return false if tokens.empty?

    @prefixes.any? do |prefix|
      p_tokens = prefix.split(/\s+/)
      p_tokens.size <= tokens.size &&
        (0...p_tokens.size).all? { |i| tokens[i] == p_tokens[i] }
    end
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
