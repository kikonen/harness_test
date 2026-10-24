# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'memories'

RSpec.describe Memories do
  def memories_in(dir)
    described_class.new(dir)
  end

  def store_dir(dir)
    File.join(dir, described_class::DIR)
  end

  describe 'the store directory' do
    it 'is .harness/memories under the working directory' do
      Dir.mktmpdir do |dir|
        expect(memories_in(dir).dir).to eq(File.expand_path('.harness/memories', dir))
      end
    end

    # An empty project is the everyday state of the feature, not an error.
    it 'reads an empty project as no memories' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)

        expect(m.exist?).to be false
        expect(m.all).to eq([])
        expect(m.names).to eq([])
        expect(m.count).to eq(0)
        expect(m.full?).to be false
        expect(m.body('anything')).to be_nil
      end
    end

    it 'writes nothing until a note is added' do
      Dir.mktmpdir do |dir|
        memories_in(dir)

        expect(Dir.children(dir)).to eq([])
      end
    end
  end

  describe '#add' do
    it 'writes one markdown note per name under the store dir' do
      Dir.mktmpdir do |dir|
        note = memories_in(dir).add('build-steps', 'run bundle exec rspec')

        # The model's text is stored with exactly one terminator (a text file
        # keeps one), and #body returns it chomped.
        expect(File.binread(File.join(store_dir(dir), 'build-steps.md')))
          .to eq("run bundle exec rspec\n")
        expect(note.name).to eq('build-steps')
        expect(note.path).to eq(File.expand_path('.harness/memories/build-steps.md', dir))
        expect(note.chars).to eq('run bundle exec rspec'.length)
      end
    end

    it 'keeps the body as markdown text' do
      Dir.mktmpdir do |dir|
        body = "# Consent\n\nAUTO-APPROVE skips the dialog on a safe: verdict."
        memories_in(dir).add('consent', body)

        expect(memories_in(dir).body('consent')).to eq(body)
      end
    end

    it 'refuses an empty note' do
      Dir.mktmpdir do |dir|
        expect { memories_in(dir).add('x', '   ') }
          .to raise_error(HarnessError, /empty/)
        expect(Dir.children(dir)).to eq([])
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)

        ['../secret', 'a/b', 'a\\b', '..', '.', '.hidden', 'c:d', 'a<b', 'a|b', 'a*b', "a\nb"].each do |bad|
          expect { m.add(bad, 'text') }.to raise_error(HarnessError, /one path segment/)
        end
        expect(m.names).to eq([])
      end
    end

    # The store must not become a writer inside .harness/: what the file tools
    # can never grant has to stay unreachable through memory.add as well.
    it 'cannot be pointed at harness state by its name' do
      Dir.mktmpdir do |dir|
        session = File.join(dir, '.harness', 'sessions', 'abc', 'session.json')
        FileUtils.mkdir_p(File.dirname(session))
        File.write(session, '{}')

        expect { memories_in(dir).add('../sessions/abc/session.json', 'boom') }
          .to raise_error(HarnessError, /one path segment/)

        expect(File.read(session)).to eq('{}')
      end
    end

    it 'refuses to overwrite an existing note without saying so' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('fact', 'first version')

        expect { m.add('fact', 'second version') }
          .to raise_error(HarnessError, /already exists/)
        expect(m.body('fact')).to eq('first version')
      end
    end

    it 'replaces the note when overwrite is asked for' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('fact', 'first version')
        m.add('fact', 'second version', overwrite: true)

        expect(m.body('fact')).to eq('second version')
        expect(m.count).to eq(1)
      end
    end

    # The cap is the feature's own limit, not advice: an over-long note is a
    # subsystem document pretending to be a memory.
    it 'refuses a note over the body cap, naming the limit' do
      Dir.mktmpdir do |dir|
        long = 'x' * (described_class::MAX_BODY_CHARS + 1)

        expect { memories_in(dir).add('huge', long) }
          .to raise_error(HarnessError, /max #{described_class::MAX_BODY_CHARS}/)
        expect(memories_in(dir).count).to eq(0)
      end
    end

    it 'accepts a note at exactly the body cap' do
      Dir.mktmpdir do |dir|
        exact = 'x' * described_class::MAX_BODY_CHARS
        memories_in(dir).add('edge', exact)

        expect(memories_in(dir).body('edge').length).to eq(described_class::MAX_BODY_CHARS)
      end
    end

    it 'folds CR and CRLF input to LF text' do
      Dir.mktmpdir do |dir|
        memories_in(dir).add('crlf', "line one\r\nline two\rline three")

        expect(memories_in(dir).body('crlf')).to eq("line one\nline two\nline three")
      end
    end
  end

  # Names are the model's choice and the model cannot see the filesystem's case
  # rules (Windows: one file for Fact/fact; Linux CI: two). The store folds them
  # so one note means one note on both.
  describe 'name case' do
    it 'folds a name to lowercase' do
      Dir.mktmpdir do |dir|
        note = memories_in(dir).add('Consent-Postures', 'text')

        expect(note.name).to eq('consent-postures')
        expect(File.exist?(File.join(store_dir(dir), 'consent-postures.md'))).to be true
      end
    end

    it 'reads the same note whichever case the name is given in' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('facts', 'body')

        expect(m.body('FACTS')).to eq('body')
        expect(m.body('Facts')).to eq('body')
        expect(m.count).to eq(1)
      end
    end

    it 'treats a note stored under another case as the existing one' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        File.write(File.join(store_dir(dir), 'Hand-Written.md'), 'original')
        m = memories_in(dir)

        expect { m.add('hand-written', 'duplicate') }
          .to raise_error(HarnessError, /already exists/)

        m.add('HAND-WRITTEN', 'replaced', overwrite: true)

        expect(m.names).to eq(['Hand-Written'])
        expect(m.body('hand-written')).to eq('replaced')
        expect(m.count).to eq(1)
      end
    end
  end

  describe 'the cap on how many notes exist' do
    it 'is full at MAX_MEMORIES and refuses a further note, naming the way out' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        described_class::MAX_MEMORIES.times { |i| m.add("note-#{i}", 'text') }

        expect(m.count).to eq(described_class::MAX_MEMORIES)
        expect(m.full?).to be true

        expect { m.add('one-too-many', 'text') }
          .to raise_error(HarnessError, /full \(#{described_class::MAX_MEMORIES} notes\)/)
        expect(m.count).to eq(described_class::MAX_MEMORIES)
      end
    end

    # A full store still lets a note be REVISED: the cap limits how many notes
    # exist, not how often one may be corrected.
    it 'still overwrites an existing note when the store is full' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        described_class::MAX_MEMORIES.times { |i| m.add("note-#{i}", 'text') }

        m.add('note-0', 'revised', overwrite: true)

        expect(m.count).to eq(described_class::MAX_MEMORIES)
        expect(m.body('note-0')).to eq('revised')
      end
    end

    it 'leaves a slot after a delete' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        described_class::MAX_MEMORIES.times { |i| m.add("note-#{i}", 'text') }
        m.delete('note-0')

        expect(m.full?).to be false
        expect { m.add('new-note', 'text') }.not_to raise_error
      end
    end
  end

  describe '#all / #find' do
    it 'lists notes sorted by name with description and size' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('zeta', 'the last one')
        m.add('alpha', "# Heading\n\nthe first fact")

        all = m.all

        expect(all.map(&:name)).to eq(%w[alpha zeta])
        expect(all.first.description).to eq('the first fact')
        expect(all.last.description).to eq('the last one')
        expect(all.first.chars).to eq("# Heading\n\nthe first fact".length)
      end
    end

    it 'skips a file that is not a note' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        File.write(File.join(store_dir(dir), 'keep.txt'), 'not a note')
        File.write(File.join(store_dir(dir), '.md'), 'no name')
        File.write(File.join(store_dir(dir), 'note.md'), 'a note')

        expect(memories_in(dir).names).to eq(['note'])
        expect(memories_in(dir).count).to eq(1)
      end
    end

    # A long description would make the index unglanceable (same rule as a
    # skill's one-liner).
    it 'truncates a description taken from a long first line' do
      Dir.mktmpdir do |dir|
        long = 'w' * (described_class::DESC_MAX + 60)
        memories_in(dir).add('wordy', long)

        listed = memories_in(dir).all.first.description

        expect(listed).to eq("#{long[0, described_class::DESC_MAX]} ...")
      end
    end

    it 'says so when a note has no prose line to describe it' do
      Dir.mktmpdir do |dir|
        memories_in(dir).add('headers-only', "# one\n\n# two\n")

        expect(memories_in(dir).all.first.description).to eq('no description')
      end
    end

    it 'finds no note for a name that is not stored' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('exact-name', 'body')

        expect(m.find('exact-name').name).to eq('exact-name')
        expect(m.find('exact')).to be_nil
        expect(m.find('exact-name-2')).to be_nil
        expect(m.find('../exact-name')).to be_nil
      end
    end

    it 'names what IS available when a name is wrong' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('one', 'x')
        m.add('two', 'x')

        expect(m.available_hint).to eq('available: one, two')
        expect(memories_in(File.join(dir, 'none')).available_hint).to eq('no memories stored')
      end
    end
  end

  describe '#delete' do
    it 'removes the note and reports its name' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('gone', 'text')

        expect(m.delete('gone')).to eq('gone')
        expect(m.names).to eq([])
        expect(File.exist?(File.join(store_dir(dir), 'gone.md'))).to be false
      end
    end

    it 'returns nil for a name that has no note' do
      Dir.mktmpdir do |dir|
        expect(memories_in(dir).delete('never')).to be_nil
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)
        m.add('keep', 'text')

        expect(m.delete('../keep')).to be_nil
        expect(m.delete('..')).to be_nil
        expect(m.names).to eq(['keep'])
      end
    end
  end

  # A note is read through the same byte boundary every other file is (issue
  # #341): the model sees valid UTF-8 with LF separators, and the file on disk
  # keeps the style it was written with.
  describe 'reading a note written outside this class' do
    it 'reads a CRLF note as LF text without rewriting the file' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        path = File.join(store_dir(dir), 'windows.md')
        File.binwrite(path, "crlf one\r\ncrlf two\r\n")

        body = memories_in(dir).body('windows')

        expect(body).to eq("crlf one\ncrlf two")
        expect(body.encoding).to eq(Encoding::UTF_8)
        expect(File.binread(path)).to eq("crlf one\r\ncrlf two\r\n")
      end
    end

    it 'replaces bytes that are not valid UTF-8 with the stand-in' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        broken = "caf\xFF keep".dup.force_encoding(Encoding::BINARY)
        File.binwrite(File.join(store_dir(dir), 'broken.md'), broken)

        expect(memories_in(dir).body('broken')).to eq('caf? keep')
      end
    end
  end

  describe '#note_path' do
    it 'names the file a canonical name would write to, before it exists' do
      Dir.mktmpdir do |dir|
        m = memories_in(dir)

        expect(m.note_path('future')).to eq(File.expand_path('.harness/memories/future.md', dir))
        expect(m.note_path('Future')).to eq(File.expand_path('.harness/memories/future.md', dir))
        expect(m.note_path('../escape')).to be_nil
      end
    end
  end
end
