# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'tools/file_read_tool'
require 'tools/dir_create_tool'

RSpec.describe Tool do
  describe '.denial_error' do
    it 'returns the plain message when there is no result' do
      expect(described_class.denial_error("error: access denied for 'x'"))
        .to eq("error: access denied for 'x'")
    end

    it 'returns the plain message for a denial without a note' do
      result = { status: :denied, note: nil }
      expect(described_class.denial_error("error: access denied for 'x'", result))
        .to eq("error: access denied for 'x'")
    end

    it 'appends the user\'s note when present' do
      result = { status: :denied, note: 'no, and because X' }
      expect(described_class.denial_error("error: access denied for 'x'", result))
        .to eq("error: access denied for 'x' (user's note: \"no, and because X\")")
    end

    it 'is safe for legacy :denied symbols' do
      expect(described_class.denial_error("error: access denied for 'x'", :denied))
        .to eq("error: access denied for 'x'")
    end

    it 'ignores non-denial results' do
      expect(described_class.denial_error("error: x", :granted))
        .to eq('error: x')
    end
  end

  describe '.granted?' do
    it 'is true only for :granted' do
      expect(described_class.granted?(:granted)).to be(true)
      expect(described_class.granted?({ status: :denied, note: nil })).to be(false)
      expect(described_class.granted?(:blocked)).to be(false)
    end
  end
end

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
end

RSpec.describe FileReadTool do
  it 'forwards the user\'s denial note to the model' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list)
      allow($stdin).to receive(:gets)
        .and_return("4 put tests under lib, not spec\n", nil)

      out = tool.execute('path' => 'secret.txt')
      expect(out).to start_with('error: access denied for')
      expect(out).to include('user\'s note: "put tests under lib, not spec"')
    end
  end

  it 'returns a plain denial when the user cancels without a note' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list)
      allow($stdin).to receive(:gets).and_return("4\n", nil)

      out = tool.execute('path' => 'secret.txt')
      expect(out).to eq("error: access denied for 'secret.txt'")
    end
  end
end

RSpec.describe DirCreateTool do
  it 'forwards the user\'s denial note for the parent dir grant' do
    Dir.mktmpdir do |dir|
      list = FileList.new(workdir: dir)
      tool = described_class.new(list, {})
      allow($stdin).to receive(:gets)
        .and_return("3 nope, use a different layout\n", nil) # grant target is the PARENT (existing dir) -> dir prompt: 1=flat, 2=recursive, 3=cancel

      out = tool.execute('path' => 'newdir')
      expect(out).to start_with('error: write access denied')
      expect(out).to include('user\'s note: "nope, use a different layout"')
    end
  end
end