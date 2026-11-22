# frozen_string_literal: true

require_relative "../command"

module Commands
  # /jobs - list the registry's jobs and mark the foreground one (issue #286),
  # switch which job is foreground, and add a new agent to the run. The registry
  # owns the flat list, so the command reports it as data through UI::Renderer
  # (issue #474): the row shape is the renderer's, not a fused string built here.
  class JobsCommand < Command
    HELP = CommandHelp.new(
      usage: "jobs",
      summary: "List every job on the registry's flat list and mark the " \
        "foreground one; 'switch <id>' makes another retained job foreground; " \
        "'add' gives the run a new agent",
      group: :session,
      forms: ["jobs", "jobs switch <id>", "jobs add"],
      form_notes: {
        "jobs switch <id>" => "switch the foreground job to an id the registry retains",
        "jobs add [prompt]" => "add a sub-agent job built through the run's " \
          "HarnessFactory and make it foreground, so the next prompt goes to it"
      },
      see_also: %w[help session])

    # Mid-turn submits would reach the new agent's first prompt on the main
    # thread, so it is refused like every LLM-driving command until input
    # becomes an event to the live task (doc/unified_loop_design.md).
    def self.mid_turn_safe? = false

    def handle(args)
      return emit_role(:note, "No registry - nothing to list.") if registry.nil?

      name, arg = args.to_s.strip.split(" ", 2)
      return add(arg.to_s) if name == "add"
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

    # Add an agent to the run and drive it (#548). Building it is the system
    # owner's business, so the command goes through the run's HarnessFactory -
    # the same call the CLI used for the main turn, with only `kind` changed -
    # and never assembles a Harness itself. Making the new job foreground is
    # what makes it drivable: #run_direct_prompt sends the next prompt to
    # `registry.foreground_job`, so its agent runs the prompt on a task thread
    # with the drain loop rendering it.
    def add(args)
      prompt = args.to_s.strip
      # The form word is consumed, not remembered: `add sub_agent x` drives the
      # new job with x, and the switch below re-records this very line into that
      # job's buffer, so keeping the word here would store the usage twice.
      prompt = "" if prompt == "sub_agent"
      if @harness_factory.nil?
        return emit_role(:error, "No HarnessFactory - this run adds no agents.")
      end
      if @session_id.nil?
        return emit_role(:error, "No system id - a job is named by its directory.")
      end

      # No `dependencies`: those gate a job's START, and a foreground job the
      # user prompts has no gate to wait behind. `requested_by` is the link out.
      job = @harness_factory.add_harness_job(
        kind: :sub_agent,
        session_id: @session_id,
        requested_by: registry.foreground_job)
      registry.foreground = job.id
      note = "job ##{job.id} (#{job.kind}) added with its own agent; " \
        "foreground job is now ##{registry.foreground}"
      emit_role(:note, note)
      show_registry(registry)
      registry.record_user_prompt(prompt, job:) unless prompt.empty?
    end
  end
end
