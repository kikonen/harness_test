# frozen_string_literal: true

require 'spec_helper'
require 'shell_tokenizer'

RSpec.describe ShellTokenizer do
  def tokenize(cmd)
    described_class.tokenize(cmd)
  end

  def kinds(cmd)
    tokenize(cmd).map(&:first)
  end

  describe '.tokenize' do
    it 'splits a simple command into word tokens' do
      expect(tokenize('ls -la')).to eq([[:word, 'ls'], [:word, '-la']])
    end

    it 'recognizes pipe separator' do
      expect(kinds('ls | grep x')).to eq(%i[word pipe word word])
    end

    it 'recognizes && separator' do
      expect(kinds('echo hi && pwd')).to eq(%i[word word and word])
    end

    it 'recognizes || separator' do
      expect(kinds('cmd1 || cmd2')).to eq(%i[word or word])
    end

    it 'recognizes ; separator' do
      expect(kinds('ls; pwd')).to eq(%i[word semi word])
    end

    it 'recognizes |& separator' do
      expect(kinds('cmd1 |& cmd2')).to eq(%i[word pipe_and word])
    end

    it 'emits :danger for file redirect >' do
      expect(kinds('ls > out.txt')).to include(:danger)
    end

    it 'emits :danger for file redirect >>' do
      expect(kinds('ls >> log')).to include(:danger)
    end

    it 'emits :danger for file redirect <' do
      expect(kinds('cmd < input.txt')).to include(:danger)
    end

    it 'emits :danger for background &' do
      expect(kinds('sleep 10 &')).to include(:danger)
    end

    it 'emits :danger for $(...) substitution' do
      expect(kinds('echo $(whoami)')).to include(:danger)
    end

    it 'emits :danger for backtick substitution' do
      expect(kinds('echo `whoami`')).to include(:danger)
    end

    it 'emits :danger for subshell ( )' do
      expect(kinds('(ls)')).to include(:danger)
    end

    it 'emits :danger for $ variable' do
      expect(kinds('echo $HOME')).to include(:danger)
    end

    it 'treats fd-to-fd redirect 2>&1 as a word' do
      tokens = tokenize('bundle exec rspec 2>&1')
      expect(tokens).to eq([
        [:word, 'bundle'], [:word, 'exec'],
        [:word, 'rspec'],   [:word, '2>&1']
      ])
    end

    it 'treats redirect to /dev/null (>) as a word' do
      tokens = tokenize('grep foo > /dev/null')
      expect(tokens).to eq([
        [:word, 'grep'], [:word, 'foo'], [:word, '> /dev/null']
      ])
    end

    it 'treats fd redirect to /dev/null (2>/dev/null) as a word' do
      tokens = tokenize('bundle exec rspec 2>/dev/null')
      expect(tokens).to eq([
        [:word, 'bundle'], [:word, 'exec'],
        [:word, 'rspec'],  [:word, '2>/dev/null']
      ])
    end

    it 'treats append redirect to /dev/null (>>) as a word' do
      expect(kinds('cmd >> /dev/null')).to eq(%i[word word])
    end

    it 'emits :danger for combined &> redirect naming the full construct' do
      tokens = tokenize('run test &> build.log')
      expect(tokens).to include([:danger, '&> build.log'])
    end

    it 'emits :danger for combined &>> append redirect' do
      expect(kinds('run test &>> build.log')).to include(:danger)
    end

    it 'treats &> /dev/null as a word (output only discarded)' do
      tokens = tokenize('grep foo &> /dev/null')
      expect(tokens).to eq(
        [[:word, 'grep'], [:word, 'foo'], [:word, '&> /dev/null']]
      )
    end

    it 'still emits :danger for background &' do
      expect(kinds('sleep 10 &')).to include(:danger)
    end

    it 'keeps && as and-list, not a redirect' do
      expect(kinds('ls && pwd')).to eq(%i[word and word])
    end

    it 'does not confuse fd-redirect 2>&1 with &> (digit guard)' do
      # "2" + ">&1" must still glue to the word "2>&1"; the & branch must
      # not misfire when a digit precedes the operator.
      tokens = tokenize('bundle exec rspec 2>&1')
      expect(tokens).to eq([
        [:word, 'bundle'], [:word, 'exec'],
        [:word, 'rspec'],   [:word, '2>&1']
      ])
    end
    it 'still emits :danger for redirect to a real file' do
      expect(kinds('ls > out.txt')).to include(:danger)
    end

    it 'still emits :danger for redirect to /dev/null-like but different path' do
      expect(kinds('cmd > /dev/zero')).to include(:danger)
    end

    it 'treats operators inside single quotes as literal words' do
      tokens = tokenize("grep 'a|b'")
      expect(tokens).to eq([[:word, 'grep'], [:word, "'a|b'"]])
    end

    it 'treats operators inside double quotes as literal words' do
      tokens = tokenize('echo "hi && bye"')
      expect(tokens).to eq([[:word, 'echo'], [:word, '"hi && bye"']])
    end

    it 'handles backslash-escaped pipe as part of a word' do
      tokens = tokenize('echo a\\|b')
      expect(tokens).to eq([[:word, 'echo'], [:word, 'a\\|b']])
    end

    it 'handles multiple separators in sequence' do
      expect(kinds('a | b && c; d || e')).to eq(
        %i[word pipe word and word semi word or word]
      )
    end

    it 'returns empty array for empty string' do
      expect(tokenize('')).to eq([])
    end

    it 'handles leading/trailing whitespace' do
      expect(tokenize('  ls   ')).to eq([[:word, 'ls']])
    end

    it 'handles adjacent quoted and bare words (parser joins them)' do
      tokens = tokenize('foo"bar baz"')
      # Tokenizer emits separate word tokens; ShellParser joins consecutive
      # words into one segment.
      expect(tokens).to eq([[:word, 'foo'], [:word, '"bar baz"']])
    end

    it 'emits :danger for unterminated single quote' do
      expect(kinds("echo 'unterminated")).to include(:danger)
    end

    it 'emits :danger for unterminated double quote' do
      expect(kinds('echo "unterminated')).to include(:danger)
    end
  end
end
