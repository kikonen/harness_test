# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

RSpec.describe FileList do
  # Feed a sequence of lines to $stdin (last element nil = EOF).
  def stub_stdin(*lines)
    allow($stdin).to receive(:gets).and_return(*lines)
  end

  describe '#grant_access denial' do
    it 'returns { status: :denied, note: nil } for a plain cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        stub_stdin("4\n") # file prompt: 1=file, 2=parent flat, 3=parent recursive, 4=cancel
        result = list.grant_access('secret.txt', :r)
        expect(result).to eq({ status: :denied, note: nil })
      end
    end

    it 'carries the user\'s note on a noted cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        stub_stdin("4 no, and because X\n")
        result = list.grant_access('secret.txt', :r)
        expect(result).to eq({ status: :denied, note: 'no, and because X' })
      end
    end

    it 'still returns :granted when the user allows' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        stub_stdin("1\n") # file prompt option 1 = allow this file only
        result = list.grant_access('secret.txt', :r)
        expect(result).to eq(:granted)
      end
    end
  end

  describe '#grant_access for a new directory (issue #54)' do
    it 'offers the target directory itself as the first option' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        stub_stdin("1\n")
        result = list.grant_access('newdir', :w)
        expect(result).to eq(:granted)
        # The grant must be on the TARGET, not the parent: existing siblings
        # of the parent stay non-writable.
        expect(list.writable?('newdir')).to be(true)
        expect(list.writable?('sibling.txt')).to be(false)
      end
    end

    it 'still allows a parent-dir grant when the user prefers one' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        stub_stdin("3\n") # 1=target, 2=parent flat, 3=parent recursive
        result = list.grant_access('newdir', :w)
        expect(result).to eq(:granted)
        expect(list.writable?('newdir')).to be(true)
        expect(list.writable?('sibling.txt')).to be(true)
      end
    end
  end

  describe '#deletable? (issue #92)' do
    it 'is independent of read and write grants' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :rw)
        expect(list.readable?('a.txt')).to be(true)
        expect(list.writable?('a.txt')).to be(true)
        expect(list.deletable?('a.txt')).to be(false)
      end
    end

    it 'grants delete on a file and does not imply read/write' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :d)
        expect(list.deletable?('a.txt')).to be(true)
        expect(list.readable?('a.txt')).to be(false)
        expect(list.writable?('a.txt')).to be(false)
      end
    end

    it 'honours recursive and flat directory delete grants' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_dir('sub', :d)
        expect(list.deletable?('sub/nested/x.txt')).to be(true)

        flat = described_class.new(workdir: dir)
        flat.add_flat_dir('sub', :d)
        expect(flat.deletable?('sub/top.txt')).to be(true)
        expect(flat.deletable?('sub/nested/x.txt')).to be(false)
      end
    end

    it 'exposes delete grants in accessible_paths under a delete section' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        list.add_file('a.txt', :d)
        access = list.accessible_paths
        expect(access[:delete][:files]).to include(list.resolve('a.txt'))
        expect(access[:both][:files] + access[:read][:files] + access[:write][:files])
          .not_to include(list.resolve('a.txt'))
      end
    end
  end
end
