# frozen_string_literal: true

require_relative "palette"
require_relative "markdown_renderer"
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

    # The verdict IS the type; the bracket label travels in the event's origin,
    # never in the content. status_info has no glyph: a count or a progress
    # line is not a verdict about an operation.
    STATUS_GLYPHS = {
      status_ok: "✓",
      status_fail: "✗",
      status_warn: "⚠",
      status_note: "!",
      status_same: "=",
      status_info: nil
    }.freeze
    STATUS_TYPES = STATUS_GLYPHS.keys.freeze

    # The bracketed one-word badge a command prints as its ack (/yolo ->
    # [YOLO ON], /markdown -> [markdown: ON], /stream -> [BUFFERED]). The
    # bracket shape is the RENDERER's, not baked into the emitted string
    # (#146). Deliberately UNPAINTED: these acks are printed with the
    # terminal's own color today, so coloring them would change terminal
    # bytes - the role exists to move the shape out of the emitter, and a
    # front-end adds its own styling (the palette entry stays nil).
    # :kind is the same bracket shape with a message after it ([LLM error] msg,
    # [palette: default] (unchanged)) - the bracket names a KIND, not a verdict.
    ACK = :ack
    KIND = :kind
    ACK_TYPES = [ACK, KIND].freeze

    # A paragraph of harness EXPLANATORY PROSE (a command report's body). The
    # emitter states ONE unwrapped paragraph with no leading indent; the renderer
    # owns the indent AND the wrap (#470 - #466's theme from the other side: the
    # line-break was the emitter's, baked into source \ continuations, so it read
    # ragged and a remote client could not re-lay it out). UNPAINTED: only the
    # wrap/indent move, no color changes. The wrap width is a FIXED column
    # count, not the terminal width - a paragraph that re-wraps on every resize
    # is as unlocatable as a boundary that moves (see RULE_WIDTH). The raw
    # paragraph is what lands in the OutputBuffer, so a browser re-wraps it in CSS.
    NOTE = :note

    # The emitter still owns these lines' shape. :spinner_detail is listed
    # because the drain loop animates it - it must never produce a line.
    VERBATIM = %i[system text stats compact spinner_detail].freeze

    INDENT      = "  "
    GUTTER      = "#{INDENT}|"
    STATUS_RULE = "#{INDENT}#{"-" * 12}"
    # Fixed width, NOT the terminal width: a boundary that depends on a
    # terminal setting is a boundary that moves.
    RULE_WIDTH = 80
    # :note content columns: RULE_WIDTH minus the indent. One fixed value so a
    # rendered paragraph is identical from a 60-col or a 176-col terminal.
    NOTE_WIDTH = RULE_WIDTH - INDENT.length

    # A structured list/table report (issue #474). The emitter states the DATA
    # - a title, a kind, a columns list and per-item field values - never a
    # fused row string, so a remote sink can lay out a real list/table from the
    # fields instead of regexing the separators back out (#146's machinery).
    # The renderer owns the layout and reproduces today's terminal bytes for the
    # converted reports byte-for-byte. UNPAINTED like :note. Payload is a Hash
    # { title:, kind:, columns:, items:, footer:, gap: }. Footer lines carry an
    # INDENT LEVEL, never baked leading spaces (see #footer_line). A row is built
    # from NAMED item fields (see LIST_KIND_FIELDS), never by reading the columns
    # array by position, so a payload that lists its columns in another order
    # renders the same row.
    LIST = :list

    # The item fields each :list kind's terminal row reads, BY NAME. The order is
    # the row template's own, not the columns array's, so a reordered columns
    # list cannot scramble a row. :arrow also renders an optional trailing
    # annotation (:note) and :kv / :numbered_kv render one (:annotation) straight
    # from their template. An unknown kind, or columns that do not name a kind's
    # required fields, is a loud diagnostic - never a garbled or field-dropping
    # row (#146).
    LIST_KIND_FIELDS = {
      bullet: %i[value],
      arrow: %i[name model location],
      kv: %i[name description],
      # A numbered kv row (  N. name - description[annotation]): the ordinal is a
      # named :number field, not the array position, so the columns order cannot
      # scramble it. The renderer right-aligns every ordinal to the width of the
      # largest in the list - the alignment is the renderer's, not baked.
      numbered_kv: %i[number name description],
      # :table needs no fixed field list: the payload's columns array IS the
      # schema (each column a named field). #table_lines builds a markdown table
      # from the fields and hands it to the kramdown renderer. See #table_lines.
      table: []
    }.freeze

    # The start of an iteration and the start of the final answer are the two
    # BLOCK boundaries, and both get the same fused rule. plan / say / tools /
    # warn / error stay plain labels: they are lines INSIDE a block.
    BOUNDARY_ROLES = %i[step_label response].freeze

    # The labeled roles whose content is MODEL PROSE that may carry markdown
    # (issue #106): the plan line and the say line. :tool_plan is a comma-joined
    # tool list (not prose) and warn / error are harness messages - both stay plain.
    MARKDOWN_ROLES = %i[plan interstitial].freeze

    # The word a boundary rule fuses: the role's label without its ":  " padding
    # ("model") - a rule reads like a short word, not like a label.
    def self.boundary_label(type)
      LABELS.fetch(type.to_sym).sub(/:\s+\z/, "")
    end

    # The palette a line written TO A GIVEN SINK should render with (#466,
    # issue #388 direction): the sink that receives the line owns its color.
    # A sink that cannot answer a palette AT ALL (a browser console seam, which
    # deliberately has no #palette method) paints NOTHING: handing it a terminal
    # palette would bake SGR it has no terminal to interpret, so the escape
    # bytes show up as literal "[38;5;240m" text in the browser. A palette-AWARE
    # sink (a UI::Console) keeps the run's colors: its own palette wins (the CLI
    # wires the live harness palette into it, cli.rb), and when it answers nil
    # the harness palette applies - that is how a terminal built before a
    # Harness exists still honors a mid-session /palette switch. Terminal output
    # stays byte-identical (the CLI console's palette IS the harness palette)
    # and "paint nothing" is the automatic behavior of a non-paintable sink.
    def self.palette_for(ui:, harness: nil)
      return nil unless ui.respond_to?(:palette)

      ui.palette || (harness.respond_to?(:output_palette) ? harness.output_palette : nil)
    end

    attr_reader :palette

    # palette: a UI::Palette, or nil to render without color (a Task with no
    # harness: specs, a bare console).
    # markdown: render an assistant :response as markdown (issue #106). Default
    # false keeps every existing line byte-for-byte; only an opted-in run renders
    # :response and the MARKDOWN_ROLES prose lines. markdown_max_width is the
    # table-width basis (nil = 80% of the terminal); the boundary chrome stays at
    # the fixed RULE_WIDTH whatever this says.
    def initialize(palette: nil, markdown: false, markdown_max_width: nil)
      @palette  = palette
      @markdown = markdown ?
        MarkdownRenderer.new(palette:, max_width: markdown_max_width) : nil
      # A :table (sessions / mcp / tools) sizes from this same basis even when
      # markdown opt-in is off, so a configured width constrains the table too.
      @markdown_max_width = markdown_max_width
    end

    # origin: for a status type, the bracket label ("file.read", "access",
    # "run.command"). Ignored by every other type.
    def line(type:, content:, origin: nil)
      type = type.to_sym
      text = content.to_s

      return list_line(content) if type == LIST

      return status_line(type, text, origin) if STATUS_GLYPHS.key?(type)
      return ack_line(type, text, origin) if ACK_TYPES.include?(type)
      return boundary_line(type, text) if BOUNDARY_ROLES.include?(type)
      return note_line(text) if type == NOTE
      return labeled_markdown_line(type, text) if markdown_role?(type)
      return wrapped_labeled_line(type, text) if MARKDOWN_ROLES.include?(type)

      paint(type, labeled(type, text))
    end

    def labeled?(type)
      type = type.to_sym
      return true if STATUS_GLYPHS.key?(type)
      return true if ACK_TYPES.include?(type)
      return true if type == NOTE
      return true if type == LIST

      !VERBATIM.include?(type) && LABELS.key?(type)
    end

    private

    # A bracketed ack: the content IS the badge word, the renderer wraps it.
    # [YOLO ON] / [markdown: ON] / [BUFFERED]. Unpainted (see ACK_TYPES).
    def ack_line(type, badge, origin)
      return "#{INDENT}[#{badge}]" if type == ACK

      # :kind - the bracket names a KIND (origin), the message follows it.
      # [LLM error] message / [palette: default] (unchanged). Unpainted.
      "#{INDENT}[#{origin || badge}] #{badge}"
    end

    # A paragraph of harness prose: indent every wrapped line and re-wrap the
    # text to the fixed NOTE_WIDTH, so the paragraph is a function of the
    # renderer, not of where the emitter happened to break the source string
    # (#470). Unpainted - only the wrap/indent move. A continuation line is the
    # INDENT alone (a paragraph line, not a status gutter).
    def note_line(paragraph)
      lines = paragraph.to_s.split("\n")
      out = []
      lines.each do |raw|
        wrapped = TextWrap.words(raw, NOTE_WIDTH)
        wrapped = [""] if wrapped.empty?
        wrapped.each { |seg| out << (seg.empty? ? INDENT : INDENT + seg) }
      end
      out.join("\n")
    end

    # Layout a structured list/table (#474). Unpainted (see LIST). A kind reads its
    # item fields BY NAME (LIST_KIND_FIELDS); the columns array is checked only to
    # confirm it NAMES those fields, never read by position. Names are matched by
    # #to_sym so a JSON round-trip (string keys re-symbolized by read_session) and
    # an in-memory payload read the same item. A kind, or columns, that break the
    # contract render a diagnostic - never a garbled row.
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
      # The numbered kind right-aligns every ordinal to the width of the largest
      # one in the list, so a 10-item list keeps the rows aligned past 9.
      number_width = kind == :numbered_kv ?
        items.map { |i| (i.is_a?(Hash) ? i[:number].to_s : "").length }.max.to_i : nil
      case kind
      when :table
        lines.concat(table_lines(columns.map(&:to_sym), items))
      else
        items.each { |item| lines << row_for(kind, item, number_width:) }
      end
      lines << "" if data[:gap]
      Array(data[:footer]).each { |f| lines << footer_line(f) }
      lines.join("\n")
    end

    # A :table: state the fields as a markdown table and let kramdown lay it out -
    # the sizing and word-wrap are the gem's (#106), not re-invented here. With no
    # palette there is no kramdown, so the raw markdown is the fallback (it is
    # itself a readable, re-lay-out-able table).
    def table_lines(columns, items)
      markdown = markdown_table(columns, items)
      return [markdown] if table_renderer.nil?

      table_renderer.render(markdown).split("\n")
    end

    # A multi-paragraph cell expands to simulated rows (see #table_rows); every
    # cell is pipe-neutralised (see #escape_cell).
    def markdown_table(columns, items)
      headers = columns.map { |c| escape_cell(c.to_s) }
      rule    = headers.map { |h| "-" * h.length }
      rows    = table_rows(columns, items)
      ([headers, rule] + rows).map { |row| "| #{row.join(" | ")} |" }.join("\n")
    end

    # Expand each item into 1..N rows: a multi-paragraph cell becomes one row per
    # paragraph, because kramdown-ansi cannot stack paragraphs inside a single
    # cell. A column that runs out of paragraphs contributes a blank cell on the
    # continuation rows (so the tool name shows only on the item's first row). A
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

    # Split a cell into paragraphs on blank lines; each paragraph's soft line
    # breaks collapse to spaces. nil/blank -> one empty paragraph.
    def cell_paragraphs(value)
      text = value.to_s
      return [""] if text.strip.empty?

      text.split(/\n[ \t]*\n/).map do |para|
        para.split("\n").map(&:strip).reject(&:empty?).join(" ")
      end
    end

    # A single-paragraph cell: a pipe is neutralised so it cannot be read as a
    # column boundary (no newlines remain after #cell_paragraphs).
    def escape_cell(paragraph)
      paragraph.gsub("|", "\\|")
    end

    # :table renders as a table in any colored terminal regardless of the opt-in
    # markdown flag; it only needs a palette (no palette means no kramdown).
    def table_renderer
      return @markdown if @markdown
      return nil unless @palette

      @table_renderer ||=
        MarkdownRenderer.new(palette: @palette, max_width: @markdown_max_width)
    end

    # A row built from NAMED fields the item hash carries; the columns array's
    # order never decides what a field is. :arrow appends an optional :note.
    def row_for(kind, item, number_width: nil)
      row = item.is_a?(Hash) ? item : {}
      case kind
      when :arrow
        name = row[:name].to_s
        tgt  = row[:model].to_s
        loc  = row[:location].to_s
        note = row[:note].to_s
        "#{INDENT}#{name}  ->  #{tgt} @ #{loc}#{note}"
      when :kv
        name = row[:name].to_s
        desc = row[:description].to_s
        "#{INDENT}#{name} - #{desc}#{row[:annotation]}"
      when :numbered_kv
        num  = row[:number].to_s.rjust(number_width.to_i)
        name = row[:name].to_s
        desc = row[:description].to_s
        "#{INDENT}#{num}. #{name} - #{desc}#{row[:annotation]}"
      else
        "#{INDENT}- #{row[:value]}"
      end
    end

    # A :list payload the layout cannot draw: name the kind and what was wrong,
    # so a broken payload is loud instead of a garbled row (#146).
    def list_error(tag, detail)
      "#{INDENT}[#{tag}] #{detail}"
    end

    # A footer line. Its indent is a LEVEL in the data, not baked leading
    # spaces: the renderer turns the level into columns (INDENT * level) for the
    # terminal, and a remote sink maps the same level to CSS margin. Baked
    # spaces mean nothing in a variable-width font, so the level is the only
    # robust form (#474). A footer entry is a String (indent 0, verbatim) or a
    # Hash { text:, indent: }.
    def footer_line(entry)
      text   = entry.is_a?(Hash) ? entry[:text].to_s : entry.to_s
      indent = entry.is_a?(Hash) ? entry[:indent].to_i : 0
      "#{INDENT * indent}#{text}"
    end

    # A multi-line message (a pasted multiline script is the everyday case)
    # renders as several lines with a gutter and a closing rule, so its END is
    # visible instead of blurring into the next entry.
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

    # A full-width fused rule naming the role, then the content EXACTLY as
    # emitted (no label, no indent: a model answer keeps its own paragraphs).
    # :step_label IS its rule - its content is the number fused inside it.
    def boundary_line(type, content)
      label = type == :step_label ? "step #{content}" : self.class.boundary_label(type)
      rule  = fused_rule(label, type)
      return rule if type == :step_label || content.empty?

      "#{rule}\n#{boundary_body(type, content)}"
    end

    # An opted-in :response is rendered as markdown (issue #106); every other
    # boundary and a markdown-off :response stay exactly as emitted.
    def boundary_body(type, content)
      return @markdown.render(content) if type == :response && @markdown

      paint(type, content)
    end

    # The spare is split in two; an odd one (a wider label) gives its extra dash
    # to the right, so the line is always exactly RULE_WIDTH wide.
    def fused_rule(label, type)
      spare = [RULE_WIDTH - label.length - 2, 2].max
      left  = spare / 2
      segment(:rule, "#{"-" * left} ") + segment(type, label) +
        segment(:rule, " #{"-" * (spare - left)}")
    end

    def labeled(type, content)
      return content if VERBATIM.include?(type)

      label = LABELS[type]
      # An entry whose type is in neither list is a MISSING type: render it,
      # but say so loudly, so a new output kind cannot pass unnoticed (#146).
      return "#{content} [untyped:#{type}]" if label.nil?

      "#{label}#{content}"
    end

    def markdown_role?(type)
      @markdown && MARKDOWN_ROLES.include?(type)
    end

    # A labeled model-prose line (plan / say) whose markdown renders multi-line:
    # the label keeps its role color on the FIRST line, and every continuation
    # line is padded to align under the label text, so the block still reads as
    # one labeled entry. The body carries the gem's own (palette-seeded) colors;
    # only the label is painted here.
    def labeled_markdown_line(type, content)
      label = LABELS[type]
      return paint(type, label) if content.empty?

      lines = @markdown.render(content).split("\n")
      pad   = " " * label.length
      out   = [segment(type, label) + lines.first.to_s]
      lines[1..].each { |cont| out << (cont.empty? ? "" : pad + cont) }
      out.join("\n")
    end

    # A labeled prose line (plan / say) with markdown OFF: wrap to the fixed
    # RULE_WIDTH minus the label and align continuations under the label
    # (#485 - a single-liner plan spilled past the terminal as one long line).
    # TextWrap.line keeps a fitting line verbatim, so a short plan stays
    # byte-identical; the buffer still holds the raw content (a browser re-wraps).
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

    # One colored RUN, not the whole line: marker and message are different
    # roles. Palette#paint resets every run, so no run bleeds into the next.
    def segment(role, text)
      return "" if text.empty?
      return text if palette.nil?

      palette.paint(role, text)
    end
  end
end
