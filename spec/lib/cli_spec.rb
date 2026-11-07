# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'reline'
require 'cli'

# issue #189: the startup banner shows the session id and where its log is
# written, so the user can find harness.log without guessing.
#
# issue #276: the rest of this file covers the bootstrap ORDER - the session
# id is resolved before the Harness is constructed, so the log file, the
# history file and the session directory are all created under ONE id.

RSpec.describe CLI do
  let(:workdir) { Dir.mktmpdir }
  let(:ui) { instance_double(UI::Console) }
  let(:options) do
    {
      workdir:   workdir,
      base_url:  'http://localhost:11434/v1',
      model:     'test-model',
      system_file: Harness::DEFAULT_SYSTEM_PROMPT_FILE
    }
  end

  def build_cli
    described_class.new(options, ui)
  end

  # run reads the idle prompt through PromptReader; a #run spec that only
  # checks the banner stubs it so the loop exits at once (read => nil).
  def stub_prompt_reader
    reader = instance_double(PromptReader, read: nil)
    allow(PromptReader).to receive(:new).and_return(reader)
  end

  # Seed a saved session in the issue #207 layout (issue #276) so a resume has
  # something real to resolve: <sessions>/<id>/session.json. active_model is
  # nil by default - the "use whatever the config default is" state - because
  # these specs are about identity, not model profiles.
  def seed_saved_session(id, model: nil, yolo: false)
    dir  = File.join(workdir, '.harness', 'sessions', id)
    FileUtils.mkdir_p(dir)
    data = {
      session_id:    id,
      created_at:    Time.now.iso8601,
      system_prompt: 'saved system prompt',
      user_prompts:  3,
      messages:      [{ role: 'system', content: 'saved system prompt' },
                      { role: 'user', content: 'earlier prompt' },
                      { role: 'assistant', content: 'earlier reply' }],
      active_model:  model,
      yolo:          yolo,
      workdir:       workdir
    }
    File.write(File.join(dir, 'session.json'), JSON.generate(data))
    dir
  end

  # A saved session WITH grants, so a resumed run has something to restore onto
  # its own FileList. Shared by the /resume specs and the standing-grant specs
  # (issue #384), so it lives at the top level like #seed_saved_session.
  def seed_saved_session_with_grants(id)
    dir  = File.join(workdir, '.harness', 'sessions', id)
    FileUtils.mkdir_p(dir)
    data = {
      session_id:    id,
      created_at:    Time.now.iso8601,
      system_prompt: 'saved system prompt',
      user_prompts:  2,
      messages:      [{ role: 'system', content: 'saved system prompt' },
                      { role: 'user', content: 'earlier prompt' }],
      yolo:          true,
      workdir:       workdir,
      access:        { both:  { files: ['lib/foo.rb'], dirs: [], flat_dirs: [] },
                       read:  { files: [], dirs: ['spec/lib'], flat_dirs: [] },
                       write: { files: [], dirs: [], flat_dirs: [] },
                       delete: { files: [], dirs: [], flat_dirs: [] } }
    }
    File.write(File.join(dir, 'session.json'), JSON.generate(data))
  end

  def session_dirs
    dir = File.join(workdir, '.harness', 'sessions')
    Dir.exist?(dir) ? Dir.children(dir).sort : []
  end

  # issue #276: identity is resolved before anything derived from it is
  # constructed, so on EVERY startup path the log file, the history file and
  # the session directory all sit under the same single id.
  describe 'identity-first bootstrap (issue #276)' do
    it 'a fresh run puts log, history and session dir under its own id' do
      cli  = build_cli
      id   = cli.harness.session.session_id

      expect(session_dirs).to eq([id])
      expect(File.file?(cli.harness.session_log_path)).to be true
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', id, 'harness_history')
      )
    end

    it '--resume puts log, history and session dir under the RESUMED id' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(saved)

      cli = described_class.new(options.merge(resume: saved[0, 8]), ui)
      id  = cli.harness.session.session_id

      expect(id).to eq(saved)
      # Issue #135's symptom: a second (throwaway) directory for the fresh
      # random id the run threw away. There is no longer a fresh id to throw.
      expect(session_dirs).to eq([saved])
      expect(File.file?(cli.harness.session_log_path)).to be true
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', saved, 'harness_history')
      )
    end

    it '--continue resolves the newest saved session before constructing' do
      older = '11111111-2222-3333-4444-555555555555'
      newer = '66666666-7777-8888-9999-000000000000'
      seed_saved_session(older)
      seed_saved_session(newer)
      File.utime(Time.now - 60, Time.now - 60,
                 File.join(workdir, '.harness', 'sessions', older, 'session.json'))

      cli = described_class.new(options.merge(continue: true), ui)

      expect(cli.harness.session.session_id).to eq(newer)
      # Same single id for log, history and the session dir - and only the two
      # REAL sessions exist (no third one minted for this run).
      expect(session_dirs).to eq([older, newer])
      expect(cli.harness.session_log_path)
        .to eq(File.join(workdir, '.harness', 'sessions', newer, 'harness.log'))
      expect(File.file?(cli.harness.session_log_path)).to be true
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', newer, 'harness_history')
      )
    end

    it 'a typo in --resume raises BEFORE any session directory exists' do
      expect {
        described_class.new(options.merge(resume: 'deadbeef'), ui)
      }.to raise_error(HarnessError, /no saved session matching 'deadbeef'/)

      # Nothing was built under a random id on the way to the failure.
      expect(session_dirs).to eq([])
    end

    it '--list-sessions lists from the locator without constructing a Harness' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(saved)
      allow(ui).to receive(:puts)

      # issue #299: initialize records the listing mode and returns BEFORE
      # setup, so no Harness is built and no session dir is minted; #run
      # dispatches the listing and returns the exit status the entry point
      # turns into exit. No SystemExit around CLI.new any more.
      cli = described_class.new(options.merge(list_sessions: true, model: nil), ui)
      expect(cli.harness).to be_nil
      expect(cli.run).to eq(0)

      expect(ui).to have_received(:puts).with(/Saved sessions \(1\)/)
      expect(ui).to have_received(:puts).with(/#{Regexp.escape(saved)}/)
      # Listing used to mint a fresh random id on the way (a Harness was
      # constructed to read JSON files). It must not create any session dir.
      expect(session_dirs).to eq([saved])
    end
  end

  # issue #279: --delete-session removes one saved session and stops. Same
  # no-Harness shape as --list-sessions: no session dir is minted, the run
  # never builds a Harness, and a bad id raises HarnessError before deleting.
  describe 'delete-session mode (issue #279)' do
    it 'removes the whole session dir and exits 0 without building a Harness' do
      saved  = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      dir    = seed_saved_session(saved)
      # Seed a log + history file inside it too - the whole dir must go.
      File.write(File.join(dir, 'harness.log'), "log\n")
      File.write(File.join(dir, 'harness_history'), "/model x\n")
      allow(ui).to receive(:puts)

      cli = described_class.new(
        options.merge(delete_session: saved[0, 8], model: nil), ui)

      expect(cli.harness).to be_nil
      expect(cli.run).to eq(0)
      expect(File.directory?(dir)).to be false
      expect(session_dirs).to eq([])
      expect(ui).to have_received(:puts).with(/Deleted session #{Regexp.escape(saved)}/)
    end

    it 'raises HarnessError for an unknown id and deletes nothing' do
      seed_saved_session('aaaaaaaa-bbbb-cccc-dddd-111111111111')
      allow(ui).to receive(:puts)

      cli = described_class.new(
        options.merge(delete_session: 'deadbeef', model: nil), ui)

      expect { cli.run }.to raise_error(HarnessError, /no saved session matching 'deadbeef'/)
      expect(session_dirs).to eq(['aaaaaaaa-bbbb-cccc-dddd-111111111111'])
    end

    it 'leaves the other saved sessions untouched' do
      keep = 'aaaaaaaa-bbbb-cccc-dddd-111111111111'
      gone = 'ffffffff-0000-1111-2222-333333333333'
      seed_saved_session(keep)
      seed_saved_session(gone)
      allow(ui).to receive(:puts)

      cli = described_class.new(
        options.merge(delete_session: gone, model: nil), ui)
      cli.run

      expect(session_dirs).to eq([keep])
    end
  end

  describe '#session_log_path_display' do
    it 'is the per-session log path relative to the workdir' do
      cli = build_cli
      id  = cli.harness.session.session_id

      expect(cli.send(:session_log_path_display))
        .to eq(File.join('.harness', 'sessions', id, 'harness.log'))
    end
  end

  # issue #282: the heavy construction lives in #setup, so it can be RUN
  # AGAIN with a different id (the shape issue #280 needs for a mid-run
  # /resume: build a FRESH Harness instead of mutating the live one). The
  # identity-first order (#276) is now the order INSIDE setup.
  describe '#setup (issue #282)' do
    it 'a second setup with a resume id builds a FRESH Harness under that id' do
      saved = 'aabbccdd-1111-2222-3333-444444444444'
      seed_saved_session(saved)

      cli    = build_cli
      before = cli.harness
      built  = cli.setup(resume_id: saved)

      expect(built).to be_a(Harness)
      expect(built).not_to equal(before)
      expect(built.session.session_id).to eq(saved)
      # Every holder is repointed at the fresh object (the repoint #280 needs).
      expect(cli.harness).to equal(built)
      expect(cli.commands.harness).to equal(built)
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', saved, 'harness_history')
      )
    end

    # The identity-first guarantee, asserted through setup: the id is resolved
    # BEFORE Harness.new, so a bad id cannot leave a half-built run behind -
    # the previous Harness, history file and commands are still in place.
    it 'a failing setup resolves the id before constructing anything' do
      cli    = build_cli
      before = cli.harness
      before_history = cli.history
      before_commands = cli.commands

      expect {
        cli.setup(resume_id: 'deadbeef')
      }.to raise_error(HarnessError, /no saved session matching 'deadbeef'/)

      expect(cli.harness).to equal(before)
      expect(cli.history).to equal(before_history)
      expect(cli.commands).to equal(before_commands)
    end

    # A re-run must never mint a throwaway id (issues #123 / #135): the id
    # this run owns is kept, whatever the startup flags were.
    it 'setup without a resume id keeps the id this run already owns' do
      cli = build_cli                    # fresh run: its own random id
      id  = cli.harness.session.session_id

      cli.setup
      expect(cli.harness.session.session_id).to eq(id)
      expect(session_dirs).to eq([id])
    end

    it 'setup without a resume id keeps a --continue id too' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session(saved)

      cli = described_class.new(options.merge(continue: true), ui)
      expect(cli.harness.session.session_id).to eq(saved)

      cli.setup
      expect(cli.harness.session.session_id).to eq(saved)
      expect(session_dirs).to eq([saved])
    end
  end

  # issue #280: a mid-run /resume re-runs #setup (through the on_resume action
  # injected into the CommandHandler) and the WHOLE run is rebuilt under the
  # resumed id - nothing of the replaced run is patched in place.
  describe 'mid-run /resume (issue #280)' do
    def log_path(id)
      File.join(workdir, '.harness', 'sessions', id, 'harness.log')
    end

    # ResumeCommand reports through the UI (the run's own console).
    before { allow(ui).to receive(:puts) }

    it 'rebuilds the run under the resumed id and repoints every holder' do
      saved  = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session_with_grants(saved)
      cli       = build_cli
      old       = cli.harness
      first_id  = cli.harness.session.session_id
      old_fl    = cli.file_list
      old_cmds  = cli.commands
      old_hist  = cli.history

      cli.commands.handle("/resume #{saved[0, 8]}")

      # Identity: the whole run is the saved session's now.
      expect(cli.session_id).to eq(saved)
      expect(cli.harness).not_to equal(old)
      expect(cli.harness.session.session_id).to eq(saved)
      contents = cli.harness.session.messages.map { |m| m[:content] }
      expect(contents).to include('earlier prompt')
      expect(cli.harness.yolo?).to be(true)
      # Holders repointed (Task.harness comes from CommandHandler#harness at
      # every run_on_task, so this is the one wiring that matters).
      expect(cli.commands).not_to equal(old_cmds)
      expect(cli.commands.harness).to equal(cli.harness)
      expect(cli.history).not_to equal(old_hist)
      expect(cli.history.history_file).to eq(
        File.join(workdir, '.harness', 'sessions', saved, 'harness_history')
      )
      # No throwaway id: only the run's first session and the resumed one.
      expect(session_dirs).to eq([first_id, saved].sort)
      # The resume is reported on the NEW session's log (#113 was about the
      # log following the id; now the log is simply built under it).
      expect(File.read(log_path(saved))).to include('session resumed')
      # Grants restored onto a FileList of its own.
      expect(cli.file_list).not_to equal(old_fl)
      expect(cli.harness.file_list).to equal(cli.file_list)
      stored = cli.file_list.accessible_paths
      expect(stored[:both][:files]).to eq([File.expand_path('lib/foo.rb', workdir)])
      expect(stored[:read][:dirs]).to eq([File.expand_path('spec/lib', workdir)])
      # The resumed session was saved with YOLO ON, and since #274 the same
      # posture covers file access too - so coverage must not be confused with
      # the restored grants above: local/ is outside it even here.
      expect(cli.harness.yolo?).to be(true)
      expect(cli.file_list.writable?('lib/other.rb')).to be true
      expect(cli.file_list.writable?('local/notes.md')).to be false
    end

    it 'closes the replaced run\'s logger and gives the fresh one its own client' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session_with_grants(saved)
      cli   = build_cli
      old   = cli.harness
      before = File.read(log_path(old.session.session_id))

      cli.commands.handle("/resume #{saved}")

      # The old logdev is closed: a late write cannot append to it.
      old.logger.info('late write to the replaced session')
      expect(File.read(log_path(old.session.session_id))).to eq(before)
      # A fresh client built under the resumed id, logging to the fresh logger
      # (the #197 wiring - the backend holds the logger - with no setter).
      expect(cli.harness.client).not_to equal(old.client)
      expect(cli.harness.client.backend.logger).to equal(cli.harness.logger)
      expect(cli.harness.session_log_path).to eq(log_path(saved))
    end
  end

  # issue #221 review (bug 2): the shell consent posture is stated in the
  # startup banner so the run's approval behavior is visible from the first
  # line (YOLO ON must never look like "nothing ever asks").
  describe 'startup banner - command consent posture' do
    it 'names the MANUAL posture and how to change it' do
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/^Command consent: MANUAL - unapproved commands ask/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #303: the palette this run renders with is a fact about the run,
    # so it is named in the banner next to the consent posture.
    it 'names the output palette and how to switch it' do
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/^Output palette: default \(\/palette <name> switches it\)/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    it 'names YOLO with the disaster floor still asking' do
      cli = build_cli
      stub_prompt_reader
      cli.harness.yolo = true

      expected = 'Command consent: YOLO - unapproved commands run ' \
                 'without asking; disaster commands still ask'
      expect(ui).to receive(:puts)
        .with(expected)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end
  end

  # issue #449: MCP servers are the only source of tool-result images, so the
  # banner names the image posture ONLY when servers are declared - and it says
  # which of the two behaviours this run has (pixels to the model vs. a path to
  # a file under .harness/content). The real gem/subprocess is never touched:
  # ServerConnection is stubbed, as in the harness MCP specs.
  describe 'startup banner - tool-result images (issue #449)' do
    def fake_connection
      conn = instance_double('Mcp::ServerConnection')
      allow(conn).to receive(:connect).and_return([])
      allow(conn).to receive(:close)
      conn
    end

    def mcp_options(extra = {})
      options.merge(
        mcp_servers: [{ name: 'fs', command: 'ruby', args: [], env: {} }],
        **extra
      )
    end

    it 'says files-only when servers are declared and no profile has vision' do
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection)
      cli = described_class.new(mcp_options, ui)
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with('Tool-result images: files only (no vision profile)')
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    it 'says inlined when the active profile declares vision' do
      allow(Mcp::ServerConnection).to receive(:new).and_return(fake_connection)
      cli = described_class.new(
        mcp_options(model: 'sees',
                    model_profiles: [{ name: 'sees', model: 'vision-model',
                                       vision: true }]), ui)
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with('Tool-result images: inlined to the model')
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # The gate is the config, not a live connection: a declared server that
    # could not start still has images in its protocol, and the run still has
    # to say what it would do with one.
    it 'states the posture even when the declared server failed to start' do
      conn = instance_double('Mcp::ServerConnection')
      allow(conn).to receive(:connect).and_raise(Errno::ENOENT, 'no such server')
      allow(conn).to receive(:close)
      allow(Mcp::ServerConnection).to receive(:new).and_return(conn)
      cli = described_class.new(mcp_options, ui)
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with('Tool-result images: files only (no vision profile)')
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    it 'says nothing about images when no MCP servers are declared' do
      cli = build_cli
      allow(ui).to receive(:puts)
      stub_prompt_reader

      cli.run

      expect(ui).not_to have_received(:puts).with(/^Tool-result images:/)
    end
  end

  # issue #384: the run starts with a STANDING grant on the working directory,
  # so the model no longer asks per file. The grant is seeded at the CLI layer
  # only (FileList's own constructor default is unchanged), so the guard rules
  # are what these specs really test: a NAME guard survives a grant on an
  # ancestor, an OUTSIDE-workdir path is not covered, and the owner's own space
  # local/ IS covered here (the grant came from the user's own config) even
  # though the YOLO posture never reaches it (#274).
  describe 'standing file-access grant (issue #384)' do
    it 'covers a file inside the project for read, write and delete with no dialog' do
      cli = build_cli

      expect(cli.file_list.readable?('lib/foo.rb')).to be true
      expect(cli.file_list.writable?('lib/foo.rb')).to be true
      # Delete is seeded as its own tier (:d), not implied by :rw - a file
      # delete must not still ask (issue #92's mode stays independent).
      expect(cli.file_list.deletable?('analysis/246/repro.rb')).to be true
    end

    # The whole point of the guard: it is a NAME rule, so a recursive grant on
    # an ancestor never reaches a sensitive name sitting under it.
    it 'keeps sensitive names blocked despite the standing grant' do
      cli = build_cli

      expect(cli.file_list.readable?('.env')).to be false
      expect(cli.file_list.writable?('.git/config')).to be false
      expect(cli.file_list.deletable?('.harness/sessions/x/session.json')).to be false
      # A nested sensitive dir under a normal path is blocked too.
      expect(cli.file_list.readable?('sub/.git/config')).to be false
    end

    it 'does not cover a path outside the working directory' do
      cli = build_cli

      expect(cli.file_list.readable?('../outside.rb')).to be false
      expect(cli.file_list.writable?('../outside.rb')).to be false
    end

    # The owner's decision (2026-11-03): a standing grant a user DECLARED in
    # their own config covers local/ too - it is the decision, already made.
    # Contrast the posture, which never reaches it (#274 / protected_dirs).
    it 'covers the owner space local/ (a config grant, not a posture)' do
      cli = build_cli

      expect(cli.file_list.writable?('local/notes.md')).to be true
      expect(cli.file_list.deletable?('local/sub/deep.md')).to be true
    end

    # The opt-out key brings the old per-file consent back: nothing is seeded.
    it 'grants nothing when grant_workdir: false (per-file consent restored)' do
      cli = described_class.new(options.merge(grant_workdir: false), ui)

      expect(cli.file_list.access_grant_count).to eq(0)
      expect(cli.file_list.readable?('lib/foo.rb')).to be false
      expect(cli.file_list.deletable?('lib/foo.rb')).to be false
    end

    it 'is a real stored grant - it shows up in the access lists /grant and a save read' do
      cli = build_cli
      access = cli.file_list.accessible_paths

      expect(access[:both][:dirs]).to include(cli.file_list.workdir)
      expect(access[:delete][:dirs]).to include(cli.file_list.workdir)
    end
    # The seed runs BEFORE the Harness restores a session (Session#restore
    # clears the list first), so a resumed run ends with exactly the grants its
    # session file saved: a /clear before saving is not silently undone by the
    # resume (the #105 rule that a grant must never come back from nowhere).
    it 'a resumed session keeps its own saved grants, not a fresh standing one' do
      saved = 'f7931611-30b4-4b4b-aec6-f7083ef2942a'
      seed_saved_session_with_grants(saved)

      cli = described_class.new(options.merge(resume: saved), ui)
      stored = cli.file_list.accessible_paths

      expect(stored[:both][:files]).to eq([File.expand_path('lib/foo.rb', workdir)])
      expect(stored[:both][:dirs]).to be_empty
      expect(stored[:delete][:dirs]).to be_empty
      expect(cli.file_list.deletable?('local/notes.md')).to be false
    end

    # Conversely: a run that saved WITH the standing grant restores it, because
    # it is an ordinary stored grant in the session's access section.
    it 'a session saved with the standing grant restores it' do
      saved = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
      dir   = File.join(workdir, '.harness', 'sessions', saved)
      FileUtils.mkdir_p(dir)
      access = {
        both:   { files: [], dirs: [workdir], flat_dirs: [] },
        read:   { files: [], dirs: [], flat_dirs: [] },
        write:  { files: [], dirs: [], flat_dirs: [] },
        delete: { files: [], dirs: [workdir], flat_dirs: [] }
      }
      File.write(File.join(dir, 'session.json'), JSON.generate({
                   session_id: saved, created_at: Time.now.iso8601,
                   system_prompt: 'sp', user_prompts: 1, workdir: workdir,
                   messages: [{ role: 'system', content: 'sp' }], access: access
                 }))

      cli = described_class.new(options.merge(resume: saved), ui)

      expect(cli.file_list.writable?('lib/anything.rb')).to be true
      expect(cli.file_list.readable?('.env')).to be false
    end

    # The startup banner states the run's file consent, the same way it states
    # the command consent posture (#221): "no dialogs for your files" is a
    # claim that must be visible and auditable from the first line.
    it 'states the standing grant in the startup banner' do
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/^File consent: standing grant on .* - read, write and delete/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    it 'states per-path consent in the banner when the key is off' do
      cli = described_class.new(options.merge(grant_workdir: false), ui)
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/^File consent: per-path consent - every file and directory asks/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end
  end

  describe '#run' do
    it 'prints the session id and its log path in the banner' do
      cli = build_cli
      id  = cli.harness.session.session_id
      stub_prompt_reader

      expect(ui).to receive(:puts)
        .with(/Session: #{Regexp.escape(id)} \(log: .*harness\.log\)/)
        .ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #341: a rules file that is not valid UTF-8 now LOADS (bad bytes
    # replaced) instead of crashing the run, so the banner has to say the
    # repair out loud - the prompt the model got is not byte-for-byte harness.md.
    it 'reports a repaired harness.md in the banner' do
      File.binwrite(File.join(workdir, 'harness.md'), "rule caf\xe9 keep 90 cols\n")
      cli = build_cli
      stub_prompt_reader

      expect(ui).to receive(:puts).with(
        '  [harness.md repaired: 1 invalid byte replaced - harness.md is not valid UTF-8]'
      ).ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #48: a declared MCP server that failed to start (or a tool whose name
    # collided) is reported in the banner, so the run never silently pretends its
    # MCP tools are available.
    it 'reports MCP status notes in the banner' do
      cli = build_cli
      allow(cli.harness).to receive(:mcp_status_notes).and_return(
        ["MCP server 'fs' failed to start (RuntimeError: boom)"]
      )
      stub_prompt_reader

      expect(ui).to receive(:puts).with(
        "  [mcp] MCP server 'fs' failed to start (RuntimeError: boom)"
      ).ordered
      expect(ui).to receive(:puts).at_least(:once)

      cli.run
    end

    # issue #298: run installs the resolved editor command on the shared
    # UI::Editor once, so every multiline read honours Ctrl+G. With nothing set
    # the global stays nil and Ctrl+G is left exactly as Reline has it.
    it 'installs the resolved editor command on UI::Editor' do
      opts = options.merge(editor: 'nvim -R')
      cli  = described_class.new(opts, ui)
      allow(ui).to receive(:puts)
      stub_prompt_reader

      cli.run

      expect(UI::Editor.external_editor).to eq('nvim -R')
    end

    it 'leaves UI::Editor.external_editor nil when no editor is configured' do
      cli = build_cli
      allow(ui).to receive(:puts)
      stub_prompt_reader

      cli.run

      expect(UI::Editor.external_editor).to be_nil
    end

    # issue #409: a save that raises on the exit path is an unexpected crash.
    # The warning line alone told the user nothing, so the frames now go to
    # this session's harness.log via ErrorText.detailed.
    it 'logs a failed auto-save WITH ITS FRAMES in the session log' do
      cli = build_cli
      cli.harness.session.add_user('keep this turn')
      allow(cli.harness.session_manager).to receive(:save_session)
        .and_raise(RuntimeError, 'save exploded')
      allow(ui).to receive(:puts)
      stub_prompt_reader

      expect { cli.run }.not_to raise_error

      log = File.read(cli.harness.session_log_path)
      expect(log).to include('auto-save failed: RuntimeError: save exploded')
      expect(log).to include('cli_spec.rb')
    end
  end

  # issue #188: session saving was bound to "a prompt was sent". A run that
  # changed settings (e.g. /model) but sent no prompt saved nothing, so
  # --continue/--resume could not recover them and the typed command was
  # orphaned under a throwaway id. The exit-save now also fires when the run
  # changed state (a new history entry is the evidence).
  describe 'exit-save on a state change with no conversation (issue #188)' do
    def session_json(id)
      File.join(workdir, '.harness', 'sessions', id, 'session.json')
    end

    it 'saves the session when a command was typed but no prompt was sent' do
      Reline::HISTORY.clear
      Reline::HISTORY << '/model some-model'
      cli = build_cli
      allow(ui).to receive(:puts)
      stub_prompt_reader
      id = cli.harness.session.session_id

      cli.run

      expect(File.file?(session_json(id))).to be(true)
    end

    it 'saves nothing when the session is empty and no command was typed' do
      Reline::HISTORY.clear
      cli = build_cli
      allow(ui).to receive(:puts)
      stub_prompt_reader
      id = cli.harness.session.session_id

      cli.run

      # The session dir exists (the run wrote its harness.log under the id),
      # but no session.json was written for a run that changed nothing.
      expect(File.exist?(session_json(id))).to be(false)
    end

    it 'still saves a normal conversation (the empty? path is unchanged)' do
      Reline::HISTORY.clear
      cli = build_cli
      cli.harness.session.add_user('a real prompt')
      allow(ui).to receive(:puts)
      stub_prompt_reader
      id = cli.harness.session.session_id

      cli.run

      expect(File.file?(session_json(id))).to be(true)
    end
  end
end
