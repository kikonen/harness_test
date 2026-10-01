# frozen_string_literal: true

require 'yaml'
require 'fileutils'

require_relative 'shell_tokenizer'
require_relative 'shell_parser'

# -- CommandAllowlist -----------------------------------------------------
#
# Persists user-approved command prefixes in .harness/allowed_commands.yml.
# When the user picks "Always allow" in the run.command dialog, the
# candidate prefix(es) are saved here. Subsequent commands whose leading
# tokens match a stored prefix are auto-approved without a dialog.
#
# Prefix lengths (issue #102): the run.command dialog offers one option
# per prefix length of each segment (e.g. 'ruby', 'ruby -c') so the user
# can grant exactly as much as they want - never more.
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

  # Classify the first dangerous token of a command (if any) into a short
  # human-readable description for the "UNSAFE" dialog note. Returns nil
  # when the command is safe (no :danger tokens), or an English phrase
  # naming the specific construct and, when possible, its target
  # (e.g. "redirect to file ('> out.txt')"). Used so the user sees WHY
  # a particular command cannot be auto-approved rather than a generic
  # list of all unsafe construct kinds (issue #102).
  def self.classify_unsafe(command)
    ShellTokenizer.tokenize(command.to_s).each do |kind, text|
      return danger_label(text) if kind == :danger
    end
    nil
  end

  def self.danger_label(text)
    t = text.to_s
    case t
    when /\A&>>?\s/   then "combined stdout+stderr redirect (#{t.inspect})"
    when /\A&>?\s/    then "redirect (#{t.inspect})"
    when /\A>+\s/     then "redirect to file (#{t.inspect})"
    when /\A<\s/      then "input redirect (#{t.inspect})"
    when '&'          then 'background operator (&)'
    when /\A\$/       then "substitution or variable expansion (#{t.inspect})"
    when '`'          then 'command substitution (`...`)'
    when '('          then 'subshell open ( )'
    when ')'          then 'subshell close ( )'
    else "unsafe construct (#{t.inspect})"
    end
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

  # Extract the candidate prefixes for a command: one per prefix length
  # of each segment, bounded by the first flag (issue #102). For a
  # segment "ruby -c lib/cli.rb" the candidates are ["ruby", "ruby -c"];
  # for "cd C:/work/x" only the full invocation is offered (a path is
  # never a subcommand, and granting a bare "cd" would cover every
  # directory). Segments that yield no candidate (no leading word) are
  # skipped. Returns [] when ANY segment is unsafe.
  #
  # Examples:
  #   "cd C:/work/x && ruby -c lib/cli.rb"
  #     => ["cd C:/work/x", "ruby", "ruby -c"]
  #   "bundle exec rspec spec/" => ["bundle", "bundle exec", "bundle exec rspec"]
  def self.extract_prefix_options(command)
    segments = split_segments(command)
    return [] if segments.empty?
    return [] unless segments.all? { |seg| segment_safe?(seg) }

    segments.map { |seg| prefix_lengths(seg) }
           .flatten
           .uniq
  end

  # The candidate prefixes for a single safe segment: every leading run
  # of subcommand-looking tokens (1..MAX_PREFIX_TOKENS), plus - when the
  # segment has flag-like arguments (e.g. "-c") - the invocation up to
  # and including the first flag IF that flag is followed by an argument
  # (e.g. "ruby -c lib/cli.rb" offers ["ruby", "ruby -c"]), but NOT when
  # the flag is trailing (e.g. "tail -5" offers only ["tail"] - "-5" is
  # a parameter, not a subcommand). When the subcommand run is just one
  # token and the rest are arguments/paths (e.g. "cd C:/work/x"), only
  # the full invocation is offered - a bare "cd" would grant every
  # directory. When the run hit the MAX_PREFIX_TOKENS cap and the next
  # token is also a subcommand, the full invocation is appended as an
  # exact-match option (e.g. "a b c d e" offers "a", "a b", "a b c",
  # "a b c d e").
  def self.prefix_lengths(segment)
    segment = segment.to_s.strip
    return [] unless segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }
    return [] if words.empty?

    flag_idx = words.index { |w| w.start_with?('-') }

    # Collect the leading run of subcommand-looking tokens.
    lengths = []
    (1..MAX_PREFIX_TOKENS).each do |n|
      break if n > words.size
      break unless words[0...n].all? { |w| SUBCOMMAND_TOKEN.match?(w) }
      lengths << words[0...n].join(' ')
    end

    # Single subcommand + non-subcommand args (e.g. "cd C:/work/x"):
    # a bare "cd" would grant every directory - too broad. Offer only
    # the full invocation so the user grants exactly what they typed.
    return [words.join(' ')] if lengths.size == 1 && flag_idx.nil? && words.size > 1

    # When the first flag is followed by an argument, include it in the
    # prefix: "ruby -c" is a different grant than bare "ruby". A trailing
    # flag (e.g. "tail -5") is just a parameter - don't offer it.
    if flag_idx && flag_idx < words.size - 1
      with_flag = words[0..flag_idx].join(' ')
      lengths << with_flag unless lengths.include?(with_flag)
    end

    # The subcommand run hit the MAX_PREFIX_TOKENS cap and the next
    # token is also a subcommand: append the full invocation as an
    # exact-match option (e.g. "a b c d e" -> add "a b c d e").
    if lengths.size == MAX_PREFIX_TOKENS && flag_idx.nil? &&
       words.size > MAX_PREFIX_TOKENS &&
       SUBCOMMAND_TOKEN.match?(words[MAX_PREFIX_TOKENS])
      full = words.join(' ')
      lengths << full unless lengths.include?(full)
    end
    lengths
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

  # Filter a list of candidate prefixes down to those that add value over
  # the stored allowlist (issue #94, issue #102). A candidate is DROPPED
  # when its tokens overlap with any stored prefix's leading run - i.e.
  # when some stored grant P and the candidate share a common leading
  # token sequence of at least one token. This catches:
  #   - exact duplicates (e.g. stored 'tail', candidate 'tail'),
  #   - candidates subsumed by a broader grant (stored 'gh issue view',
  #     candidate 'gh' or 'gh issue' - the existing grant already covers
  #     them, so offering them is redundant),
  #   - candidates that subsume a narrower grant (stored 'git status',
  #     candidate 'git' - 'git' already covers 'git status', so a new
  #     grant of 'git' would just make the stored one redundant).
  # Candidates with NO overlap (different command tree) are kept.
  def filter_uncovered(candidates)
    (candidates || []).reject do |cand|
      cand = cand.to_s.strip
      # An empty candidate would match any stored prefix at index 0 via
      # the overlap rule below - but reject it explicitly to be safe.
      next true if cand.empty?

      c_tokens = cand.split(/\s+/)
      @prefixes.any? do |p|
        p_tokens = p.to_s.strip.split(/\s+/)
        # Overlap: at least one leading token position where both lists
        # have an equal token, AND the shared run does not extend beyond
        # either list's length. In practice this means "some stored
        # prefix starts with the same word(s)" - enough to consider the
        # candidate redundant.
        min_len = [p_tokens.size, c_tokens.size].min
        (0...min_len).any? { |i| p_tokens[i] == c_tokens[i] } &&
          p_tokens.first == c_tokens.first
      end
    end
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
