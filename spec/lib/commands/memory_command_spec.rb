# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'memories'
require 'commands/memory_command'

RSpec.describe Commands::MemoryCommand do
  def harness_with(dir)
    memories = Memories.new(dir)
    h = Object.new
    h.define_singleton_method(:memories) { memories }
    h
  end

  # A harness that answers a palette is the real-run shape (Harness#output_palette
  # is ALWAYS a palette there), and it is what lets the renderer render the body as
  # markdown (#474): the emitter states the RAW stored text, the markers are consumed
  # by the render. palette 'none' renders structure with no ANSI; a double that
  # answers no palette prints the body as stored.
  def harness_with_palette(dir, name = 'default')
    memories = Memories.new(dir)
    h = Object.new
    h.define_singleton_method(:memories) { memories }
    h.define_singleton_method(:output_palette) { UI::Palette.new(name) }
    h
  end

  def run_command(dir, args = '')
    stdout = StringIO.new
    described_class.new(harness: harness_with(dir), file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  def run_with_palette(dir, args = '', palette = 'default')
    stdout = StringIO.new
    described_class.new(harness: harness_with_palette(dir, palette),
                        file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: stdout)).handle(args)
    stdout.string
  end

  def write_note(dir, name, content)
    FileUtils.mkdir_p(File.join(dir, Memories::DIR))
    File.write(File.join(dir, Memories::DIR, "#{name}.md"), content)
  end

  describe 'the help entry (issue #323 contract)' do
    it 'declares a HELP entry whose usage starts with its registered name' do
      help = described_class.help

      expect(help.usage).to start_with('memory')
      expect(help.summary).not_to be_empty
      expect(CommandHelp::GROUPS).to have_key(help.group)
    end
  end

  describe 'with no argument (the listing)' do
    it 'lists each note with its description and the count' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'consent', 'YOLO skips the shell dialog.')
        write_note(dir, 'ci', "# CI\n\nrspec and rubocop on ubuntu.")

        out = run_command(dir)

        expect(out).to include("Memories (2/#{Memories::MAX_MEMORIES} notes")
        expect(out).to include('  consent - YOLO skips the shell dialog.')
        expect(out).to include('  ci - rspec and rubocop on ubuntu.')
        expect(out).to include('Show one with: /memory <name>')
      end
    end

    # An empty store is the everyday state; the answer names both the model's
    # route (memory.add) and the file the owner can inspect.
    it 'answers an empty store with where a note would live' do
      Dir.mktmpdir do |dir|
        out = run_command(dir)

        expect(out).to include('No memories stored')
        expect(out).to include('memory.add(name:, text:)')
        expect(out).to include("#{Memories::DIR}/<name>.md")
      end
    end

    # issue #474: the body is stored markdown. The command states the RAW text as the
    # :body role and UI::Renderer renders it, so the markers are consumed by the
    # render instead of printed - the same rule /plans follows, and the bug this closes.
    it 'renders the body markdown with a palette instead of printing markers' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'styled', "# Title\n\nRun **bin/rspec** first.\n")
        out = run_with_palette(dir, 'styled')

        expect(out).to include("\e[")
        expect(out).to include('Title')
        expect(out).not_to include('# Title')
        expect(out).not_to include('**bin/rspec**')
      end
    end

    # palette 'none' renders the STRUCTURE: plain text, no ANSI, no markers.
    it 'renders plain marker-free text under palette none' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'plain', "# Title\n\nRun **bin/rspec** first.\n")
        out = run_with_palette(dir, 'plain', 'none')

        expect(out).not_to include("\e[")
        expect(out).to include('Run bin/rspec first.')
        expect(out).not_to include('# Title')
      end
    end

    it 'shows each note size in chars' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'sized', '12345')

        expect(run_command(dir)).to include('sized - 12345 (5 chars)')
      end
    end
  end

  describe 'with a name (the body)' do
    it 'prints one note body under a named rule line' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'pipeline', "step one\nstep two\n")

        out = run_command(dir, 'pipeline')

        expect(out).to include("--- pipeline (#{Memories::DIR})")
        expect(out).to include("step one\nstep two")
      end
    end

    # Same data the model sees through memory.read (one reader, no drift).
    it 'prints the same text memory.read returns' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'shared', "a\nb\n")

        command_out = run_command(dir, 'shared')
        model_out   = Tools::MemoryReadTool.new(Memories.new(dir)).execute('name' => 'shared')

        expect(command_out).to include(model_out)
      end
    end

    it 'reports an unknown name with the names that exist' do
      Dir.mktmpdir do |dir|
        write_note(dir, 'real', 'text')

        out = run_command(dir, 'typo')

        # The bracket and the glyph are the renderer's (the origin names the store).
        expect(out).to eq("  [memory] ✗ no memory named 'typo' (real)\n")
      end
    end

    it 'refuses a name that is not one path segment' do
      Dir.mktmpdir do |dir|
        expect(run_command(dir, '../sessions'))
          .to eq("  [memory] ✗ a memory name is one path segment: ../sessions\n")
      end
    end
  end

  it 'reads harness.memories, the same store memory.* writes (issue #10)' do
    Dir.mktmpdir do |dir|
      Memories.new(dir).add('written-by-model', 'body')

      expect(run_command(dir)).to include('written-by-model')
    end
  end
end
