# frozen_string_literal: true

require 'spec_helper'
require 'session_file_cache'

RSpec.describe SessionFileCache do
  WORKDIR = '/work/repo'.freeze

  let(:cache) { described_class.new }

  describe 'key derivation (issue #170 follow-up: portable sessions)' do
    it 'stores entries under workdir-relative paths' do
      cache.record('/work/repo/lib/foo.rb', 'abc123', workdir: WORKDIR)
      expect(cache.to_h).to eq('lib/foo.rb' => 'abc123')
    end

    it 'resolves lookups by the same relative key' do
      cache.record('/work/repo/lib/foo.rb', 'abc123', workdir: WORKDIR)
      expect(cache.digest('/work/repo/lib/foo.rb', workdir: WORKDIR)).to eq('abc123')
      expect(cache.known?('/work/repo/lib/foo.rb', workdir: WORKDIR)).to be(true)
    end

    it 'normalizes paths against the workdir so a different absolute prefix matches' do
      cache.record('/old/location/repo/lib/foo.rb', 'abc123', workdir: '/old/location/repo')
      expect(cache.digest('/new/location/repo/lib/foo.rb', workdir: '/new/location/repo'))
        .to eq('abc123')
    end

    it 'keys files outside the workdir by their canonical path' do
      cache.record('/elsewhere/notes.txt', 'def456', workdir: WORKDIR)
      expect(cache.to_h).to eq('/elsewhere/notes.txt' => 'def456')
    end

    it 'falls back to the given path as key without a workdir (standalone use)' do
      cache.record('/work/repo/lib/foo.rb', 'abc123')
      expect(cache.to_h).to eq('/work/repo/lib/foo.rb' => 'abc123')
      expect(cache.digest('/work/repo/lib/foo.rb')).to eq('abc123')
    end

    it 'does not treat the workdir prefix as a substring match on a sibling dir' do
      other = '/work/repo2/lib/foo.rb'
      cache.record(other, 'xyz789', workdir: WORKDIR)
      expect(cache.to_h).to eq(other => 'xyz789')
    end
  end

  describe '#record / #digest / #known?' do
    it 'overwrites an existing entry for the same file' do
      cache.record('/work/repo/a.txt', 'one', workdir: WORKDIR)
      cache.record('/work/repo/a.txt', 'two', workdir: WORKDIR)
      expect(cache.digest('/work/repo/a.txt', workdir: WORKDIR)).to eq('two')
    end

    it 'returns nil / false for unknown files' do
      expect(cache.digest('/work/repo/none.txt', workdir: WORKDIR)).to be_nil
      expect(cache.known?('/work/repo/none.txt', workdir: WORKDIR)).to be(false)
    end
  end

  describe '#clear' do
    it 'drops the entry for a file' do
      cache.record('/work/repo/a.txt', 'one', workdir: WORKDIR)
      cache.clear('/work/repo/a.txt', workdir: WORKDIR)
      expect(cache.empty?).to be(true)
    end

    it 'is a no-op for unknown files' do
      expect { cache.clear('/work/repo/none.txt', workdir: WORKDIR) }.not_to raise_error
    end
  end

  describe '#rename' do
    it 're-keys the entry under the new path (digest travels with the file)' do
      cache.record('/work/repo/a.txt', 'one', workdir: WORKDIR)
      cache.rename('/work/repo/a.txt', '/work/repo/b.txt', workdir: WORKDIR)
      expect(cache.to_h).to eq('b.txt' => 'one')
    end

    it 'is a no-op when the file had no entry' do
      expect { cache.rename('/work/repo/a.txt', '/work/repo/b.txt', workdir: WORKDIR) }
        .not_to raise_error
      expect(cache.empty?).to be(true)
    end
  end

  describe '#clear_all / #empty? / #to_h' do
    it 'starts empty' do
      expect(cache.empty?).to be(true)
      expect(cache.to_h).to eq({})
    end

    it 'drops every entry' do
      cache.record('/work/repo/a.txt', 'one', workdir: WORKDIR)
      cache.clear_all
      expect(cache.empty?).to be(true)
    end

    it 'returns a copy, not the internal hash' do
      cache.record('/work/repo/a.txt', 'one', workdir: WORKDIR)
      h = cache.to_h
      h.delete('a.txt')
      expect(cache.to_h).to eq('a.txt' => 'one')
    end
  end

  describe '#restore' do
    it 'restores entries verbatim (relative keys are location-independent)' do
      cache.restore('lib/foo.rb' => 'abc123')
      expect(cache.digest('/moved/repo/lib/foo.rb', workdir: '/moved/repo')).to eq('abc123')
    end

    it 'clears previous state first' do
      cache.record('/work/repo/old.txt', 'one', workdir: WORKDIR)
      cache.restore('lib/foo.rb' => 'abc123')
      expect(cache.to_h).to eq('lib/foo.rb' => 'abc123')
    end

    it 'skips entries without a usable digest or path' do
      cache.restore('good.txt' => 'abc', 'no_digest.txt' => '', 123 => 'xyz')
      expect(cache.to_h).to eq('good.txt' => 'abc')
    end
  end
end
