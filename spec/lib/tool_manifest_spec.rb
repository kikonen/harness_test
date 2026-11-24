# frozen_string_literal: true

require 'spec_helper'
require 'tool_manifest'
require 'tool_registry'
require 'tool'
require 'job'
require 'harness_error'

ManifestProbe = Class.new(Tool) do
  def initialize(name)
    super(name:, description: "the #{name} tool", parameters: {})
  end

  def execute(args)
    args
  end
end

RSpec.describe ToolManifest do
  def registry_with(*names)
    flat = names.flatten
    ToolRegistry.new.tap { |r| flat.each { |n| r.register(ManifestProbe.new(n)) } }
  end

  # Point the module at a file this example controls.
  def with_manifest_file(path)
    ToolManifest.file = path
    ToolManifest.instance_variable_set(:@manifests, nil)
  end

  after do
    ToolManifest.file = nil
    ToolManifest.instance_variable_set(:@manifests, nil)
  end

  def temp_manifest(name)
    path = File.join(Dir.tmpdir, "harness-manifest-#{name}-#{Process.pid}.yml")
    @path = path
    path
  end

  # The shipped file IS the tool policy, so it is tested against the real kinds.
  describe 'the shipped config/tool_manifests.yml' do
    it 'names every job kind' do
      expect(Job::KINDS - described_class.manifests.keys).to be_empty
    end

    it 'gives the harness-driven kinds the full set' do
      %i[main command timed].each do |kind|
        expect(described_class.manifests[kind]).to eq(described_class::FULL)
      end
    end

    it 'lists the read-only tools for a sub-agent' do
      expect(described_class.manifests[:sub_agent]).to include('file.read', 'ui.dialog')
    end

    it 'names no write or execute tool for a sub-agent' do
      expect(described_class.manifests[:sub_agent])
        .not_to include('run.command', 'file.write', 'file.patch', 'file.delete',
                        'dir.create', 'dir.delete', 'git.patch')
    end

    it 'names no tool that writes harness state shared with the main agent' do
      expect(described_class.manifests[:sub_agent])
        .not_to include('ui.note', 'memory.add', 'memory.delete', 'plan.add', 'plan.delete')
    end

    it 'names no web.fetch for a sub-agent (its consent axis is unsettled there)' do
      expect(described_class.manifests[:sub_agent]).not_to include('web.fetch')
    end
  end

  describe '.names_for' do
    it 'is the whole registry for a kind marked full' do
      reg = registry_with('file.read', 'run.command')

      %i[main command timed].each do |kind|
        expect(described_class.names_for(kind, reg)).to eq(%w[file.read run.command])
      end
    end

    it 'is the YAML list for a kind the file lists' do
      reg = registry_with(described_class.manifests[:sub_agent])

      expect(described_class.names_for(:sub_agent, reg))
        .to eq(described_class.manifests[:sub_agent])
    end

    it 'raises on a kind the file does not name' do
      expect { described_class.names_for(:nope, registry_with('file.read')) }
        .to raise_error(HarnessError, /no tool manifest for job kind nope/)
    end

    it 'is the whole registry for the FULL marker and for no kind at all' do
      reg = registry_with('file.read', 'run.command')

      expect(described_class.names_for(described_class::FULL, reg)).to eq(%w[file.read run.command])
      expect(described_class.names_for(nil, reg)).to eq(%w[file.read run.command])
    end

    # A typo would otherwise silently produce a smaller agent.
    it 'raises when the manifest names a tool the run does not have' do
      reg = registry_with(described_class.manifests[:sub_agent] - ['file.info'])

      expect { described_class.names_for(:sub_agent, reg) }
        .to raise_error(HarnessError, /does not have: file.info/)
    end
  end

  describe 'the manifest file' do
    it 'treats a missing file as no manifests at all' do
      with_manifest_file(File.join(Dir.tmpdir, "harness-no-manifests-#{Process.pid}.yml"))

      expect(described_class.manifests).to eq({})
      expect { described_class.names_for(:sub_agent, registry_with('file.read')) }
        .to raise_error(HarnessError, /no tool manifest for job kind sub_agent/)
    end

    it 'accepts a kind named by a string and an entry given as full' do
      with_manifest_file(temp_manifest('full'))
      File.write(@path, "sub_agent: full\n")

      expect(described_class.names_for('sub_agent', registry_with('file.read', 'run.command')))
        .to eq(%w[file.read run.command])
    end

    it 'raises on an entry that is neither full nor a list' do
      with_manifest_file(temp_manifest('notalist'))
      File.write(@path, "sub_agent: file.read\n")

      expect { described_class.manifests }
        .to raise_error(HarnessError, /sub_agent in .* is neither 'full' nor a list/)
    end

    it 'raises on a malformed YAML file' do
      with_manifest_file(temp_manifest('broken'))
      File.write(@path, "sub_agent: [file.read\n")

      expect { described_class.manifests }
        .to raise_error(HarnessError, /invalid tool manifest file/)
    end
  end
end
