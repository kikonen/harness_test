# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ui/palette'
require 'commands/palette_command'

# issue #303: /palette switches the rendered-output palette mid-session and
# the choice travels with the session. The command only talks to
# Harness#output_palette / #output_palette=, so a double exposing that pair
# (real UI::Palette objects, like the real Harness resolves) is enough.
RSpec.describe Commands::PaletteCommand do
  # Mirrors Harness#output_palette / #output_palette= (validation included).
  def build_harness(name = nil)
    h = Object.new
    palette = UI::Palette.fetch(name)
    h.define_singleton_method(:output_palette) { palette }
    h.define_singleton_method(:output_palette=) do |arg|
      palette = UI::Palette.fetch(arg)
    end
    h
  end

  def run_command(args = '', harness = build_harness)
    io = StringIO.new
    described_class.new(harness: harness, file_list: nil, options: nil,
                        ui: UI::Console.new(stdout: io)).handle(args)
    io.string
  end

  describe 'with no argument (/palette)' do
    it 'reports the current palette name' do
      expect(run_command('', build_harness('basic16'))).to include('Output palette: basic16')
    end

    it 'lists the names it accepts' do
      out = run_command

      expect(out).to include('default, basic16, none')
      expect(out).to include('/palette <name>')
    end

    it 'accepts /palette status as the same view' do
      out = run_command('status', build_harness('basic16'))

      expect(out).to include('Output palette: basic16')
      # 'status' is reserved: it must never be treated as a palette name.
      expect(out).not_to include('unknown output palette')
    end

    it 'names which roles the palette colors and which stay plain' do
      out = run_command('', build_harness('default'))

      expect(out).to include('plan=34')
      expect(out).to include('warn=38;5;130')
      expect(out).to include('model answer, tool and command lines')
    end

    it 'shows a sample line so the change is visible without a new turn' do
      out = run_command('', build_harness('default'))

      expect(out).to include("\e[34mplan:  inspect the drain loop first\e[0m")
      expect(out).to include('step 1')
    end

    it 'the none palette paints nothing in the sample either' do
      out = run_command('', build_harness('none'))

      expect(out).to include('colored roles: (none)')
      expect(out).not_to include("\e[")
    end
  end

  describe 'switching (/palette <name>)' do
    it 'changes the harness palette and acks with the new label' do
      harness = build_harness('default')
      out = run_command('basic16', harness)

      expect(harness.output_palette.name).to eq('basic16')
      expect(out).to include('[palette: basic16] (was default)')
    end

    it 'says unchanged when the same palette is set again' do
      out = run_command('default', build_harness('default'))

      expect(out).to include('[palette: default] (unchanged)')
      expect(out).not_to include('was')
    end

    it 'accepts a name in any case (/palette NONE)' do
      harness = build_harness('default')
      run_command('NONE', harness)

      expect(harness.output_palette.name).to eq('none')
    end

    it 'says the choice is saved with the session' do
      expect(run_command('none')).to include('Saved with the session (resume keeps it)')
    end

    it 'rejects an unknown name with the available list' do
      expect { run_command('crayola') }
        .to raise_error(HarnessError, /unknown output palette/)
    end

    it 'leaves the palette untouched when the name is rejected' do
      harness = build_harness('basic16')
      begin
        run_command('crayola', harness)
      rescue HarnessError
        nil
      end

      expect(harness.output_palette.name).to eq('basic16')
    end
  end
end
