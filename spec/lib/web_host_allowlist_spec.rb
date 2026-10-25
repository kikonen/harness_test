# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'web_host_allowlist'

RSpec.describe WebHostAllowlist do
  # The allowlist lives in .harness/, which is this class' own business and not
  # the file tools' - so the specs write it directly.
  def allowlist_in(dir)
    described_class.new(dir)
  end

  def path_in(dir)
    File.join(dir, '.harness', described_class::FILENAME)
  end

  describe 'exact-host matching' do
    it 'grants only the exact host it was given' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('example.com')

        expect(list.allowed?('example.com')).to be true
        # THE rule a domain-suffix match would break: a granted domain must not
        # cover a look-alike host under it or beside it.
        expect(list.allowed?('evil.example.com')).to be false
        expect(list.allowed?('example.com.attacker.tld')).to be false
        expect(list.allowed?('notexample.com')).to be false
        expect(list.allowed?('example.org')).to be false
      end
    end

    it 'refuses every host while nothing is granted' do
      Dir.mktmpdir do |dir|
        expect(allowlist_in(dir).hosts).to eq([])
        expect(allowlist_in(dir).allowed?('example.com')).to be false
      end
    end

    it 'grants several hosts independently' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('a.example')
        list.add('b.example')

        expect(list.hosts).to eq(%w[a.example b.example])
        expect(list.allowed?('a.example')).to be true
        expect(list.allowed?('b.example')).to be true
        expect(list.allowed?('c.example')).to be false
      end
    end
  end

  describe '.normalize (the same form when saving and when looking up)' do
    it 'makes case, surrounding space, a scheme and a trailing slash irrelevant' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('Example.COM')

        expect(list.allowed?('example.com')).to be true
        expect(list.allowed?('  example.com  ')).to be true
        expect(list.allowed?('http://example.com')).to be true
        expect(list.allowed?('https://example.com/')).to be true
        expect(list.allowed?('HTTPS://Example.Com/')).to be true
        expect(list.hosts).to eq(['example.com'])
      end
    end

    it 'normalizes a host read back from disk the same way' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(path_in(dir), YAML.dump(['Docs.Example.ORG/']))

        list = allowlist_in(dir)
        expect(list.hosts).to eq(['docs.example.org'])
        expect(list.allowed?('docs.example.org')).to be true
      end
    end

    # issue #257: a model-supplied host can carry bytes invalid in UTF-8, and the
    # String methods below would raise on them.
    it 'does not raise on a byte invalid in UTF-8 (the byte is replaced)' do
      bad = [0xE2, 0x90].pack('C*').force_encoding(Encoding::UTF_8)
      expect(bad.valid_encoding?).to be false
      expect { bad.strip }.to raise_error(StandardError)

      normalized = described_class.normalize(bad)
      expect(normalized.valid_encoding?).to be true
      expect { described_class.normalize("a#{bad}.test") }.not_to raise_error
    end

    it 'normalizes a nil and a blank to an empty host (never allowed, never saved)' do
      expect(described_class.normalize(nil)).to eq('')
      expect(described_class.normalize('   ')).to eq('')

      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add(nil)
        list.add('   ')

        expect(list.hosts).to eq([])
        expect(list.allowed?('')).to be false
        expect(list.allowed?(nil)).to be false
      end
    end
  end

  describe '.grantable? (what the dialog may offer to save)' do
    it 'accepts a plain host name' do
      expect(described_class.grantable?('example.com')).to be true
      # A grant is normalized before it is judged, so a scheme the model typed
      # does not make the host ungrantable.
      expect(described_class.grantable?('https://example.com/')).to be true
      expect(described_class.grantable?(' Example.COM ')).to be true
    end

    it 'refuses anything that is not a bare host' do
      # A port, a path, userinfo or whitespace cannot be an exact-host grant: it
      # would either never match again or match something else entirely.
      expect(described_class.grantable?('example.com:8080')).to be false
      expect(described_class.grantable?('example.com/docs')).to be false
      expect(described_class.grantable?('user@example.com')).to be false
      expect(described_class.grantable?('two words.example')).to be false
      expect(described_class.grantable?('localhost')).to be false
      expect(described_class.grantable?('')).to be false
      expect(described_class.grantable?(nil)).to be false
    end
  end

  describe 'persistence' do
    it 'writes the host to .harness/allowed_hosts.yml' do
      Dir.mktmpdir do |dir|
        allowlist_in(dir).add('example.com')

        expect(File.file?(path_in(dir))).to be true
        expect(YAML.safe_load(File.read(path_in(dir)))).to eq(['example.com'])
      end
    end

    it 'reads a grant back in a NEW allowlist object (it is not session state)' do
      Dir.mktmpdir do |dir|
        allowlist_in(dir).add('api.example.com')

        expect(allowlist_in(dir).allowed?('api.example.com')).to be true
      end
    end

    it 'never saves the same host twice' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('example.com')
        list.add('example.com')
        list.add('EXAMPLE.COM')

        expect(list.hosts).to eq(['example.com'])
        expect(YAML.safe_load(File.read(path_in(dir)))).to eq(['example.com'])
      end
    end

    it 'removes a host and persists the removal' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('a.example')
        list.add('b.example')
        list.remove('A.Example')

        expect(list.hosts).to eq(['b.example'])
        expect(allowlist_in(dir).hosts).to eq(['b.example'])
      end
    end

    it 'leaves the file alone when there is nothing to remove' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('a.example')
        path = path_in(dir)
        before = File.read(path)

        list.remove('never.granted')
        expect(File.read(path)).to eq(before)
      end
    end

    it 'survives a file that is not a YAML list at all' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(path_in(dir), "some: mapping\n")

        list = allowlist_in(dir)
        expect(list.hosts).to eq([])
        expect(list.allowed?('example.com')).to be false

        # A broken file must not make every fetch ask forever, either: a new
        # grant still works over it.
        list.add('fresh.example')
        expect(allowlist_in(dir).allowed?('fresh.example')).to be true
      end
    end

    it 'survives a file that is not valid YAML' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, '.harness'))
        File.write(path_in(dir), "- 'unclosed\n")

        expect(allowlist_in(dir).hosts).to eq([])
      end
    end
  end

  describe '#candidates (what the dialog is offered)' do
    it 'offers exactly the host it was asked about' do
      Dir.mktmpdir do |dir|
        expect(allowlist_in(dir).candidates('example.com')).to eq(['example.com'])
      end
    end

    # The shell allowlist filters candidates that a broader prefix already
    # covers; matching here is exact, so the only candidate worth hiding is one
    # the user has already granted.
    it 'offers nothing for a host that is already granted' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('example.com')

        expect(list.candidates('example.com')).to eq([])
        expect(list.candidates('Example.Com')).to eq([])
        expect(list.candidates('sub.example.com')).to eq(['sub.example.com'])
      end
    end

    it 'offers nothing for a blank host' do
      Dir.mktmpdir do |dir|
        expect(allowlist_in(dir).candidates('')).to eq([])
        expect(allowlist_in(dir).candidates(nil)).to eq([])
      end
    end
  end

  describe '#hosts (a copy, not the internal list)' do
    it 'cannot be used to mutate the allowlist state' do
      Dir.mktmpdir do |dir|
        list = allowlist_in(dir)
        list.add('example.com')

        list.hosts << 'injected.example'
        expect(list.allowed?('injected.example')).to be false
        expect(allowlist_in(dir).hosts).to eq(['example.com'])
      end
    end
  end
end
