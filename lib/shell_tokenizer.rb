# frozen_string_literal: true

require 'strscan'

# -- ShellTokenizer ---------------------------------------------------------
#
# A StringScanner-based tokenizer for a SAFE SUBSET of POSIX shell.
#
# It emits a flat token stream that ShellParser (a Racc grammar) consumes
# to build an AST of pipelines and simple-commands. The tokenizer is NOT
# responsible for syntax validation - it only classifies each lexeme.
#
# Token kinds (symbol values):
#   :word       - a shell word: bare text, single-quoted, double-quoted,
#                 or a mix (e.g. `foo"bar baz"`). The token's string value
#                 preserves the original quoting so downstream code can
#                 inspect it; ShellParser uses it verbatim for prefix
#                 matching (quotes do not change what command runs).
#   :pipe       - `|`
#   :and        - `&&`
#   :or         - `||`
#   :semi       - `;`
#   :pipe_and   - `|&`  (pipe with stderr)
#   :danger     - any construct that must NEVER be auto-approved:
#                   <, >, >> (file redirects - EXCEPT to /dev/null, which
#                            only discards output and is safe, see below)
#                   &>, &>> (combined stdout+stderr redirect; same
#                            /dev/null exemption as above)
#                   &        (background)
#                   $        (substitution / variable expansion)
#                   `        (command substitution)
#                   (, )      (subshell / grouping)
#                 The token's string value holds the offending lexeme so
#                 error messages can name it.
#
# Design notes:
#   * fd-to-fd redirects like `2>&1` are NOT dangerous - they only swap
#     stderr/stdout within the same process. The tokenizer treats them as
#     a single :word token (e.g. "2>&1") so that pipelines such as
#     `bundle exec rspec 2>&1 | grep x` can be auto-approved.
#   * Redirects TO /dev/null (`>/dev/null`, `2>/dev/null`, `>>/dev/null`)
#     are NOT dangerous either - they only discard output, creating or
#     modifying no file. The tokenizer treats them as a single :word token
#     (e.g. ">/dev/null", "2>/dev/null") so such commands can be
#     auto-approved. Any other redirect target is still :danger.
#   * Combined stdout+stderr redirects (`&>`, `&>>`) follow the same rules:
#     safe only when targeting /dev/null.
#   * Operators inside quotes are literal characters, never separators.
#   * Backslash-escaped operators outside quotes become part of the
#     surrounding word (e.g. `echo a\|b` -> one word "a\|b").
#   * The tokenizer is intentionally conservative: anything it cannot
#     classify confidently is emitted as :danger, which ShellParser
#     rejects. This errs on the safe side.
#
class ShellTokenizer
  # Characters that always produce a :danger token when seen outside quotes.
  DANGER_CHARS = '<>&$`()'.freeze

  # A redirect whose target is this path only discards output (no file is
  # created or modified), so it is safe to auto-approve - like `2>&1`.
  DEVNULL = '/dev/null'.freeze

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  # Tokenize a command string into an array of [kind, text] pairs.
  # kind is a Symbol (see class docs), text is the original lexeme.
  def self.tokenize(command)
    new(command).tokens
  end

  def initialize(command)
    @command  = command.to_s
    @scanner  = StringScanner.new(@command)
    @tokens   = []
    @word_buf = +''
  end

  # Run the tokenizer and return the token array.
  def tokens
    scan!
    flush_word
    @tokens
  end

  private

  # Main dispatch loop.
  def scan!
    until @scanner.eos?
      # Skip leading whitespace (word boundary).
      if @scanner.check(/\s+/)
        @scanner.skip(/\s+/)
        flush_word
        break if @scanner.eos?
      end

      ch = @scanner.peek(1)

      case ch
      when "'"  then scan_single_quoted
      when '"'  then scan_double_quoted
      when '&'  then scan_ampersand
      when '|'  then scan_pipe
      when '>'  then scan_gt
      when ';'  then flush_word; emit(:semi, ';'); @scanner.getch
      when '<'  then flush_word; emit(:danger, scan_redirect)
      when '$'  then flush_word; emit(:danger, scan_dollar)
      when '`'  then flush_word; emit(:danger, '`'); @scanner.getch
      when '('  then flush_word; emit(:danger, '('); @scanner.getch
      when ')'  then flush_word; emit(:danger, ')'); @scanner.getch
      else           scan_word
      end
    end
  end

  # Single-quoted: consume until closing '. Backslash has no special
  # meaning inside single quotes (POSIX). Unterminated -> :danger.
  def scan_single_quoted
    start = @scanner.pos
    @scanner.getch # opening '
    if @scanner.eos? || @scanner.scan_until(/'/).nil?
      text = @command[start..]
      @scanner.terminate
      flush_word
      emit(:danger, text)
    else
      end_pos = @scanner.pos - 1 # position of closing '
      text    = @command[start..end_pos]
      @scanner.getch # consume closing '
      flush_word
      emit(:word, text)
    end
  end

  # Double-quoted: consume until unescaped ". Backslash escapes only $, `,
  # ", \, and newline inside double quotes (POSIX); other backslash+char
  # pairs keep both characters literally.
  def scan_double_quoted
    @scanner.getch # opening "
    buf = ['"']
    loop do
      if @scanner.eos?
        flush_word
        emit(:danger, buf.join)
        return
      end
      ch = @scanner.getch
      if ch == '\\' && !@scanner.eos?
        nxt = @scanner.peek(1)
        if '$`"\\'.include?(nxt)
          buf << ch << nxt
          @scanner.getch
        else
          buf << ch # backslash is literal here
        end
      elsif ch == '"'
        buf << ch
        break
      else
        buf << ch
      end
    end
    flush_word
    emit(:word, buf.join)
  end

  # `&` can be: background (`&`) or and-list (`&&`).
  # fd-to-fd redirects (`2>&1`) are handled at the `>` dispatch point
  # (see scan_gt), since `>` comes first in the stream.
  def scan_ampersand
    if @scanner.check('&&')
      flush_word
      @scanner.skip('&&')
      emit(:and, '&&')
    elsif !word_buf_ends_with_digit? && @scanner.check('&>')
      # Combined stdout+stderr redirect (bash/zsh &> operator). Treated
      # like a file redirect: safe only when targeting /dev/null.
      if (dn = scan_devnull_redirect('&>'))
        emit(:word, dn)
      else
        flush_word
        emit(:danger, scan_combined_redirect)
      end
    else
      flush_word
      emit(:danger, '&')
      @scanner.getch
    end
  end

  # `|` can be: pipe (`|`), or-list (`||`), or pipe-and (`|&`).
  def scan_pipe
    if @scanner.check('||')
      flush_word
      @scanner.skip('||')
      emit(:or, '||')
    elsif @scanner.check('|&')
      flush_word
      @scanner.skip('|&')
      emit(:pipe_and, '|&')
    else
      flush_word
      @scanner.getch
      emit(:pipe, '|')
    end
  end

  # `>` dispatch: either a file redirect (danger) or part of a fd-to-fd
  # redirect (`2>&1`) or a redirect to /dev/null. The latter two are safe
  # (no hidden execution, no file created/modified) and become one word.
  def scan_gt
    # Check for fd-to-fd redirect: digit + `>&` + optional digit.
    if @scanner.check('>&') && word_buf_ends_with_digit?
      # e.g. "2" + ">&1" -> word "2>&1".
      text = @word_buf.dup
      @word_buf.clear
      @scanner.skip('>&')
      text << '>&'
      if (n = @scanner.peek(1)) && n =~ /\d/
        text << n
        @scanner.getch
      end
      emit(:word, text)
    else
      # Redirect to /dev/null: safe (only discards output, creates or
      # modifies no file) - becomes one word token, gluing any preceding
      # fd digit (e.g. "2" + ">/dev/null" -> "2>/dev/null").
      if (dn = scan_devnull_redirect('>'))
        emit(:word, dn)
      else
        # Any other file redirect: danger.
        flush_word
        emit(:danger, scan_redirect)
      end
    end
  end

  # Match a /dev/null redirect for the given operator ('>' or '&>'),
  # gluing any preceding word buffer (e.g. an fd digit). Returns the
  # combined text when it matches (safe - output is only discarded), or
  # nil leaving the scanner positioned so a danger-redirect scan can run.
  def scan_devnull_redirect(operator)
    # '+': allow one or more of the operator's trailing '>' so both
    # '>/dev/null' and '>>/dev/null' (and '&>', '&>>') match.
    re = Regexp.new("#{Regexp.escape(operator[0..-2])}(>+)\\s*#{Regexp.escape(DEVNULL)}(?![\\w./-])")
    return unless @scanner.check(re)

    devnull = @scanner.scan(re)
    prefix  = @word_buf.dup
    @word_buf.clear
    prefix + devnull
  end

  # `<` or `>`: consume the full redirect lexeme (e.g. `>>`, `> file`)
  # and return as a string for the :danger token.
  def scan_redirect
    buf = [@scanner.getch]
    if @scanner.check(buf.last) && buf.last == '>'
      buf << @scanner.getch # >>
    end
    buf << scan_target  # include the target (e.g. "file") in the label
    buf.join
  end

  # Consume an optional whitespace-separated redirect target and return it
  # prefixed by a single space (e.g. " tmpfile"), or '' when the operator
  # is immediately followed by whitespace/EOS. Lets danger-token labels name
  # the whole construct ("&> build.log") instead of just the operator.
  def scan_target
    return '' unless @scanner.check(/\s*[^\s|;&<>$`()\n]/)

    @scanner.scan(/\s*/)  # eat any separating whitespace (discarded)
    target = @scanner.scan(/[^\s|;&<>$`()\n]+/)
    " #{target}" if target
  end

  # `&>` or `&>>`: consume the full combined-redirect lexeme (e.g. `&> log`)
  # and return it as a string for the :danger token, so error/note messages
  # name the whole construct rather than just `>`.
  def scan_combined_redirect
    buf = ['&']
    @scanner.getch
    if @scanner.check('>')
      buf << '>'
      @scanner.getch
      if @scanner.check('>')
        buf << '>'
        @scanner.getch
      end
    end
    buf << scan_target  # include the target in the label (e.g. " log")
    buf.join
  end

  # `$`: consume a plausible substitution lexeme for the error message.
  def scan_dollar
    @scanner.getch
    if @scanner.check('(')
      # $(...) - consume up to matching ) or end, whichever comes first.
      depth = 0
      buf = ['$', '(']
      @scanner.getch
      depth = 1
      while !@scanner.eos? && depth > 0
        c = @scanner.getch
        buf << c
        depth += 1 if c == '('
        depth -= 1 if c == ')'
      end
      buf.join
    elsif (name = @scanner.check(/[A-Za-z_][A-Za-z0-9_]*/))
      word = @scanner.scan(/[A-Za-z_][A-Za-z0-9_]*/)
      '$' + word
    else
      '$'
    end
  end

  # Bare word: consume until whitespace or a known operator/danger char.
  # Characters are accumulated in @word_buf (NOT emitted yet) so that
  # consecutive bare-word chunks and escaped-literals glue into one token.
  def scan_word
    while !@scanner.eos?
      ch = @scanner.peek(1)
      break if ch =~ /\s/
      break if DANGER_CHARS.include?(ch)
      break if ch == ';' || ch == "'" || ch == '"'

      # Two-char operators we must not eat as word chars.
      break if @scanner.check('&&') || @scanner.check('||') || @scanner.check('|&')

      # Backslash-escaped char outside quotes: the escaped char is a
      # literal inside the current word (e.g. `a\|b` -> one word). A
      # backslash before whitespace is a line-continuation: skip both.
      if ch == '\\'
        @scanner.getch
        break if @scanner.eos?
        nxt = @scanner.peek(1)
        if nxt =~ /\s/
          # Line continuation: skip the whitespace, stop scanning.
          @scanner.getch
          return
        end
        @word_buf << ch << nxt
        @scanner.getch
        next
      end

      @word_buf << ch
      @scanner.getch
    end
  end

  # True when the current word buffer ends with a digit (e.g. "2" before
  # `>&1`). Used to detect fd-to-fd redirects.
  def word_buf_ends_with_digit?
    !@word_buf.empty? && @word_buf[-1] =~ /\d/
  end

  def flush_word
    return if @word_buf.empty?
    emit(:word, @word_buf.dup)
    @word_buf.clear
  end

  def emit(kind, text)
    @tokens << [kind, text]
  end
end
