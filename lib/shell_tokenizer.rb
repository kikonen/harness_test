# frozen_string_literal: true

require "strscan"
require_relative "text_normalizer"

# -- ShellTokenizer ---------------------------------------------------------
# A StringScanner-based tokenizer for a SAFE SUBSET of POSIX shell, emitting a
# flat token stream for ShellParser; token kinds and design: doc/shell_tokenizer_design.md
class ShellTokenizer
  # Characters that always produce a :danger token when seen outside quotes.
  DANGER_CHARS = "<>&$`()".freeze

  # A redirect whose target is this path only discards output (no file is
  # created or modified), so it is safe to auto-approve - like `2>&1`.
  DEVNULL = "/dev/null".freeze

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  # Tokenize a command string into an array of [kind, text] pairs.
  # kind is a Symbol (see class docs), text is the original lexeme.
  def self.tokenize(command)
    new(command).tokens
  end

  def initialize(command)
    # The command is externally-sourced text; regex matching on byte-invalid
    # UTF-8 raises ArgumentError, so normalize at this entry point.
    @command  = TextNormalizer.normalize(command)
    @scanner  = StringScanner.new(@command)
    @tokens   = []
    @word_buf = +""
  end

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
      when "&"  then scan_ampersand
      when "|"  then scan_pipe
      when ">"  then scan_gt
      when ";"  then flush_word; emit(:semi, ";"); @scanner.getch
      when "<"  then flush_word; emit(:danger, scan_redirect)
      when "$"  then flush_word; emit(:danger, scan_dollar)
      when "`"  then flush_word; emit(:danger, "`"); @scanner.getch
      when "("  then flush_word; emit(:danger, "("); @scanner.getch
      when ")"  then flush_word; emit(:danger, ")"); @scanner.getch
      else           scan_word
      end
    end
  end

  # Single-quoted: consume until closing '. Backslash has no special meaning
  # inside single quotes (POSIX). Unterminated -> :danger.
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
      if ch == "\\" && !@scanner.eos?
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

  # `&` can be: background (`&`) or and-list (`&&`). fd-to-fd redirects
  # (`2>&1`) are handled at the `>` dispatch point (see scan_gt).
  def scan_ampersand
    if @scanner.check("&&")
      flush_word
      @scanner.skip("&&")
      emit(:and, "&&")
    elsif !word_buf_ends_with_digit? && @scanner.check("&>")
      # Combined stdout+stderr redirect (&> operator). Treated like a file
      # redirect: safe only when targeting /dev/null.
      if (dn = scan_devnull_redirect("&>"))
        emit(:word, dn)
      else
        flush_word
        emit(:danger, scan_combined_redirect)
      end
    else
      flush_word
      emit(:danger, "&")
      @scanner.getch
    end
  end

  # `|` can be: pipe (`|`), or-list (`||`), or pipe-and (`|&`).
  def scan_pipe
    if @scanner.check("||")
      flush_word
      @scanner.skip("||")
      emit(:or, "||")
    elsif @scanner.check("|&")
      flush_word
      @scanner.skip("|&")
      emit(:pipe_and, "|&")
    else
      flush_word
      @scanner.getch
      emit(:pipe, "|")
    end
  end

  # `>` dispatch: a file redirect (danger), or a safe fd-to-fd redirect
  # (`2>&1`) or redirect to /dev/null, which become one word.
  def scan_gt
    # fd-to-fd redirect: digit + `>&` + optional digit, e.g. "2" + ">&1" -> "2>&1".
    if @scanner.check(">&") && word_buf_ends_with_digit?
      text = @word_buf.dup
      @word_buf.clear
      @scanner.skip(">&")
      text << ">&"
      if (n = @scanner.peek(1)) && n =~ /\d/
        text << n
        @scanner.getch
      end
      emit(:word, text)
    else
      # Redirect to /dev/null is safe (discards output only), gluing any
      # preceding fd digit (e.g. "2" + ">/dev/null" -> "2>/dev/null").
      if (dn = scan_devnull_redirect(">"))
        emit(:word, dn)
      else
        flush_word
        emit(:danger, scan_redirect)
      end
    end
  end

  # Match a /dev/null redirect for the given operator ('>' or '&>'), gluing any
  # preceding word buffer (e.g. an fd digit). Returns the combined text when it
  # matches, or nil leaving the scanner positioned for a danger-redirect scan.
  def scan_devnull_redirect(operator)
    # '+': allow one or more trailing '>' so both '>/dev/null' and '>>/dev/null'
    # (and '&>', '&>>') match.
    re = Regexp.new("#{Regexp.escape(operator[0..-2])}(>+)\\s*#{Regexp.escape(DEVNULL)}(?![\\w./-])")
    return unless @scanner.check(re)

    devnull = @scanner.scan(re)
    prefix  = @word_buf.dup
    @word_buf.clear
    prefix + devnull
  end

  # `<` or `>`: consume the full redirect lexeme (e.g. `>>`, `> file`) and
  # return as a string for the :danger token.
  def scan_redirect
    buf = [@scanner.getch]
    if @scanner.check(buf.last) && buf.last == ">"
      buf << @scanner.getch # >>
    end
    buf << scan_target # include the target (e.g. "file") in the label
    buf.join
  end

  # Consume an optional whitespace-separated redirect target, prefixed by a
  # single space (e.g. " tmpfile"), or '' when the operator is immediately
  # followed by whitespace/EOS. Lets danger labels name the whole construct.
  def scan_target
    return "" unless @scanner.check(/\s*[^\s|;&<>$`()\n]/)

    @scanner.scan(/\s*/) # eat any separating whitespace (discarded)
    target = @scanner.scan(/[^\s|;&<>$`()\n]+/)
    " #{target}" if target
  end

  # `&>` or `&>>`: consume the full combined-redirect lexeme and return it for
  # the :danger token, so messages name the whole construct rather than just `>`.
  def scan_combined_redirect
    buf = ["&"]
    @scanner.getch
    if @scanner.check(">")
      buf << ">"
      @scanner.getch
      if @scanner.check(">")
        buf << ">"
        @scanner.getch
      end
    end
    buf << scan_target # include the target in the label (e.g. " log")
    buf.join
  end

  # `$`: consume a plausible substitution lexeme for the error message.
  def scan_dollar
    @scanner.getch
    if @scanner.check("(")
      # $(...) - consume up to matching ) or end, whichever comes first.
      depth = 0
      buf = ["$", "("]
      @scanner.getch
      depth = 1
      while !@scanner.eos? && depth > 0
        c = @scanner.getch
        buf << c
        depth += 1 if c == "("
        depth -= 1 if c == ")"
      end
      buf.join
    elsif (name = @scanner.check(/[A-Za-z_][A-Za-z0-9_]*/))
      word = @scanner.scan(/[A-Za-z_][A-Za-z0-9_]*/)
      "$" + word
    else
      "$"
    end
  end

  # Bare word: consume until whitespace or a known operator/danger char.
  # Characters accumulate in @word_buf (NOT emitted yet) so consecutive
  # bare-word chunks and escaped-literals glue into one token.
  def scan_word
    while !@scanner.eos?
      ch = @scanner.peek(1)
      break if ch =~ /\s/
      break if DANGER_CHARS.include?(ch)
      break if ch == ";" || ch == "'" || ch == '"'

      # Two-char operators we must not eat as word chars.
      break if @scanner.check("&&") || @scanner.check("||") || @scanner.check("|&")

      # Backslash-escaped char outside quotes is a literal inside the current
      # word (e.g. `a\|b` -> one word). A backslash before whitespace is a
      # line-continuation: skip both.
      if ch == "\\"
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
