# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'ui/external_editor'

# issue #298: the external-editor round-trip. These run a REAL child process (a
# tiny stand-in editor script), because the two facts that matter - the command
# is exec'd as argv words (no shell), and a child that cannot run leaves the
# draft intact - are exactly what a stubbed spawn would hide.
RSpec.describe UI::ExternalEditor do
  # A stand-in editor: rewrites the draft file named by ARGV[0] (extra argv
  # words are ignored, as a real editor ignores its own flags), exits 3 when
  # EDITOR_FAIL is set. Written once per example into the temp dir.
  def fake_editor(dir)
    script = File.join(dir, 'fake_editor.rb')
    File.write(script, <<~RUBY)
      # The harness spawns  <program> <extra argv...> <draft-path>, so the draft
      # is the LAST argument and everything before it is the editor's own flags.
      path = ARGV.last
      before = File.binread(path)
      File.binwrite(path, "EDITED(\#{ARGV.size - 1}):\\n\#{before}appended\\n")
      exit(3) if ENV['EDITOR_FAIL']
    RUBY
    script
  end

  describe '.command (resolution order)' do
    it 'is nil when nothing is set' do
      expect(described_class.command(nil, env: {})).to be_nil
    end

    it 'reads the config key when no ENV tier is set' do
      expect(described_class.command('cfg', env: {})).to eq('cfg')
    end

    it 'HARNESS_EDITOR beats the config key and EDITOR' do
      env = { 'HARNESS_EDITOR' => 'har', 'EDITOR' => 'ed' }

      expect(described_class.command('cfg', env: env)).to eq('har')
    end

    it 'EDITOR beats VISUAL' do
      expect(described_class.command(nil, env: { 'EDITOR' => 'ed', 'VISUAL' => 'vi' }))
        .to eq('ed')
    end

    it 'skips a blank tier and falls to the next one' do
      expect(described_class.command('cfg', env: { 'HARNESS_EDITOR' => '   ' })).to eq('cfg')
    end
  end

  describe '#program / #available?' do
    it 'program is the first argv word' do
      expect(described_class.new('nvim -R --headless').program).to eq('nvim')
    end

    it 'a command with no program word is not available' do
      expect(described_class.new('').available?).to be(false)
      expect(described_class.new('"unclosed').available?).to be(false)
      expect(described_class.new('nvim').available?).to be(true)
    end
  end

  describe '#open (round-trip with a real editor)' do
    around do |ex|
      Dir.mktmpdir { |dir| @dir = dir; @script = fake_editor(dir); ex.run }
    end

    it 'writes the draft, runs the editor and returns what it wrote' do
      r = described_class.new("ruby #{@script}").open("first\nsecond")

      expect(r.status).to eq(:ok)
      expect(r.note).to eq("edited with ruby")
      expect(r.text).to include('first')
      expect(r.text).to include('appended')
    end

    it 'hands back LF text even when the draft carried CRLF (file boundary)' do
      r = described_class.new("ruby #{@script}").open("a\r\nb")

      expect(r.status).to eq(:ok)
      expect(r.text).not_to include("\r")
    end

    it 'preserves the draft when the editor exits non-zero' do
      ENV['EDITOR_FAIL'] = '1'
      begin
        r = described_class.new("ruby #{@script}").open('my draft')

        expect(r.status).to eq(:error)
        expect(r.note).to include('exited with status 3')
        expect(r.text).to eq('my draft') # what the user typed is not swallowed
      ensure
        ENV.delete('EDITOR_FAIL')
      end
    end

    it 'reports :error (draft intact) when the program cannot be started' do
      r = described_class.new('definitely-not-a-program-xyz').open('my draft')

      expect(r.status).to eq(:error)
      expect(r.note).to include('could not run definitely-not-a-program-xyz')
      expect(r.text).to eq('my draft')
    end

    it 'answers :unavailable (draft intact) when there is no program to run' do
      r = described_class.new('').open('my draft')

      expect(r.status).to eq(:unavailable)
      expect(r.note).to include('no editor command')
      expect(r.text).to eq('my draft')
    end

    # The command is exec'd as argv words, never through a shell: a && and a
    # quoted word are handed to the child as LITERAL arguments, so the shell's
    # second command never runs.
    it 'does not run a shell: && and quotes stay literal argv words' do
      cmd  = "ruby #{@script} --flag 'with space' && echo SHELL_RAN"
      r    = described_class.new(cmd).open('x')

      expect(r.text).not_to include('SHELL_RAN')
      # The editor saw the literal words as extra argv (ARGV.size - 1 == 5).
      expect(r.text).to include('EDITED(5)')
    end

    it 'leaves no scratch directory behind, even on a failing editor' do
      # Both the editor's scratch dir and this example's leftover scan have to
      # land in a PRIVATE temp root: a concurrent rspec process (parallel suite
      # runs, issue #396) holds its own live harness-editor* dir in the shared
      # one at the same moment. All three vars because Dir.tmpdir prefers
      # TMP/TEMP over TMPDIR on Windows.
      %w[TMP TEMP TMPDIR].each { |k| ENV[k] = @dir }
      ENV['EDITOR_FAIL'] = '1'
      begin
        described_class.new("ruby #{@script}").open('d')
      ensure
        ENV.delete('EDITOR_FAIL')
        %w[TMP TEMP TMPDIR].each { |k| ENV.delete(k) }
      end

      leftovers = Dir.glob(File.join(Dir.tmpdir, 'harness-editor*'))
      expect(leftovers).to eq([])
    end
  end
end
