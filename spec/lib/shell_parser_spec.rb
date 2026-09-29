# frozen_string_literal: true

require 'spec_helper'
require 'shell_parser'

RSpec.describe ShellParser do
  describe '.parse' do
    it 'parses a single simple command' do
      expect(described_class.parse('ls')).to eq(['ls'])
    end

    it 'parses a command with arguments' do
      expect(described_class.parse('git log --oneline')).to eq(['git log --oneline'])
    end

    it 'parses a pipeline' do
      expect(described_class.parse('ls | grep x')).to eq(['ls', 'grep x'])
    end

    it 'parses a multi-stage pipeline' do
      expect(described_class.parse('cat file | grep foo | head -5')).to eq(
        ['cat file', 'grep foo', 'head -5']
      )
    end

    it 'parses && chain' do
      expect(described_class.parse('echo hi && pwd')).to eq(['echo hi', 'pwd'])
    end

    it 'parses || chain' do
      expect(described_class.parse('cmd1 || cmd2')).to eq(['cmd1', 'cmd2'])
    end

    it 'parses ; separator' do
      expect(described_class.parse('ls; pwd')).to eq(['ls', 'pwd'])
    end

    it 'parses mixed separators' do
      expect(described_class.parse('bundle exec rspec | grep fail; echo done')).to eq(
        ['bundle exec rspec', 'grep fail', 'echo done']
      )
    end

    it 'parses |& separator' do
      expect(described_class.parse('cmd1 |& cmd2')).to eq(['cmd1', 'cmd2'])
    end

    it 'preserves quoted arguments verbatim' do
      expect(described_class.parse('echo "hello world"')).to eq(['echo "hello world"'])
    end

    it 'handles fd-to-fd redirect as part of the command' do
      expect(described_class.parse('bundle exec rspec 2>&1 | grep fail')).to eq(
        ['bundle exec rspec 2>&1', 'grep fail']
      )
    end

    it 'raises ParseError for file redirect >' do
      expect { described_class.parse('ls > out.txt') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for file redirect >>' do
      expect { described_class.parse('ls >> log') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for input redirect <' do
      expect { described_class.parse('cat < input.txt') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for background &' do
      expect { described_class.parse('sleep 10 &') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for $(...) substitution' do
      expect { described_class.parse('echo $(whoami)') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for backtick substitution' do
      expect { described_class.parse('echo `whoami`') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for subshell ( )' do
      expect { described_class.parse('(ls)') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for variable expansion $' do
      expect { described_class.parse('echo $HOME') }
        .to raise_error(ShellParser::ParseError, /unsafe construct/)
    end

    it 'raises ParseError for empty command' do
      expect { described_class.parse('') }
        .to raise_error(ShellParser::ParseError)
    end

    it 'does NOT flag operators inside single quotes' do
      expect(described_class.parse("grep 'a|b'")).to eq(["grep 'a|b'"])
    end

    it 'does NOT flag operators inside double quotes' do
      expect(described_class.parse('echo "hi && bye"')).to eq(['echo "hi && bye"'])
    end

    it 'handles backslash-escaped pipe as literal' do
      expect(described_class.parse('echo a\\|b')).to eq(['echo a\\|b'])
    end

    it 'parses complex multi-segment command' do
      result = described_class.parse('bundle exec rspec spec/ 2>&1 | grep FAIL && echo done; ls')
      expect(result).to eq(
        ['bundle exec rspec spec/ 2>&1', 'grep FAIL', 'echo done', 'ls']
      )
    end
  end
end
