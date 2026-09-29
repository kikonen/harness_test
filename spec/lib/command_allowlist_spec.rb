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
