# frozen_string_literal: true

require_relative "harness"
require_relative "file_list"
require_relative "task"
require_relative "reporting"
require_relative "command_runner"
require_relative "command"

# Individual command classes.
require_relative "commands/grant_command"
require_relative "commands/clear_command"
require_relative "commands/retry_command"
require_relative "commands/session_command"
require_relative "commands/session_clear_command"
require_relative "commands/compact_command"
require_relative "commands/ctx_command"
require_relative "commands/jobs_command"
require_relative "commands/save_command"
require_relative "commands/reasoning_command"
require_relative "commands/replay_command"
require_relative "commands/sessions_command"
require_relative "commands/tools_command"
require_relative "commands/mcp_command"
require_relative "commands/models_command"
require_relative "commands/model_command"
require_relative "commands/param_command"
require_relative "commands/help_command"
require_relative "commands/exit_command"
require_relative "commands/yolo_command"
require_relative "commands/palette_command"
require_relative "commands/stream_command"
require_relative "commands/skills_command"
require_relative "commands/markdown_command"
require_relative "commands/memory_command"
require_relative "commands/plans_command"
require_relative "commands/plan_command"

require_relative "ui/help_renderer"
require_relative "help_topics"

# Thin dispatcher: checks if input starts with "/", extracts the first word,
# looks up the command class in a registry map, and delegates.
class CommandHandler
  include Reporting

  attr_reader :file_list,
    :ui,
    :settings

  # Registry: command name (without slash) -> class
  COMMANDS = {
    "grant"         => Commands::GrantCommand,
    "clear"         => Commands::ClearCommand,
    "retry"         => Commands::RetryCommand,
    "session"       => Commands::SessionCommand,
    "session-clear" => Commands::SessionClearCommand,
    "compact"       => Commands::CompactCommand,
    "ctx"           => Commands::CtxCommand,
    "jobs"          => Commands::JobsCommand,
    "save"          => Commands::SaveCommand,
    "reasoning"     => Commands::ReasoningCommand,
    "replay"        => Commands::ReplayCommand,
    "sessions"      => Commands::SessionsCommand,
    "tools"         => Commands::ToolsCommand,
    "mcp"           => Commands::McpCommand,
    "models"        => Commands::ModelsCommand,
    "model"         => Commands::ModelCommand,
    "param"         => Commands::ParamCommand,
    "help"          => Commands::HelpCommand,
    "exit"          => Commands::ExitCommand,
    "yolo"          => Commands::YoloCommand,
    "palette"       => Commands::PaletteCommand,
    "stream"        => Commands::StreamCommand,
    "skills"        => Commands::SkillsCommand,
    "markdown"      => Commands::MarkdownCommand,
    "memory"        => Commands::MemoryCommand,
    "plans"         => Commands::PlansCommand,
    "plan"          => Commands::PlanCommand,
  }.freeze

  def initialize(
    file_list:,
    ui:,
    settings: nil,
    registry: nil,
    system_saver: nil,
    harness_factory: nil,
    locator: nil
  )
    @file_list = file_list
    # The run-wide posture/consent state (#286): posture commands read and
    # write it directly instead of routing through Harness.
    @settings  = settings
    @exiting   = false
    @ui        = ui
    # One renderer for the whole run: it reads the registry this class owns,
    # so /help can never list a different set than /dispatch accepts.
    @help_renderer = UI::HelpRenderer.new(
      registry: COMMANDS,
      ui:,
      settings: @settings)
    HelpTopics.validate!(COMMANDS.keys)
    # The JobRegistry the run owns (#286), exposed through Reporting#registry;
    # it is passed to every command built here (build_command).
    self.registry = registry
    # The run's single SystemSaver (#548), passed to every command built here.
    self.system_saver = system_saver
    # The run's HarnessFactory and SessionLocator (#548), passed to every
    # command built here, like the registry.
    @harness_factory = harness_factory
    @locator         = locator
  end

  # The run's single MainLoop (issue #286 increment 3). The loop builds itself and
  # hands the handler a reference so a command that drives an LLM round (a direct
  # prompt, /retry, /compact) submits to the loop's worker instead of starting a
  # drain loop of its own. Set by the CLI right after the loop is built.
  attr_accessor :main_loop

  def exiting?
    @exiting
  end

  # The dispatcher reaches the Harness through the foreground job the run's
  # registry marks (its #run_prompt), never a global (#286).
  def foreground_harness
    registry.foreground_job&.harness
  end

  # Dispatch one submitted line (issue #286 increment 4c): the run loop hands
  # EVERY idle submit here. A bare prompt is recorded and submitted to the
  # worker as a WORK item; a slash-command goes through the registry, and one
  # that needs an LLM round submits its own WORK item (#submit_turn); "!" runs
  # a shell command locally (issue #129). The return value is the JOB whose
  # :done the loop must drain - nil when the line ran inline and nothing is
  # live. No command blocks the main thread on a turn.
  def handle(input)
    input = input.strip
    return if input.empty?

    unless input.start_with?("/")
      if input.start_with?("!")
        run_bang_command(input[1..].to_s.strip)
        return nil
      end
      # A bare prompt is a turn: record the user's line, then submit the round.
      registry.record_user_prompt(input)
      return submit_turn do |task|
        run_prompt(task, input)
      end
    end

    # Flatten multiline slash commands into one line.
    input = input.gsub(/\s*\n\s*/, " ")

    name, args = input[1..].split(" ", 2)
    args ||= ""

    cmd_class = COMMANDS[name]
    if cmd_class
      cmd = build_command(cmd_class)
      cmd.handle(args) # a turn-starting command returns its job (Command#submit_turn)
      @exiting = true if cmd.respond_to?(:exited?) && cmd.exited?
    else
      unknown_command(name)
    end
    nil
  end

  # Submit a turn's block to the run loop's worker and return the job the loop
  # must drain. The non-blocking shape the event model demands: the handler
  # never waits for the turn - MainLoop#run's drain state renders it.
  def submit_turn(&)
    @main_loop&.begin_turn(&)
  end

  # Mid-turn dispatch (issue #286, doc/unified_loop_design.md): the poll loop
  # IS the main thread, so a "/command" submitted while a turn runs is dispatched
  # here. A command that declares mid_turn_safe? (a pure state write) runs inline;
  # one that drives an LLM round or rebuilds the run is refused with a hint
  # instead of silently starting a second drain loop over the single queue. This
  # is what removes the old /yolo note-gesture special case: /yolo is now just a
  # command like any other. A non-slash submit is ignored (the caller routes it
  # as a note).
  def run_mid_turn(input)
    input = input.to_s.strip
    return unless input.start_with?("/")

    name, args = input.gsub(/\s*\n\s*/, " ")[1..].split(" ", 2)
    args ||= ""
    cmd_class = COMMANDS[name]
    if cmd_class.nil?
      unknown_command(name)
      return
    end

    unless cmd_class.mid_turn_safe?
      emit_role(
        :kind,
        "/#{name} is not available while a turn is running",
        origin: "note")
      return
    end

    build_command(cmd_class).handle(args)
  end

  # Build a command instance with the run's context. Shared by idle #handle and
  # the mid-turn dispatcher so both construct identically.
  def build_command(cmd_class)
    cmd_class.new(
      file_list:,
      ui:,
      help_renderer: @help_renderer,
      settings: @settings,
      registry:,
      system_saver:,
      harness_factory: @harness_factory,
      main_loop: @main_loop,
      locator: @locator)
  end

  # issue #129: `! cmd` runs a shell command locally, bypassing the model.
  # The same safety model as the run.command tool applies (CommandRunner):
  # the full command is shown and an explicit "Allow" is required unless the
  # prefix is in the local shell allowlist (shell_commands.yml - separate
  # from the run.command list). The command and its output never enter the
  # session. Runs on the main thread - the dialog is served in place on the
  # console, no Task involved.
  def run_bang_command(command)
    if command.empty?
      ui.puts "  usage: ! <command> (runs locally, never sent to the model)"
      return
    end

    # Flatten multiline input the same way slash commands are flattened.
    command = command.gsub(/\s*\n\s*/, " ").strip

    # Issue #221: the bang path is the one place where the harness asks a
    # human to confirm a command the SAME human just typed - the purest form
    # of consent fatigue. The config key 'bang_requires_confirmation'
    # (default true, i.e. today's behavior) lets the user drop it: with the
    # key false, auto_approve_all is passed to the runner and every bang
    # command runs immediately. YOLO does NOT cover bang syntax - the
    # human's own typing is already the consent, so a separate switch
    # controls it (the user's choice for issue #221). Either way the
    # disaster denylist still gates the command: `! rm -rf /` is always
    # confirmed.
    runner = CommandRunner.new(
      @file_list,
      @settings,
      label: "shell",
      harness: foreground_harness, # failed commands traced in harness.log (issue #185)
      title_fmt: CommandRunner::BANG_TITLE,
      ui: @ui,
      list: :shell,
      # Default true: bang commands keep the confirmation dialog (issue #221).
      auto_approve_all: @settings.bang_requires_confirmation == false)
    result = runner.run(command).to_s

    if result.start_with?("error: user denied")
      # The runner already printed the denial status line.
    elsif result.start_with?("error:")
      # State the :error role; UI::Renderer adds the label (#146 / #466),
      # and the sink decides its color. No hand-written "  [error] " prefix.
      emit_role(:error, result.delete_prefix("error: "))
    else
      ui.puts result
    end
  end

  # The turn block for a bare prompt (issue #286 increment 4c): the user's own
  # line is one side of the exchange the resume replay redraws; the registry
  # records it in the foreground buffer (issue #458). The block runs on the
  # worker thread (single-thread I/O rule): the model layer is reached through
  # the job's own Harness. #report_turn_error below is called by the loop's
  # drain state, so both stay public.
  def run_prompt(_task, text)
    foreground_harness.session_manager.run_prompt(text)
  end

  # A turn ended with a task error: report it the way the old run_on_task did -
  # a :kind role line plus the aborted-turn summary (printed, not emitted: the
  # turn is over, an event would be read by the next one, #567).
  def report_turn_error(job, error)
    emit_role(:kind, error, origin: "task error") if error
    summary = job&.harness&.aborted_turn_stats_line(job.id)
    ui.puts(summary) unless summary.nil?
  end

  private

  # A wrong command name is usually a typo, so name the closest registered
  # names - all of them derived from the SAME registry the dispatch just
  # missed (issue #323).
  def unknown_command(name)
    suggestions = @help_renderer.command_suggestions(name)
    if suggestions.empty?
      ui.puts "Unknown command: /#{name}. Type /help for available commands."
      return
    end

    named = suggestions.map { |s| "/#{s}" }.join(", ")
    ui.puts "Unknown command: /#{name}. Did you mean #{named}? (/help lists all)"
  end
end
