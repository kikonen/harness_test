# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'session_locator'
require 'tools/sessions_search_tool'

# issue #279: the model cannot find a saved session by what it was ABOUT from
# /sessions alone (it only counts them). sessions.search reads each saved
# session's message text and shows a window around a hit, so "the session
# where I was doing X" has an answer. Read-only: it never resumes or deletes.
RSpec.describe Tools::SessionsSearchTool do
  let(:workdir) { Dir.mktmpdir('sessions-search-spec') }
  after { FileUtils.remove_entry(workdir) if File.directory?(workdir) }

  def tool
    described_class.new(SessionLocator.new(workdir))
  end

  def seed_session(id, contents:, saved_at: Time.now)
    dir  = File.join(workdir, '.harness', 'sessions', id)
    path = File.join(dir, 'session.json')
    FileUtils.mkdir_p(dir)
    data = {
      session_id: id,
      workdir:,
      messages: contents.map { |c| { role: 'user', content: c } }
    }
    File.write(path, JSON.generate(data))
    File.utime(saved_at, saved_at, path)
  end

  it 'has the sessions.search name and a required query argument' do
    expect(tool.name).to eq('sessions.search')
    expect(tool.namespace).to eq('sessions')
    expect(tool.parameters[:required]).to eq(['query'])
  end

  it 'matches a session by its message content and reports id, counts and a snippet' do
    seed_session('aaaaaaaa-bbbb-cccc-dddd-111111111111',
                 contents: ['first line', 'we refactored the auth flow here', 'done'])

    out = tool.execute('query' => 'auth')

    expect(out).to start_with('Sessions matching "auth" (1)')
    expect(out).to include('aaaaaaaa-bbbb-cccc-dddd-111111111111')
    expect(out).to include('3 messages, 1 hit(s)')
    expect(out).to include('we refactored the auth flow here')
  end

  it 'is case-insensitive' do
    seed_session('aaaaaaaa-bbbb-cccc-dddd-111111111111', contents: ['Refactor Authentication'])

    expect(tool.execute('query' => 'authentication')).to include('Refactor Authentication')
  end

  it 'matches an abbreviated id too' do
    seed_session('deadbeef-1111-2222-3333-444444444444', contents: ['nothing relevant'])

    expect(tool.execute('query' => 'deadbeef'))
      .to include('deadbeef-1111-2222-3333-444444444444')
  end

  it 'counts several hits in one session but shows only one window' do
    seed_session('aaaaaaaa-bbbb-cccc-dddd-111111111111',
                 contents: ['deploy the api', 'the api is up', 'ship it'])

    out = tool.execute('query' => 'api')

    expect(out).to include('2 hit(s)')
  end

  it 'returns matches newest first' do
    seed_session('older-1111-2222-3333-444444444444', contents: ['about kubernetes'],
                 saved_at: Time.now - 100)
    seed_session('newer-0000-1111-2222-333333333333', contents: ['about kubernetes again'],
                 saved_at: Time.now)

    out = tool.execute('query' => 'kubernetes')

    expect(out.index('newer-0000')).to be < out.index('older-1111')
  end

  it 'reports no match and points at /sessions' do
    seed_session('aaaaaaaa-bbbb-cccc-dddd-111111111111', contents: ['unrelated'])

    out = tool.execute('query' => 'zzz')

    expect(out).to start_with('no saved sessions match "zzz"')
    expect(out).to include('/sessions')
  end

  it 'refuses an empty query' do
    out = tool.execute('query' => '   ')

    expect(out).to start_with('error:')
    expect(out).to include('non-empty query')
  end

  it 'skips an unreadable session file instead of raising' do
    dir = File.join(workdir, '.harness', 'sessions', 'broken-1111-2222-3333-444444444444')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'session.json'), '{ not valid json')
    seed_session('good-0000-1111-2222-333333333333', contents: ['kubernetes rules'])

    out = tool.execute('query' => 'kubernetes')

    expect(out).to include('good-0000')
    expect(out).not_to include('broken')
  end
end
