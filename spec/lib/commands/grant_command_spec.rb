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
    command = described_class.new(harness: nil, file_list:, options: nil, stdout: io)
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
    allowlist = CommandAllowlist.new(workdir)
    allowlist.add('git log')
    allowlist.add('bundle exec rspec')

    out = run_command

    expect(out).to include('Commands (auto-approved prefixes):')
    expect(out).to include('1. git log')
    expect(out).to include('2. bundle exec rspec')
  end

  it 'reports no allowed commands when the allowlist is empty' do
    out = run_command

    expect(out).to include('Commands: (none allowed)')
  end
end
