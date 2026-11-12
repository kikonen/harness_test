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
  let(:fixed_saved_at) { Time.new(2026, 1, 1, 10, 0, 0) }

  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  def seed_saved_session(id, saved_at: fixed_saved_at, messages: 1)
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

  # Split a markdown table row (`| a | b |`) into its cells. The field
  # boundaries survive to the output as real delimiters - the point of #474 -
  # rather than a fused string a sink would have to regex apart.
  def split_table_row(line)
    line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split(/\s*\|\s*/).map(&:strip)
  end

  # The listing is a :table (#474). This sink has no palette, so it renders the
  # raw markdown table form (the re-lay-out-able DATA the buffer keeps; a colored
  # sink would get the kramdown box instead). Columns are asserted by splitting
  # each row on the | delimiters - the field boundaries survive to the output,
  # robust to the tmpdir's variable workdir width.
  it 'lists a saved session as a markdown :table (header, rule, one row)' do
    seed_saved_session(sid)

    lines = run_command.lines.map(&:chomp)

    expect(lines).to include('Saved sessions (1):')
    header = lines.find { |l| l.start_with?('|') && l.include?('workdir') }
    expect(split_table_row(header)).to eq(%w[id saved messages files workdir])
    expect(lines).to include(a_string_matching(/\A\| [-| ]+\|\z/)) # the markdown rule row
    row = lines.find { |l| l.include?(sid) }
    expect(split_table_row(row)).to eq([sid, '2026-01-01 10:00:00', '1', '1', workdir])
    expect(lines.last).to include('/resume <id>')
  end

  it 'names the sessions dir when nothing is saved' do
    sessions_dir = File.join(workdir, '.harness', 'sessions')

    # A :note now owns the wrap, so a long path lands on a continuation line;
    # rejoin the renderer's lines before matching the sentence.
    out = run_command.lines.map(&:chomp).map { |l| l.delete_prefix("  ") }.join(" ")

    expect(out).to eq("No saved sessions (#{sessions_dir}).")
  end

  it 'creates no session directory while listing' do
    seed_saved_session(sid)
    run_command

    expect(Dir.children(File.join(workdir, '.harness', 'sessions'))).to eq([sid])
  end
end
