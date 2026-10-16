# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'commands/sessions_command'

# issue #276: listing saved sessions is path + JSON reading, so it needs no
# harness at all - CLI's --list-sessions runs this command with harness: nil,
# before any Harness is constructed (the old path built a whole Harness,
# minting a fresh random session id on the way to reading a few files).
RSpec.describe Commands::SessionsCommand do
  let(:workdir) { Dir.mktmpdir('sessions-cmd-spec') }
  let(:file_list) { FileList.new([], workdir: workdir) }
  let(:sid) { 'f7931611-30b4-4b4b-aec6-f7083ef2942a' }

  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  def seed_saved_session(id, saved_at: Time.now, messages: 1)
    dir = File.join(workdir, '.harness', 'sessions', id)
    FileUtils.mkdir_p(dir)
    data = { session_id: id, workdir: workdir,
             messages: Array.new(messages) { |i| { role: 'user', content: "m#{i}" } },
             files: ['lib/a.rb'] }
    path = File.join(dir, 'session.json')
    File.write(path, JSON.generate(data))
    File.utime(saved_at, saved_at, path)
  end

  # harness: nil is the point of this helper - the command must not need one.
  def run_command
    io      = StringIO.new
    command = described_class.new(harness: nil, file_list: file_list,
                                  options: nil, ui: UI::Console.new(stdout: io))
    command.handle('')
    io.string
  end

  it 'lists a saved session with its id, save time and counts' do
    seed_saved_session(sid)

    out = run_command

    expect(out).to include('Saved sessions (1):')
    expect(out).to include(sid)
    expect(out).to include('1 messages, 1 file(s)')
    expect(out).to include(workdir)
    expect(out).to include('/resume <id>')
  end

  it 'names the sessions dir when nothing is saved' do
    sessions_dir = File.join(workdir, '.harness', 'sessions')

    expect(run_command).to include("No saved sessions (#{sessions_dir})")
  end

  it 'creates no session directory while listing' do
    seed_saved_session(sid)
    run_command

    expect(Dir.children(File.join(workdir, '.harness', 'sessions'))).to eq([sid])
  end
end
