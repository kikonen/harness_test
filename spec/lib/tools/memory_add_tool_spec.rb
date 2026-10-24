# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'memories'
require 'tools/memory_add_tool'

RSpec.describe Tools::MemoryAddTool do
  def tool_for(dir)
    described_class.new(Memories.new(dir))
  end

  it 'has the memory.add name and name+text required' do
    tool = tool_for(Dir.mktmpdir)

    expect(tool.name).to eq('memory.add')
    expect(tool.namespace).to eq('memory')
    expect(tool.parameters[:required]).to eq(%w[name text])
  end

  it 'writes the note into the store dir' do
    Dir.mktmpdir do |dir|
      out = tool_for(dir).execute('name' => 'gotcha', 'text' => 'shell_parser.rb is racc output')

      expect(out).to start_with('ok: saved memory')
      expect(File.binread(File.join(dir, Memories::DIR, 'gotcha.md')))
        .to eq("shell_parser.rb is racc output\n")
    end
  end

  # The consent decision (issue #10): a memory call names ONE note NAME, never a
  # path, so there is nothing to grant and no grant is asked for.
  it 'asks for no FileList grant (the argument is a name, not a path)' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)

      expect(tool).not_to respond_to(:file_list)
      expect(tool.execute('name' => 'no-grant', 'text' => 'body')).to start_with('ok:')
    end
  end

  it 'reports the name and char count in the status line' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)

      expect(tool).to receive(:status).with(:ok, 'note-name (4 chars)')
      tool.execute('name' => 'note-name', 'text' => 'body')
    end
  end

  # A refusal the model can ACT on: the error line names the limit and the way
  # out, because re-sending the same call shape would fail identically.
  it 'refuses a duplicate name and names the alternatives' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)
      tool.execute('name' => 'fact', 'text' => 'first')

      out = tool.execute('name' => 'fact', 'text' => 'second')

      expect(out).to start_with('error:')
      expect(out).to include('already exists')
      expect(out).to include('overwrite: true')
      expect(Memories.new(dir).body('fact')).to eq('first')
    end
  end

  it 'replaces the note when overwrite is passed' do
    Dir.mktmpdir do |dir|
      tool = tool_for(dir)
      tool.execute('name' => 'fact', 'text' => 'first')
      tool.execute('name' => 'fact', 'text' => 'second', 'overwrite' => true)

      expect(Memories.new(dir).body('fact')).to eq('second')
    end
  end

  # The store must not become a writer inside .harness/ (issue #10): what the
  # file tools can never grant stays unreachable through memory.add too.
  it 'refuses a name that is not one path segment' do
    Dir.mktmpdir do |dir|
      expect(tool_for(dir).execute('name' => '../sessions/x/session.json', 'text' => 'boom'))
        .to include('one path segment')
      expect(Memories.new(dir).count).to eq(0)
    end
  end

  it 'refuses an empty text' do
    Dir.mktmpdir do |dir|
      expect(tool_for(dir).execute('name' => 'empty', 'text' => '  ')).to include('empty')
    end
  end

  it 'refuses a text over the body cap, quoting the limit' do
    Dir.mktmpdir do |dir|
      long = 'x' * (Memories::MAX_BODY_CHARS + 1)
      out  = tool_for(dir).execute('name' => 'huge', 'text' => long)

      expect(out).to include("max #{Memories::MAX_BODY_CHARS}")
      expect(Memories.new(dir).count).to eq(0)
    end
  end

  it 'refuses a note when the store is full and names consolidation as the way out' do
    Dir.mktmpdir do |dir|
      memories = Memories.new(dir)
      Memories::MAX_MEMORIES.times { |i| memories.add("note-#{i}", 'text') }

      out = tool_for(dir).execute('name' => 'too-many', 'text' => 'body')

      expect(out).to include("full (#{Memories::MAX_MEMORIES} notes)")
      expect(out).to include('memory.delete')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      expect { tool_for(dir).execute('name' => 'one', 'text' => 'body') }.not_to output.to_stdout
    end
  end
end
