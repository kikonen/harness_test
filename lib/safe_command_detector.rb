# frozen_string_literal: true

# -- SafeCommandDetector ---------------------------------------------------
#
# Conservative read-only command detector (issue #69). A command is "safe"
# when EVERY segment (split on && / ;) consists of a known read-only command
# with only plain arguments. Anything the detector cannot verify - pipes,
# redirects, command substitution, shell metacharacters, unknown commands,
# writing flags like find -delete/-exec - is NOT safe and still requires the
# normal user confirmation dialog. When in doubt: ask.
#
# This is a convenience feature, not a security boundary: auto-approved
# commands are still shown in the transcript and logged.
class SafeCommandDetector
  # Single-word read-only commands (any plain arguments allowed).
  SINGLE_COMMANDS = %w[
    ls cat head tail wc find grep rg which env pwd date whoami
  ].freeze

  # Multi-word read-only command prefixes (all tokens up to the prefix must
  # match exactly; remaining tokens are checked as plain arguments only).
  MULTI_COMMANDS = [
    %w[git log], %w[git status], %w[git diff], %w[git show],
    %w[git branch -a],
    %w[gh pr view], %w[gh pr list], %w[gh pr status],
    %w[gh issue view], %w[gh issue list],
    %w[gh repo view]
  ].freeze

  # find flags that cause side effects - any command containing them is unsafe.
  DANGEROUS_FLAGS = %w[-delete -exec -execdir].freeze

  # A token must be plain text: letters, digits, and the punctuation chars
  # _ . / - , ~ only. This rejects shell metacharacters ($, backtick, *, ;,
  # |, (, ), >, <, &, !, ...), and therefore command substitution, globs,
  # redirects and env assignment. Commas and tilde are allowed (harmless in
  # arguments, e.g. gh pr view --json state,mergedAt; git show HEAD~1).
  SAFE_TOKEN = /\A[-A-Za-z0-9._\/,~]+\z/

  def safe?(command)
    segments = split_segments(command.to_s.strip)
    return false if segments.nil? || segments.empty?

    segments.all? { |segment| safe_segment?(segment) }
  end

  private

  # Split on && / ; (outside quotes). Pipes make the command unsafe, so a
  # pipe returns nil. Returns an array of trimmed segments, or nil when the
  # command contains a pipe or unbalanced quotes.
  def split_segments(command)
    return nil if command.include?('|')

    in_single = false
    in_double = false
    segments  = []
    current   = +''
    i         = 0
    while i < command.length
      ch = command[i]
      case ch
      when "'" then in_single = !in_single
      when '"' then in_double = !in_double
      when '&'
        if !in_single && !in_double && command[i + 1] == '&'
          segments << current
          current = +''
          i += 2
          next
        end
      when ';'
        unless in_single || in_double
          segments << current
          current = +''
          i += 1
          next
        end
      end
      current << ch
      i += 1
    end
    return nil if in_single || in_double

    segments << current
    segments.map(&:strip).reject(&:empty?)
  end

  def safe_segment?(segment)
    tokens = tokenize(segment)
    return false if tokens.nil? || tokens.empty?

    first = tokens[0]
    if SINGLE_COMMANDS.include?(first)
      find_unsafe?(tokens)
    else
      prefix_match?(tokens) && find_unsafe?(tokens)
    end
  end

  # Split a segment into whitespace-separated tokens, keeping quoted strings
  # together. Returns nil when quotes are unbalanced.
  def tokenize(segment)
    tokens  = []
    in_single = false
    in_double = false
    current   = +''
    segment.each_char do |ch|
      if ch == "'"
        in_single = !in_single
        next
      elsif ch == '"'
        in_double = !in_double
        next
      end
      if /\s/.match?(ch) && !in_single && !in_double
        tokens << current
        current = +''
      else
        current << ch
      end
    end
    return nil if in_single || in_double

    tokens << current
    tokens.reject(&:empty?)
  end

  # True when the command is safe (i.e. no dangerous flags present).
  def find_unsafe?(tokens)
    !tokens.any? { |t| DANGEROUS_FLAGS.include?(t) } &&
      tokens.all? { |t| SAFE_TOKEN.match?(t) }
  end

  # True when the token list starts with one of the multi-word prefixes.
  def prefix_match?(tokens)
    MULTI_COMMANDS.any? do |prefix|
      prefix.size <= tokens.size &&
        (0...prefix.size).all? { |i| tokens[i] == prefix[i] }
    end
  end
end
