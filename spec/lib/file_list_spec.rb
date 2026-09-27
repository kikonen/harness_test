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
end
