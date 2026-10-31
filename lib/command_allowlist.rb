# frozen_string_literal: true

require "yaml"
require "fileutils"

require_relative "shell_tokenizer"
require_relative "shell_parser"
require_relative "text_normalizer"

# -- CommandAllowlist -----------------------------------------------------
#
# Persists user-approved command prefixes in .harness/allowed_commands.yml
# (run.command tool) or .harness/shell_commands.yml (`!` bang syntax) - two
# separate lists, so a local convenience grant never auto-approves a
# model-initiated command (issue #129).
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
#   DISASTER COMMANDS (issue #221): a command matching DISASTER_PATTERNS
#     (or recursive-force rm, see recursive_force_rm?) is refused by EVERY
#     auto-approval path - a stored allowlist grant, the AUTO-APPROVE model
#     verdict and the YOLO posture alike. Such a command can only ever run
#     through an explicit one-off "Allow". The check inspects the raw
#     command (not only the allowlist-decomposable segments), so it also
#     covers the unsafe constructs YOLO otherwise auto-approves.
#     The recursive-force delete tests match the verb by BASENAME
#     (verb_token?): 'bin/rm -rf /' is the same disaster as 'rm -rf /',
#     because a DIRECTORY grant covers the program in that directory. A
#     quoted PHRASE is never a verb (verb_text returns nil for it), so a
#     commit message that merely names a path verb stays clean.
#   YOLO posture (issue #221): switched on by the user (/yolo), it skips
#     the consent dialog for every run.command call - except denylisted
#     disaster commands, which keep the dialog in every posture. It is the
#     user's own decision, never a model decision, and every auto-approved
#     command is logged (harness.log) and status-lined.
#   Quotes are NOT in the blocklist: they only affect argument splitting,
#     not what runs. Operators inside quotes are literal characters.
#   DIRECTORY GLOB GRANTS (issue #417): a stored grant token of the form
#     '<dir>/*' auto-approves every program DIRECTLY in that directory
#     (token_matches_grant?). It is the broadest grant the harness offers:
#     it also covers a program the model writes there LATER, so the trust
#     boundary is stated in the dialog option (glob_note) at the moment it
#     is chosen, and the basename disaster rule above is what keeps it from
#     standing for 'bin/rm -rf /'.
#
# INTERNALS:
#   Tokenization is done by ShellTokenizer (StringScanner-based).
#   Parsing is done by ShellParser (Racc grammar). Together they replace
#   the previous hand-rolled char-by-char splitting and safety scanning.
#
class CommandAllowlist
  # Two SEPARATE lists (issue #129): the same prefix must not auto-approve
  # both model-driven and locally typed commands.
  TOOL_FILENAME = "allowed_commands.yml"   # run.command tool (LLM)
  SHELL_FILENAME = "shell_commands.yml"    # `!` bang syntax (local shell)

  FILENAME = TOOL_FILENAME

  # Maximum number of tokens considered for a single command's prefix.
  MAX_PREFIX_TOKENS = 3

  # A token that "looks like a subcommand": lowercase alphanumeric, starts
  # with a letter. Distinguishes subcommands (status, log, exec) from
  # arguments (-la, --oneline, main, 68, spec/foo_spec.rb).
  SUBCOMMAND_TOKEN = /\A[a-z][a-z0-9]*\z/

  # Issue #417: a program invoked BY PATH ('bin/rspec', './script.sh',
  # 'C:\work\tool.exe') names the same verb as the bare word, and a grant for
  # it may be written as a DIRECTORY glob ('bin/*'). SEPARATOR_CHARS is what a
  # path token or a glob carries; GLOB_TOKEN is exactly one trailing '*' after
  # a directory part, PATH_TOKEN_CHARS the shape of an unquoted path token, and
  # PROGRAM_NAME the basename that makes a path token a PROGRAM rather than an
  # argument ('spec/' and '2>&1' name nothing).
  SEPARATOR_CHARS = %r{[/\\]}
  GLOB_TOKEN      = %r{\A.*[/\\]\*\z}
  PATH_TOKEN_CHARS = %r{\A[\w.\-:/\\]+\z}
  PROGRAM_NAME     = /\A[a-z][a-z0-9_]*(\.\w+)?\z/i
  # A token that looks like a URL rather than a path: 'https://evil.sh' spells
  # no program, and a 'https://*' grant would be meaningless.
  SCHEME           = %r{\A[a-z][a-z0-9+.-]*://}i

  # Separator token kinds (ShellTokenizer) - used to split a command into
  # raw segments for the disaster scan.
  SEPARATORS = %i[pipe and or semi pipe_and].freeze

  # Well-known disaster commands - POSIX side (issue #221). Matched
  # against every raw segment of the command AND against the whole command
  # (see disaster_scan?). Deliberately broad: a disaster does not need the
  # exact spelling "rm -rf /", and a false positive only costs one
  # confirmation dialog.
  DISASTER_PATTERNS = [
    /\bmkfs(\.|\s|$)/,                            # make filesystem
    /\bfsck\b.*(?<!\w)-f(\s|$)/,                  # force filesystem check
    /\bdd\b.*\bof=\/dev\//,                       # raw write to a device
    /\b(shutdown|reboot|halt|poweroff)\b/,        # power off the machine
    /\bsudo\b/,                                   # privilege escalation
    # Forced push. --force-with-lease is deliberately NOT matched: it is
    # the safe variant (it refuses when the remote moved).
    /\bgit\s+push\b(?=.*(--force(?![\w-])|(?<!\w)-f(\s|$)))/,
    /\bkill\b.*\s-\d+\s+-1\b/,                    # kill every process
    /\bchmod\b.*-[A-Za-z]*R[A-Za-z]*\b.*\b777\b/, # world-writable everything
    /\bchown\b.*\s-R\b.*\s\/(\s|$)/,              # chown the whole tree
    /\bDROP\s+DATABASE\b/i,                       # sql
  ].freeze

  # Patterns whose construct SPANS a separator (a pipe, a subshell), so
  # they must be matched against the whole command string rather than a
  # single segment - the tokenizer removes the separator when segmenting.
  WHOLE_COMMAND_PATTERNS = [
    /\bcurl\b[^|]*\|\s*(sh|bash|zsh|perl|python)\b/,        # download -> shell
    /\bwget\b[^|]*\|\s*(sh|bash|zsh|perl|python)\b/,        # download -> shell
    /:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;?/           # fork bomb
  ].freeze

  # cmd.exe recursive-force delete (del /s /q, rd /q /s, erase /s /q):
  # the Windows twin of `rm -rf`. Lookaheads over the WHOLE segment text
  # so the construct is also caught inside a quoted payload
  # (`cmd //c "del /q /s C:\work\*"` - the payload is one quoted token,
  # so the word-based win_recursive_force_delete? below never sees `del`
  # as its own word).
  WIN_CMD_RECURSIVE_DELETE = /
    (?=.*\b(?:del|erase|rd|rmdir)(\.exe)?\b)
    (?=.*\/s(\s|$))
    (?=.*\/[qfp](\s|$))
  /ix
  # PowerShell recursive-force delete (Remove-Item -Recurse -Force and the
  # short -r / -f forms, including inside a quoted powershell -Command
  # payload). -Rec/-r for the recursion, -F* for the force.
  WIN_PS_RECURSIVE_DELETE = /
    (?=.*\bRemove-Item\b)
    (?=.*(?:-(?:Rec|Recursive)|(?<!\w)-r(\s|$)))
    (?=.*-F)
  /ix

  # Well-known disaster commands - Windows / PowerShell side (issue #221).
  # Commands always reach us through `sh -c`, but from there they invoke
  # cmd.exe (`cmd //c "del /s /q C:\..."`) and PowerShell
  # (`powershell -Command "Remove-Item -Recurse -Force ..."`) just as
  # easily as a POSIX binary, so the Windows spellings must be recognized
  # too. All patterns are case-insensitive: Windows tools are not.
  # Note: quoted payloads ARE visible here (the tokenizer keeps the quotes
  # in the token text), which is what catches `powershell -Command
  # "Remove-Item -Recurse -Force ..."`. The price is that a commit message
  # literally containing such a phrase trips the gate too - accepted for
  # the disaster gate: it costs one extra confirmation, never a run.
  WINDOWS_DISASTER_PATTERNS = [
    /\bformat\b\s+[a-z]:/i,                       # format C:
    /\b(diskpart|sdelete|cleanmgr)\b/i,           # partition / wipe tools
    /\bdiskpart\b.*\bclean\b/i,                   # wipe a disk's partition table
    # delete shadow copies (the ransomware idiom of destroying backups)
    /\bvssadmin\b.*\bdelete\b/i,
    /\breg(\.exe)?\s+delete\b/i,                  # delete registry keys
    /\bbcdedit\b.*\s\/(set|create|delete)/i,      # boot configuration store edits
    /\bmountvol\b.*\/[dD]\b/i,                    # remove volume mount points
    # takeown is typed WITHOUT the .exe in practice (`takeown /f C:\x /r`),
    # so the suffix must be optional - the .exe-only form never matched.
    /\btakeown(\.exe)?\b/i, # seize ownership of a tree
    # blanket ACL grant ("give everyone full control")
    # (icacls, not *ir*cacls - the old spelling matched nothing real).
    /\bicacls?\b.*\/(grant|reset)\b.*\beveryone\b/i,
    /\bClear-Disk\b/i,                            # PowerShell: wipe a disk
    /\bInitialize[-.]?Disk\b.*(-Force|(?<!\w)-Confirm:)/i,
    WIN_CMD_RECURSIVE_DELETE,
    WIN_PS_RECURSIVE_DELETE,
    /\bSet-Content\b.*\bNUL\b/i,                  # overwrite a device name
  ].freeze

  # cmd.exe delete verbs whose recursive + quiet/force combination is the
  # Windows equivalent of `rm -rf` (see win_recursive_force_delete?). Kept
  # free of duplicates and of verbs that are not real cmd.exe commands.
  WIN_DELETE_COMMANDS = %w[del erase rd rmdir].freeze

  # The POSIX twin of WIN_DELETE_COMMANDS (see recursive_force_rm?). Path verbs
  # matter for the disaster gate because a directory grant ('bin/*') would
  # otherwise stand for 'bin/rm -rf /' (issue #417).
  RM_COMMANDS = %w[rm].freeze

  # ------------------------------------------------------------------
  # Disaster scan (issue #221)
  # ------------------------------------------------------------------

  # Split a command into RAW segments at the separator tokens. Unlike
  # split_segments (the ShellParser path, which returns [] for unsafe
  # constructs) this keeps every segment even when the command contains
  # redirects, substitutions or subshells - the disaster scan must see the
  # whole command, including exactly the shapes YOLO auto-approves.
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

  # True when the command is a well-known disaster: either a separator-
  # spanning construct in the whole string (curl ... | sh, a fork bomb) or
  # any single segment matching the per-segment patterns.
  def self.disaster?(command)
    text = TextNormalizer.normalize(command.to_s)
    return true if WHOLE_COMMAND_PATTERNS.any? { |re| re.match?(text) }

    raw_segments(text).any? { |seg| disaster_segment?(seg) }
  end

  # Short human-readable label for the denylist dialog note (issue #221):
  # names the matched construct (and the segment it was found in) so the
  # user sees WHY this command is refused every auto-approval path rather
  # than a bare "denylisted".
  def self.disaster_label(command)
    text = TextNormalizer.normalize(command.to_s)
    (WHOLE_COMMAND_PATTERNS + DISASTER_PATTERNS +
     WINDOWS_DISASTER_PATTERNS).each do |re|
      m = re.match(text)
      # A match must be skipped when the pattern matched ZERO characters:
      # the recursive-delete twins are pure lookaheads (they assert flag
      # combinations without consuming), so their m[0] is empty and would
      # render as "DENYLISTED:  - well-known disaster...". Falling through
      # lands on the fallback label below, which is exactly what those
      # patterns mean.
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

  # True when a command token IS one of `verbs`: the bare word, or a PATH
  # naming that program ('bin/rm', './rd', 'C:\work\bin\rm.exe', 'rm.exe').
  # A path token counts by its BASENAME (the part after the last separator,
  # '.exe' dropped, case-insensitive) because a directory grant ('bin/*')
  # stands for every program in that directory - the mitigation the gate needs
  # before such a grant can be OFFERED at all.
  def self.verb_token?(token, verbs)
    text = verb_text(token)
    return false if text.nil?
    return verbs.include?(bare_word(text)) unless SEPARATOR_CHARS.match?(text)

    verbs.include?(bare_word(text.split(SEPARATOR_CHARS).last.to_s))
  end

  # The text a token spells as a WORD: its own text, or the text inside quotes
  # when the whole token is ONE quoted word ('"rm"', '"/usr/bin/rm"' - quoting
  # a verb does not change what runs). A quoted PHRASE yields nil: it names no
  # program, which is what keeps the quoted-message rule - a commit message
  # merely containing 'bin/rm -rf x' is not a disaster.
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

  # True when a token names a PROGRAM a grant could stand for. Position 0 of a
  # segment may be a PATH program ('bin/rspec' - issue #417); later positions
  # must look like plain subcommands, so an argument that merely contains a
  # separator ('tmp/probe.rb', 'spec/foo_spec.rb') never joins the run.
  def self.program_token?(token, index)
    return true if SUBCOMMAND_TOKEN.match?(token)
    return false unless index.zero?

    path_program_token?(token)
  end

  # A PATH token whose basename names a program: 'bin/rspec', './script.sh',
  # 'C:\work\tool.exe', '/usr/bin/rm'. A quoted or scheme-shaped token
  # ('https://evil.sh') is never one, nor one whose basename names nothing
  # ('spec/', '2>&1').
  def self.path_program_token?(token)
    text = token.to_s
    return false if text.start_with?('"', "'")
    return false if SCHEME.match?(text)
    return false unless PATH_TOKEN_CHARS.match?(text) && SEPARATOR_CHARS.match?(text)

    PROGRAM_NAME.match?(bare_word(text.split(SEPARATOR_CHARS).last.to_s))
  end

  # The DIRECTORY glob a single path program could be granted as, keeping the
  # token's OWN separator: 'bin/rspec' -> 'bin/*', 'C:\work\tool.exe' ->
  # 'C:\work\*'. A directory with a '.', '..' or EMPTY segment is refused:
  # a glob for the current directory, one that resolves out of it
  # ('bin/../*' is the working-tree root), or one whose spelling is not the
  # clean directory shown to the user ('bin//evil'), would trust programs
  # outside that directory - including one the model writes there later.
  def self.directory_glob(token)
    return nil unless path_program_token?(token)

    text  = token.to_s
    index = text.rindex(SEPARATOR_CHARS)
    dir   = text[0, index.to_i]
    return nil if dir.empty?
    # split(-1) keeps the empty segments: an absolute path may have ONE leading
    # empty (the root), but no empty anywhere else ('bin//evil' - the spelling
    # is not a clean directory), and no '.' or '..' segment.
    segments = dir.split(SEPARATOR_CHARS, -1)
    segments = segments[1..].to_a if segments.first.to_s.empty?
    return nil if segments.empty?
    return nil if segments.any? { |s| s.empty? || s == "." || s == ".." }

    "#{dir}#{text[index]}*"
  end

  # The dialog note for a DIRECTORY glob candidate, nil for an exact prefix:
  # the broadest grant the dialog offers must state what it trusts AT THE
  # MOMENT IT IS CHOSEN (issue #417).
  def self.glob_note(candidate)
    return nil unless GLOB_TOKEN.match?(candidate.to_s)

    "covers every program in that directory, including one written there later"
  end

  # cmd.exe / Windows recursive-force delete: `del /s /q C:\...`,
  # `rd /s /q dir`, `erase /s`, and their PowerShell cousins (handled by
  # Remove-Item above). Matched on the command word plus its flags so
  # `git commit -m "del /s /q"` inside quotes does not trip it - quoted
  # words are not :word-kind flags here.
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

  # `rm` with BOTH a recursive and a force flag, in any spelling or order
  # (rm -rf /, rm -fr tmp/, rm -r -f ..., rm --recursive --force ...), whether
  # the verb is bare or a path ('bin/rm -rf /'). Split out from
  # DISASTER_PATTERNS because the test is about flag combination, not a fixed
  # phrase. Quoted arguments are skipped so a message like git commit -m
  # "rm -rf is dangerous" is not flagged: the scan only looks at unquoted words.
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
    # issue #257: strip on byte-invalid UTF-8 raises, so normalize first.
    ShellParser.parse(TextNormalizer.normalize(command).strip)
  rescue ShellParser::ParseError
    []
  end

  # True when a single segment contains no dangerous shell constructs.
  # Uses ShellTokenizer to classify each token; any :danger token means
  # the segment is unsafe.
  def self.segment_safe?(segment)
    # issue #257: normalize before matching (see ShellTokenizer).
    tokens = ShellTokenizer.tokenize(TextNormalizer.normalize(segment))
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
    when "&"          then "background operator (&)"
    when /\A\$/       then "substitution or variable expansion (#{t.inspect})"
    when "`"          then "command substitution (`...`)"
    when "("          then "subshell open ( )"
    when ")"          then "subshell close ( )"
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
  # The prefix is the leading sequence of program-looking tokens (subcommands,
  # or the leading PATH token - issue #417), up to MAX_PREFIX_TOKENS. Stops at
  # the first argument-looking token.
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
  # for "cd C:/work/x" both the short prefix and the full invocation are
  # offered, so the user can grant as broadly or as narrowly as they want
  # (issue #249). Segments that yield no candidate (no leading word) are
  # skipped. Returns [] when ANY segment is unsafe.
  #
  # Examples:
  #   "cd C:/work/x && ruby -c lib/cli.rb"
  #     => ["cd", "cd C:/work/x", "ruby", "ruby -c"]
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
  # of program-looking tokens (1..MAX_PREFIX_TOKENS: subcommands, or a leading
  # PATH program - issue #417), plus these options:
  #   * the whole invocation when the run is a single program and the rest are
  #     arguments ("cd C:/work/x", the issue #249 shape "ruby tmp/probe.rb");
  #   * the invocation up to and INCLUDING the first flag, but only when that
  #     flag directly follows the run ("ruby -c" is a different grant from bare
  #     "ruby"; a flag buried in the arguments - "bin/rspec spec/x -e" - would
  #     only ever authorize THAT command, so it is not offered);
  #   * the run's DIRECTORY glob when the run is one path program
  #     ("bin/rspec" -> "bin/*"), which is what makes a grant useful for the
  #     harness' own bin/ scripts (issue #417).
  # A trailing flag ("tail -5") is just a parameter - never offered. When the
  # run hit the MAX_PREFIX_TOKENS cap and the next token is also a subcommand,
  # the full invocation is appended as an exact-match option (e.g.
  # "a b c d e" offers "a", "a b", "a b c", "a b c d e").
  def self.prefix_lengths(segment)
    segment = segment.to_s.strip
    return [] unless segment_safe?(segment)

    tokens = ShellTokenizer.tokenize(segment)
    words  = tokens.select { |kind, _t| kind == :word }.map { |_k, t| t }
    return [] if words.empty?

    flag_idx = words.index { |w| w.start_with?("-") }

    # The leading run of program tokens. A PATH program ('bin/rspec') is ONE
    # token: whatever follows it is its arguments, even a word that would
    # otherwise read as a subcommand ('bin/rspec spec -e'). A bare-word run
    # continues over subcommand-looking tokens only ('bundle exec rspec'),
    # never over an argument that happens to be a path ('ruby tmp/probe.rb').
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

    # Single subcommand + non-subcommand args (e.g. "cd C:/work/x", or the
    # issue #249 shape "ruby tmp/issue240_probe.rb"): offer the short prefix
    # AND the full invocation as an exact-match option, so the user grants
    # exactly as much as they want rather than only the whole line.
    if lengths.size == 1 && flag_idx.nil? && words.size > 1
      full = words.join(" ")
      lengths << full unless lengths.include?(full)
    end

    # The first flag directly after the run, and followed by an argument:
    # "ruby -c" is a different grant than bare "ruby". A flag inside the
    # arguments is not a grant shape at all.
    if flag_idx && flag_idx == run_size && flag_idx < words.size - 1
      with_flag = words[0..flag_idx].join(" ")
      lengths << with_flag unless lengths.include?(with_flag)
    end

    # A program invoked by path also gets its DIRECTORY glob: 'bin/rspec'
    # alone would authorize one exact invocation, which is not a grant.
    if run_size == 1 && (glob = directory_glob(words[0]))
      lengths << glob unless lengths.include?(glob)
    end

    # The subcommand run hit the MAX_PREFIX_TOKENS cap and the next
    # token is also a subcommand: append the full invocation as an
    # exact-match option (e.g. "a b c d e" -> add "a b c d e").
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
    return false if @prefixes.empty?
    # issue #257: strip on byte-invalid UTF-8 raises, so normalize at this
    # public entry point (the caller may pass raw JSON-parsed text).
    command = TextNormalizer.normalize(command)
    return false if command.strip.empty?

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
  # when it is already covered by a stored grant in either direction,
  # i.e. when one is a full token-level prefix of the other. This catches:
  #   - exact duplicates (e.g. stored 'tail', candidate 'tail'),
  #   - candidates subsumed by a broader grant (stored 'gh issue view',
  #     candidate 'gh' or 'gh issue' - the existing grant already covers
  #     them, so offering them is redundant),
  #   - candidates that subsume a narrower grant (stored 'git log',
  #     candidate 'git' - saving 'git' would make the stored 'git log'
  #     entry dead weight, so it is not offered).
  # Candidates in a DIFFERENT command tree are kept (issue #164): a
  # stored 'gh issue view' must not hide an unrelated 'git remote'. A stored
  # DIRECTORY glob covers every program of that directory, so its exact
  # candidates are dropped (issue #417); the reverse is NOT dropped - a glob
  # candidate next to a narrower stored grant ('bin/*' beside 'bin/harness')
  # genuinely adds behaviour, and refusing it would leave no way to widen a
  # grant from the dialog.
  def filter_uncovered(candidates)
    (candidates || []).reject do |cand|
      cand = cand.to_s.strip
      # An empty candidate would match any stored prefix at index 0 via
      # the overlap rule below - but reject it explicitly to be safe.
      next true if cand.empty?

      c_tokens = cand.split(/\s+/)
      @prefixes.any? do |stored|
        stored_tokens = stored.to_s.strip.split(/\s+/)
        # True-prefix subsumption: one list is a full token-level prefix
        # of the other - either the candidate is already covered by the
        # stored grant, or it would cover the stored grant.
        self.class.starts_with_tokens?(stored_tokens, c_tokens) ||
          self.class.grant_covers_tokens?(c_tokens, stored_tokens)
      end
    end
  end

  # True when `head` starts with every token of `prefix`, token for token.
  # Used by filter_uncovered to detect token-level subsumption in either
  # direction (issue #164).
  def self.starts_with_tokens?(head, prefix)
    return false if prefix.empty? || head.size < prefix.size

    (0...prefix.size).all? { |i| head[i] == prefix[i] }
  end

  # True when the stored grant `grant` covers the candidate `candidate` token
  # for token (issue #417): the only glob-aware direction, because only a
  # STORED grant can be a directory glob.
  def self.grant_covers_tokens?(candidate, grant)
    return false if grant.empty? || candidate.size < grant.size

    (0...grant.size).all? { |i| token_matches_grant?(candidate[i], grant[i]) }
  end

  # True when the command token `token` is authorized by the stored grant
  # token `grant`: exact equality, or a DIRECTORY glob grant ('bin/*' authorizes
  # 'bin/rspec' and 'bin/harness', both spellings of the separator). A glob
  # never authorizes another glob, and never a token whose directory differs -
  # 'bin/*' says nothing about 'tools/build', and a bare 'bin' matches no path.
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

  private

  # A single segment is allowed when it is safe AND its leading tokens
  # match one of the stored prefixes (a stored DIRECTORY glob authorizes any
  # direct program of that directory - issue #417).
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
