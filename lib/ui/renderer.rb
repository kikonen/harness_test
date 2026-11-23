# frozen_string_literal: true

require_relative "palette"
require_relative "markdown_renderer"
require_relative "width"
require_relative "text_wrap"

# Renders one output entry to a console line: the PATTERN (label, status
# bracket and glyph, gutter, color) belongs here, never in the emitted string.
# Design and the full type list: doc/output_rendering_design.md.
module UI
  class Renderer
    LABELS = {
      step_label: "step ",
      plan: "plan:  ",
      interstitial: "say:   ",
      tool_plan: "tools: ",
      response: "model: ",
      user: "user:  ",
      warn: "warn:  ",
      error: "error: "
    }.freeze

    # The verdict IS the type; the bracket label travels in the event's origin.
    # status_info has no glyph: a count is not a verdict about an operation.
    STATUS_GLYPHS = {
      status_ok: "✓",
      status_fail: "✗",
      status_warn: "⚠",
      status_note: "!",
      status_same: "=",
      status_info: nil
    }.freeze
    STATUS_TYPES = STATUS_GLYPHS.keys.freeze

    # The bracketed one-word badge a command prints as its ack. The bracket shape
    # is the renderer's, not baked into the string. UNPAINTED: these acks print in
    # the terminal's own color today, so coloring them would change terminal bytes.
    # :kind is the same bracket shape with a message after it - the bracket names a
    # KIND, not a verdict.
    ACK = :ack
    KIND = :kind
    ACK_TYPES = [ACK, KIND].freeze

    # An ack whose body is a PARAGRAPH (a steering note). The renderer lays the ack
    # and body out as ONE block at the note width, the first wrapped line continuing
    # the ack line. UNPAINTED like NOTE; the buffer still stores the paragraph as
    # NOTE, so a replay redraws it as a plain paragraph.
    ACK_NOTE = :ack_note

    # A paragraph of harness explanatory prose. The emitter states ONE unwrapped
    # paragraph with no leading indent; the renderer owns the indent AND the wrap.
    # UNPAINTED. The wrap width is a fixed column count, not the terminal width. The
    # raw paragraph is what lands in the OutputBuffer, so a browser re-wraps it in CSS.
    NOTE = :note

    # A store body read by name (a plan, a memory, a skill): the emitter states the RAW
    # markdown and the renderer renders it. NOT the :note role - a body keeps its own
    # markdown structure, and a body no renderer can render stays as stored.
    BODY = :body

    # A BLANK LINE between entries. A role because the spacing shape is the renderer's,
    # not the emitter's (a browser adds its own margin). Inside one :list payload the
    # gap is a key instead, because the payload is a single entry. Unpainted.
    GAP = :gap

    # The emitter still owns these lines' shape. :spinner_detail is listed because the
    # drain loop animates it - it must never produce a line. :rule is listed because the
    # content IS the rule the emitter drew: the type exists only to carry the palette's
    # rule colour, which no other type named.
    VERBATIM = %i[system text stats compact spinner_detail rule].freeze

    INDENT      = "  "
    GUTTER      = "#{INDENT}|"
    STATUS_RULE = "#{INDENT}#{"-" * 12}"
    # Fixed width, NOT the terminal width: a boundary that depends on a terminal setting
    # is a boundary that moves.
    RULE_WIDTH = 80
    # The FALLBACK page width when no terminal can be detected (a spec console, a pipe).
    # A live terminal resolves its own through UI::Width. NOTE_WIDTH is the content budget
    # that fallback implies: RULE_WIDTH - INDENT.
    RULE_FALLBACK_WIDTH = RULE_WIDTH
    NOTE_WIDTH = RULE_WIDTH - INDENT.length

    # A structured list/table report. The emitter states the DATA (title, kind, columns,
    # per-item field values) - never a fused row string - so a remote sink can lay out a
    # real list/table from the fields. The renderer owns the layout. UNPAINTED like :note.
    # Footer lines carry an INDENT LEVEL, never baked leading spaces (see #footer_line).
    LIST = :list

    # The item fields each :list kind's row reads, BY NAME. The order is the row template's
    # own, not the columns array's, so a reordered columns list cannot scramble a row. An
    # unknown kind, or columns missing a kind's required fields, is a loud diagnostic.
    LIST_KIND_FIELDS = {
      bullet: %i[value],
      kv: %i[name description],
      # :table needs no fixed field list: the columns array IS the schema. See #table_lines.
      table: []
    }.freeze

    # The start of an iteration and the start of the final answer are the two block
    # boundaries, and both get the same fused rule. plan / say / tools / warn / error
    # stay plain labels: they are lines INSIDE a block.
    BOUNDARY_ROLES = %i[step_label response].freeze

    # The labeled roles whose content is model prose that may carry markdown (the plan
    # and say lines). :tool_plan is a tool list (not prose) and warn / error are harness
    # messages - both stay plain.
    MARKDOWN_ROLES = %i[plan interstitial].freeze

    # The word a boundary rule fuses: the role's label without its ":  " padding - a rule
    # reads like a short word, not a label.
    def self.boundary_label(type)
      LABELS.fetch(type.to_sym).sub(/:\s+\z/, "")
    end

    # The palette a line written TO A GIVEN SINK should render with: the sink that receives
    # the line owns its colour. A sink with no #palette method (a browser console seam) paints
    # NOTHING - a terminal palette would bake SGR it has no terminal to interpret. A
    # palette-aware sink (UI::Console) keeps its own palette, else the settings palette - so a
    # terminal built before the Harness exists still honours a mid-session /palette switch.
    def self.palette_for(ui:, settings: nil)
      return nil unless ui.respond_to?(:palette)

      ui.palette || settings&.output_palette
    end

    attr_reader :palette

    # palette: a UI::Palette, or nil to render without color (specs, a bare console).
    # markdown: render an assistant :response and the MARKDOWN_ROLES lines as markdown.
    #   Default false keeps every existing line byte-for-byte.
    # markdown_max_width: the table-width basis (nil = 80% of the terminal); the boundary
    #   chrome stays at the fixed RULE_WIDTH whatever this says.
    # ui: the SINK the lines are written to, so width is resolved from that terminal.
    def initialize(
      palette: nil,
      markdown: false,
      markdown_max_width: nil,
      ui: nil
    )
      @palette  = palette
      @markdown = markdown ?
        MarkdownRenderer.new(palette:, max_width: markdown_max_width) : nil
      # A :table sizes from this basis even when markdown opt-in is off, so a configured
      # width constrains the table too.
      @ui = ui
      # The RAW basis stays as data: a percentage is the only form a sink with no column
      # count of its own can lay out from, so the record must carry "85%" not this run's number.
      @markdown_max_width = markdown_max_width
    end

    # The resolved content width for THIS renderer: the paragraph budget, table basis, and
    # wrap width all read it.
    def width
      UI::Width.resolve(
        value: @markdown_max_width,
        # terminal_columns, not columns_for: the sink alone often cannot answer (a redirected
        # or closed stdout raises on #winsize), and columns_for has no terminal of its own.
        terminal: UI::Width.terminal_columns(@ui),
        fallback: RULE_FALLBACK_WIDTH)
    end

    # The prose budget: the page width minus the indent a paragraph carries, so a wrapped
    # line stays inside the page width.
    def note_width
      width - INDENT.length
    end

    # origin: for a status type, the bracket label ("file.read", "access"). Ignored otherwise.
    # ack: the badge word an :ack_note puts before its body. Ignored otherwise.
    def line(type:, content:, origin: nil, ack: nil)
      type = type.to_sym
      text = content.to_s

      return "" if type == GAP
      return list_line(content) if type == LIST

      return status_line(type, text, origin) if STATUS_GLYPHS.key?(type)
      return ack_note_line(text, origin, ack) if type == ACK_NOTE
      return ack_line(type, text, origin) if ACK_TYPES.include?(type)
      return boundary_line(type, content) if BOUNDARY_ROLES.include?(type)
      return note_line(text) if type == NOTE
      return labeled_markdown_line(type, text) if markdown_role?(type)
      return wrapped_labeled_line(type, text) if MARKDOWN_ROLES.include?(type)
      return body_line(text) if type == BODY

      paint(type, labeled(type, text))
    end

    def labeled?(type)
      type = type.to_sym
      return true if STATUS_GLYPHS.key?(type)
      return true if ACK_TYPES.include?(type)
      return true if type == NOTE
      return true if type == ACK_NOTE
      return true if type == LIST
      return true if type == BODY
      return true if type == GAP

      !VERBATIM.include?(type) && LABELS.key?(type)
    end

    private

    # A bracketed ack: the content IS the badge word, the renderer wraps it. Unpainted.
    def ack_line(type, badge, origin)
      return "#{INDENT}[#{badge}]" if type == ACK

      # :kind - the bracket names a KIND (origin), the message follows it. Unpainted.
      "#{INDENT}[#{origin || badge}] #{badge}"
    end

    # An ack with a paragraph body (a steering note): the body starts on the NEXT line at
    # the same indent, so ack and body are one block at the note width. UNPAINTED like NOTE.
    def ack_note_line(paragraph, origin, badge)
      ack = "#{INDENT}[#{origin}] #{badge}"
      ([ack] + note_line(paragraph).split("\n")).join("\n")
    end

    # A paragraph of harness prose: indent every wrapped line and re-wrap the text to the
    # resolved note width, so the paragraph is a function of the renderer, not of where the
    # emitter broke the source string. Unpainted. A continuation line is the INDENT alone.
    def note_line(paragraph)
      lines = paragraph.to_s.split("\n")
      out = []
      lines.each do |raw|
        wrapped = TextWrap.words(raw, note_width)
        wrapped = [""] if wrapped.empty?
        wrapped.each { |seg| out << (seg.empty? ? INDENT : INDENT + seg) }
      end
      out.join("\n")
    end

    # Layout a structured list/table. Unpainted. A kind reads its item fields BY NAME; the
    # columns array is checked only to confirm it NAMES those fields, never read by position.
    # Names are matched by #to_sym so a JSON round-trip and an in-memory payload read the same
    # item. A kind or columns that break the contract render a diagnostic, never a garbled row.
    def list_line(payload)
      data    = payload.is_a?(Hash) ? payload : {}
      kind    = (data[:kind] || :bullet).to_sym
      columns = Array(data[:columns])
      required = LIST_KIND_FIELDS[kind]
      if required.nil?
        kinds = LIST_KIND_FIELDS.keys.join(", ")
        return list_error("list-kind:#{kind}", "known kinds: #{kinds}")
      end

      missing = required - columns.map(&:to_sym)
      unless missing.empty?
        names = required.join(", ")
        return list_error("list-fields:#{kind}", "columns must name #{names}")
      end

      lines = []
      lines << data[:title].to_s unless data[:title].nil?
      items = Array(data[:items])
      case kind
      when :table
        lines.concat(table_lines(columns.map(&:to_sym), items))
      else
        items.each { |item| lines << row_for(kind, item) }
      end
      lines << "" if data[:gap]
      Array(data[:footer]).each { |f| lines << footer_line(f) }
      lines.join("\n")
    end

    # A :table: state the fields as a markdown table and let kramdown lay it out (its sizing
    # and word-wrap, not re-invented here). With no palette there is no kramdown, so the raw
    # markdown is the fallback (it is itself a readable, re-lay-out-able table).
    def table_lines(columns, items)
      markdown = markdown_table(columns, items)
      return [markdown] if kramdown.nil?

      kramdown.render(markdown).split("\n")
    end

    # A store body: the content is RAW markdown and the render IS the line, and kramdown is
    # used whatever the opt-in flag says (a stored file renders whenever a palette exists). The
    # gem closes its last block with a blank line, so trim to the single newline the sink writes.
    def body_line(content)
      rendered = kramdown&.render(content)
      return content if rendered.nil?

      rendered.sub(/\n+\z/, "")
    end

    # A multi-paragraph cell expands to simulated rows (see #table_rows); every cell is
    # pipe-neutralised (see #escape_cell).
    def markdown_table(columns, items)
      headers = columns.map { |c| escape_cell(c.to_s) }
      rule    = headers.map { |h| "-" * h.length }
      rows    = table_rows(columns, items)
      ([headers, rule] + rows).map { |row| "| #{row.join(" | ")} |" }.join("\n")
    end

    # Expand each item into 1..N rows: a multi-paragraph cell becomes one row per paragraph
    # (kramdown-ansi cannot stack paragraphs in one cell). A column out of paragraphs gives a
    # blank cell on continuation rows (so the name shows only on the first row). A
    # single-paragraph item is one row - a plain table like /sessions is unchanged.
    def table_rows(columns, items)
      items.flat_map do |item|
        paras = columns.map { |c| cell_paragraphs(item[c]) }
        count = [paras.map(&:size).max, 1].max
        (0...count).map do |k|
          columns.each_index.map { |i| escape_cell(paras[i][k].to_s) }
        end
      end
    end

    # Split a cell into paragraphs on blank lines; each paragraph's soft line breaks collapse
    # to spaces. nil/blank -> one empty paragraph.
    def cell_paragraphs(value)
      text = value.to_s
      return [""] if text.strip.empty?

      text.split(/\n[ \t]*\n/).map do |para|
        para.split("\n").map(&:strip).reject(&:empty?).join(" ")
      end
    end

    # A single-paragraph cell: a pipe is neutralised so it cannot be read as a column boundary.
    def escape_cell(paragraph)
      paragraph.gsub("|", "\\|")
    end

    # The kramdown instance to render with. A :table renders as a table in any colored terminal
    # regardless of the opt-in flag, and so does a :body; both need a palette (no palette means
    # no kramdown, and both fall back to raw markdown / the text as stored).
    def kramdown
      return @markdown if @markdown
      return nil unless @palette

      @kramdown ||=
        MarkdownRenderer.new(palette: @palette, max_width: @markdown_max_width)
    end

    # A row built from NAMED fields the item hash carries; the columns array's order never
    # decides what a field is.
    def row_for(kind, item)
      row = item.is_a?(Hash) ? item : {}
      case kind
      when :kv
        name = row[:name].to_s
        desc = row[:description].to_s
        "#{INDENT}#{name} - #{desc}#{row[:annotation]}"
      else
        "#{INDENT}- #{row[:value]}"
      end
    end

    # A :list payload the layout cannot draw: name the kind and what was wrong, so a broken
    # payload is loud instead of a garbled row.
    def list_error(tag, detail)
      "#{INDENT}[#{tag}] #{detail}"
    end

    # A footer line. Its indent is a LEVEL in the data, not baked leading spaces: the renderer
    # turns the level into columns (INDENT * level) for the terminal, and a remote sink maps the
    # same level to CSS margin. Baked spaces mean nothing in a variable-width font.
    def footer_line(entry)
      text   = entry.is_a?(Hash) ? entry[:text].to_s : entry.to_s
      indent = entry.is_a?(Hash) ? entry[:indent].to_i : 0
      "#{INDENT * indent}#{text}"
    end

    # A multi-line message renders as several lines with a gutter and a closing rule, so its
    # END is visible instead of blurring into the next entry.
    def status_line(type, message, origin)
      glyph = STATUS_GLYPHS[type]
      head  = "#{INDENT}[#{origin.nil? ? "tool" : origin}]"
      lines = message.split("\n")
      lines = [""] if lines.empty?

      out = lines.each_with_index.map do |line, index|
        tail = +""
        tail << " #{glyph}" if index.zero? && glyph
        tail << " #{line}" unless line.empty?
        segment(:marker, index.zero? ? head : GUTTER) + segment(type, tail)
      end
      out << segment(:rule, STATUS_RULE) if lines.size > 1
      out.join("\n")
    end

    # A full-width fused rule naming the role, then the content EXACTLY as emitted (no label,
    # no indent: a model answer keeps its own paragraphs). :step_label IS its rule - its content
    # is the number fused inside it.
    # :step_label content is the step DATA: a bare number, or a {number:, calls:} hash whose
    # calls count is fused as a compact "[N]" so the rule says how many tool calls the step ran.
    def boundary_line(type, content)
      label =
        if type == :step_label
          data   = content.is_a?(Hash) ? content : { number: content }
          number = data[:number]
          calls  = data[:calls]
          calls.nil? ? "step #{number}" : "step #{number} [#{calls}]"
        else
          self.class.boundary_label(type)
        end
      rule  = fused_rule(label, type)
      return rule if type == :step_label || content.empty?

      "#{rule}\n#{boundary_body(type, content)}"
    end

    # An opted-in :response is rendered as markdown; every other boundary and a markdown-off
    # :response stay exactly as emitted.
    def boundary_body(type, content)
      return @markdown.render(content) if type == :response && @markdown

      paint(type, content)
    end

    # The spare is split in two; an odd one (a wider label) gives its extra dash to the right,
    # so the line is always exactly RULE_WIDTH wide.
    def fused_rule(label, type)
      spare = [RULE_WIDTH - label.length - 2, 2].max
      left  = spare / 2
      segment(:rule, "#{"-" * left} ") + segment(type, label) +
        segment(:rule, " #{"-" * (spare - left)}")
    end

    def labeled(type, content)
      return content if VERBATIM.include?(type)

      label = LABELS[type]
      # A type in neither list is a MISSING type: render it, but say so loudly, so a new
      # output kind cannot pass unnoticed.
      return "#{content} [untyped:#{type}]" if label.nil?

      "#{label}#{content}"
    end

    def markdown_role?(type)
      @markdown && MARKDOWN_ROLES.include?(type)
    end

    # A labeled model-prose line (plan / say) whose markdown renders multi-line: the label keeps
    # its role color on the FIRST line, continuations pad to align under the label text. Only
    # the label is painted here - the body carries the gem's own colors.
    def labeled_markdown_line(type, content)
      label = LABELS[type]
      return paint(type, label) if content.empty?

      lines = @markdown.render(content).split("\n")
      pad   = " " * label.length
      out   = [segment(type, label) + lines.first.to_s]
      lines[1..].each { |cont| out << (cont.empty? ? "" : pad + cont) }
      out.join("\n")
    end

    # A labeled prose line (plan / say) with markdown OFF: wrap to RULE_WIDTH minus the label and
    # align continuations under the label. TextWrap.line keeps a fitting line verbatim, so a short
    # plan stays byte-identical; the buffer still holds the raw content.
    def wrapped_labeled_line(type, content)
      label = LABELS[type]
      return paint(type, label) if content.empty?

      width = RULE_WIDTH - label.length
      segs  = content.split("\n").flat_map { |para| TextWrap.line(para, width) }
      segs = [""] if segs.empty?
      pad  = " " * label.length
      out  = [paint(type, label + segs.first.to_s)]
      segs[1..].each { |seg| out << (pad + paint(type, seg)) }
      out.join("\n")
    end

    def paint(type, text)
      palette.nil? ? text : palette.paint(type, text)
    end

    # One colored RUN, not the whole line: marker and message are different roles. Palette#paint
    # resets every run, so no run bleeds into the next.
    def segment(role, text)
      return "" if text.empty?
      return text if palette.nil?

      palette.paint(role, text)
    end
  end
end
