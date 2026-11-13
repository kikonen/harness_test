# frozen_string_literal: true

require 'spec_helper'
require 'ui/renderer'

RSpec.describe UI::Renderer do
  subject(:renderer) { described_class.new }

  # Display width of a rendered line, ignoring the ANSI runs the palette adds.
  def strip_ansi(line)
    line.gsub(/\e\[[0-9;]*m/, '')
  end

  # The sink-owns-color rule (#466): who a line paints with depends on the SINK,
  # not on the caller. A colored UI::Palette is the stand-in for "the terminal's
  # colors"; "paints nothing" is proven by the returned palette being nil.
  describe '.palette_for (the sink owns the color, issue #466)' do
    let(:colored) { UI::Palette.fetch('default') }
    # A palette-AWARE sink (a UI::Console): answers #palette (nil when it has none).
    def console_sink(palette) = Object.new.tap { |o| o.define_singleton_method(:palette) { palette } }
    # A non-paintable sink (a browser console seam): NO #palette method at all.
    def plain_sink = Object.new
    def harness(palette) = Object.new.tap { |o| o.define_singleton_method(:output_palette) { palette } }

    it 'a non-paintable sink paints NOTHING even when the harness is colored' do
      # The whole point: a browser sink borrows no terminal palette, so its
      # lines never carry SGR the browser would show as literal text.
      expect(described_class.palette_for(ui: plain_sink, harness: harness(colored))).to be_nil
    end

    it 'a non-paintable sink paints nothing with no harness either' do
      expect(described_class.palette_for(ui: plain_sink, harness: nil)).to be_nil
    end

    it 'a palette-aware sink with its own palette wins over the harness' do
      expect(described_class.palette_for(ui: console_sink(colored),
                                         harness: harness(nil))).to equal(colored)
    end

    it 'a palette-aware sink with no palette falls back to the harness (terminal keeps colors)' do
      expect(described_class.palette_for(ui: console_sink(nil),
                                         harness: harness(colored))).to equal(colored)
    end
  end

  describe '#line (labeled roles)' do
    it 'labels a role with its pattern' do
      expect(renderer.line(type: :plan, content: 'read the tool first')).to eq(
        'plan:  read the tool first'
      )
      expect(renderer.line(type: :interstitial, content: 'checking one more site')).to eq(
        'say:   checking one more site'
      )
      expect(renderer.line(type: :tool_plan, content: 'file.read, file.search')).to eq(
        'tools: file.read, file.search'
      )
    end

    it 'labels the two alert roles' do
      expect(renderer.line(type: :error, content: 'auto-save failed')).to eq(
        'error: auto-save failed'
      )
      expect(renderer.line(type: :warn, content: 'compact skipped')).to eq(
        'warn:  compact skipped'
      )
    end

    it 'renders verbatim types exactly as the emitter wrote them' do
      expect(renderer.line(type: :text, content: 'plain command output')).to eq('plain command output')
      expect(renderer.line(type: :stats, content: '  [3 iterations]')).to eq('  [3 iterations]')
      expect(renderer.line(type: :compact, content: '  [compacting...]')).to eq('  [compacting...]')
      expect(renderer.line(type: :system, content: '  [rules reloaded]')).to eq('  [rules reloaded]')
    end

    it 'renders a rule line verbatim and colors it with the palette rule role' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))

      expect(painted.line(type: :rule, content: 'a rule the emitter drew')).to eq(
        "\e[38;5;240ma rule the emitter drew\e[0m"
      )
    end

    it 'announces an unknown type loudly instead of hiding it (issue #146)' do
      expect(renderer.line(type: :brand_new_kind, content: 'text')).to eq('text [untyped:brand_new_kind]')
    end

    it 'accepts a string type (the outbox carries symbols, the buffer is public)' do
      expect(renderer.line(type: 'plan', content: 'x')).to eq('plan:  x')
    end

    it 'never carries the old markers (issue #146)' do
      types = described_class::LABELS.keys + described_class::VERBATIM + described_class::STATUS_TYPES
      lines = types.map { |t| renderer.line(type: t, content: 'body', origin: 'tool') }

      expect(lines).not_to include(a_string_matching(/>>>/))
      expect(lines).not_to include(a_string_matching(/\|\|\|/))
    end
  end

  describe '#line (:step_label) - the iteration boundary' do
    it 'fuses short rules with the number so the step start is visible at a glance' do
      expect(renderer.line(type: :step_label, content: 8)).to eq("#{'-' * 36} step 8 #{'-' * 36}")
    end

    it 'is exactly RULE_WIDTH wide whatever the number is' do
      widths = [1, 9, 10, 99, 100].map do |n|
        renderer.line(type: :step_label, content: n).length
      end

      expect(widths).to all(eq(described_class::RULE_WIDTH))
    end

    it 'gives the odd spare dash to the right side (a wider number)' do
      expect(renderer.line(type: :step_label, content: 12)).to eq(
        "#{'-' * 35} step 12 #{'-' * 36}"
      )
    end
  end

  # The final answer gets the SAME boundary shape as an iteration start, which
  # is what makes it locatable instead of "in between" the turn's lines.
  describe '#line (:response) - the answer boundary' do
    it 'names the role in a full-width fused rule, then the answer as emitted' do
      expect(renderer.line(type: :response, content: 'done')).to eq(
        "#{'-' * 36} model #{'-' * 37}\ndone"
      )
    end

    it 'every boundary rule is exactly RULE_WIDTH wide' do
      widths = [
        renderer.line(type: :response, content: 'x'),
        renderer.line(type: :step_label, content: 1),
        renderer.line(type: :step_label, content: 1234)
      ].map { |line| line.lines.first.chomp.length }

      expect(widths).to all(eq(described_class::RULE_WIDTH))
    end

    it 'non-boundary roles keep their plain label (no rule)' do
      expect(renderer.line(type: :plan, content: 'read the tool')).to eq('plan:  read the tool')
      expect(renderer.line(type: :warn, content: 'x')).to eq('warn:  x')
      expect(renderer.line(type: :error, content: 'x')).to eq('error: x')
    end

    it 'keeps the answer text untouched (own paragraphs and indentation)' do
      answer = "first paragraph\n\n  - indented item\n  - another"
      out = renderer.line(type: :response, content: answer).lines[1..].map(&:chomp)

      expect(out).to eq(answer.split("\n"))
    end
  end

  # issue #474: a structured list/table report. The emitter states the fields
  # (title, kind, columns, items) and the renderer owns the layout, so the
  # durable record and a remote sink carry the fields, not a fused row string.
  describe '#line (:list) - structured list/table (issue #474)' do
    it 'renders a bullet list (1-field: the dash is the renderer layout, not the emitter string)' do
      payload = {
        title: 'Hosts for web.fetch:',
        kind: :bullet,
        columns: [:value],
        items: [{ value: 'api.example.com' }, { value: 'docs.example.org' }],
        footer: [{ text: 'revoke with: /clear hosts', indent: 1 }]
      }
      expect(renderer.line(type: :list, content: payload)).to eq(
        ['Hosts for web.fetch:',
         '  - api.example.com',
         '  - docs.example.org',
         '  revoke with: /clear hosts'].join("\n")
      )
    end

    it 'renders an arrow table (entity -> target @ location + note)' do
      payload = {
        title: 'Configured models (1):',
        kind: :arrow,
        columns: %i[name model location note],
        items: [{ name: 'qwen', model: 'qwen3:8b', location: 'http://x', note: ' (ollama)' }],
        footer: [],
        gap: false
      }
      expect(renderer.line(type: :list, content: payload)).to eq(
        ['Configured models (1):',
         '  qwen  ->  qwen3:8b @ http://x (ollama)'].join("\n")
      )
    end

    # The :kv kind: the flat `name - description` row the skills and memory
    # listings share. An optional :annotation rides the row verbatim (the memory
    # listing's " (N chars)" suffix is a FIELD, not a baked-in tail).
    it 'renders a kv list (name - description, flat table)' do
      payload = {
        title: 'Skills (2):',
        kind: :kv,
        columns: %i[name description],
        items: [{ name: 'changelog', description: 'Regenerate the changelog' },
                { name: 'triage', description: 'Sort issues' }],
        footer: ['Show one with: /skills <name>']
      }
      expect(renderer.line(type: :list, content: payload)).to eq(
        ['Skills (2):',
         '  changelog - Regenerate the changelog',
         '  triage - Sort issues',
         'Show one with: /skills <name>'].join("\n")
      )
    end

    it 'appends a kv row\'s optional annotation verbatim (memory size suffix)' do
      payload = {
        kind: :kv,
        columns: %i[name description annotation],
        items: [{ name: 'sized', description: '12345', annotation: ' (5 chars)' }]
      }
      expect(renderer.line(type: :list, content: payload)).to eq('  sized - 12345 (5 chars)')
    end

    # The :numbered_kv kind (the /plans listing): a named :number ordinal, the
    # size suffix as :annotation, and right-alignment to the width of the largest
    # ordinal so the block stays aligned past 9. The ordinal is a FIELD, not the
    # array position, so a reordered columns list cannot scramble it.
    it 'renders a numbered_kv list, right-aligned past 9' do
      payload = {
        kind: :numbered_kv,
        columns: %i[number name description annotation],
        items: (1..10).map { |n| { number: n, name: "plan#{n}", description: "d #{n}", annotation: '' } }
      }
      lines = renderer.line(type: :list, content: payload).lines.map(&:chomp)

      expect(lines.first).to eq('   1. plan1 - d 1')
      expect(lines.last).to eq('  10. plan10 - d 10')
    end

    it 'numbered_kv annotation is a field, not a fused tail' do
      payload = {
        kind: :numbered_kv,
        columns: %i[number name description],
        items: [{ number: 1, name: 'sized', description: '12345', annotation: ' (5 chars)' }]
      }
      expect(renderer.line(type: :list, content: payload)).to eq('  1. sized - 12345 (5 chars)')
    end

    # The :table kind: the payload's columns ARE the schema. The renderer states
    # the fields as a markdown table and hands it to the kramdown renderer
    # (#106's MarkdownRenderer), which owns the column sizing - the padding is not
    # re-invented in the harness. A cell is read BY NAME from the item. A SINK WITH
    # NO PALETTE (a plain console, a spec) gets the raw markdown: itself a
    # readable, re-lay-out-able table, the DATA form #474 keeps in the buffer.
    it 'renders a :table as a markdown table (the data form, no palette)' do
      payload = {
        title: 'Saved sessions (2):',
        kind: :table,
        columns: %i[id saved messages files workdir],
        items: [{ id: 'abc', saved: '2026-01-01 10:00:00', messages: 3, files: 2, workdir: '/work' },
                { id: 'de', saved: '2026-02-01 11:00:00', messages: 12, files: 1, workdir: '/w2' }]
      }
      expect(renderer.line(type: :list, content: payload)).to eq(
        ['Saved sessions (2):',
         '| id | saved | messages | files | workdir |',
         '| -- | ----- | -------- | ----- | ------- |',
         '| abc | 2026-01-01 10:00:00 | 3 | 2 | /work |',
         '| de | 2026-02-01 11:00:00 | 12 | 1 | /w2 |'].join("\n")
      )
    end

    # A colored sink renders the :table through kramdown: a bordered box table,
    # the layout the gem (not the harness) draws. The column widths are the gem's
    # (terminal-dependent), so the pin asserts the table's identity - borders and
    # every field value survive - not its exact column count.
    it 'renders a :table as a kramdown box table when the sink is colored' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))
      payload = {
        kind: :table,
        columns: %i[id saved workdir],
        items: [{ id: 'abc', saved: '2026-01-01 10:00:00', workdir: '/work' }]
      }
      out = painted.line(type: :list, content: payload)
      body = strip_ansi(out)

      expect(out).to include('╭') # kramdown's box border, not raw pipe markdown
      expect(body).to include('id')
      expect(body).to include('2026-01-01')
      expect(body).to include('/work')
      expect(out).not_to include('| -- |') # the raw fallback was not used
    end

    # A multi-paragraph cell is the case kramdown-ansi cannot stack inside one
    # box-table cell (it would collapse the paragraphs). The renderer expands a
    # multi-paragraph item into one row per paragraph, the item's name on its
    # first row only. A single-paragraph item (a plain table like /sessions) is
    # still one row, unchanged.
    it 'expands a multi-paragraph :table cell into one row per paragraph' do
      payload = {
        kind: :table,
        columns: %i[tool description],
        items: [
          { tool: 'blender.exec',
            description: "First paragraph here.\n\nSecond paragraph with `code` spans." },
          { tool: 'blender.run', description: 'Just one line.' }
        ]
      }
      expect(renderer.line(type: :list, content: payload)).to eq(
        ['| tool | description |',
         '| ---- | ----------- |',
         '| blender.exec | First paragraph here. |',
         '|  | Second paragraph with `code` spans. |',
         '| blender.run | Just one line. |'].join("\n")
      )
    end

    # The colored sink renders the same expansion as a box table: the name sits
    # on the item's first row, the continuation row's tool column is blank. The
    # column widths are the gem's (terminal-dependent), so the pin asserts the
    # row structure, not the exact width.
    it 'renders the multi-paragraph expansion as a box table when the sink is colored' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))
      payload = {
        kind: :table,
        columns: %i[tool description],
        items: [{ tool: 'blender.exec', description: "Para one.\n\nPara two." }]
      }
      body = strip_ansi(painted.line(type: :list, content: payload))
      rows = body.lines.map(&:chomp).reject { |l| l.match?(/─/) } # drop the box rules

      expect(body).to include('╭')
      data = rows.reject { |r| r.include?('tool') } # drop the header row too
      tool_cells = data.map { |r| r.split('│')[1].strip } # the tool column, per data row
      expect(tool_cells).to eq(['blender.exec', '']) # name on first row, blank continuation
    end

    # The :table honors the renderer's markdown_max_width basis even with markdown
    # opt-in OFF (the table renderer is built with it, so a configured width -
    # --markdown-width / 'markdown_max_width:' - actually constrains the table
    # instead of being ignored). The cells are wrappable (space-separated), so the
    # gem lays them within the basis; a wider basis uses the extra room, proving
    # the width is read and not defaulted.
    it 'sizes a :table to a configured markdown_max_width (even with markdown off)' do
      desc = "Executes a shell command in the harness working directory. Most " \
             "commands require explicit user confirmation before they run; " \
             "approved prefixes auto-approve. Long prose wraps at 120 but not 176."
      payload = { kind: :table, columns: %i[tool description],
                  items: [{ tool: 'run.command', description: desc }] }

      allow(Tins::Terminal).to receive(:columns).and_return(176)
      wide = described_class.new(palette: UI::Palette.fetch('default'))
                            .line(type: :list, content: payload)
      capped = described_class.new(palette: UI::Palette.fetch('default'),
                                   markdown_max_width: 120)
                            .line(type: :list, content: payload)

      expect(wide.lines.map { |l| strip_ansi(l).rstrip.length }.max).to be > 120
      expect(capped.lines.map { |l| strip_ansi(l).rstrip.length }.max).to be <= 120
    end

    it 'leaves the list unpainted with a palette (only the layout moves)' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))
      payload = {
        title: 'X:',
        kind: :bullet,
        columns: [:value],
        items: [{ value: 'a' }]
      }
      expect(painted.line(type: :list, content: payload)).to eq("X:\n  - a")
    end
    # The row is built from NAMED item fields (LIST_KIND_FIELDS), never by reading
    # the columns array by position. A payload that lists its columns in a
    # different ORDER renders the same row; one that omits a required field is a
    # loud diagnostic, not a field-dropping row (#146's "unknown is loud").
    it 'is a loud diagnostic for an unknown kind (never silently bullet-shaped)' do
      out = renderer.line(type: :list, content: { kind: :grid, columns: %i[a b], items: [] })

      known = described_class::LIST_KIND_FIELDS.keys.join(", ")
      expect(out).to eq("  [list-kind:grid] known kinds: #{known}")
    end

    it 'is a loud diagnostic when the columns do not name a kind\'s required fields' do
      # :arrow reads name/model/location; omitting location would drop a field.
      out = renderer.line(type: :list, content: { kind: :arrow, columns: %i[name model], items: [] })

      expect(out).to eq('  [list-fields:arrow] columns must name name, model, location')
    end

    it 'renders the same row whatever order the columns array lists (no positional read)' do
      payload = { kind: :arrow, columns: %i[location name note model],
                  items: [{ name: 'a', model: 'b', location: 'c', note: ' (x)' }] }

      expect(renderer.line(type: :list, content: payload)).to eq('  a  ->  b @ c (x)')
    end

    # The footer's indent is a LEVEL in the data, not baked leading spaces - the
    # renderer turns the level into columns so a variable-width sink (a browser)
    # can map the same level to CSS margin. A plain String is indent 0 verbatim.
    it 'indents a footer line from its LEVEL, not baked spaces' do
      payload = {
        kind: :bullet,
        columns: [:value],
        items: [{ value: 'a' }],
        footer: [
          { text: 'top level', indent: 0 },
          { text: 'revoke with: /clear hosts', indent: 1 },
          { text: 'plain string footer' }
        ]
      }
      expect(renderer.line(type: :list, content: payload)).to eq(
        ['  - a', 'top level', '  revoke with: /clear hosts', 'plain string footer'].join("\n")
      )
    end

  end

  # issue #106: an opted-in :response is rendered as markdown; the default (off)
  # keeps every answer byte-for-byte as emitted.
  describe '#line (:response) markdown rendering (issue #106)' do
    let(:answer) { "# Title\n\nSome **bold** text." }

    it 'renders the answer as markdown when markdown is on' do
      md = described_class.new(palette: UI::Palette.fetch('default'), markdown: true)
      out = md.line(type: :response, content: answer)

      # The fused rule stays; the body is now ANSI-styled markdown.
      expect(out.lines.first.chomp).to include('model')
      expect(out).to include("\e[1mbold\e[0m")
      expect(out).not_to include('**bold**')
    end

    it 'leaves the answer verbatim when markdown is off (the default)' do
      plain = described_class.new(palette: UI::Palette.fetch('default'))
      out = plain.line(type: :response, content: answer)

      expect(out).to include("**bold**")
      expect(out).not_to include("\e[1mbold")
    end
  end

  # The table-width basis (issue #106) is a CONTENT knob: the boundary chrome
  # stays the fixed RULE_WIDTH whatever it says.
  describe 'markdown_max_width does not move the boundary chrome (issue #106)' do
    it 'keeps the model rule exactly RULE_WIDTH with a wide table basis set' do
      md = described_class.new(palette: UI::Palette.fetch('default'),
                               markdown: true, markdown_max_width: 160)
      rule = md.line(type: :response, content: "a | b\n| - | -\n| 1 | 2").lines.first.chomp

      expect(strip_ansi(rule).length).to eq(described_class::RULE_WIDTH)
    end
  end

  # issue #106: the labeled model-prose lines (plan / say) render as markdown too,
  # with the label on the first line and continuation lines aligned under it.
  describe '#line (MARKDOWN_ROLES) markdown rendering (issue #106)' do
    let(:md) { described_class.new(palette: UI::Palette.fetch('default'), markdown: true) }
    let(:plain) { described_class.new(palette: UI::Palette.fetch('default')) }

    it 'renders a plan line with emphasis when markdown is on' do
      out = md.line(type: :plan, content: 'read then **patch** the file')

      expect(out).to include('plan:  ')
      expect(out).to include("\e[1mpatch\e[0m")
      expect(out).not_to include('**patch**')
    end

    it 'aligns a multi-line plan block under the label' do
      out = md.line(type: :plan, content: "first line\n\n- item one\n- item two")
      lines = out.lines.map(&:chomp)

      expect(lines.first).to include('plan:  ')
      # Continuation lines carry the label-width pad (no ANSI in the pad).
      expect(lines.last).to start_with(' ' * 'plan:  '.length)
    end

    it 'leaves a plan line verbatim when markdown is off (the default)' do
      out = plain.line(type: :plan, content: 'read then **patch** the file')

      expect(out).to eq("\e[34mplan:  read then **patch** the file\e[0m")
    end

    it 'keeps :tool_plan verbatim even when markdown is on (a tool list, not prose)' do
      out = md.line(type: :tool_plan, content: 'file.read, file.search')

      expect(out).to eq("\e[32mtools: file.read, file.search\e[0m")
    end
  end

  describe '#line (status types) - bracket, glyph and gutter' do
    it 'builds the bracket from the ORIGIN and the glyph from the TYPE' do
      expect(renderer.line(type: :status_ok, origin: 'file.read', content: 'lib/foo.rb')).to eq(
        '  [file.read] ✓ lib/foo.rb'
      )
    end

    it 'colors nothing without a palette but still shapes every verdict' do
      rendered = described_class::STATUS_GLYPHS.map do |type, _glyph|
        renderer.line(type: type, origin: 'file.write', content: 'x')
      end

      expect(rendered).to eq(
        ['  [file.write] ✓ x',
         '  [file.write] ✗ x',
         '  [file.write] ⚠ x',
         '  [file.write] ! x',
         '  [file.write] = x',
         '  [file.write] x']
      )
    end

    it 'renders a verdict with no message as a bare bracket' do
      expect(renderer.line(type: :status_fail, origin: 'access', content: '')).to eq('  [access] ✗')
    end

    it 'a multi-line message gets a gutter on every continuation line' do
      out = renderer.line(type: :status_ok, origin: 'run.command',
                          content: "cd app && ruby -e '\nputs 1\n'\n")

      expect(out.lines.map(&:chomp)).to eq(
        ["  [run.command] ✓ cd app && ruby -e '",
         '  | puts 1',
         "  | '",
         '  ' + ('-' * 12)]
      )
    end

    it 'closes a multi-line entry with a short rule so its end is visible' do
      out = renderer.line(type: :status_info, origin: 'git.diff', content: "a\nb").lines.last.chomp

      expect(out).to eq('  ' + ('-' * 12))
    end

    it 'a single-line entry gets NO gutter and NO rule' do
      out = renderer.line(type: :status_ok, origin: 'file.read', content: 'a').lines

      expect(out.size).to eq(1)
      expect(out.first).not_to include('|')
      expect(out.first).not_to include('--')
    end
  end

  # The bracketed ack and kind roles: the RENDERER owns the [ ... ] shape so
  # the emitter stops baking it into the string (#146). Unpainted - the badge
  # and the kind keep the terminal's own color (see ACK_TYPES in the renderer).
  describe '#line (:ack / :kind) - bracketed acks (issue #466)' do
    it 'wraps a badge in brackets from the content alone (:ack)' do
      expect(renderer.line(type: :ack, content: 'YOLO ON')).to eq('  [YOLO ON]')
      expect(renderer.line(type: :ack, content: 'markdown: ON')).to eq('  [markdown: ON]')
      expect(renderer.line(type: :ack, content: 'BUFFERED')).to eq('  [BUFFERED]')
    end

    it 'names a KIND in brackets and puts the message after it (:kind)' do
      expect(renderer.line(type: :kind, origin: 'LLM error', content: 'rate limited')).to eq(
        '  [LLM error] rate limited'
      )
      expect(renderer.line(type: :kind, origin: 'palette: default',
                           content: '(unchanged)')).to eq('  [palette: default] (unchanged)')
    end

    it 'falls back to the content as the bracket name when no origin is given' do
      expect(renderer.line(type: :kind, content: 'no origin')).to eq('  [no origin] no origin')
    end

    it 'leaves both roles unpainted with a palette (terminal color, not SGR)' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))

      expect(painted.line(type: :ack, content: 'YOLO ON')).to eq('  [YOLO ON]')
      expect(painted.line(type: :kind, origin: 'tool loop', content: 'x')).to eq('  [tool loop] x')
    end
  end

  # Harness explanatory prose (a command report body): the renderer re-wraps a
  # single unwrapped paragraph to a FIXED width and indents every line, so the
  # wrap is the renderer's, not baked into the emitted string (#470). Unpainted.
  describe '#line (:note) - wrapped prose paragraphs (issue #470)' do
    it 'indents a short paragraph onto one line' do
      expect(renderer.line(type: :note, content: 'Saved with the session (resume keeps it).')).to eq(
        '  Saved with the session (resume keeps it).'
      )
    end

    it 're-wraps a long paragraph and indents every continuation line' do
      out = renderer.line(type: :note,
                          content: 'Responses are buffered: the whole answer arrives before it is printed (the full retry policy applies).')
      lines = out.split("\n")

      expect(lines).to eq(
        ['  Responses are buffered: the whole answer arrives before it is printed (the',
         '  full retry policy applies).']
      )
      # No rendered line exceeds the fixed RULE_WIDTH whatever the terminal is.
      expect(lines).to all(satisfy { |l| l.length <= described_class::RULE_WIDTH })
    end

    it 'gives a word wider than the wrap its own line (never split mid-word)' do
      long = 'short wordssupercalifragilisticexpialidociousandthensome more text here'
      out = renderer.line(type: :note, content: long)
      expect(out).to eq('  ' + long)
    end

    it 'leaves the paragraph unpainted with a palette (only the wrap moves)' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))

      expect(painted.line(type: :note, content: 'Saved with the session.')).to eq('  Saved with the session.')
    end
  end

  # issue #474: a store body (plan / memory / skill) is RAW markdown. The emitter
  # states the role and the stored text; the renderer renders it, so the markers are
  # consumed by the render instead of printed - the three-copies bug the design doc
  # left for a follow-up. With no palette there is no kramdown, so the text comes
  # back as stored (a plain console, a spec double).
  describe '#line (:body) - a store body rendered from raw markdown (issue #474)' do
    it 'returns the text as stored when the sink has no palette to render with' do
      expect(renderer.line(type: :body, content: '# Title')).to eq('# Title')
    end

    it 'renders the markdown so the markers are consumed, not printed' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))
      out = painted.line(type: :body, content: '# Title' + "\n\nRun **bin/rspec** first.")

      expect(out).to include("\e[")
      expect(out).to include('Title')
      expect(out).not_to include('# Title')
      expect(out).not_to include('**bin/rspec**')
    end

    # kramdown closes its last block with a blank line; the render is trimmed to the
    # single newline the sink writes, so a body ends like the file it was read from.
    it 'trims the render to one trailing newline' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))

      expect(painted.line(type: :body, content: "step one\nstep two\n")).to eq("step one\nstep two")
    end
  end

  # issue #485: a labeled prose line (plan / say) spilled past the terminal as
  # one long unwrapped line when markdown was OFF. The default path now wraps to
  # the fixed RULE_WIDTH minus the label and aligns continuations under the
  # label (the markdown-on path already did this; the buffer still holds the raw
  # content so a browser re-wraps). A fitting line stays byte-identical.
  describe '#line (plan / say wrap when markdown is off, issue #485)' do
    it 'wraps a long plan to the fixed width, label-aligned continuation' do
      content = 'Now the bad-arg tests already assert usage. But the old def ' \
                'usage printed combined forms; the new render_inline prints them ' \
                'separately, which a spec only asserts as a substring.'
      out   = renderer.line(type: :plan, content: content)
      lines = out.lines.map(&:chomp)

      expect(lines.size).to be > 1
      expect(lines.first).to start_with('plan:  ')
      # Continuation lines carry the label-width pad (no ANSI in the pad).
      expect(lines[1]).to start_with(' ' * 'plan:  '.length)
      # No rendered line exceeds RULE_WIDTH whatever the terminal is.
      expect(lines).to all(satisfy { |l| strip_ansi(l).length <= described_class::RULE_WIDTH })
    end

    it 'wraps a long say line the same way' do
      content = 'Checking one more site before answering, because a long interim ' \
                'note also spilled as a single long line before this fix landed.'
      lines = renderer.line(type: :interstitial, content: content).lines.map(&:chomp)

      expect(lines.size).to be > 1
      expect(lines[1]).to start_with(' ' * 'say:   '.length)
      expect(lines).to all(satisfy { |l| strip_ansi(l).length <= described_class::RULE_WIDTH })
    end

    it 'leaves a plan/say line that fits on one line byte-identical' do
      expect(renderer.line(type: :plan, content: 'read the tool first')).to eq('plan:  read the tool first')
      expect(renderer.line(type: :interstitial, content: 'checking one more site')).to eq(
        'say:   checking one more site'
      )
    end

    it 'keeps coloring on every wrapped line (label run + body runs, no bleed)' do
      painted = described_class.new(palette: UI::Palette.fetch('default'))
      content = 'wrap this long plan line so it becomes two colored runs that ' \
                'each reset, proving the wrap does not drop the role color'
      out = painted.line(type: :plan, content: content)
      lines = out.lines.map(&:chomp)

      expect(lines.size).to be > 1
      expect(lines).to all(end_with("\e[0m"))
      expect(out).not_to include("\e[0m\e[0m")
    end
  end

  describe '#labeled?' do
    it 'is true for a role the renderer patterns' do
      expect(renderer.labeled?(:plan)).to eq(true)
      expect(renderer.labeled?(:response)).to eq(true)
    end

    it 'is true for the status types (the renderer owns their bracket)' do
      expect(described_class::STATUS_TYPES).to all(satisfy { |t| renderer.labeled?(t) })
    end

    it 'is true for the ack roles (the renderer owns their bracket too)' do
      expect(renderer.labeled?(:ack)).to eq(true)
      expect(renderer.labeled?(:kind)).to eq(true)
    end

    it 'is true for the note role (the renderer owns its wrap and indent)' do
      expect(renderer.labeled?(:note)).to eq(true)
    end

    it 'is true for the list role (the renderer owns its layout)' do
      expect(renderer.labeled?(:list)).to eq(true)
    end

    it 'is true for the body role (the renderer owns its render)' do
      expect(renderer.labeled?(:body)).to eq(true)
    end

    it 'is false for verbatim types and for the spinner' do
      expect(renderer.labeled?(:text)).to eq(false)
      expect(renderer.labeled?(:spinner_detail)).to eq(false)
      expect(renderer.labeled?(:rule)).to eq(false)
    end

    it 'is false for an unknown type (there is no pattern to check)' do
      expect(renderer.labeled?(:nope)).to eq(false)
    end
  end

  describe 'with a palette (issue #303)' do
    subject(:painted) do
      described_class.new(palette: UI::Palette.fetch('default'))
    end

    it 'labels and colors the same line' do
      expect(painted.line(type: :plan, content: 'read the tool')).to eq(
        "\e[34mplan:  read the tool\e[0m"
      )
    end

    it 'leaves a role the palette does not color in the terminal color' do
      # :response is a BOUNDARY role: the rule is gray and the answer text stays
      # in the terminal's own color (the palette colors no :response role).
      expect(painted.line(type: :response, content: 'done')).to eq(
        "\e[38;5;240m#{'-' * 36} \e[0mmodel\e[38;5;240m #{'-' * 37}\e[0m\ndone"
      )
    end

    it 'colors verbatim roles the palette names (stats and system notes)' do
      expect(painted.line(type: :stats, content: '  [3 iterations]')).to eq(
        "\e[38;5;240m  [3 iterations]\e[0m"
      )
    end

    it 'paints the step number in its own hue with gray rules around it' do
      expect(painted.line(type: :step_label, content: 3)).to eq(
        "\e[38;5;240m#{'-' * 36} \e[0m\e[36mstep 3\e[0m\e[38;5;240m #{'-' * 36}\e[0m"
      )
    end

    it 'paints the bracket gray and the message in the verdict color' do
      expect(painted.line(type: :status_fail, origin: 'file.read', content: 'not found')).to eq(
        "\e[38;5;240m  [file.read]\e[0m\e[31m ✗ not found\e[0m"
      )
    end

    it 'gutter and rule are recessive (gray), the message carries the hue' do
      out = painted.line(type: :status_ok, origin: 'run.command', content: "a\nb")

      expect(out).to eq(
        [
          "\e[38;5;240m  [run.command]\e[0m\e[32m ✓ a\e[0m",
          "\e[38;5;240m  |\e[0m\e[32m b\e[0m",
          "\e[38;5;240m  #{'-' * 12}\e[0m"
        ].join("\n")
      )
    end

    it 'leaves a status_info message in the terminal color with a gray bracket' do
      expect(painted.line(type: :status_info, origin: 'tools.list', content: '12 tool(s)')).to eq(
        "\e[38;5;240m  [tools.list]\e[0m 12 tool(s)"
      )
    end

    it 'never bleeds a color past the line it painted' do
      lines = %i[plan error warn step_label status_ok status_fail].map do |t|
        painted.line(type: t, content: 'x', origin: 'tool')
      end

      expect(lines).to all(end_with("\e[0m"))
      expect(lines.join("\n")).not_to include("\e[0m\e[0m")
    end
  end
end
