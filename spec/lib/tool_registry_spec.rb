# frozen_string_literal: true

require 'spec_helper'
require 'tool_registry'

class RegistryProbe < Tool
  def initialize(name)
    super(name:, description: "the #{name} tool", parameters: {})
  end

  def execute(args)
    args
  end
end

RSpec.describe ToolRegistry do
  # A named stand-in for a Tool: the registry only ever asks a tool for its
  # name/description/namespace, so a full Tool subclass would only restate Tool.

  def registry_with(*names)
    reg = described_class.new
    names.each { |n| reg.register(RegistryProbe.new(n)) }
    reg
  end

  describe '#register / #get' do
    it 'stores a tool under its own name' do
      reg = described_class.new
      tool = RegistryProbe.new('file.read')
      reg.register(tool)

      expect(reg.get('file.read')).to be(tool)
      expect(reg.get('nope')).to be_nil
    end

    it 'returns self, so registrations chain' do
      reg = described_class.new
      expect(reg.register(RegistryProbe.new('a'))).to be(reg)
    end

    # A later registration under the same name REPLACES the first: the registry is
    # keyed by name, and a duplicate name must not produce two entries.
    it 'replaces a tool registered twice under the same name' do
      reg   = described_class.new
      first = RegistryProbe.new('a')
      second = RegistryProbe.new('a')
      reg.register(first).register(second)

      expect(reg.get('a')).to be(second)
      expect(reg.tools.size).to eq(1)
    end
  end

  describe 'ordering (the prompt-cache contract)' do
    # The order is what a prompt cache keys on: insertion order must not leak into
    # the tool list the API is sent.
    it 'sorts names and tools alphabetically, whatever the insertion order' do
      reg = registry_with('zeta.tool', 'alpha.tool', 'mid.tool')

      expect(reg.names).to eq(%w[alpha.tool mid.tool zeta.tool])
      expect(reg.sorted_tools.map(&:name)).to eq(%w[alpha.tool mid.tool zeta.tool])
    end

    it 'is empty-safe' do
      reg = described_class.new
      expect(reg.empty?).to be true
      expect(reg.names).to eq([])
      expect(reg.sorted_tools).to eq([])
      expect(reg.to_openai).to eq([])
    end
  end

  describe '#grouped' do
    it 'groups by namespace, each group and the group list sorted' do
      reg = registry_with('file.write', 'file.read', 'dir.create', 'ui.notify')
      groups = reg.grouped

      expect(groups.map(&:first)).to eq(%w[dir file ui])
      expect(groups.find { |ns, _| ns == 'file' }.last.map(&:name)).to eq(%w[file.read file.write])
    end

    # A name with no dot is its own namespace (see Tool#namespace).
    it 'treats a dotless name as its own namespace' do
      reg = registry_with('plain', 'file.read')
      expect(reg.grouped.map(&:first)).to eq(%w[file plain])
    end
  end

  describe '#search' do
    it 'matches on the name, case-insensitively' do
      reg = registry_with('file.read', 'git.diff')
      expect(reg.search('FILE').map(&:name)).to eq(['file.read'])
    end

    it 'matches on the description too' do
      reg = registry_with('file.read', 'git.diff')
      expect(reg.search('the git.diff tool').map(&:name)).to eq(['git.diff'])
    end

    it 'returns every tool for a blank query (a search for nothing is a listing)' do
      reg = registry_with('b.tool', 'a.tool')
      expect(reg.search('   ').map(&:name)).to eq(%w[a.tool b.tool])
      expect(reg.search(nil).map(&:name)).to eq(%w[a.tool b.tool])
    end

    it 'returns nothing when no tool matches' do
      expect(registry_with('file.read').search('nothing matches this')).to eq([])
    end

    it 'returns matches in name order' do
      reg = registry_with('z.search', 'a.search', 'm.other')
      expect(reg.search('search').map(&:name)).to eq(%w[a.search z.search])
    end
  end

  describe '#to_openai' do
    it 'maps every tool through the function shape, in sorted order' do
      reg = registry_with('b.tool', 'a.tool')
      payload = reg.to_openai

      expect(payload.map { |t| t[:function][:name] }).to eq(%w[a.tool b.tool])
      expect(payload.first[:type]).to eq('function')
    end
  end

  describe '#tools' do
    it 'exposes the stored tools (unsorted - callers use sorted_tools)' do
      reg = registry_with('b.tool', 'a.tool')
      expect(reg.tools.size).to eq(2)
      expect(reg.tools.keys).to contain_exactly('a.tool', 'b.tool')
    end
  end
end
