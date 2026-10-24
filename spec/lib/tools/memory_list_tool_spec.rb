# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'memories'
require 'tools/memory_list_tool'

RSpec.describe Tools::MemoryListTool do
  def tool_with(dir)
    described_class.new(Memories.new(dir))
  end

  def add(dir, name, text = 'a stored fact')
    Memories.new(dir).add(name, text)
  end

  it 'has the memory.list name and a namespace of memory' do
    tool = tool_with(Dir.mktmpdir)

    expect(tool.name).to eq('memory.list')
    expect(tool.namespace).to eq('memory')
    expect(tool.parameters[:required]).to eq([])
  end

  # The description is the ONLY place a model learns the feature exists (memories
  # are not injected into the system prompt), so it has to name the point of them.
  it 'says in its description that these notes came from earlier sessions' do
    expect(tool_with(Dir.mktmpdir).description).to include('EARLIER sessions')
  end

  it 'lists each note as "name - description" under a count header' do
    Dir.mktmpdir do |dir|
      add(dir, 'consent-postures', 'YOLO skips the shell dialog.')
      add(dir, 'ci', 'CI runs rspec and rubocop on ubuntu.')

      out = tool_with(dir).execute({})

      expect(out).to start_with("Memories (2/#{Memories::MAX_MEMORIES})")
      expect(out).to include('consent-postures - YOLO skips the shell dialog.')
      expect(out).to include('ci - CI runs rspec and rubocop on ubuntu.')
      expect(out.lines.size).to eq(3) # header + 2 notes
    end
  end

  it 'reports the count through the status line' do
    Dir.mktmpdir do |dir|
      add(dir, 'one')
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:info, "1/#{Memories::MAX_MEMORIES} memories")
      tool.execute({})
    end
  end

  # An empty store is the everyday state; the answer names the way to fill it so
  # the model does not go hunting.
  it 'answers an empty store with a plain line naming how to save one' do
    Dir.mktmpdir do |dir|
      tool = tool_with(dir)

      expect(tool).to receive(:status).with(:info, 'no memories stored')
      expect(tool.execute({}))
        .to eq("no memories stored (#{Memories::DIR}/ is empty) - " \
               'save one with memory.add(name:, text:)')
    end
  end

  it 'never writes to $stdout (issue #40)' do
    Dir.mktmpdir do |dir|
      add(dir, 'one')

      expect { tool_with(dir).execute({}) }.not_to output.to_stdout
    end
  end
end
