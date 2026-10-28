# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'fileutils'
require 'tmpdir'
require 'commands/grant_command'

# issue #101: /grant shows ALL current grants in one place - file/dir access
# grants (read, write, delete) and command allowlist prefixes - replacing
# the constant grant display that used to be printed above every prompt.
RSpec.describe Commands::GrantCommand do
  let(:workdir) { Dir.mktmpdir }
  after { FileUtils.remove_entry(workdir) }

  let(:file_list) { FileList.new([], workdir: workdir) }

  # Commands write to an explicit stream (TUI-ready), so the spec supplies a
  # StringIO and reads it back instead of swapping $stdout.
  def run_command
    io      = StringIO.new
    command = described_class.new(harness: nil, file_list:, options: nil, ui: UI::Console.new(stdout: io))
    command.handle('')
    io.string
  end

  it 'lists file, dir and flat-dir grants grouped by mode' do
    file_list.add_file('lib/foo.rb', :r)
    file_list.add_dir('spec', :rw)
    file_list.add_flat_dir('tmp', :d)

    out = run_command

    expect(out).to include('Read only:')
    expect(out).to include('1. lib/foo.rb')
    expect(out).to include('Read + write:')
    expect(out).to include('spec/ (recursive)')
    expect(out).to include('Delete:')
    expect(out).to include('tmp/ (dir only)')
  end

  it 'shows a placeholder when no file/dir grants exist' do
    out = run_command

    expect(out).to include('Commands: (none allowed)')
    # No read/write/delete sections should be printed at all.
    expect(out).not_to include('Read only:')
    expect(out).not_to include('Delete:')
  end

  it 'lists the command allowlist prefixes' do
    CommandAllowlist.new(workdir).add('git log')
    shell = CommandAllowlist.new(workdir,
                                 file: CommandAllowlist::SHELL_FILENAME)
    shell.add('ls -la')

    out = run_command

    expect(out).to include('Commands for run.command:')
    expect(out).to include('- git log')
    expect(out).to include('Commands for shell (!):')
    expect(out).to include('- ls -la')
  end

  it 'reports no allowed commands when the allowlist is empty' do
    out = run_command

    expect(out).to include('Commands: (none allowed)')
    expect(out).not_to include('Commands for run.command:')
  end

  it 'shows only the non-empty command list' do
    CommandAllowlist.new(workdir).add('git log')

    out = run_command

    expect(out).to include('Commands for run.command:')
    expect(out).to include('- git log')
    expect(out).not_to include('Commands for shell (!):')
  end

  # issue #33: a web.fetch host grant is security state like the command
  # allowlists, so /grant must show it - a user reviewing "what is allowed"
  # should not have to know that a second grant system exists.
  it 'lists the web.fetch host grants' do
    WebHostAllowlist.new(workdir).add('api.example.com')
    WebHostAllowlist.new(workdir).add('docs.example.org')

    out = run_command

    expect(out).to include('Hosts for web.fetch (exact hosts only):')
    expect(out).to include('- api.example.com')
    expect(out).to include('- docs.example.org')
  end

  it 'says nothing about hosts when none are granted, and keeps the command placeholder' do
    CommandAllowlist.new(workdir).add('git log')

    out = run_command

    expect(out).not_to include('Hosts for web.fetch')
    # The placeholder means "no commands", so a host grant must not swallow it.
    expect(out).not_to include('Commands: (none allowed)')
  end

  # issue #274: YOLO auto-covers file access inside the working directory, and a
  # posture that approves without asking must be visible exactly where a user
  # reviews what a run may touch. It is a POSTURE line, never a grant entry -
  # a session saves grants, so a posture must not land in them.
  context 'with the YOLO posture on' do
    before do
      file_list.posture = -> { true }
    end

    it 'shows the posture coverage line' do
      out = run_command

      expect(out).to include('Posture (YOLO):')
      expect(out).to include('not a stored grant')
      # The dirs the posture leaves asking are named (issue #385); the default
      # FileList here protects local/.
      expect(out).to include('except sensitive paths and local/')
      expect(out).not_to include('Read only:')
    end

    it 'keeps the posture line separate from the stored grants' do
      file_list.add_dir('spec', :rw)

      out = run_command

      expect(out).to include('Read + write:')
      expect(out).to include('spec/ (recursive)')
      expect(out.lines.index { |l| l.include?('Read + write:') })
        .to be < out.lines.index { |l| l.include?('Posture (YOLO):') }
    end
  end
end
