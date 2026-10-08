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
    it 'requires a non-empty title' do
      expect(tool.execute(base_args.merge('title' => '  '))).to include('title')
    end

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

  context 'dialog construction' do
    it 'passes title and options through' do
      out, kwargs = run_tool(base_args, :a)
      expect(out).to eq('selected: :a')
      expect(kwargs[:title]).to eq('Pick some tools')
      expect(kwargs[:options].size).to eq(3)
      expect(kwargs[:options][0].value).to eq(:a)
    end

    it 'defaults multi_select to false' do
      _out, kwargs = run_tool(base_args, :a)
      expect(kwargs[:multi_select]).to be(false)
    end

    it 'passes multi_select: true through when requested (issue #72)' do
      _out, kwargs = run_tool(base_args.merge('multi_select' => true), :a)
      expect(kwargs[:multi_select]).to be(true)
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

    it 'formats free text' do
      out, = run_tool(base_args, [UI::Dialog::FREE_TEXT, 'my own answer'])
      expect(out).to include('my own answer')
    end

    it 'formats a choice with a note' do
      out, = run_tool(base_args, [:b, 'prefer this one'])
      expect(out).to eq("selected: :b (user's note: \"prefer this one\")")
    end

    it 'formats cancel' do
      out, = run_tool(base_args, UI::Dialog::CANCEL_VALUE)
      expect(out).to include('cancelled')
    end
  end
end
