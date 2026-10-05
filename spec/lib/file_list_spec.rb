# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

RSpec.describe FileList do
  # Drive the grant dialog without any real I/O: intercept Dialog#show and
  # perform it on StringIO streams we control. grant_access passes
  # ui: nil (task-thread contract), so the stub must NOT
  # call through to show - it performs the direct I/O itself. Returns
  # [grant result, dialog output].
  def drive_grant_dialog(list, *lines)
    stdin  = StringIO.new(lines.join("\n"))
    stdout = StringIO.new
    allow_any_instance_of(UI::Dialog).to receive(:show) do |dialog|
      dialog.perform_direct(ui: UI::Console.new(stdout: stdout, stdin: stdin))
    end
    result = list.grant_access(*@grant_args)
    [result, stdout.string]
  end

  describe '#grant_access denial' do
    it 'returns { status: :denied, note: nil } for a plain cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        # file prompt: 1=file, 2=parent flat, 3=parent recursive, 4=cancel
        result, _out = drive_grant_dialog(list, "4\n")
        expect(result).to eq({ status: :denied, note: nil })
      end
    end

    it 'carries the user\'s note on a noted cancel' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        result, _out = drive_grant_dialog(list, "4 no, and because X\n")
        expect(result).to eq({ status: :denied, note: 'no, and because X' })
      end
    end

    it 'still returns :granted when the user allows' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['secret.txt', :r]
        # file prompt option 1 = allow this file only
        result, _out = drive_grant_dialog(list, "1\n")
        expect(result).to eq(:granted)
      end
    end
  end

  describe '#grant_access for a new directory (issue #54)' do
    it 'offers the target directory itself as the first option' do
      Dir.mktmpdir do |dir|
        list = described_class.new(workdir: dir)
        @grant_args = ['newdir', :w]
        result, _out = drive_grant_dialog(list, "1\n")
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
        @grant_args = ['newdir', :w]
        # 1=target, 2=parent flat, 3=parent recursive
        result, _out = drive_grant_dialog(list, "3\n")
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
