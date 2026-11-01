# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'sandbox_gemfile'

RSpec.describe SandboxGemfile do
  def sandbox_in(dir)
    described_class.new(dir)
  end

  describe 'the paths' do
    it 'points at .harness/sandbox/Gemfile under the working directory' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        expect(s.dir).to eq(File.join(dir, '.harness', 'sandbox'))
        expect(s.gemfile_path).to eq(File.join(dir, '.harness', 'sandbox', 'Gemfile'))
      end
    end

    it 'exposes the workdir-relative path the model types' do
      Dir.mktmpdir do |dir|
        expect(sandbox_in(dir).relative_gemfile_path).to eq('.harness/sandbox/Gemfile')
      end
    end
  end

  describe 'the starter' do
    # bundle exec isolates the load path, so an empty starter would break even
    # csv/rexml/logger (doc/sandbox_gemfile_design.md); the seed must list gems.
    it 'is not empty and declares the common stdlib-adjacent gems' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        s.ensure_starter!
        text = File.read(s.gemfile_path)

        expect(text).to include('source "https://rubygems.org"')
        %w[csv json rexml logger racc base64].each do |name|
          expect(text).to match(/gem "#{name}"/)
        end
      end
    end

    it 'writes the starter and creates the directory' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        expect(s.exist?).to be false

        expect(s.ensure_starter!).to eq(s.gemfile_path)
        expect(s.exist?).to be true
        expect(File.directory?(s.dir)).to be true
      end
    end
  end

  describe '#ensure_starter!' do
    it 'is idempotent - a second call leaves the file untouched' do
      Dir.mktmpdir do |dir|
        s = sandbox_in(dir)
        s.ensure_starter!
        first = File.read(s.gemfile_path)

        s.ensure_starter!
        expect(File.read(s.gemfile_path)).to eq(first)
      end
    end

    # The harness seeds it but the model manages it: an existing (model-edited)
    # Gemfile is NEVER clobbered, even when it is nothing like the starter.
    it 'never overwrites a model-managed Gemfile' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(sandbox_in(dir).dir)
        managed = "# frozen_string_literal: true\n\ngem 'nokogiri'\n"
        File.write(sandbox_in(dir).gemfile_path, managed)

        sandbox_in(dir).ensure_starter!
        expect(File.read(sandbox_in(dir).gemfile_path)).to eq(managed)
      end
    end
  end
end
