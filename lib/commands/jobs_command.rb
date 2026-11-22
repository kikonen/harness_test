# frozen_string_literal: true

require_relative "../command"

module Commands
  # /jobs - list the registry's jobs and mark the foreground one (issue #286),
  # switch which job is foreground, add a new agent, and delete one (issue #558).
  # Removal is delegated: the registry owns the live list, SystemSaver the dir.
  class JobsCommand < Command
    HELP = CommandHelp.new(
      usage: "jobs",
      summary: "List every job on the registry's flat list and mark the " \
        "foreground one; 'switch <id>' makes another retained job foreground; " \
        "'add' gives the run a new agent; 'delete <id>' removes one",
      group: :session,
      forms: ["jobs", "jobs <id>", "jobs switch <id>", "jobs add", "jobs delete <id>"],
      form_notes: {
        "jobs <id>" => "short form of 'switch <id>': /job 1 style switching",
        "jobs switch <id>" => "switch the foreground job to an id the registry retains",
        "jobs add [prompt]" => "add a sub-agent job built through the run's " \
          "HarnessFactory and make it foreground, so the next prompt goes to it",
        "jobs delete <id>" => "remove a job from the run and its saved dir; the " \
          "foreground job cannot be deleted, a running job cannot be interrupted here"
      },
      see_also: %w[help session])

    # Mid-turn submits would reach the new agent's first prompt on the main
    # thread, so it is refused like every LLM-driving command until input
    # becomes an event to the live task (doc/unified_loop_design.md).
    def self.mid_turn_safe? = false

    def handle(args)
      return emit_role(:note, "No registry - nothing to list.") if registry.nil?

      # name is nil for empty args (split of "" is []), so every test below
      # goes through to_s.
      name, arg = args.to_s.strip.split(/\s+/, 2)
      return add(arg.to_s) if name == "add"
      return delete(arg) if name == "delete"
      return switch(registry, arg) if name == "switch"
      # A bare id is the short form of a switch: /jobs 1 (or /jobs #1) reaches the
      # job the next prompt should go to without the word. Checked AFTER the words
      # so a word is never mistaken for an id.
      return switch(registry, name) if name.to_s.match?(/\A#?\d+\z/)

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

      # A job can only carry the record it owns: a saved tail is written per job,
      # so handing the current job's tail to the job being switched to would move
      # one job's history into another and then save it there.
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
      # The line is recorded BEFORE this job is made foreground, named as its
      # owner: the job being foregrounded is the one its saved tail is read from,
      # so a record written while some other job was foreground would land in
      # that other job's buffer and this job would save an empty one.
      registry.record_user_prompt(prompt, job:) unless prompt.empty?
      registry.foreground = job.id
      note = "job ##{job.id} (#{job.kind}) added with its own agent; " \
        "foreground job is now ##{registry.foreground}"
      emit_role(:note, note)
      show_registry(registry)
    end

    # A running job is refused: a command dispatched while idle has no handle
    # on a live task's thread to stop it.
    def delete(raw_id)
      shown = raw_id.to_s.strip
      return render_usage if shown.empty?

      id = shown.delete("#").to_i
      target = registry.job(id)
      return emit_role(:error, "job ##{id} is not retained") if target.nil?
      if registry.foreground?(id)
        return emit_role(:error, "cannot delete the foreground job ##{id}")
      end
      if target.running?
        return emit_role(:error, "job ##{id} is running; it cannot be interrupted here")
      end
      if @session_id.nil? || system_saver.nil?
        return emit_role(:error, "No system id - a job is named by its directory.")
      end

      target.interrupt
      removed = system_saver.remove_job(@session_id, id)
      re_save_running_system
      emit_role(:note, "job ##{removed} (#{target.kind}) deleted from the run")
      show_registry(registry)
    end

    # Re-save so a delete-then-quit run cannot rewrite the removed job back
    # into system.json from the live registry.
    def re_save_running_system
      return if @session_id.nil?
      return unless system_saver.job_restores(@session_id).any?

      begin
        system_saver.save_run(@session_id)
      rescue StandardError => e
        emit_role(:warn, "job removed but the system re-save failed (#{e.message})")
      end
    end
  end
end
