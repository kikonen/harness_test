# frozen_string_literal: true

require_relative 'harness'
require_relative 'file_list'

# Individual command classes.
require_relative 'commands/file_command'
require_relative 'commands/dir_command'
require_relative 'commands/clear_command'
require_relative 'commands/retry_command'
require_relative 'commands/session_command'
require_relative 'commands/session_clear_command'
require_relative 'commands/compact_command'
require_relative 'commands/ctx_command'
require_relative 'commands/reload_command'
require_relative 'commands/save_command'
require_relative 'commands/resume_command'
require_relative 'commands/sessions_command'
require_relative 'commands/tools_command'
require_relative 'commands/models_command'
require_relative 'commands/model_command'
require_relative 'commands/help_command'
require_relative 'commands/exit_command'

# Thin dispatcher: checks if input starts with "/", extracts the first word,
# looks up the command class in a registry map, and delegates.
class CommandHandler
  attr_reader :harness, :file_list, :options

  # Registry: command name (without slash) -> class
  COMMANDS = {
    'file'          => Commands::FileCommand,
    'dir'           => Commands::DirCommand,
    'clear'         => Commands::ClearCommand,
    'retry'         => Commands::RetryCommand,
    'session'       => Commands::SessionCommand,
    'session-clear' => Commands::SessionClearCommand,
    'compact'       => Commands::CompactCommand,
    'ctx'           => Commands::CtxCommand,
    'reload'        => Commands::ReloadCommand,
    'save'          => Commands::SaveCommand,
    'resume'        => Commands::ResumeCommand,
    'sessions'      => Commands::SessionsCommand,
    'tools'         => Commands::ToolsCommand,
    'models'        => Commands::ModelsCommand,
    'model'         => Commands::ModelCommand,
    'help'          => Commands::HelpCommand,
    'exit'          => Commands::ExitCommand,
  }.freeze

  def initialize(harness, file_list, options)
    @harness   = harness
    @file_list = file_list
    @options   = options
    @exiting   = false
  end

  def exiting?
    @exiting
  end

  # Delegate for CLI's --list-sessions flag.
  def list_sessions
    Commands::SessionsCommand.new(harness, file_list, options).handle('')
  end

  # Build the command line to resume a saved session in a new harness run.
  def resume_command(id)
    Commands::ResumeCommand.new(harness, file_list, options).resume_cli_string(id)
  end

  # Dispatch a single line of input. Slash-commands go through the registry;
  # anything else is sent as a direct prompt to the model.
  def handle(input)
    input = input.strip
    return if input.empty?

    unless input.start_with?('/')
      run_direct_prompt(input)
      return
    end

    # Flatten multiline slash commands into one line.
    input = input.gsub(/\s*\n\s*/, ' ')

    name, args = input[1..].split(' ', 2)
    args ||= ''

    cmd_class = COMMANDS[name]
    if cmd_class
      cmd = cmd_class.new(harness, file_list, options)
      cmd.handle(args)
      @exiting = true if cmd.respond_to?(:exited?) && cmd.exited?
    else
      puts "Unknown command: /#{name}.\n----\nType /help for available commands."
    end
  end

  private

  def run_direct_prompt(text)
    puts
    @harness.session_manager.run_prompt(text)
    puts
  end
end
