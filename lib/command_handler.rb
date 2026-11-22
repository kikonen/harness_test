# frozen_string_literal: true

require_relative "harness"
require_relative "file_list"
require_relative "task"
require_relative "task_runner"
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
  include TaskRunner

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
    session_id: nil
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
    # The JobRegistry the run owns (#286), exposed through TaskRunner#registry;
    # it is passed to every command built here (build_command).
    self.registry = registry
    # The run's single SystemSaver (#548), passed to every command built here.
    self.system_saver = system_saver
    # The run's HarnessFactory and SYSTEM id (#548): a command that adds an
    # agent to the run builds it through the factory, under the id the run
    # owner alone knows. Passed to every command built here, like the registry.
    @harness_factory = harness_factory
    @session_id      = session_id
  end

  def exiting?
    @exiting
  end

  # The dispatcher reaches the Harness through the foreground job the run's
  # registry marks (its #run_direct_prompt), never a global (#286).
  def foreground_harness
    registry.foreground_job&.harness
  end

  # Dispatch a single line of input. Slash-commands go through the registry;
  # lines starting with "!" run a shell command locally (issue #129);
  # anything else is sent as a direct prompt to the model.
  def handle(input)
    input = input.strip
    return if input.empty?

    unless input.start_with?("/")
      if input.start_with?("!")
        run_bang_command(input[1..].to_s.strip)
        return
      end
      run_direct_prompt(input)
      return
    end

    # Flatten multiline slash commands into one line.
    input = input.gsub(/\s*\n\s*/, " ")

    name, args = input[1..].split(" ", 2)
    args ||= ""

    cmd_class = COMMANDS[name]
    if cmd_class
      cmd = build_command(cmd_class)
      cmd.handle(args)
      @exiting = true if cmd.respond_to?(:exited?) && cmd.exited?
    else
      unknown_command(name)
    end
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
      session_id: @session_id)
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

  private

  # issue #40: direct prompts run on a Task thread. All console I/O is
  # serialized through the main thread via the drain loop (single-thread
  # I/O rule): the task thread emits typed entries to its OutputBuffer via
  # Task.emit (or posts blocking requests for dialogs), and the drain loop
  # renders everything on the main thread - including spinner frames.
  # The shared wrapper lives in TaskRunner (issue #235: /retry reuses it).
  def run_direct_prompt(text)
    # The user's own line is one side of the exchange the resume replay
    # redraws; the run's JobRegistry records it in the foreground buffer
    # (issue #458, #286: the run record is not the single-turn-engine's).
    registry.record_user_prompt(text)
    run_on_task do |_t|
      foreground_harness.session_manager.run_prompt(text)
    end
  end

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
