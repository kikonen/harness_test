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
#   A command may be auto-approved only if it can be decomposed into
#   SIMPLE segments separated by shell operators that do not execute
#   hidden code. Supported separators (quote-aware):
#     |    pipe          (stdout -> stdin)
#     &&   and-list      (next runs only if previous succeeded)
#     ||   or-list       (next runs only if previous failed)
#     ;    list sep      (next runs unconditionally)
#   Each segment must be a "simple command": no file redirects,
#   substitutions, subshells, or background operators. Rationale:
#     - The separators above only control execution ORDER or wire
#       stdout->stdin; they do not inject code.
#     - File redirects (<, >), substitutions ($(, `), subshells (()),
#       and background (&) can read/write files or run arbitrary code,
#       so a segment containing them is NEVER auto-approved and its
#       prefix can never be saved.
#   Quotes are NOT in the blocklist: they only affect argument splitting,
#   not what runs. Operators inside quotes are literal characters.
#
class CommandAllowlist
  FILENAME = 'allowed_commands.yml'

  # Maximum number of tokens considered for a single command's prefix.
  MAX_PREFIX_TOKENS = 3

  # A token that "looks like a subcommand": lowercase alphanumeric, starts
  # with a letter. Distinguishes subcommands (status, log, exec) from
  # arguments (-la, --oneline, main, 68, spec/foo_spec.rb).
  SUBCOMMAND_TOKEN = /\A[a-z][a-z0-9]*\z/

  # fd-to-fd redirects like `2>&1`, `1>&2` are harmless: they only swap
  # stderr/stdout within the same process, no file I/O. Stripped before
  # the safety check so pipelines like `bundle exec rspec 2>&1 | grep x`
  # can be auto-approved.
  FD_REDIRECT = /\b\d+>&\d+\b/

  # ------------------------------------------------------------------
  # Quote-aware shell splitting
  # ------------------------------------------------------------------

  # Split a command string into segments using quote-aware parsing.
  # Recognized separators (only when OUTSIDE quotes):
  #   |, ||, |&, &&, ;
  # Returns an array of trimmed, non-empty segment strings.
  #
  # Examples:
  #   "ls | grep x"                          => ["ls", "grep x"]
  #   "echo hi && pwd"                       => ["echo hi", "pwd"]
  #   'grep -i "fix\\|feat"'                 => ['grep -i "fix\\|feat"]  (one segment)
  #   'echo "a; b" && ls'                    => ['echo "a; b"', "ls"]
  def self.split_segments(command)
    segments = []
    current  = +''
    i        = 0
    len      = command.to_s.length

    while i < len
      ch = command[i]

      case ch
      when "'"
        # Single-quoted: consume until closing '
        current << ch
        i += 1
        while i < len && command[i] != "'"
          current << command[i]
          i += 1
        end
        current << command[i] if i < len
        i += 1

      when '"'
        # Double-quoted: consume until unescaped "
        current << ch
        i += 1
        while i < len
          if command[i] == '\\' && i + 1 < len
            current << command[i] << command[i + 1]
            i += 2
          elsif command[i] == '"'
            current << command[i]
            i += 1
            break
          else
            current << command[i]
            i += 1
          end
        end

      when '&'
        if command[i, 2] == '&&'
          segments << current
          current = +''
          i += 2
        else
          current << ch
          i += 1
        end

      when '|'
        # Handle ||, |&, and plain |
        if command[i, 2] == '||' || command[i, 2] == '|&'
          segments << current
          current = +''
          i += 2
        else
          segments << current
          current = +''
          i += 1
        end

      when ';'
        segments << current
        current = +''
        i += 1

      when '\\'
        # Escaped char outside quotes: consume as literal (not a separator)
        current << ch
        i += 1
        if i < len
          current << command[i]
          i += 1
        end

      else
        current << ch
        i += 1
      end
    end

    segments << current
    segments.map(&:strip).reject(&:empty?)
  end

  # ------------------------------------------------------------------
  # Per-segment safety check (quote-aware)
  # ------------------------------------------------------------------

  # True when a single segment contains no dangerous shell constructs
  # outside of quotes. Dangerous: file redirects (<, >), background (&),
  # substitutions ($, backtick), subshells ((), )).
  # fd-to-fd redirects (2>&1) are stripped first as they are harmless.
  def self.segment_safe?(segment)
    cleaned = segment.to_s.gsub(FD_REDIRECT, '')
    i   = 0
    len = cleaned.length

    while i < len
      ch = cleaned[i]
      case ch
      when "'"
        i += 1
        while i < len && cleaned[i] != "'"
          i += 1
        end
        i += 1

      when '"'
        i += 1
        while i < len
          if cleaned[i] == '\\'
            i += 2
          elsif cleaned[i] == '"'
            i += 1
            break
          else
            i += 1
          end
        end

      when '\\'
        # Escaped char: skip both (literal, not an operator)
        i += 2

      when '<', '>', '&', '$', '`', '(', ')'
        return false

      else
        i += 1
      end
    end

    true
  end

  # Backward-compatible: true when the entire command is a single simple
  # segment with no operators at all.
  def self.simple_command?(command)
    segments = split_segments(command)
    segments.size == 1 && segment_safe?(segments[0])
  end

  # ------------------------------------------------------------------
  # Prefix extraction
  # ------------------------------------------------------------------

  # Extract the command prefix from a single safe segment string.
  # The prefix is the leading sequence of subcommand-looking tokens, up to
  # MAX_PREFIX_TOKENS. Stops at the first argument-looking token.
  def self.extract_prefix(segment)
    segment = segment.to_s.strip
    return '' unless segment_safe?(segment)

    cleaned = segment.gsub(FD_REDIRECT, '')
    tokens  = cleaned.split(/\s+/).reject(&:empty?)
    prefix  = []
    tokens.each do |tok|
      break if prefix.size >= MAX_PREFIX_TOKENS
      break unless SUBCOMMAND_TOKEN.match?(tok)
      prefix << tok
    end
    prefix.join(' ')
  end

  # Extract the set of command prefixes that make up a command.
  # Splits on |, &&, ||, ; (quote-aware). Returns [] when ANY segment is
  # not safe (redirects, substitutions, subshells, background) or when no
  # segment yields a prefix.
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
  # Persistence & matching
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
