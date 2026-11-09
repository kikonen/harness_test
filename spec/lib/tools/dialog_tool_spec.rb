# frozen_string_literal: true

require 'spec_helper'
require 'tools/dialog_tool'

RSpec.describe Tools::DialogTool do
  subject(:tool) { described_class.new }

  let(:base_args) do
    {
      'title' => 'Pick some tools',
      'options' => [
        { 'title' => 'A', 'value' => :a },
        { 'title' => 'B', 'value' => :b },
        { 'title' => 'C', 'value' => :c }
      ]
    }
  end

  # Stub UI::Dialog.new, execute the tool with the given args, and return
  # [tool output, kwargs the dialog was built with].
  def run_tool(args, choice)
    captured = nil
    allow(UI::Dialog).to receive(:new) do |**kw|
      captured = kw
      instance_double(UI::Dialog, show: choice)
    end
    out = tool.execute(args)
    [out, captured]
  end

  context 'argument validation' do
    it 'requires a non-empty array of options' do
      expect(tool.execute(base_args.merge('options' => []))).to include('options')
    end

    it 'caps the number of options at 10' do
      many = 11.times.map { |i| { 'title' => "t#{i}", 'value' => i } }
      expect(tool.execute(base_args.merge('options' => many))).to include('too many options')
    end

    it 'rejects options without a title or a value' do
      bad1 = base_args.merge('options' => [{ 'value' => :x }])
      bad2 = base_args.merge('options' => [{ 'title' => 'n' }])
      expect(tool.execute(bad1)).to include('title')
      expect(tool.execute(bad2)).to include('value')
    end
  end

  context 'malformed arguments (issue #427)' do
    it 'fills a neutral head for a title-less call' do
      out, kwargs = run_tool(base_args.reject { |k, _| k == 'title' }, :a)
      expect(out).to eq('selected: :a')
      expect(kwargs[:title]).to eq(Tools::DialogTool::DEFAULT_TITLE)
    end

    it 'fills the same head when the title is blank' do
      _out, kwargs = run_tool(base_args.merge('title' => '   '), :a)
      expect(kwargs[:title]).to eq(Tools::DialogTool::DEFAULT_TITLE)
    end

    it 'accepts options re-encoded by the model as a JSON string' do
      str_opts = JSON.generate([{ 'title' => 'A', 'value' => 'a' }, { 'title' => 'B', 'value' => 'b' }])
      out, kwargs = run_tool(base_args.merge('options' => str_opts), 'a')
      expect(out).to eq("selected: \"a\"")
      expect(kwargs[:options].size).to eq(2)
    end

    it 'rejects an options string that is not a JSON array' do
      expect(tool.execute(base_args.merge('options' => 'just words'))).to include('not a JSON array')
    end

    # issue #468: the model double-encodes the options array as a string AND
    # fuses the sibling title/note keys onto it, so the whole string is not
    # valid JSON. Salvage the balanced leading array; the outer arguments still
    # carry the real title/note, so the fused text is discarded.
    it 'salvages a leading array from a double-encoded, sibling-fused options string' do
      fused = '[{"title": "A", "value": "a"}, {"title": "B", "value": "b"}], ' \
              '"title": "swallowed", "note": "swallowed"}]'
      out, kwargs = run_tool(base_args.merge('options' => fused), 'b')
      expect(out).to eq("selected: \"b\"")
      expect(kwargs[:options].size).to eq(2)
      expect(kwargs[:options].map(&:value)).to eq(%w[a b])
      # title/note come from the OUTER args, not the fused junk.
      expect(kwargs[:title]).to eq(base_args['title'])
      # base_args carries no note, so the fused "note" text must NOT leak in.
      expect(kwargs[:note]).to be_nil
    end

    it 'a salvaged array keeps a ] that sits inside an option string' do
      # A ] inside a quoted option title must not close the array early.
      fused = '[{"title": "A] B", "value": "a"}, {"title": "C", "value": "c"}], junk]'
      _out, kwargs = run_tool(base_args.merge('options' => fused), 'a')
      expect(kwargs[:options].size).to eq(2)
      expect(kwargs[:options][0].title).to eq('A] B')
    end

    it 'names the shape when a string holds no salvageable array' do
      out = tool.execute(base_args.merge('options' => '{"title": "A", "value": "a"}'))
      expect(out).to include('not a JSON array of options')
      expect(out).to include('separate parameters')
    end

    it 'parses a single option that arrived as a JSON object string' do
      one_opt = JSON.generate({ 'title' => 'A', 'value' => 'a' })
      out, kwargs = run_tool(base_args.merge('options' => [one_opt]), 'a')
      expect(out).to eq("selected: \"a\"")
      expect(kwargs[:options].size).to eq(1)
    end

    it 'names the option that is missing a title' do
      bad = base_args.merge('options' => [
        { 'title' => 'A', 'value' => 'a' },
        { 'description' => 'no title here', 'value' => 'b' }
      ])
      expect(tool.execute(bad)).to include('option 2')
      expect(tool.execute(bad)).to include('missing a')
    end

    it 'names the option with an empty title' do
      bad = base_args.merge('options' => [{ 'title' => '  ', 'value' => 'b' }])
      expect(tool.execute(bad)).to include('option 1')
      expect(tool.execute(bad)).to include('non-empty')
    end

    it 'names the option missing a value' do
      bad = base_args.merge('options' => [{ 'title' => 'A' }])
      expect(tool.execute(bad)).to include('option 1')
      expect(tool.execute(bad)).to include('missing a')
    end

    it 'names the option with an empty value' do
      bad = base_args.merge('options' => [{ 'title' => 'A', 'value' => '' }])
      expect(tool.execute(bad)).to include('option 1')
      expect(tool.execute(bad)).to include('non-empty')
    end
  end

  context 'dialog construction' do
    it 'passes title and options through' do
      out, kwargs = run_tool(base_args, :a)
      expect(out).to eq('selected: :a')
      expect(kwargs[:title]).to eq('Pick some tools')
      expect(kwargs[:options].size).to eq(3)
      expect(kwargs[:options][0].value).to eq(:a)
    end

    it 'always enables free text (issue #72: every model dialog gets "Additional details")' do
      _out, kwargs = run_tool(base_args, :a)
      expect(kwargs[:free_text]).to be(true)
    end

    it 'defaults multi_select to false' do
      _out, kwargs = run_tool(base_args, :a)
      expect(kwargs[:multi_select]).to be(false)
    end

    it 'passes multi_select: true through when requested (issue #72)' do
      _out, kwargs = run_tool(base_args.merge('multi_select' => true), :a)
      expect(kwargs[:multi_select]).to be(true)
    end

    it 'passes free_text_prompt through as the "Additional details" label hint' do
      _out, kwargs = run_tool(base_args.merge('free_text_prompt' => 'or type a short note'), :a)
      expect(kwargs[:free_text_prompt]).to eq('or type a short note')
    end

    it 'treats a truthy non-boolean multi_select as false' do
      _out, kwargs = run_tool(base_args.merge('multi_select' => 'yes'), :a)
      expect(kwargs[:multi_select]).to be(false)
    end
  end

  context 'choice formatting' do
    it 'formats a single selection' do
      out, = run_tool(base_args, :b)
      expect(out).to eq('selected: :b')
    end

    it 'formats a multi-select result as an array of values (issue #72)' do
      out, = run_tool(base_args, [:a, :c])
      expect(out).to eq("selected: :a, :c")
    end

    it 'formats bare free text (only "Additional details" picked)' do
      out, = run_tool(base_args, [UI::Dialog::FREE_TEXT, 'my own answer'])
      expect(out).to eq('free text response from the user: "my own answer"')
    end

    it 'formats a selection with details riding along (issue #72)' do
      out, = run_tool(base_args, [:b, [UI::Dialog::FREE_TEXT, 'prefer this one, because Z']])
      expect(out)
        .to eq("selected: :b (user's details: \"prefer this one, because Z\")")
    end

    it 'formats cancel' do
      out, = run_tool(base_args, UI::Dialog::CANCEL_VALUE)
      expect(out).to include('cancelled')
    end

    it 'formats cancel with a one-line reason' do
      out, = run_tool(base_args, [UI::Dialog::CANCEL_VALUE, 'no, and because X'])
      expect(out).to eq("cancelled (user's note: \"no, and because X\")")
    end

    it 'formats cancel with a details block (issue #72)' do
      out, = run_tool(
        base_args,
        [UI::Dialog::CANCEL_VALUE, [UI::Dialog::FREE_TEXT, 'the options miss Z']]
      )
      expect(out).to eq("cancelled (user's details: \"the options miss Z\")")
    end
  end
end
