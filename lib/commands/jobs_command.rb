# frozen_string_literal: true

require_relative "../command"

module Commands
  # /jobs - list the registry's jobs and mark the foreground one (issue #286),
  # and switch which job is foreground. The registry owns the flat list, so the
  # command reports it as data through UI::Renderer (issue #474): the row shape
  # is the renderer's, not a fused string built here.
  class JobsCommand < Command
    HELP = CommandHelp.new(
      usage: "jobs",
      summary: "List every job on the registry's flat list and mark the " \
        "foreground one; 'switch <id>' makes another retained job foreground",
      group: :session,
      forms: ["jobs", "jobs switch <id>"],
      form_notes: {
        "jobs switch <id>" => "switch the foreground job to an id the registry retains"
      },
      see_also: %w[help session])

    def handle(args)
      registry = @harness.respond_to?(:registry) ? @harness.registry : nil
      return emit_role(:note, "No registry - nothing to list.") if registry.nil?

      name, arg = args.to_s.strip.split(" ", 2)
      return switch(registry, arg) if name == "switch"

      show_registry(registry)
    end

    private

    def show_registry(registry)
      items = registry.jobs.map do |job|
        {
          mark: registry.foreground?(job.id) ? "*" : "",
          job: "##{job.id}",
          kind: job.kind.to_s,
          status: job.status.to_s
        }
      end
      emit_list(
        title: "Jobs (foreground marked *)",
        kind: :table,
        columns: %i[mark job kind status],
        items:,
        origin: "jobs")
    end

    # Only a retained job can be made foreground: a dropped job has no buffer to
    # show, so the registry refuses an id it does not hold.
    def switch(registry, raw_id)
      shown = raw_id.to_s.strip
      return render_usage if shown.empty?

      id = shown.delete("#").to_i
      begin
        registry.foreground = id
      rescue ArgumentError => e
        return emit_role(:error, e.message.delete_prefix("error: "))
      end

      emit_role(:note, "foreground job is now ##{registry.foreground} (buffer is active)")
    end
  end
end
