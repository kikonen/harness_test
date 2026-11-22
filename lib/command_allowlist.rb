# frozen_string_literal: true

require "yaml"
require "fileutils"

require_relative "shell_tokenizer"
require_relative "shell_parser"
require_relative "text_normalizer"

# Persists user-approved command prefixes and decides which commands may run
# without a dialog. Security model, the disaster denylist, and candidate-prefix
# generation: doc/command_allowlist_design.md.
class CommandAllowlist
  # Two SEPARATE lists: the same prefix must not auto-approve both
  # model-driven and locally typed commands.
  TOOL_FILENAME = "allowed_commands.yml"   # run.command tool (LLM)
  SHELL_FILENAME = "shell_commands.yml"    # `!` bang syntax (local shell)

  FILENAME = TOOL_FILENAME

  # Maximum number of tokens considered for a single command's prefix.
  MAX_PREFIX_TOKENS = 3

  # A "subcommand-looking" token: lowercase alphanumeric starting with a letter.
  # Distinguishes subcommands (status, log, exec) from arguments (-la, main).
  SUBCOMMAND_TOKEN = /\A[a-z][a-z0-9]*\z/

  # POSIX shell reserved words: control-flow keywords that spell no program, so
  # program_token? rejects them and a shell loop is not exploded into
  # meaningless grants. A PATH token whose basename matches one ('bin/done')
  # is a real executable checked by path_program_token?, so the block is on
  # the bare word.
  SHELL_RESERVED_WORDS = %w[
    ! { [[ ]] case do done elif else esac fi for function if
    in select then time until while
  ].freeze

  # The scope sentence an "Always allow" offer states. A grant ending with a
  # program is flag-blind; one that already names a flag/argument cannot drift.
  SCOPE_RUN = "any command starting with these words, whatever follows them"
  SCOPE_PIN = "only commands starting with exactly these words"

  # A program invoked BY PATH ('bin/rspec', 'C:\work\tool.exe') names the same
  # verb as the bare word, and a grant for it may be a DIRECTORY glob ('bin/*').
  # SEPARATOR_CHARS is what a path token/glob carries; GLOB_TOKEN is one trailing
  # '*' after a directory; PATH_TOKEN_CHARS an unquoted path token; PROGRAM_NAME
  # the basename that makes a path token a program rather than an argument.
  SEPARATOR_CHARS = %r{[/\\]}
  GLOB_TOKEN      = %r{\A.*[/\\]\*\z}
  PATH_TOKEN_CHARS = %r{\A[\w.\-:/\\]+\z}
  PROGRAM_NAME     = /\A[a-z][a-z0-9_]*(\.\w+)?\z/i
  # A token that looks like a URL, not a path: 'https://evil.sh' spells no program.
  SCHEME           = %r{\A[a-z][a-z0-9+.-]*://}i

  # Separator token kinds (ShellTokenizer) used to split a command for the disaster scan.
  SEPARATORS = %i[pipe and or semi pipe_and].freeze

  # Well-known disaster commands - POSIX side. Matched against every raw segment
  # AND the whole command. Deliberately broad: a false positive only costs one dialog.
  DISASTER_PATTERNS = [
    /\bmkfs(\.|\s|$)/,                            # make filesystem
    /\bfsck\b.*(?<!\w)-f(\s|$)/,                  # force filesystem check
    /\bdd\b.*\bof=\/dev\//,                       # raw write to a device
    /\b(shutdown|reboot|halt|poweroff)\b/,        # power off the machine
    /\bsudo\b/,                                   # privilege escalation
    # --force-with-lease is deliberately NOT matched: it is the safe variant.
    /\bgit\s+push\b(?=.*(--force(?![\w-])|(?<!\w)-f(\s|$)))/,
    /\bkill\b.*\s-\d+\s+-1\b/,                    # kill every process
    /\bchmod\b.*-[A-Za-z]*R[A-Za-z]*\b.*\b777\b/, # world-writable everything
    /\bchown\b.*\s-R\b.*\s\/(\s|$)/,              # chown the whole tree
    /\bDROP\s+DATABASE\b/i,                       # sql
  ].freeze

  # Patterns whose construct spans a separator (pipe, subshell), so they match the
  # whole command string - the tokenizer drops the separator when segmenting.
  WHOLE_COMMAND_PATTERNS = [
    /\bcurl\b[^|]*\|\s*(sh|bash|zsh|perl|python)\b/,        # download -> shell
    /\bwget\b[^|]*\|\s*(sh|bash|zsh|perl|python)\b/,        # download -> shell
    /:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;?/           # fork bomb
  ].freeze

  # cmd.exe recursive-force delete (del /s /q, rd /q /s): the Windows twin of
  # rm -rf. Lookaheads over the whole segment text so the construct is also
  # caught inside a quoted payload (where the verb is not its own word).
  WIN_CMD_RECURSIVE_DELETE = /
    (?=.*\b(?:del|erase|rd|rmdir)(\.exe)?\b)
    (?=.*\/s(\s|$))
    (?=.*\/[qfp](\s|$))
  /ix
  # PowerShell recursive-force delete (Remove-Item -Recurse -Force, and the
  # short -r / -f forms, including inside a quoted powershell -Command payload).
  WIN_PS_RECURSIVE_DELETE = /
    (?=.*\bRemove-Item\b)
    (?=.*(?:-(?:Rec|Recursive)|(?<!\w)-r(\s|$)))
    (?=.*-F)
  /ix

  # Well-known disaster commands - Windows / PowerShell side. Commands reach us
  # through `sh -c` but invoke cmd.exe and PowerShell just as easily, so the
  # Windows spellings are recognized too. Case-insensitive: Windows tools are.
  # Quoted payloads are visible here, which catches `powershell -Command
  # "Remove-Item -Recurse -Force ..."`; the price is a commit message containing
  # such a phrase also trips the gate - accepted, it costs a confirmation not a run.
  WINDOWS_DISASTER_PATTERNS = [
    /\bformat\b\s+[a-z]:/i,                       # format C:
    /\b(diskpart|sdelete|cleanmgr)\b/i,           # partition / wipe tools
    /\bdiskpart\b.*\bclean\b/i,                   # wipe a disk's partition table
    /\bvssadmin\b.*\bdelete\b/i,                  # delete shadow copies
    /\breg(\.exe)?\s+delete\b/i,                  # delete registry keys
    /\bbcdedit\b.*\s\/(set|create|delete)/i,      # boot configuration store edits
    /\bmountvol\b.*\/[dD]\b/i,                    # remove volume mount points
    # takeown is typed without .exe in practice, so the suffix must be optional.
    /\btakeown(\.exe)?\b/i, # seize ownership of a tree
    # blanket ACL grant ("give everyone full control"); icacls, not *ir*cacls.
    /\bicacls?\b.*\/(grant|reset)\b.*\beveryone\b/i,
    /\bClear-Disk\b/i,                            # PowerShell: wipe a disk
    /\bInitialize[-.]?Disk\b.*(-Force|(?<!\w)-Confirm:)/i,
    WIN_CMD_RECURSIVE_DELETE,
    WIN_PS_RECURSIVE_DELETE,
    /\bSet-Content\b.*\bNUL\b/i,                  # overwrite a device name
  ].freeze

  # cmd.exe delete verbs whose recursive + quiet/force combination is the
  # Windows equivalent of rm -rf (see win_recursive_force_delete?).
  WIN_DELETE_COMMANDS = %w[del erase rd rmdir].freeze

  # The POSIX twin of WIN_DELETE_COMMANDS. Path verbs matter because a directory
  # grant ('bin/*') would otherwise stand for 'bin/rm -rf /'.
  RM_COMMANDS = %w[rm].freeze

  # ------------------------------------------------------------------
  # Disaster scan
  # ------------------------------------------------------------------

  # Split a command into RAW segments at the separator tokens. Unlike split_segments
  # (which returns [] for unsafe constructs) this keeps every segment even when the
  # command has redirects/substitutions/subshells - the disaster scan must see the
  # whole command, including the shapes YOLO auto-approves.
  def self.raw_segments(command)
    tokens = ShellTokenizer.tokenize(TextNormalizer.normalize(command.to_s))
    segments = []
    current  = []
    tokens.each do |kind, text|
      if SEPARATORS.include?(kind)
        segments << current.join(" ") unless current.empty?
        current = []
      else
        current << text.to_s
      end
    end
    segments << current.join(" ") unless current.empty?
    segments.reject { |s| s.strip.empty? }
  end

  # True when the command is a well-known disaster: either a separator-spanning
  # construct in the whole string, or any single segment matching the per-segment patterns.
  def self.disaster?(command)
    text = TextNormalizer.normalize(command.to_s)
    return true if WHOLE_COMMAND_PATTERNS.any? { |re| re.match?(text) }

    raw_segments(text).any? { |seg| disaster_segment?(seg) }
  end

  # Short label for the denylist dialog note: names the matched construct so the
  # user sees WHY the command is refused rather than a bare "denylisted".
  def self.disaster_label(command)
    text = TextNormalizer.normalize(command.to_s)
    (WHOLE_COMMAND_PATTERNS + DISASTER_PATTERNS +
     WINDOWS_DISASTER_PATTERNS).each do |re|
      m = re.match(text)
      # Skip a ZERO-length match: the recursive-delete twins are pure lookaheads,
      # so their m[0] is empty and would render as "DENYLISTED:  - ...". Falling
      # through lands on the fallback label below, which is what they mean.
      next if m.nil? || m[0].to_s.strip.empty?
      return m[0].strip
    end
    "recursive-force delete"
  end

  def self.disaster_segment?(segment)
    return true if DISASTER_PATTERNS.any? { |re| re.match?(segment) }
    return true if WINDOWS_DISASTER_PATTERNS.any? { |re| re.match?(segment) }
    return true if win_recursive_force_delete?(segment)

    recursive_force_rm?(segment)
  end

  # True when a token IS one of `verbs`: the bare word, or a PATH naming that
  # program. A path counts by its BASENAME (after the last separator, .exe
  # dropped, case-insensitive) because a directory grant stands for every program
  # in that directory - the mitigation the gate needs before such a grant is offered.
  def self.verb_token?(token, verbs)
    text = verb_text(token)
    return false if text.nil?
    return verbs.include?(bare_word(text)) unless SEPARATOR_CHARS.match?(text)

    verbs.include?(bare_word(text.split(SEPARATOR_CHARS).last.to_s))
  end

  # The text a token spells as a WORD: its own text, or the inside of quotes when
  # the whole token is ONE quoted word ('"rm"' - quoting a verb does not change
  # what runs). A quoted PHRASE yields nil: it names no program, which keeps the
  # quoted-message rule.
  def self.verb_text(token)
    text  = token.to_s
    quote = text[0]
    return text unless quote == '"' || quote == "'"
    return nil unless text.end_with?(quote)

    inner = text[1..-2].to_s
    return nil if inner.empty? || /\s/.match?(inner)

    inner
  end

  # A verb as the command names it: lower-case, without an '.exe' suffix.
  def self.bare_word(text)
    text.to_s.downcase.sub(/\.exe\z/, "")
  end

  # True when a token names a PROGRAM a grant could stand for. Position 0 may be a
  # PATH program; later positions must look like plain subcommands, so an argument
  # containing a separator ('spec/foo_spec.rb') never joins the run. A shell
  # reserved word is never a program.
  def self.program_token?(token, index)
    return false if SHELL_RESERVED_WORDS.include?(token.to_s)
    return true if SUBCOMMAND_TOKEN.match?(token)
    return false unless index.zero?

    path_program_token?(token)
  end

  # A PATH token whose basename names a program. A quoted or scheme-shaped token
  # is never one, nor one whose basename names nothing ('spec/', '2>&1').
  def self.path_program_token?(token)
    text = token.to_s
    return false if text.start_with?('"', "'")
    return false if SCHEME.match?(text)
    return false unless PATH_TOKEN_CHARS.match?(text) && SEPARATOR_CHARS.match?(text)

    PROGRAM_NAME.match?(bare_word(text.split(SEPARATOR_CHARS).last.to_s))
  end

  # The DIRECTORY glob a single path program could be granted as, keeping the
  # token's own separator ('bin/rspec' -> 'bin/*'). A directory with a '.', '..'
  # or EMPTY segment is refused: such a glob would trust programs outside the shown
  # directory (including one the model writes there later).
  def self.directory_glob(token)
    return nil unless path_program_token?(token)

    text  = token.to_s
    index = text.rindex(SEPARATOR_CHARS)
    dir   = text[0, index.to_i]
    return nil if dir.empty?
    # split(-1) keeps empty segments: an absolute path may have one leading empty
    # (the root) but none elsewhere, and no '.' or '..' segment.
    segments = dir.split(SEPARATOR_CHARS, -1)
    segments = segments[1..].to_a if segments.first.to_s.empty?
    return nil if segments.empty?
    return nil if segments.any? { |s| s.empty? || s == "." || s == ".." }

    "#{dir}#{text[index]}*"
  end

  # The dialog note for a DIRECTORY glob candidate (nil for an exact prefix): the
  # broadest grant must state what it trusts AT THE MOMENT IT IS CHOSEN.
  def self.glob_note(candidate)
    return nil unless GLOB_TOKEN.match?(candidate.to_s)

    "covers every program in that directory, including one written there later"
  end

  # What an "Always allow" offer authorizes, stated AT THE MOMENT IT IS CHOSEN.
  # One rule governs every grant, but a grant naming a flag/argument cannot drift,
  # so the two shapes need different sentences. Table: doc/command_grant_scope_design.md.
  def self.grant_scope_note(candidate)
    glob = glob_note(candidate)
    return glob if glob

    tokens = candidate.to_s.strip.split(/\s+/).reject(&:empty?)
    return nil if tokens.empty?

    last = tokens.last
    run_shape = SUBCOMMAND_TOKEN.match?(last) ||
                (tokens.size == 1 && path_program_token?(last))
    run_shape ? SCOPE_RUN : SCOPE_PIN
  end

  # cmd.exe recursive-force delete: matched on the command word plus its flags so
  # `git commit -m "del /s /q"` inside quotes does not trip it (quoted words are
  # not :word-kind flags here). PowerShell cousins are handled by Remove-Item above.
  def self.win_recursive_force_delete?(segment)
    words = ShellTokenizer.tokenize(segment)
            .select { |kind, _t| kind == :word }
            .map { |_k, t| t.to_s }
    idx   = words.index { |w| verb_token?(w, WIN_DELETE_COMMANDS) }
    return false unless idx

    recursive = false
    force     = false
    words[(idx + 1)..].each do |w|
      next unless w.start_with?("/") || w.start_with?("-")
      flag = w[1..].to_s.downcase.delete(":")
      recursive ||= %w[s recursive].include?(flag)
      force     ||= %w[q quiet f force p prompt-].include?(flag)
    end
    recursive && force
  end

  # `rm` with BOTH a recursive and a force flag, any spelling/order, bare or path.
  # Split from DISASTER_PATTERNS because the test is a flag combination, not a fixed
  # phrase. Quoted arguments are skipped so a message about rm is not flagged.
  def self.recursive_force_rm?(segment)
    words = ShellTokenizer.tokenize(segment)
            .select { |kind, _t| kind == :word }
            .map { |_k, t| t.to_s }
    rm_idx = words.index { |w| verb_token?(w, RM_COMMANDS) }
    return false unless rm_idx

    recursive = false
    force     = false
    words[(rm_idx + 1)..].each do |w|
      next unless w.start_with?("-")
      if w.start_with?("--")
        recursive ||= (w == "--recursive")
        force     ||= (w == "--force")
      else
        chars = w[1..].chars
        recursive ||= chars.include?("r") || chars.include?("R")
        force     ||= chars.include?("f")
      end
    end
    recursive && force
  end

  # ------------------------------------------------------------------
  # Public class-level API
  # ------------------------------------------------------------------

  # Split a command into segment strings using ShellParser. Returns trimmed,
  # non-empty segments, or [] if the command contains any unsafe construct.
  #   "ls | grep x"  => ["ls", "grep x"]    "ls > out.txt" => []
  def self.split_segments(command)
    ShellParser.parse(TextNormalizer.normalize(command).strip)
  rescue ShellParser::ParseError
    []
  end

  # True when a segment contains no dangerous shell constructs (no :danger token).
  def self.segment_safe?(segment)
    tokens = ShellTokenizer.tokenize(TextNormalizer.normalize(segment))
    tokens.none? { |kind, _text| kind == :danger }
  end

  # Classify the first dangerous token of a command into a short phrase naming the
  # specific construct and, when possible, its target (e.g. "redirect to file
  # ('> out.txt')"). Returns nil when the command is safe. Used so the user sees
  # WHY a command cannot be auto-approved rather than a generic list.
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
    when "&"          then "background operator (&)"
    when /\A\$/       then "substitution or variable expansion (#{t.inspect})"
    when "`"          then "command substitution (`...`)"
    when "("          then "subshell open ( )"
    when ")"          then "subshell close ( )"
    else "unsafe construct (#{t.inspect})"
    end
  end

  # True when the command is a single simple segment with no operators at all.
  def self.simple_command?(command)
    segments = split_segments(command)
    segments.size == 1 && segment_safe?(segments[0])
  end

  # Extract the prefix from a single safe segment: the leading program-looking
  # tokens (subcommands, or the leading PATH token) up to MAX_PREFIX_TOKENS,
  # stopping at the first argument-looking token.
  def self.extract_prefix(segment)
    segment = segment.to_s.strip
    return "" unless segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }

    prefix = []
    words.each_with_index do |tok, index|
      break if prefix.size >= MAX_PREFIX_TOKENS
      break unless program_token?(tok, index)
      prefix << tok
    end
    prefix.join(" ")
  end

  # Extract the set of prefixes making up a command. Returns [] when any segment
  # is unsafe or no segment yields a prefix.
  #   "bundle exec rspec | grep x" => ["bundle exec rspec", "grep"]
  def self.extract_all_prefixes(command)
    segments = split_segments(command)
    return [] if segments.empty?
    return [] unless segments.all? { |seg| segment_safe?(seg) }

    segments.map { |seg| extract_prefix(seg) }
           .uniq
           .select { |p| !p.empty? }
  end

  # Extract candidate prefixes: one per prefix length of each segment, bounded by
  # the first flag. The user can grant as broadly or narrowly as they want.
  #   "cd C:/work/x && ruby -c lib/cli.rb" => ["cd", "cd C:/work/x", "ruby", "ruby -c"]
  # Returns [] when any segment is unsafe.
  def self.extract_prefix_options(command)
    segments = split_segments(command)
    return [] if segments.empty?
    return [] unless segments.all? { |seg| segment_safe?(seg) }

    segments.map { |seg| prefix_lengths(seg) }
           .flatten
           .uniq
  end

  # Candidate prefixes for one safe segment: every leading run of program tokens
  # (1..MAX_PREFIX_TOKENS), plus:
  #   * the whole invocation when the run is one program and the rest are args;
  #   * the invocation up to and INCLUDING the first flag, only when it directly
  #     follows the run (a flag buried in the arguments would only ever authorize
  #     that command, so it is not offered);
  #   * the run's DIRECTORY glob when the run is one path program ('bin/*').
  # A trailing flag is a parameter - never offered. When the run hits the token cap
  # and the next token is also a subcommand, the full invocation is appended.
  def self.prefix_lengths(segment)
    segment = segment.to_s.strip
    return [] unless segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }
    return [] if words.empty?

    flag_idx = words.index { |w| w.start_with?("-") }

    # The leading run of program tokens. A PATH program is ONE token: whatever
    # follows is its arguments. A bare-word run continues over subcommand-looking
    # tokens only, never over an argument that happens to be a path.
    run_size = 0
    if path_program_token?(words[0])
      run_size = 1
    else
      words.each_with_index do |word, index|
        break if run_size >= MAX_PREFIX_TOKENS
        break unless program_token?(word, index)
        run_size += 1
      end
    end
    lengths = (1..run_size).map { |n| words[0...n].join(" ") }

    # Single subcommand + non-subcommand args: offer the short prefix AND the full
    # invocation, so the user grants exactly as much as they want.
    if lengths.size == 1 && flag_idx.nil? && words.size > 1
      full = words.join(" ")
      lengths << full unless lengths.include?(full)
    end

    # The first flag directly after the run, followed by an argument: "ruby -c" is
    # a different grant than bare "ruby". A flag inside the arguments is not a grant shape.
    if flag_idx && flag_idx == run_size && flag_idx < words.size - 1
      with_flag = words[0..flag_idx].join(" ")
      lengths << with_flag unless lengths.include?(with_flag)
    end

    # A program invoked by path also gets its DIRECTORY glob.
    if run_size == 1 && (glob = directory_glob(words[0]))
      lengths << glob unless lengths.include?(glob)
    end

    # The run hit the token cap and the next token is also a subcommand: append the
    # full invocation as an exact-match option.
    if lengths.size == MAX_PREFIX_TOKENS && flag_idx.nil? &&
       words.size > MAX_PREFIX_TOKENS &&
       SUBCOMMAND_TOKEN.match?(words[MAX_PREFIX_TOKENS])
      full = words.join(" ")
      lengths << full unless lengths.include?(full)
    end
    lengths
  end

  # ------------------------------------------------------------------
  # Persistence & matching (instance methods)
  # ------------------------------------------------------------------

  attr_reader :prefixes

  def initialize(workdir, file: TOOL_FILENAME)
    @workdir  = workdir
    @path     = File.join(workdir, ".harness", file)
    @prefixes = load
  end

  # True when every segment of the command matches a stored prefix.
  def allowed?(command)
    reload!
    return false if @prefixes.empty?

    command = TextNormalizer.normalize(command)
    return false if command.strip.empty?

    segments = self.class.split_segments(command)
    return false if segments.empty?
    return false unless segments.all? { |seg| self.class.segment_safe?(seg) }

    segments.all? { |seg| segment_allowed?(seg) }
  end

  # Add a prefix (if new) and persist. The stored state is re-read first: an
  # instance lives for a whole run, so writing its own snapshot would resurrect
  # prefixes /clear removed mid-run - the merge is always with what is on disk.
  def add(prefix)
    prefix = prefix.to_s.strip
    return if prefix.empty?
    reload!
    return if @prefixes.include?(prefix)
    @prefixes << prefix
    save
  end

  # Filter candidates down to those that add value over the stored allowlist. A
  # candidate is dropped when one is a token-level prefix of the other in either
  # direction: exact duplicates, candidates covered by a broader stored grant, and
  # candidates that would subsume a narrower stored grant (making it dead weight).
  # Candidates in a DIFFERENT command tree are kept. A stored glob covers its exact
  # candidates (dropped); the reverse is NOT dropped - a glob candidate next to a
  # narrower grant genuinely adds behaviour.
  def filter_uncovered(candidates)
    (candidates || []).reject do |cand|
      cand = cand.to_s.strip
      # An empty candidate would match any stored prefix at index 0 via the
      # overlap rule below - reject it explicitly to be safe.
      next true if cand.empty?

      c_tokens = cand.split(/\s+/)
      @prefixes.any? do |stored|
        stored_tokens = stored.to_s.strip.split(/\s+/)
        self.class.starts_with_tokens?(stored_tokens, c_tokens) ||
          self.class.grant_covers_tokens?(c_tokens, stored_tokens)
      end
    end
  end

  # True when `head` starts with every token of `prefix`, token for token.
  def self.starts_with_tokens?(head, prefix)
    return false if prefix.empty? || head.size < prefix.size

    (0...prefix.size).all? { |i| head[i] == prefix[i] }
  end

  # True when the stored grant `grant` covers the candidate token for token - the
  # only glob-aware direction, because only a STORED grant can be a directory glob.
  def self.grant_covers_tokens?(candidate, grant)
    return false if grant.empty? || candidate.size < grant.size

    (0...grant.size).all? { |i| token_matches_grant?(candidate[i], grant[i]) }
  end

  # True when the command token is authorized by the stored grant token: exact
  # equality, or a DIRECTORY glob ('bin/*' authorizes 'bin/rspec', both separator
  # spellings). A glob never authorizes another glob, nor a token whose directory
  # differs ('bin/*' says nothing about 'tools/build').
  def self.token_matches_grant?(token, grant)
    return true if token == grant
    return false unless GLOB_TOKEN.match?(grant)
    return false if GLOB_TOKEN.match?(token)

    index = grant.rindex(SEPARATOR_CHARS)
    dir   = grant[0, index.to_i]
    return false if dir.empty?

    token.start_with?("#{dir}#{grant[index]}") &&
      !SEPARATOR_CHARS.match?(token[(dir.length + 1)..].to_s)
  end

  # Remove a previously saved prefix and persist.
  def remove(prefix)
    before = @prefixes.dup
    @prefixes.reject! { |p| p == prefix }
    save if @prefixes.size != before.size
  end

  # Drop every stored prefix and persist the empty list. The file is kept: removing
  # it too would leave a hand-edited one in place for the next save to overwrite.
  def clear
    return 0 if @prefixes.empty?

    count = @prefixes.size
    @prefixes = []
    save
    count
  end

  private

  # Re-read the stored prefixes: a list revoked by /clear or hand-edited must apply
  # to the NEXT command of a run that already built its runner. The list is a few
  # short strings, so the re-read is not a cost.
  def reload!
    @prefixes = load
  end

  # A segment is allowed when it is safe AND its leading tokens match a stored
  # prefix (a stored DIRECTORY glob authorizes any direct program of that directory).
  def segment_allowed?(segment)
    segment = segment.strip
    return false if segment.empty?
    return false unless self.class.segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }

    @prefixes.any? do |prefix|
      p_tokens = prefix.split(/\s+/)
      p_tokens.size <= words.size &&
        (0...p_tokens.size).all? do |i|
          self.class.token_matches_grant?(words[i], p_tokens[i])
        end
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
