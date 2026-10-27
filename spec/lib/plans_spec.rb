# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'plans'

RSpec.describe Plans do
  def plans_in(dir)
    described_class.new(dir)
  end

  def store_dir(dir)
    File.join(dir, described_class::DIR)
  end

  describe 'the store directory' do
    it 'is .harness/plans under the working directory' do
      Dir.mktmpdir do |dir|
        expect(plans_in(dir).dir).to eq(File.expand_path('.harness/plans', dir))
      end
    end

    # An empty project is the everyday state of the feature, not an error.
    it 'reads an empty project as no plans' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)

        expect(p.exist?).to be false
        expect(p.all).to eq([])
        expect(p.names).to eq([])
        expect(p.count).to eq(0)
        expect(p.full?).to be false
        expect(p.body('anything')).to be_nil
      end
    end

    it 'writes nothing until a plan is added' do
      Dir.mktmpdir do |dir|
        plans_in(dir)

        expect(Dir.children(dir)).to eq([])
      end
    end
  end

  describe '#add' do
    it 'writes one markdown plan per name under the store dir' do
      Dir.mktmpdir do |dir|
        plan = plans_in(dir).add('refactor-auth', 'read the flow, then split it')

        # The model's text is stored with exactly one terminator (a text file
        # keeps one), and #body returns it chomped.
        expect(File.binread(File.join(store_dir(dir), 'refactor-auth.md')))
          .to eq("read the flow, then split it\n")
        expect(plan.name).to eq('refactor-auth')
        expect(plan.path).to eq(File.expand_path('.harness/plans/refactor-auth.md', dir))
        expect(plan.chars).to eq('read the flow, then split it'.length)
      end
    end

    it 'keeps the body as markdown text' do
      Dir.mktmpdir do |dir|
        body = "# Plan\n\n1. read\n2. split\n3. test"
        plans_in(dir).add('steps', body)

        expect(plans_in(dir).body('steps')).to eq(body)
      end
    end

    it 'refuses an empty plan' do
      Dir.mktmpdir do |dir|
        expect { plans_in(dir).add('x', '   ') }
          .to raise_error(HarnessError, /empty/)
        expect(Dir.children(dir)).to eq([])
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)

        ['../secret', 'a/b', 'a\\b', '..', '.', '.hidden', 'c:d', 'a<b', 'a|b', 'a*b', "a\nb"].each do |bad|
          expect { p.add(bad, 'text') }.to raise_error(HarnessError, /one path segment/)
        end
        expect(p.names).to eq([])
      end
    end

    # The store must not become a writer inside .harness/: what the file tools
    # can never grant has to stay unreachable through plan.add as well.
    it 'cannot be pointed at harness state by its name' do
      Dir.mktmpdir do |dir|
        session = File.join(dir, '.harness', 'sessions', 'abc', 'session.json')
        FileUtils.mkdir_p(File.dirname(session))
        File.write(session, '{}')

        expect { plans_in(dir).add('../sessions/abc/session.json', 'boom') }
          .to raise_error(HarnessError, /one path segment/)

        expect(File.read(session)).to eq('{}')
      end
    end

    it 'refuses to overwrite an existing plan without saying so' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('plan', 'first version')

        expect { p.add('plan', 'second version') }
          .to raise_error(HarnessError, /already exists/)
        expect(p.body('plan')).to eq('first version')
      end
    end

    it 'replaces the plan when overwrite is asked for' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('plan', 'first version')
        p.add('plan', 'second version', overwrite: true)

        expect(p.body('plan')).to eq('second version')
        expect(p.count).to eq(1)
      end
    end

    # The cap is the feature's own limit, not advice: an over-long plan is a
    # subsystem document pretending to be a plan.
    it 'refuses a plan over the body cap, naming the limit' do
      Dir.mktmpdir do |dir|
        long = 'x' * (described_class::MAX_BODY_CHARS + 1)

        expect { plans_in(dir).add('huge', long) }
          .to raise_error(HarnessError, /max #{described_class::MAX_BODY_CHARS}/)
        expect(plans_in(dir).count).to eq(0)
      end
    end

    it 'accepts a plan at exactly the body cap' do
      Dir.mktmpdir do |dir|
        exact = 'x' * described_class::MAX_BODY_CHARS
        plans_in(dir).add('edge', exact)

        expect(plans_in(dir).body('edge').length).to eq(described_class::MAX_BODY_CHARS)
      end
    end

    it 'folds CR and CRLF input to LF text' do
      Dir.mktmpdir do |dir|
        plans_in(dir).add('crlf', "line one\r\nline two\rline three")

        expect(plans_in(dir).body('crlf')).to eq("line one\nline two\nline three")
      end
    end
  end

  # A mnemonic name is generated when the model omits one (issue #359 owner
  # note). It is adjective-noun, always fresh, and a real one-path-segment name.
  describe 'generated mnemonic names' do
    it 'generates an adjective-noun name when none is given' do
      Dir.mktmpdir do |dir|
        plan = plans_in(dir).add(nil, 'the plan text')

        expect(plan.name).to match(/\A[a-z]+-[a-z]+\z/)
        expect(described_class::ADJECTIVES).to include(plan.name.split('-').first)
        expect(described_class::NOUNS).to include(plan.name.split('-').last)
        expect(plans_in(dir).body(plan.name)).to eq('the plan text')
      end
    end

    it 'treats a blank name as no name and generates one' do
      Dir.mktmpdir do |dir|
        plan = plans_in(dir).add('   ', 'text')

        expect(plan.name).to match(/\A[a-z]+-[a-z]+\z/)
      end
    end

    it 'generates a fresh name that does not collide with a stored one' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        first  = p.add(nil, 'a')
        second = p.add(nil, 'b')

        expect(second.name).not_to eq(first.name)
        expect(p.count).to eq(2)
      end
    end

    it 'keeps a name the model does provide (the generator is a fallback)' do
      Dir.mktmpdir do |dir|
        plan = plans_in(dir).add('refactor-auth', 'text')

        expect(plan.name).to eq('refactor-auth')
      end
    end
  end

  # Names are the model's choice and the model cannot see the filesystem's case
  # rules (Windows: one file for Plan/plan; Linux CI: two). The store folds them
  # so one plan means one plan on both.
  describe 'name case' do
    it 'folds a name to lowercase' do
      Dir.mktmpdir do |dir|
        plan = plans_in(dir).add('Refactor-Auth', 'text')

        expect(plan.name).to eq('refactor-auth')
        expect(File.exist?(File.join(store_dir(dir), 'refactor-auth.md'))).to be true
      end
    end

    it 'reads the same plan whichever case the name is given in' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('plans', 'body')

        expect(p.body('PLANS')).to eq('body')
        expect(p.body('Plans')).to eq('body')
        expect(p.count).to eq(1)
      end
    end

    it 'treats a plan stored under another case as the existing one' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        File.write(File.join(store_dir(dir), 'Hand-Written.md'), 'original')
        p = plans_in(dir)

        expect { p.add('hand-written', 'duplicate') }
          .to raise_error(HarnessError, /already exists/)

        p.add('HAND-WRITTEN', 'replaced', overwrite: true)

        expect(p.names).to eq(['Hand-Written'])
        expect(p.body('hand-written')).to eq('replaced')
        expect(p.count).to eq(1)
      end
    end
  end

  describe 'the cap on how many plans exist' do
    it 'is full at MAX_PLANS and refuses a further plan, naming the way out' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        described_class::MAX_PLANS.times { |i| p.add("plan-#{i}", 'text') }

        expect(p.count).to eq(described_class::MAX_PLANS)
        expect(p.full?).to be true

        expect { p.add('one-too-many', 'text') }
          .to raise_error(HarnessError, /full \(#{described_class::MAX_PLANS} plans\)/)
        expect(p.count).to eq(described_class::MAX_PLANS)
      end
    end

    # A full store still lets a plan be REVISED: the cap limits how many plans
    # exist, not how often one may be corrected.
    it 'still overwrites an existing plan when the store is full' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        described_class::MAX_PLANS.times { |i| p.add("plan-#{i}", 'text') }

        p.add('plan-0', 'revised', overwrite: true)

        expect(p.count).to eq(described_class::MAX_PLANS)
        expect(p.body('plan-0')).to eq('revised')
      end
    end

    it 'leaves a slot after a delete' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        described_class::MAX_PLANS.times { |i| p.add("plan-#{i}", 'text') }
        p.delete('plan-0')

        expect(p.full?).to be false
        expect { p.add('new-plan', 'text') }.not_to raise_error
      end
    end
  end

  describe '#all / #find' do
    it 'lists plans sorted by name with description and size' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('zeta', 'the last one')
        p.add('alpha', "# Heading\n\nthe first plan")

        all = p.all

        expect(all.map(&:name)).to eq(%w[alpha zeta])
        expect(all.first.description).to eq('the first plan')
        expect(all.last.description).to eq('the last one')
        expect(all.first.chars).to eq("# Heading\n\nthe first plan".length)
      end
    end

    it 'skips a file that is not a plan' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        File.write(File.join(store_dir(dir), 'keep.txt'), 'not a plan')
        File.write(File.join(store_dir(dir), '.md'), 'no name')
        File.write(File.join(store_dir(dir), 'plan.md'), 'a plan')

        expect(plans_in(dir).names).to eq(['plan'])
        expect(plans_in(dir).count).to eq(1)
      end
    end

    # A long description would make the index unglanceable (same rule as a
    # memory's one-liner).
    it 'truncates a description taken from a long first line' do
      Dir.mktmpdir do |dir|
        long = 'w' * (described_class::DESC_MAX + 60)
        plans_in(dir).add('wordy', long)

        listed = plans_in(dir).all.first.description

        expect(listed).to eq("#{long[0, described_class::DESC_MAX]} ...")
      end
    end

    it 'says so when a plan has no prose line to describe it' do
      Dir.mktmpdir do |dir|
        plans_in(dir).add('headers-only', "# one\n\n# two\n")

        expect(plans_in(dir).all.first.description).to eq('no description')
      end
    end

    it 'finds no plan for a name that is not stored' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('exact-name', 'body')

        expect(p.find('exact-name').name).to eq('exact-name')
        expect(p.find('exact')).to be_nil
        expect(p.find('exact-name-2')).to be_nil
        expect(p.find('../exact-name')).to be_nil
      end
    end

    it 'names what IS available when a name is wrong' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('one', 'x')
        p.add('two', 'x')

        expect(p.available_hint).to eq('available: one, two')
        expect(plans_in(File.join(dir, 'none')).available_hint).to eq('no plans stored')
      end
    end
  end

  # Search is the capability Memories deliberately omit (issue #359): a plan
  # store is expected to outgrow a listable one. It matches names AND bodies,
  # case-insensitively, with no ranking.
  describe '#search' do
    it 'matches a substring in a plan body' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('auth', 'split the authentication flow into steps')
        p.add('build', 'run bundle exec rspec')

        found = p.search('authentication')

        expect(found.map(&:name)).to eq(['auth'])
      end
    end

    it 'matches a substring in a plan name' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('refactor-auth', 'text')
        p.add('other', 'text')

        found = p.search('refactor')

        expect(found.map(&:name)).to eq(['refactor-auth'])
      end
    end

    it 'is case-insensitive' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('one', 'Authentication Flow here')

        expect(p.search('AUTHENTICATION').map(&:name)).to eq(['one'])
      end
    end

    it 'returns every match, sorted by name (no ranking)' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('zeta', 'a shared keyword')
        p.add('alpha', 'also a shared keyword')
        p.add('unrelated', 'nothing here')

        expect(p.search('shared keyword').map(&:name)).to eq(%w[alpha zeta])
      end
    end

    it 'returns nothing for an empty query (a search must say something)' do
      Dir.mktmpdir do |dir|
        plans_in(dir).add('one', 'text')

        expect(plans_in(dir).search('')).to eq([])
        expect(plans_in(dir).search('   ')).to eq([])
      end
    end

    it 'returns nothing when no plan matches' do
      Dir.mktmpdir do |dir|
        plans_in(dir).add('one', 'text')

        expect(plans_in(dir).search('absent')).to eq([])
      end
    end
  end

  describe '#delete' do
    it 'removes the plan and reports its name' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('gone', 'text')

        expect(p.delete('gone')).to eq('gone')
        expect(p.names).to eq([])
        expect(File.exist?(File.join(store_dir(dir), 'gone.md'))).to be false
      end
    end

    it 'returns nil for a name that has no plan' do
      Dir.mktmpdir do |dir|
        expect(plans_in(dir).delete('never')).to be_nil
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)
        p.add('keep', 'text')

        expect(p.delete('../keep')).to be_nil
        expect(p.delete('..')).to be_nil
        expect(p.names).to eq(['keep'])
      end
    end
  end

  # A plan is read through the same byte boundary every other file is (issue
  # #341): the model sees valid UTF-8 with LF separators, and the file on disk
  # keeps the style it was written with.
  describe 'reading a plan written outside this class' do
    it 'reads a CRLF plan as LF text without rewriting the file' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(store_dir(dir))
        path = File.join(store_dir(dir), 'windows.md')
        File.binwrite(path, "crlf one\r\ncrlf two\r\n")

        body = plans_in(dir).body('windows')

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

        expect(plans_in(dir).body('broken')).to eq('caf? keep')
      end
    end
  end

  describe '#plan_path' do
    it 'names the file a canonical name would write to, before it exists' do
      Dir.mktmpdir do |dir|
        p = plans_in(dir)

        expect(p.plan_path('future')).to eq(File.expand_path('.harness/plans/future.md', dir))
        expect(p.plan_path('Future')).to eq(File.expand_path('.harness/plans/future.md', dir))
        expect(p.plan_path('../escape')).to be_nil
      end
    end
  end
end
