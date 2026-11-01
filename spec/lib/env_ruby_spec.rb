# frozen_string_literal: true

require 'spec_helper'
require 'env_ruby'

RSpec.describe EnvRuby do
  # A canned report so format/parse are tested deterministically, without
  # spawning a child ruby. Shape mirrors #probe's return.
  def sample_report
    {
      error: nil, ruby: '3.4.1', exe: '/usr/bin/ruby', bundler: 'no',
      rubylib: '/usr/lib/ruby/3.4.0', default_dir: '/usr/lib/ruby/gems/3.4.0',
      user_dir: '/home/u/.gem', count: 4,
      gems: [
        { name: 'csv', version: '3.3.0', kind: 'stdlib' },
        { name: 'kramdown', version: '2.5.2', kind: 'user' },
        { name: 'kramdown', version: '2.4.0', kind: 'ruby' },
        { name: 'nokogiri', version: '1.19.4', kind: 'user' }
      ]
    }
  end

  describe '#probe (real child ruby)' do
    it 'reports the unbundled child ruby without error' do
      report = described_class.new(Dir.pwd).probe

      expect(report[:error]).to be_nil
      expect(report[:count]).to be_positive
      expect(report[:gems].size).to eq(report[:count])
    end

    # The point of the probe: it describes the CHILD env, where the harness' own
    # bundler is NOT active (run.command unbundles it, issue #185).
    it 'states the child ruby has no bundler loaded' do
      expect(described_class.new(Dir.pwd).probe[:bundler]).to eq('no')
    end

    it 'classifies every installed gem into a known kind' do
      kinds = described_class.new(Dir.pwd).probe[:gems].map { |g| g[:kind] }.uniq

      expect(kinds - EnvRuby::KINDS).to eq([])
    end
  end

  describe '#format without query (full scan)' do
    it 'names the child ruby and its bundler state' do
      out = described_class.new('.').format(sample_report)

      expect(out).to include('ruby 3.4.1  (/usr/bin/ruby)')
      expect(out).to include('bundler active in that child: no')
      expect(out).to include('installed specs: 4 (stdlib 1, ruby 1, user 2, other 0)')
    end

    it 'groups gem names by kind, versions dropped' do
      out = described_class.new('.').format(sample_report)

      expect(out).to include('stdlib - ships with Ruby itself')
      expect(out)
        .to include('user - installed for this user (gem install --user-install): kramdown, nokogiri')
      # A full scan drops versions (it lists distinct names, not versioned matches).
      expect(out).not_to include('2.5.2')
    end
  end

  describe '#format with a query' do
    it 'reports installed matches with versions for each token' do
      out = described_class.new('.').format(sample_report, query: ['nokogiri'])

      expect(out).to include('nokogiri: nokogiri 1.19.4 (user)')
    end

    it 'says plainly when a token matches nothing' do
      out = described_class.new('.').format(sample_report, query: ['pdf'])

      expect(out).to include('pdf: no installed gem matches')
    end

    # A gem installed at two versions in two locations is a fact worth keeping,
    # not something to silently collapse.
    it 'lists every version of a duplicated gem' do
      out = described_class.new('.').format(sample_report, query: ['kramdown'])

      expect(out).to include('kramdown 2.5.2 (user)')
      expect(out).to include('kramdown 2.4.0 (ruby)')
    end

    it 'matches a substring case-insensitively' do
      out = described_class.new('.').format(sample_report, query: ['KRAM'])

      expect(out).to include('kramdown 2.5.2 (user)')
    end
  end

  describe '#format when the probe failed' do
    it 'returns the error text instead of a report' do
      out = described_class.new('.').format({ error: 'the probe produced no output' })

      expect(out).to eq('the probe produced no output')
    end
  end

  describe '#probe timeout' do
    # A probe that never produces a RUBY header is treated as a failure, not as
    # an empty success (the model must not be told "0 gems" when the child died).
    it 'reports an error when the child produced no parseable header' do
      env = described_class.new(Dir.pwd)
      allow(env).to receive(:run_probe).and_return(['', 0])

      expect(env.probe[:error]).to eq('the probe produced no output')
    end

    it 'reports an error when the child ruby timed out' do
      env = described_class.new(Dir.pwd)
      allow(env).to receive(:run_probe).and_return(['', :timeout])

      expect(env.probe[:error]).to include('timed out')
    end
  end
end
