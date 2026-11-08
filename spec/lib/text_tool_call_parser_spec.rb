# frozen_string_literal: true

require 'spec_helper'
require 'text_tool_call_parser'
require 'tool_registry'

# TextToolCallParser recovers a tool call a model (qwen) wrote as pseudo-XML
# text instead of a structured tool_calls array (issue #461). The pseudo-XML is
# built from tag fragments so the literal pseudo-tags never sit as a contiguous
# token in this file.
RSpec.describe TextToolCallParser do
  def tag(name) = '<' + name + '>'
  def end_tag(name) = '</' + name + '>'

  # A registry with the short-name collisions a real one has: 'read' and 'list'
  # are ambiguous, 'echo' is unique. Names are chosen only to exercise the
  # resolution rules; execute is never called (the parser only resolves names).
  def stub_tool(name)
    Tool.new(name: name, description: "stub #{name}", parameters: {})
  end

  def registry
    ToolRegistry.new.tap do |r|
      %w[test.echo file.read memory.read file.list tools.list file.write].each do |n|
        r.register(stub_tool(n))
      end
    end
  end

  def parser
    described_class.new(registry)
  end

  # qwen dialect: the name is glued to the tag with '='.
  def qwen_call(func, params)
    body = params.map { |k, v| tag("parameter=#{k}") + v + end_tag('parameter') }
    tag('tool_call') + tag("function=#{func}") + body.join +
      end_tag('function') + end_tag('tool_call')
  end

  describe '#text_call?' do
    it 'is true on an open marker, false on plain prose or nil' do
      expect(parser.text_call?(qwen_call('test.echo', 'text' => 'hi'))).to be(true)
      expect(parser.text_call?('just prose')).to be(false)
      expect(parser.text_call?(nil)).to be(false)
    end
  end

  describe '#parse' do
    it 'builds a synthetic tool_calls array the tool loop already consumes' do
      calls = parser.parse(qwen_call('test.echo', 'text' => 'hi'))

      expect(calls.size).to eq(1)
      expect(calls[0][:id]).to eq('text_call_1')
      expect(calls[0][:function][:name]).to eq('test.echo')
      expect(JSON.parse(calls[0][:function][:arguments])).to eq('text' => 'hi')
    end

    it 'returns [] for content that is not a call' do
      expect(parser.parse('plain answer')).to eq([])
    end

    it 'resolves a unique short name to its qualified tool (echo -> test.echo)' do
      calls = parser.parse(qwen_call('echo', 'text' => 'hi'))

      expect(calls[0][:function][:name]).to eq('test.echo')
    end

    it 'leaves an ambiguous short name unresolved (read = file.read OR memory.read)' do
      expect(parser.parse(qwen_call('read', 'path' => 'x'))).to eq([])
    end

    it 'leaves an unknown name unresolved so quoted prose never runs' do
      quoted = "the broken format looks like #{qwen_call('bogus_tool', 'path' => 'x')} here"

      expect(parser.parse(quoted)).to eq([])
    end

    # The qwen dialect is deliberately malformed XML, so a plain parse would
    # lose it; Nokogiri recovery + the '='-header rewrite is what recovers these.
    it 'recovers a bare function block with no tool_call wrapper' do
      bare = tag('function=echo') + tag('parameter=text') + 'hi' +
             end_tag('parameter') + end_tag('function')

      calls = parser.parse(bare)
      expect(calls[0][:function][:name]).to eq('test.echo')
      expect(JSON.parse(calls[0][:function][:arguments])).to eq('text' => 'hi')
    end

    it 'recovers a truncated call whose closing tags never arrived' do
      truncated = tag('tool_call') + tag('function=file.write') +
                  tag('parameter=path') + 'tmp/x.txt'

      calls = parser.parse(truncated)
      expect(calls[0][:function][:name]).to eq('file.write')
      expect(JSON.parse(calls[0][:function][:arguments])).to eq('path' => 'tmp/x.txt')
    end

    it 'parses a multi-line value verbatim (no whitespace mangling)' do
      multi = qwen_call('file.write', 'path' => 'tmp/x.txt', 'content' => "a\nb")

      args = JSON.parse(parser.parse(multi)[0][:function][:arguments])
      expect(args['content']).to eq("a\nb")
    end

    it 'carries the Anthropic name="..." attribute form too' do
      anthropic = tag('tool_call') + tag('function name="test.echo"') +
                  tag('parameter name="text"') + 'hi' +
                  end_tag('parameter') + end_tag('function') +
                  end_tag('tool_call')

      calls = parser.parse(anthropic)
      expect(calls[0][:function][:name]).to eq('test.echo')
    end
  end

  describe '#parse synthetic ids continue past committed ones' do
    it 'numbers new calls past the highest committed text_call_N' do
      committed = [{ id: 'text_call_1' }, { id: 'text_call_2' }]

      calls = parser.parse(qwen_call('test.echo', 'text' => 'hi'), committed:)

      expect(calls.map { |c| c[:id] }).to eq(['text_call_3'])
    end

    it 'ignores a real (server-issued) call id when numbering' do
      committed = [{ id: 'call_real_1' }]

      calls = parser.parse(qwen_call('test.echo', 'text' => 'hi'), committed:)

      expect(calls.map { |c| c[:id] }).to eq(['text_call_1'])
    end

    it 'numbers several recovered calls of one response in order' do
      content = qwen_call('test.echo', 'text' => 'a') + qwen_call('echo', 'text' => 'b')

      calls = parser.parse(content)

      expect(calls.map { |c| c[:id] }).to eq(%w[text_call_1 text_call_2])
    end
  end
end
