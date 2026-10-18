# frozen_string_literal: true

require_relative "../command"
require_relative "../ui/palette"
require_relative "../ui/renderer"

module Commands
  # /palette [name|status] - show or switch the rendered-output palette for
  # this session (issue #303).
  #
  # What it changes: the palette Harness hands to every Task it runs, so the
  # NEXT turn renders with it (a Task builds its UI::Renderer once, at #run).
  # What it does NOT change: the OutputBuffer entries, which stay plain role
  # content whatever the console line looks like.
  #
  # A sample line is printed with the NEW palette so the change is visible
  # immediately instead of only from the next turn.
  #
  # The choice is saved with the session (SessionManager#save_session) like the
  # active model and the YOLO posture, so a resumed session keeps it. An
  # unknown name raises HarnessError, which the CLI prints as [error].
  class PaletteCommand < Command
    # Roles shown in the sample line: the three the user asked to be told
    # apart (issue #303) plus one alert role.
    SAMPLE = [
      [:step_label, 1],
      [:plan, "inspect the drain loop first"],
      [:tool_plan, "file.read, file.search"],
      [:error, "hunk at old-line 42 did not apply"]
    ].freeze

    def handle(args)
      arg = args.to_s.strip.downcase
      case arg
      when "", "status"
        report
      else
        set(arg)
      end
    end

    private

    def set(name)
      previous = @harness.output_palette&.name
      @harness.output_palette = name
      current = @harness.output_palette

      # Same shape as /yolo: the bare bracketed label is the ack.
      changed = current.name != previous
      label   = changed ? "(was #{previous || 'none'})" : "(unchanged)"
      @ui.puts "  [palette: #{current.name}] #{label}"
      # A Task builds its renderer once at Task.run, so a turn already running
      # keeps the palette it started with; the sample line shows the new one.
      @ui.puts "  Effective from the next turn (this turn's Task already chose)."
      print_roles(current)
      print_sample(current)
      @ui.puts "  Saved with the session (resume keeps it). Startup choice:"
      @ui.puts "  -p/--palette NAME or 'output_palette:' in the config."
    end

    def report
      current = @harness.output_palette
      @ui.puts "Output palette: #{current ? current.name : 'none'}"
      print_roles(current)
      print_sample(current)
      @ui.puts "Switch with /palette <name>; available: " \
        "#{UI::Palette.names.join(', ')}"
      @ui.puts "  basic16 - codes stay inside 30..37 (a 16-color-only terminal)"
      @ui.puts "  none    - no color at all (what --no-color selects)"
    end

    # What the palette actually paints, so the names are not guesswork.
    def print_roles(palette)
      roles = palette_roles(palette).filter_map do |role|
        code = palette&.color_for(role)
        code.nil? ? nil : "#{role}=#{code}"
      end
      @ui.puts "  colored roles: #{roles.empty? ? '(none)' : roles.join(' ')}"
      @ui.puts "  plain roles: model answer, tool and command lines"
    end

    # Rendered through the SAME UI::Renderer the drain loop uses, so the
    # preview is the real thing and not a hand-built approximation.
    def print_sample(palette)
      renderer = UI::Renderer.new(palette:)
      SAMPLE.each { |type, text| @ui.puts "  #{renderer.line(type:, content: text)}" }
    end

    def palette_roles(palette)
      return [] if palette.nil?

      UI::Renderer::LABELS.keys + %i[system stats compact text]
    end
  end
end
