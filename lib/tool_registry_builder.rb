# frozen_string_literal: true

require_relative "tool_registry"
require_relative "mcp/manager"
require_relative "skills"
require_relative "memories"
require_relative "plans"
require_relative "error_text"

require_relative "tools/echo_tool"
require_relative "tools/notify_tool"
require_relative "tools/dialog_tool"
require_relative "tools/get_time_tool"
require_relative "tools/file_list_tool"
require_relative "tools/file_read_tool"
require_relative "tools/file_image_tool"
require_relative "tools/file_write_tool"
require_relative "tools/file_rename_tool"
require_relative "tools/file_delete_tool"
require_relative "tools/file_search_tool"
require_relative "tools/file_patch_tool"
require_relative "tools/file_copy_tool"
require_relative "tools/file_info_tool"
require_relative "tools/note_tool"
require_relative "tools/dir_create_tool"
require_relative "tools/dir_delete_tool"
require_relative "tools/git_diff_tool"
require_relative "tools/git_show_tool"
require_relative "tools/git_status_tool"
require_relative "tools/git_log_tool"
require_relative "tools/git_grep_tool"
require_relative "tools/git_apply_tool"
require_relative "tools/run_command_tool"
require_relative "tools/web_fetch_tool"
require_relative "tools/tools_list_tool"
require_relative "tools/tools_search_tool"
require_relative "tools/skills_list_tool"
require_relative "tools/skills_read_tool"
require_relative "tools/memory_list_tool"
require_relative "tools/memory_read_tool"
require_relative "tools/memory_add_tool"
require_relative "tools/plan_list_tool"
require_relative "tools/plan_read_tool"
require_relative "tools/plan_add_tool"
require_relative "tools/plan_delete_tool"
require_relative "tools/plan_search_tool"
require_relative "tools/memory_delete_tool"
require_relative "tools/sessions_search_tool"

# Builds the run's ToolRegistry from collaborators handed in, not from Harness
# state (#286): the file cache, the run settings, the logger and the session
# locator all arrive as arguments, so the registry (and the MCP::Manager it
# loads) can be owned by the run's creator instead of being assembled inside
# the turn engine.
#
# The one remaining Harness dependency is run.command: CommandRunner's
# AUTO-APPROVE safety fork needs a live turn (client + session chain +
# tools_payload), so a harness-shaped object is passed straight through to the
# tool. Narrowing that to a dedicated safety-fork collaborator is the separate
# TurnEngine increment; until then this builder forwards `harness:`.
class ToolRegistryBuilder
  # The Mcp::Manager this build connected, so its owner can close it, report
  # its startup notes, save its connected_summary, and compare a resumed
  # session's saved servers against it (#48, #405). Built here, not in Harness.
  attr_reader :mcp

  def initialize(file_list:, file_cache:, options:, settings:, logger:, locator:,
                 harness: nil)
    @file_list = file_list
    @file_cache = file_cache
    @options   = options
    @settings  = settings
    @logger    = logger
    @locator   = locator
    @harness   = harness
    @mcp       = Mcp::Manager.new(logger)
  end

  def build
    registry = ToolRegistry.new
    registry.register(Tools::EchoTool.new)
    registry.register(Tools::NotifyTool.new)
    registry.register(Tools::DialogTool.new)
    registry.register(Tools::GetTimeTool.new)
    registry.register(Tools::FileListTool.new(@file_list))
    registry.register(Tools::FileReadTool.new(@file_list, @file_cache))
    registry.register(Tools::FileImageTool.new(@file_list))
    registry.register(Tools::FileWriteTool.new(@file_list, @file_cache))
    registry.register(Tools::FileRenameTool.new(@file_list, @file_cache))
    registry.register(Tools::FileDeleteTool.new(@file_list, @file_cache))
    registry.register(Tools::FileSearchTool.new(@file_list))
    registry.register(Tools::FilePatchTool.new(@file_list, @file_cache))
    registry.register(Tools::FileCopyTool.new(@file_list))
    registry.register(Tools::FileInfoTool.new(@file_list))
    registry.register(Tools::DirCreateTool.new(@file_list))
    registry.register(
      Tools::DirDeleteTool.new(
        @file_list,
        file_cache: @file_cache,
        logger: @logger))
    registry.register(Tools::NoteTool.new)
    registry.register(Tools::GitDiffTool.new(@file_list))
    registry.register(Tools::GitShowTool.new(@file_list))
    registry.register(Tools::GitStatusTool.new(@file_list))
    registry.register(Tools::GitLogTool.new(@file_list))
    registry.register(Tools::GitGrepTool.new(@file_list))
    registry.register(Tools::GitApplyTool.new(@file_list, @file_cache))
    registry.register(
      Tools::RunCommandTool.new(
        @file_list,
        @options,
        harness: @harness))
    registry.register(
      Tools::WebFetchTool.new(
        @file_list,
        @options,
        logger: @logger))
    registry.register(Tools::ToolsListTool.new(registry))
    registry.register(Tools::ToolsSearchTool.new(registry))
    # The FS-backed stores (memories, plans, skills) are not Harness state: each
    # is a stateless reader over its on-disk dir, so the tools that serve them get
    # their own instance built here from the run's workdir. /memory, /plans and
    # /skills build the same store from the same workdir - the dir is the single
    # source of truth, so the tool side and the command side cannot drift (#286).
    # The note cap is the config 'max_memories:' key (#435); nil -> the default.
    skills    = Skills.new(@file_list.workdir)
    memories  = Memories.new(@file_list.workdir, max_memories: @settings.max_memories)
    plans     = Plans.new(@file_list.workdir)
    registry.register(Tools::SkillsListTool.new(skills))
    registry.register(Tools::SkillsReadTool.new(skills))
    registry.register(Tools::MemoryListTool.new(memories))
    registry.register(Tools::MemoryReadTool.new(memories))
    registry.register(Tools::MemoryAddTool.new(memories))
    registry.register(Tools::MemoryDeleteTool.new(memories))
    registry.register(Tools::PlanListTool.new(plans))
    registry.register(Tools::PlanReadTool.new(plans))
    registry.register(Tools::PlanAddTool.new(plans))
    registry.register(Tools::PlanDeleteTool.new(plans))
    registry.register(Tools::PlanSearchTool.new(plans))
    # issue #279: let the model FIND a saved session by what it was ABOUT, not
    # just count them. Read-only, over the run's own SessionLocator (the single
    # place that knows where sessions live) - no Harness, no resume, no delete.
    registry.register(Tools::SessionsSearchTool.new(@locator))
    # MCP last, so a server tool whose name collides with a built-in is skipped
    # (the built-in wins) and the servers connect after the run's own tools exist.
    @mcp.load(registry, @settings.mcp_servers)
    registry
  end
end
