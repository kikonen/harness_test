# frozen_string_literal: true

require_relative "../command"
require_relative "../main_loop"

module Commands
  # /replay - print the tail of what the run RECORDED, the same entries a resume
  # redraws at startup (issue #458), without leaving the run. The record is the
  # registry's (issue #286), so the command reads it through the registry instead
  # of opening a saved file: what it shows is what the next resume would show.
  #
  # The SHAPE is the startup replay's, on purpose: the same UI::Renderer#line per
  # entry between two block rules. A record line is stored as its role (:user,
  # :response, a tool status, a :list payload), so redrawing it through the
  # renderer reproduces the line the user saw - a flattened table would not be the
  # replay any more. The limit picks HOW MANY of those lines to show; the record
  # itself is capped by the saved window (max_saved).
  class ReplayCommand < Command
    HELP = CommandHelp.new(
      usage: "replay [n] [job <id>|all]",
      summary: "Print the last recorded lines of the run - the same tail a " \
        "resume redraws - optionally how many, and for one job or every job",
      group: :session,
      forms: ["replay [n]", "replay [n] job <id>", "replay [n] all"],
      form_notes: {
        "replay [n]" => "the foreground job's tail, last n lines (default 10)",
        "replay [n] job <id>" => "one job's own tail",
        "replay [n] all" => "every retained job's tail, each labelled"
      },
      see_also: %w[help session jobs sessions])

    # How many recorded lines one report shows when no count is given. The saved
    # window (max_saved) is the ceiling on what exists to show.
    DEFAULT_LIMIT = 10

    def handle(args)
      return emit_role(:note, "No registry - nothing recorded.") if registry.nil?

      parts = args.to_s.strip.split(/\s+/)
      return if limit_for(parts).nil?

      return show_every_job if parts.include?("all")

      show_job(job_for(parts))
    end

    private

    # The count is the first bare number BEFORE a selector word: "all 20" counts
    # 20, "job 1" names job 1 (its digits belong to the selector).
    def limit_for(parts)
      selector = parts.index { |part| %w[all job].include?(part) }
      scoped   = selector ? parts[0...selector] : parts
      @limit   = scoped.find { |part| part.match?(/\A\d+\z/) }&.to_i || DEFAULT_LIMIT
      return emit_role(:note, "limit 0 prints nothing") if @limit.zero?

      @limit
    end

    def job_for(parts)
      return registry.foreground_job unless parts.index("job")

      parse_job(parts)
    end

    def parse_job(parts)
      raw = parts[parts.index("job") + 1].to_s
      return report_no_job("usage: replay job <id>") if raw.empty?

      job = registry.job(raw.delete("#").to_i)
      job || report_no_job("job #{raw} is not retained by this run")
    end

    def report_no_job(message)
      emit_role(:error, message)
      nil
    end

    def show_job(job)
      return if job.nil?

      # The header names the job with the modeline/spinner tag (issue #548), plus
      # FOREGROUND for the one the next prompt reaches.
      tag = MainLoop.job_tag(job).to_s
      tag += " FOREGROUND" if registry.foreground?(job.id)
      header  = "Replay #{tag} (#{job.kind}, #{job.status})"
      entries = registry.replay_tail_for_job(job.id)
      render_block(header, entries)
    end

    def show_every_job
      registry.jobs.each { |job| show_job(job) }
    end

    # The startup replay's layout (StartupBanner#print_resume_replay): rule, one header
    # line, the entries through the renderer, rule. The renderer is built the way
    # TaskRunner builds one (the sink's palette wins, then the run's settings) so
    # a command with no harness of its own paints the same lines the run does.
    def render_block(header, entries)
      return emit_role(:note, "#{header}: nothing recorded") if entries.empty?

      shown = tail_of(entries)
      renderer = UI::Renderer.new(
        palette: UI::Renderer.palette_for(ui:, settings:),
        markdown: settings&.markdown?,
        markdown_max_width: settings&.markdown_max_width,
        ui:)
      rule = "-" * UI::Renderer::RULE_WIDTH

      ui.puts
      ui.puts rule
      ui.puts "#{header}: #{shown.size} of #{entries.size} recorded lines"
      shown.each do |entry|
        line = renderer.line(
          type: entry[:type],
          content: entry[:content],
          origin: entry[:origin])
        ui.puts line
      end
      ui.puts rule
      ui.flush if ui.respond_to?(:flush)
    end

    def tail_of(entries)
      return entries if @limit >= entries.size

      entries.last(@limit)
    end
  end
end
