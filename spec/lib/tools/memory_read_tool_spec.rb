# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'memories'
require 'tools/memory_read_tool'

RSpec.describe Tools::MemoryReadTool do
  def tool_with(dir)
    described_class.new(Memories.new(dir))
  end

  it 'has the memory.read name and one required name parameter' do
    tool = tool_with(Dir.mktmpdir)

    expect(tool.name).to eq('memory.read')
    expect(tool.namespace).to eq('memory')
    expect(tool.parameters[:required]).to eq(['name'])
  end

  it 'returns the stored note body as the tool result' do
    Dir.mktmpdir do |dir|
      body = "# Rubocop\n\nbundle exec rubocop is also in CI."
      Memories.new(dir).add('rubocop', body)

      expect(tool_with(dir).execute('name' => 'rubocop')).to eq(body)
    end
  end

  it 'names the line count in the status line' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('two-lines', "one\ntwo")
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:ok, 'two-lines (2 lines)')
      tool.execute('name' => 'two-lines')
    end
  end

  # A note is harness-owned instruction content (like a skill body): the model
  # reads it without ever being granted a path.
  it 'reads a note with no FileList grant involved' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('grant-free', 'text')
      tool = tool_with(dir)

      expect(tool).not_to respond_to(:file_list)
      expect(tool.execute('name' => 'grant-free')).to eq('text')
    end
  end

  it 'refuses a name that is not one path segment' do
    Dir.mktmpdir do |dir|
      tool = tool_with(dir)

      expect(tool.execute('name' => '../sessions/abc/session.json'))
        .to include('one path segment')
    end
  end

  # The failure line names what IS available, so the model picks a real name
  # instead of guessing again.
  it 'lists the available names when the name matches no note' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('real-name', 'text')

      out = tool_with(dir).execute('name' => 'guessed')

      expect(out).to include('no memory named')
      expect(out).to include('available: real-name')
    end
  end

  it 'says the store is empty when there is nothing to read' do
    Dir.mktmpdir do |dir|
      expect(tool_with(dir).execute('name' => 'anything')).to include('no memories stored')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('one', 'text')

      expect { tool_with(dir).execute('name' => 'one') }.not_to output.to_stdout
    end
  end
end
