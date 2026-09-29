# frozen_string_literal: true

require 'yaml'
require 'fileutils'

require_relative 'shell_tokenizer'
require_relative 'shell_parser'

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
#   A command may be auto-approved only if it can be decomposed into
#   SIMPLE segments separated by shell operators that do not execute
#   hidden code. Supported separators (quote-aware):
#     |    pipe          (stdout -> stdin)
#     &&   and-list      (next runs only if previous succeeded)
#     ||   or-list       (next runs only if previous failed)
#     ;    list sep      (next runs unconditionally)
#     |&   pipe-stderr   (stdout+stderr -> stdin)
#   Each segment must be a "simple command": no file redirects,
#   substitutions, subshells, or background operators. Rationale:
#     - The separators above only control execution ORDER or wire
#       stdout->stdin; they do not inject code.
#     - File redirects (<, >), substitutions ($, `), subshells (()),
#       and background (&) can read/write files or run arbitrary code,
#       so a segment containing them is NEVER auto-approved and its
#       prefix can never be saved.
#   Quotes are NOT in the blocklist: they only affect argument splitting,
#   not what runs. Operators inside quotes are literal characters.
#
# INTERNALS:
#   Tokenization is done by ShellTokenizer (StringScanner-based).
#   Parsing is done by ShellParser (Racc grammar). Together they replace
#   the previous hand-rolled char-by-char splitting and safety scanning.
#
class CommandAllowlist
  FILENAME = 'allowed_commands.yml'

  # Maximum number of tokens considered for a single command's prefix.
  MAX_PREFIX_TOKENS = 3

  # A token that "looks like a subcommand": lowercase alphanumeric, starts
  # with a letter. Distinguishes subcommands (status, log, exec) from
  # arguments (-la, --oneline, main, 68, spec/foo_spec.rb).
  SUBCOMMAND_TOKEN = /\A[a-z][a-z0-9]*\z/

  # ------------------------------------------------------------------
# Public class-level API (used by specs and RunCommandTool)
  # ------------------------------------------------------------------

  # Split a command string into segment strings using the ShellParser.
  # Returns an array of trimmed, non-empty segment strings.
  # Returns [] if the command contains any unsafe construct (danger token).
  #
  # Examples:
  #   "ls | grep x"                          => ["ls", "grep x"]
  #   "echo hi && pwd"                       => ["echo hi", "pwd"]
  #   'grep -i "fix\\|feat"'                 => ['grep -i "fix\\|feat"]
  #   "ls > out.txt"                         => [] (unsafe)
  def self.split_segments(command)
    ShellParser.parse(command.to_s.strip)
  rescue ShellParser::ParseError
    []
  end

  # True when a single segment contains no dangerous shell constructs.
  # Uses ShellTokenizer to classify each token; any :danger token means
  # the segment is unsafe.
  def self.segment_safe?(segment)
    tokens = ShellTokenizer.tokenize(segment.to_s)
    tokens.none? { |kind, _text| kind == :danger }
  end

  # True when the entire command is a single simple segment with no
  # operators at all.
  def self.simple_command?(command)
    segments = split_segments(command)
    segments.size == 1 && segment_safe?(segments[0])
  end

  # Extract the command prefix from a single safe segment string.
  # The prefix is the leading sequence of subcommand-looking tokens, up to
  # MAX_PREFIX_TOKENS. Stops at the first argument-looking token.
  def self.extract_prefix(segment)
    segment = segment.to_s.strip
    return '' unless segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }

    prefix = []
    words.each do |tok|
      break if prefix.size >= MAX_PREFIX_TOKENS
      break unless SUBCOMMAND_TOKEN.match?(tok)
      prefix << tok
    end
    prefix.join(' ')
  end

  # Extract the set of command prefixes that make up a command.
  # Returns [] when ANY segment is not safe (redirects, substitutions,
  # subshells, background) or when no segment yields a prefix.
  #
  # Examples:
  #   "bundle exec rspec | grep x | head -30" => ["bundle exec rspec", "grep", "head"]
  #   "git log --oneline | grep fix && echo done" => ["git log", "grep", "echo"]
  #   "ls > out.txt"                         => []
  #   "echo $(whoami)"                       => []
  def self.extract_all_prefixes(command)
    segments = split_segments(command)
    return [] if segments.empty?
    return [] unless segments.all? { |seg| segment_safe?(seg) }

    segments.map { |seg| extract_prefix(seg) }
           .uniq
           .select { |p| !p.empty? }
  end

  # ------------------------------------------------------------------
  # Persistence & matching (instance methods)
  # ------------------------------------------------------------------

  attr_reader :prefixes

  def initialize(workdir)
    @workdir  = workdir
    @path     = File.join(workdir, '.harness', FILENAME)
    @prefixes = load
  end

  # True when every segment of the command matches a stored prefix.
  def allowed?(command)
    return false if @prefixes.empty?
    return false if command.to_s.strip.empty?

    segments = self.class.split_segments(command)
    return false if segments.empty?
    return false unless segments.all? { |seg| self.class.segment_safe?(seg) }

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

  # True when the exact prefix is already stored in the allowlist.
  def already_allowed?(prefix)
    !prefix.to_s.strip.empty? && @prefixes.include?(prefix.strip)
  end

  # Remove a previously saved prefix and persist.
  def remove(prefix)
    before = @prefixes.dup
    @prefixes.reject! { |p| p == prefix }
    save if @prefixes.size != before.size
  end

  private

  # A single segment is allowed when it is safe AND its leading tokens
  # match one of the stored prefixes.
  def segment_allowed?(segment)
    segment = segment.strip
    return false if segment.empty?
    return false unless self.class.segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }

    @prefixes.any? do |prefix|
      p_tokens = prefix.split(/\s+/)
      p_tokens.size <= words.size &&
        (0...p_tokens.size).all? { |i| words[i] == p_tokens[i] }
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
