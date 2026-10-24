# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'memories'
require 'tools/memory_delete_tool'

RSpec.describe Tools::MemoryDeleteTool do
  def tool_for(dir)
    described_class.new(Memories.new(dir))
  end

  it 'has the memory.delete name and one required name parameter' do
    tool = tool_for(Dir.mktmpdir)

    expect(tool.name).to eq('memory.delete')
    expect(tool.namespace).to eq('memory')
    expect(tool.parameters[:required]).to eq(['name'])
  end

  # Deleting a note is NOT a file delete: no DELETE grant is asked for, because
  # the argument is a note name and the store is harness-owned.
  it 'removes the note with no DELETE grant involved' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('stale', 'wrong fact')
      tool = tool_for(dir)

      expect(tool).not_to respond_to(:file_list)
      expect(tool.execute('name' => 'stale')).to start_with('ok: removed memory')
      expect(Memories.new(dir).names).to eq([])
    end
  end

  it 'reports how many notes are left' do
    Dir.mktmpdir do |dir|
      m = Memories.new(dir)
      m.add('one', 'x')
      m.add('two', 'x')

      expect(tool_for(dir).execute('name' => 'one')).to eq("ok: removed memory 'one' (1 left)")
    end
  end

  # A name that matches nothing is reported with what IS available, so the model
  # deletes a note that exists instead of guessing again.
  it 'refuses a name with no note and lists the available ones' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('real', 'x')

      out = tool_for(dir).execute('name' => 'typo')

      expect(out).to start_with('error:')
      expect(out).to include('no memory named')
      expect(out).to include('available: real')
    end
  end

  it 'refuses a name that is not one path segment' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('keep', 'x')

      expect(tool_for(dir).execute('name' => '../keep')).to include('one path segment')
      expect(Memories.new(dir).names).to eq(['keep'])
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('one', 'x')

      expect { tool_for(dir).execute('name' => 'one') }.not_to output.to_stdout
    end
  end
end
