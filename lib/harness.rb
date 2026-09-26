# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'time'
require 'thread'
require 'digest'
require 'fileutils'

require_relative 'keep_alive_http'
require_relative 'harness_error'
require_relative 'spinner'
require_relative 'tool'
require_relative 'file_list'
require_relative 'session'
require_relative 'tools/echo_tool'
require_relative 'tools/notify_tool'
require_relative 'tools/get_time_tool'
require_relative 'tools/file_read_tool'
require_relative 'tools/file_write_tool'
require_relative 'tools/file_sha_tool'
require_relative 'tools/file_rename_tool'
require_relative 'tools/file_delete_tool'
require_relative 'tools/file_list_tool'
require_relative 'tools/file_search_tool'
require_relative 'tools/file_patch_tool'
require_relative 'tools/file_copy_tool'
require_relative 'tools/dir_create_tool'
require_relative 'tools/dir_delete_tool'
require_relative 'tools/git_diff_tool'
require_relative 'tools/git_show_tool'
require_relative 'tools/git_status_tool'
require_relative 'tools/git_log_tool'
require_relative 'tools/git_apply_tool'
require_relative 'tools/tools_list_tool'
require_relative 'tools/tools_search_tool'
require_relative 'tool_registry'

# -- Harness --------------------------------------------------------------

class Harness
  SYSTEM_PROMPT = File.read(File.join(__dir__, 'system_prompt.txt'))

  MAX_TOOL_ITERATIONS = 100
  # After this many consecutive tool-call iterations, inject a "stop looping" message
  TOOL_LOOP_WARN_THRESHOLD = 10
  # After this many consecutive tool-call iterations, force-break and return whatever we have
  TOOL_LOOP_HARD_LIMIT = 20

  # Generous HTTP timeouts for local / slow model servers.
  # open_timeout: how long to wait for the TCP connection to establish.
  # read_timeout: how long to wait between bytes of the response (per read).
  DEFAULT_OPEN_TIMEOUT = 120
  DEFAULT_READ_TIMEOUT = 1800

  # How long (seconds) an idle keep-alive connection may sit unused before
  # Net::HTTP closes it and re-establishes a new one. The default is only
  # 2 seconds, which is too short for the tool loop (tool execution between
  # requests easily exceeds it), so we raise it.
  KEEP_ALIVE_TIMEOUT = 60

  # Transient network errors that are safe to retry (the request was never
  # completed, so re-sending it is idempotent from the server's perspective).
  RETRYABLE_ERRORS = [
    Errno::ECONNRESET,
    Errno::EPIPE,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    OpenSSL::SSL::SSLError,
    IOError,
    Net::OpenTimeout,
    Net::ReadTimeout
  ].freeze

  # Automatic retry settings for transient network errors.
  # RETRY_COUNT: total number of attempts (1 initial + N-1 retries).
  # RETRY_DELAY: base delay in seconds (exponential backoff: 2s, 4s, 8s, ...).
  RETRY_COUNT = 3
  RETRY_DELAY = 2

  # Ollama generation limits. -1 means "no limit" (generate until the model
  # stops on its own). num_ctx is the context window size (65K tokens).
  NUM_PREDICT = -1
  NUM_CTX     = 65536

  # Default reasoning effort (NOTE KI default for qwen is xhigh)
  REASONING_EFFORT = "medium"

  # Sampling parameters (defaults). temperature controls randomness
  # (lower = more deterministic); top_p is nucleus sampling.
  TEMPERATURE = 0.2
  TOP_P       = 0.9
  TOP_K       = 20
  MIN_P       = 0
  PRESENCE_PENALTY = 1.0
  REPEAT_PENALTY   = 1.05

  # All harness state (saved sessions, log, history) lives in this
  # directory inside the working directory, so it can be ignored from
  # git with a single entry (.harness/).
  HARNESS_DIR = '.harness'

  # Saved sessions live in this subdirectory of HARNESS_DIR.
  SESSIONS_DIR = File.join(HARNESS_DIR, 'sessions')

  # Log file name (inside HARNESS_DIR).
  LOG_FILE = 'harness.log'

  # Name of the project-specific rules file (in the working directory).
  # If present, its content is appended to the system prompt as
  # "Project-Specific Rules". The file is re-read automatically when
  # its modification time changes (detected before each prompt).
  RULES_FILE = 'harness.md'

  attr_reader :options, :logger, :tool_registry, :file_list, :session

  def initialize(options, file_list)
    @options       = options
    @file_list     = file_list
    @logger        = build_logger
    @tool_registry = build_tool_registry
    @session       = Session.new(build_system_prompt)
    @spinner       = nil
    @rules_mtime   = current_rules_mtime
  end

  # Base system prompt (from --system-file, the config 'system' key, or
  # the built-in default) plus optional project-specific rules from a harness.md
  # file in the working directory. This lets each project keep its own
  # centralized set of rules for the LLM.
  #
  # NOTE: the tool list is NOT included in the system prompt - the full
  # tool schemas (names, descriptions, parameters) are already provided
  # in the API "tools" field, so repeating them here would be pure
  # duplication. Tool discovery is handled by the tools.list /
  # tools.search meta-tools.
  def build_system_prompt
    base = options[:system]
    project_file = File.join(@file_list.workdir, RULES_FILE)
    if File.file?(project_file)
      content = File.read(project_file).strip
      return "#{base}\n\n## Project-Specific Rules\n\n#{content}\n" unless content.empty?
    end
    base
  end

  # Current mtime of the rules file (nil if it doesn't exist).
  def current_rules_mtime
    path = File.join(@file_list.workdir, RULES_FILE)
    File.file?(path) ? File.mtime(path) : nil
  end

  # Check whether harness.md has been modified since the last check.
  # If so, rebuild the system prompt and update the session in-place.
  # Returns true if a reload happened, false otherwise.
  def check_rules_reload
    mtime = current_rules_mtime
    return false if mtime == @rules_mtime

    @rules_mtime   = mtime
    new_prompt     = build_system_prompt
    @session.update_system_prompt(new_prompt)
    logger.info("harness.md reloaded (mtime changed)")
    true
  end

  # Explicitly reload harness.md (called by /reload command).
  # Always re-reads the file regardless of mtime.
  def reload_rules
    new_prompt = build_system_prompt
    @rules_mtime = current_rules_mtime
    logger.info("harness.md reloaded (manual /reload)")
    new_prompt
  end

  def build_logger
    # Log file lives in the .harness directory inside the working
    # directory so different harness instances (different working
    # directories) do not share a log.
    log_file = File.join(@file_list.workdir, HARNESS_DIR, LOG_FILE)
    FileUtils.mkdir_p(File.dirname(log_file))
    logger = Logger.new(log_file)
    logger.formatter = proc { |severity, datetime, _progname, msg|
      "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
    }
    logger
  end

  def build_tool_registry
    registry = ToolRegistry.new
    registry.register(EchoTool.new)
    registry.register(NotifyTool.new)
    registry.register(GetTimeTool.new)
    registry.register(FileListTool.new(@file_list))
    registry.register(FileReadTool.new(@file_list))
    registry.register(FileWriteTool.new(@file_list, @options))
    registry.register(FileShaTool.new(@file_list))
    registry.register(FileRenameTool.new(@file_list, @options))
    registry.register(FileDeleteTool.new(@file_list, @options))
    registry.register(FileSearchTool.new(@file_list))
    registry.register(FilePatchTool.new(@file_list, @options))
    registry.register(FileCopyTool.new(@file_list, @options))
    registry.register(DirCreateTool.new(@file_list))
    registry.register(DirDeleteTool.new(@file_list, @options))
    # Git tools (operate on the repository containing the working dir).
    registry.register(GitDiffTool.new(@file_list))
    registry.register(GitShowTool.new(@file_list))
    registry.register(GitStatusTool.new(@file_list))
    registry.register(GitLogTool.new(@file_list))
    registry.register(GitApplyTool.new(@file_list))
    # Meta-tools (discovery): registered last so they appear at the end
    # of the sorted tool list. They take the registry itself as an
    # argument (built before the tools are instantiated).
    registry.register(ToolsListTool.new(registry))
    registry.register(ToolsSearchTool.new(registry))
    registry
  end

  def build_user_prompt(file_list, instruction)
    parts = ["## Working Directory\n\n#{file_list.workdir}"]

    access = file_list.accessible_paths
    any_grants = access.any? do |_mode, section|
      !section[:files].empty? || !section[:dirs].empty? ||
        !(section[:flat_dirs] || []).empty?
    end

    if any_grants
      sections = []
      %i[both read write].each do |mode|
        section = access[mode]
        lines = []
        lines += section[:files].map { |f| file_list.display_path(f) }
        lines += section[:dirs].map { |d| "#{file_list.display_path(d)}/ (recursive)" }
        lines += (section[:flat_dirs] || []).map { |d| "#{file_list.display_path(d)}/ (dir only)" }
        next if lines.empty?

        label = case mode
                when :both then 'Read + write'
                when :read then 'Read only'
                else 'Write only'
                end
        sections << "#{label}:\n#{lines.join("\n")}"
      end
      parts << "## Accessible Paths\n\n#{sections.join("\n\n")}"
    end

    parts << "## Instruction\n\n#{instruction}\n"
    parts.join("\n\n")
  end

  # Context window size: prefer the value from options (CLI flag or config
  # file), falling back to the built-in default.
  def num_ctx
    options[:num_ctx] || NUM_CTX
  end

  # Reasoning effort: prefer the value from options (CLI flag or config
  # file), falling back to the built-in default.
  def reasoning_effort
    options[:reasoning_effort] || REASONING_EFFORT
  end

  # Sampling temperature (defaults). temperature controls randomness
  # (lower = more deterministic); top_p is nucleus sampling.
  def temperature
    options[:temperature] || TEMPERATURE
  end

  # Nucleus sampling (top_p)
  def top_p
    options[:top_p] || TOP_P
  end

  # Top-k sampling (limit to the N most likely tokens)
  def top_k
    options[:top_k] || TOP_K
  end

  # Minimum probability threshold
  def min_p
    options[:min_p] || MIN_P
  end

  # Penalty for already-present tokens
  def presence_penalty
    options[:presence_penalty] || PRESENCE_PENALTY
  end

  # Penalty for repeated tokens
  def repeat_penalty
    options[:repeat_penalty] || REPEAT_PENALTY
  end

  # Number of recent messages retained verbatim after compaction:
  # prefer the value from options (CLI flag or config 'compact.recent_messages'),
  # falling back to the built-in default.
  def compact_recent_messages
    options[:compact_recent] || Session::COMPACT_RECENT_MESSAGES
  end

  # Max length (words) of the compaction summary, from the config
  # 'compact.max_size' key. nil means "no explicit limit".
  def compact_max_size
    options[:compact_max_size]
  end

  # Total retry attempts for transient network errors:
  # from the config file ('retry.count'), falling back to the built-in
  # default.
  def retry_count
    options[:retry_count] || RETRY_COUNT
  end

  # Base delay (seconds) between retries (exponential backoff):
  # from the config file ('retry.delay'), falling back to the built-in
  # default.
  def retry_delay
    options[:retry_delay] || RETRY_DELAY
  end

  # -- Model selection ----------------------------------------------------
  # The active model can be switched at runtime (/model). Model profiles come
  # from the config file (options[:model_profiles]); switching applies the
  # profile's settings to options in place, so the very next request uses them.
  # options is shared with the CLI, so no other wiring is needed.

  # All configured model profiles (array of hashes), or [] when none.
  def model_profiles
    Array(options[:model_profiles])
  end

  # Name (or id) of the configured default model, or nil.
  def default_model_name
    options[:default_model]
  end

  # Name (or id) of the currently active model.
  def active_model_name
    options[:active_model] || options[:model]
  end

  # Switch to a configured model profile by name (or raw model id). Applies
  # the profile's settings to options in place and returns the applied
  # profile hash. Raises HarnessError when the model is not found.
  def switch_model(name)
    name = name.to_s.strip
    raise HarnessError, 'usage: /model <name>' if name.empty?

    profiles = model_profiles
    if profiles.empty?
      # No profiles configured: treat the argument as a raw model id.
      options[:model]        = name
      options[:active_model] = name
      return { name: name, model: name }
    end

    match = find_profile(name)
    raise HarnessError, "unknown model '#{name}'. Type /models to see the available models." unless match

    apply_profile(match)
    match
  end

  # Find a configured profile by its name or raw model id (nil when absent).
  def find_profile(name)
    model_profiles.find { |p| p[:name] == name || p[:model] == name }
  end

  # Apply a model profile's settings to options in place. Missing (nil)
  # sampling values fall back to the built-in defaults via the accessor
  # methods above; base_url keeps its current value when the profile has none.
  def apply_profile(profile)
    options[:base_url]         = profile[:url] || options[:base_url]
    options[:model]            = profile[:model]
    options[:token]            = profile[:token]
    options[:num_ctx]          = profile[:num_ctx]
    options[:reasoning_effort] = profile[:reasoning_effort]
    options[:temperature]      = profile[:temperature]
    options[:top_p]            = profile[:top_p]
    options[:top_k]            = profile[:top_k]
    options[:min_p]            = profile[:min_p]
    options[:presence_penalty] = profile[:presence_penalty]
    options[:repeat_penalty]   = profile[:repeat_penalty]
    options[:active_model]     = profile[:name] || profile[:model]
  end

  # Restore the model saved in a session:
  #   * nil (the default was active when the session was saved) - the config
  #     default is already active, so there is nothing to do.
  #   * a known model - switch to it.
  #   * an unknown model (e.g. removed from the config since the save) -
  #     show an error and reset to the config default.
  def restore_active_model(name)
    return if name.nil?

    name = name.to_s.strip
    return if name.empty?

    match = find_profile(name)
    unless match
      raise HarnessError, "session's model '#{name}' is not configured anymore - reset to the default model"
    end

    apply_profile(match)
  end

  # -- Session persistence ------------------------------------------------
  #
  # Sessions are saved as JSON files in the .harness/sessions directory
  # inside the working directory. Each session has a stable UUID id
  # (assigned by the Session, see Session#session_id), so saving the
  # session - possibly multiple times - always writes to the same file:
  # a session can be continued and re-saved under the same id instead of
  # creating a new session file each time.

  # Directory where saved sessions are stored (inside the working directory).
  def sessions_dir
    File.join(@file_list.workdir, SESSIONS_DIR)
  end

  # Save the current session (conversation + file list) to disk.
  # Returns the session id (UUID).
  def save_session
    FileUtils.mkdir_p(sessions_dir)

    data = @session.to_h(@file_list)
    data[:active_model] = options[:active_model]
    json = JSON.generate(data)

    id   = @session.session_id
    path = File.join(sessions_dir, "#{id}.json")

    File.write(path, json)
    logger.info("session saved: #{id} (#{path})")
    id
  end

  # Resume a saved session by id (full or abbreviated UUID).
  # Restores the conversation chain and the file list.
  def resume_session(id)
    id = id.to_s.strip
    raise HarnessError, 'usage: /resume <session-id>' if id.empty?

    path = find_session_file(id)
    raise HarnessError, "no saved session matching '#{id}' (see /sessions)" unless path

    data = JSON.parse(File.read(path), symbolize_names: true)
    @session.restore(data, @file_list)
    restore_session_model(data[:active_model])
    @rules_mtime = current_rules_mtime
    logger.info("session resumed: #{File.basename(path, '.json')} (#{path})")
    path
  end

  # Restore the session's model (see #restore_active_model). When the stored
  # model is no longer configured, show an error and reset to the config
  # default model. A nil stored value means the default was active when the
  # session was saved - it is already active, so nothing to do.
  def restore_session_model(name)
    restore_active_model(name)
  rescue HarnessError => e
    puts "  [error] #{e.message}"
    default = default_model_name
    raise HarnessError, "#{e.message} - and no default model is configured either" unless default

    apply_profile(find_profile(default))
  end
  # List saved sessions, newest first. Returns an array of hashes:
  #   { id:, path:, saved_at:, messages:, files:, workdir: }
  # Corrupt/unreadable entries are skipped rather than aborting the listing.
  def list_sessions
    return [] unless File.directory?(sessions_dir)

    Dir.glob(File.join(sessions_dir, '*.json')).sort_by { |p| File.mtime(p) }.reverse.map do |path|
      data = JSON.parse(File.read(path), symbolize_names: true)
      {
        id:       File.basename(path, '.json'),
        path:     path,
        saved_at: File.mtime(path),
        messages: (data[:messages] || []).size,
        files:    (data[:files] || []).size,
        workdir:  data[:workdir]
      }
    rescue JSON::ParserError, StandardError
      nil
    end.compact
  end

  # -- Public prompt API (called by the CLI with an explicit receiver) ----

  # Appends a new user prompt to the session and sends the chain to the LLM.
  # If the request fails, the prompt stays in the session (pending) so it can
  # be re-sent with #retry.
  def run_prompt(instruction)
    # Auto-detect harness.md changes before each prompt.
    if check_rules_reload
      puts "  [harness.md reloaded - project rules updated]"
    end

    user_prompt = build_user_prompt(@file_list, instruction)

    if options[:verbose]
      logger.info("--- system ---\n#{@session.system_prompt}")
      logger.info("--- user ---\n#{user_prompt}")
      logger.info("--- #{options[:model]} @ #{options[:base_url]} ---")
    end

    @session.add_user(user_prompt)
    send_session
  end

  # Re-sends the current session chain (e.g. after a failed request).
  # Requires a pending user prompt at the end of the chain.
  def retry
    unless @session.pending?
      raise HarnessError, 'nothing to retry - no pending prompt in the session (send a prompt first)'
    end

    logger.info("--- retry: re-sending session chain (#{@session.messages.size} messages) ---")
    send_session
  end

  # Compact the session: ask the LLM to summarize the conversation, then
  # replace the full message chain with the summary. This frees up context
  # window space while preserving the essential information.
  # The last N recent messages (tunable via --compact-recent or the config
  # 'compact.recent_messages' key) are retained verbatim after the summary so
  # immediate working context is not lost to summarization.
  #
  # Returns a hash: { summary:, before:, after:, retained: }
  def compact_session
    before = @session.messages.size

    if @session.conversation_size < 4
      raise HarnessError, 'session too small to compact (need at least 4 conversation messages)'
    end

    # Build a standalone summarization request (no tools, no system prompt
    # from the session - just the conversation + an instruction).
    conversation = @session.messages[1..] # skip the system message
    max_words = compact_max_size || 500
    messages = conversation + [
      {
        role: 'user',
        content: 'Summarize the entire conversation above in a concise, structured format. ' \
                 'Include: (1) what was being worked on, (2) key decisions made, ' \
                 'files that were modified or created, (4) any pending tasks or ' \
                 'unresolved issues, (5) important context needed to continue. ' \
                 "Keep it under #{max_words} words. Do NOT include the summarization instruction itself."
      }
    ]

    spinner = Spinner.new("Compacting session (#{before} messages to summary)")
    @spinner = spinner
    spinner.start

    summary_text = nil
    begin
      data = make_request(options[:base_url], options[:model], messages,
                          auth_token: options[:token], tools: nil)
      summary_text = data[:choices][0][:message][:content]
    ensure
      spinner.stop
      @spinner = nil
    end

    raise HarnessError, 'LLM returned empty summary' if summary_text.nil? || summary_text.strip.empty?

    summary_text = summary_text.strip
    @session.compact(summary_text, recent_count: compact_recent_messages)
    after = @session.messages.size
    # after = system + summary + ack + retained recent messages
    retained = [after - 3, 0].max

    logger.info("session compacted: #{before} to #{after} messages (summary: #{summary_text.length} chars, #{retained} recent retained)")
    { summary: summary_text, before: before, after: after, retained: retained }
  end

  # Sends the session chain to the LLM and prints the response.
  def send_session
    spinner = Spinner.new("Sending to #{options[:model]}")
    @spinner = spinner
    spinner.start

    response = nil
    begin
      response = call_llm
    ensure
      spinner.stop
      @spinner = nil
    end

    if options[:verbose]
      logger.info("--- reasoning ---\n#{response[:reasoning]}")
      logger.info("--- response ---\n#{response[:content]}")
    end

    puts response[:content]
    print_stats(response[:stats])
  end

  private

  # Find a saved session file by (abbreviated) id: the id must be a prefix
  # of the file name (without extension). Raises HarnessError on ambiguity.
  def find_session_file(id)
    raise HarnessError, "invalid session id: #{id}" unless id =~ /\A[0-9a-fA-F-]+\Z/

    matches = Dir.glob(File.join(sessions_dir, '*.json')).select do |p|
      File.basename(p, '.json').downcase.start_with?(id.downcase)
    end

    case matches.size
    when 0 then nil
    when 1 then matches.first
    else
      raise HarnessError, "ambiguous session id '#{id}' - matches: #{matches.map { |p| File.basename(p) }.join(', ')}"
    end
  end

  def make_request(base_url, model, messages, auth_token: nil, timeout: DEFAULT_READ_TIMEOUT, tools: nil)
    uri  = URI("#{base_url}/chat/completions")
    http = KeepAliveHTTP.new(uri.host, uri.port)
    http.logger       = logger
    http.use_ssl      = (uri.scheme == 'https')
    http.open_timeout = DEFAULT_OPEN_TIMEOUT
    http.read_timeout = timeout
    # NOTE: keep-alive is the default in Net::HTTP (the keep_alive= setter
    # was removed in Ruby 3.4), so no explicit setting is needed here.
    # But the default keep_alive_timeout is only 2 seconds - too short for
    # the tool loop (tool execution between requests easily exceeds it),
    # so raise it to keep the connection reusable across iterations.
    http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT

    body = {
      model: model,
      messages: messages,
      temperature: temperature,
      top_p: top_p,
      top_k: top_k,
      min_p: min_p,
      presence_penalty: presence_penalty,
      repeat_penalty: repeat_penalty,
      max_tokens: NUM_PREDICT,
      reasoning_effort: reasoning_effort,
      options: {
        num_predict: NUM_PREDICT,
        num_ctx: num_ctx
      }
    }
    body[:tools] = tools if tools && !tools.empty?

    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{auth_token}" if auth_token
    req.body = JSON.generate(body)

    attempts = retry_count
    result = nil
    attempts.times do |attempt|
      begin
        resp = http.request(req)
      rescue *RETRYABLE_ERRORS => e
        if attempt < attempts - 1
          delay = retry_delay * (2 ** attempt)
          logger.warn("network error (attempt #{attempt + 1}/#{attempts}): #{e.class}: #{e.message} - retrying in #{delay}s")
          sleep(delay)
          next
        end
        raise LLMError, "LLM request failed after #{attempts} attempts: #{e.message}"
      end

      unless resp.is_a?(Net::HTTPSuccess)
        # 5xx = transient server-side error (gateway, overload, timeout) → retry
        if resp.code.to_i >= 500 && attempt < attempts - 1
          delay = retry_delay * (2 ** attempt)
          logger.warn("HTTP #{resp.code} (attempt #{attempt + 1}/#{attempts}) - retrying in #{delay}s")
          sleep(delay)
          next
        end
        raise LLMError, "LLM error (HTTP #{resp.code}):\n#{resp.body}"
      end

      logger.info("=" * 50)
      logger.info(resp.body)
      logger.info("=" * 50)

      begin
        result = JSON.parse(resp.body, symbolize_names: true)
      rescue JSON::ParserError => e
        raise LLMError, "LLM returned invalid JSON: #{e.message}"
      end
      break
    end
    result
  end

  def execute_tool_call(tool_call)
    func_name = tool_call[:function][:name]
    args_json = tool_call[:function][:arguments]
    args      = args_json ? JSON.parse(args_json) : {}

    tool = tool_registry.get(func_name)
    unless tool
      return "error: unknown tool '#{func_name}'"
    end

    # Pause (and clear) the spinner so tool output/input is not broken
    # by the animation. Resume it afterwards if it was running.
    spinner_paused = false
    if @spinner
      @spinner.pause
      spinner_paused = true
    end

    begin
      result = tool.execute(args)
      logger.info("tool #{func_name} → #{result}")
      result.to_s
    rescue => e
      logger.error("tool #{func_name} failed: #{e.message}")
      "error: #{e.message}"
    ensure
      @spinner&.resume if spinner_paused
    end
  end

  # Sends the current session message chain to the LLM (with the tool loop).
  # On success the final assistant reply is appended to the session and the
  # stats are recorded. On failure the session is left untouched (the pending
  # user message stays in the chain) so it can be retried with #retry.
  def call_llm
    messages = @session.messages.dup

    tools = tool_registry.empty? ? nil : tool_registry.to_openai

    iteration = 0
    consecutive_tool_calls = 0
    last_tool_name = nil
    loop_warning_injected = false
    loop_hard_break = false
    total_usage = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
    start_time = Time.now

    loop do
      iteration += 1
      raise ToolLoopError, "exceeded max tool iterations (#{MAX_TOOL_ITERATIONS})" if iteration > MAX_TOOL_ITERATIONS

      data    = make_request(options[:base_url], options[:model], messages, auth_token: options[:token], tools: tools)
      message = data[:choices][0][:message]

      # Accumulate usage stats
      if data[:usage]
        total_usage[:prompt_tokens]     += data[:usage][:prompt_tokens]     || 0
        total_usage[:completion_tokens] += data[:usage][:completion_tokens] || 0
        total_usage[:total_tokens]      += data[:usage][:total_tokens]      || 0
      end

      if message[:tool_calls]
        # -- Tool-loop detection --
        current_tool_name = message[:tool_calls].first[:function][:name]
        if current_tool_name == last_tool_name
          consecutive_tool_calls += 1
        else
          consecutive_tool_calls = 1
          last_tool_name = current_tool_name
        end

        if consecutive_tool_calls >= TOOL_LOOP_HARD_LIMIT
          logger.warn("tool-loop hard limit reached (#{consecutive_tool_calls} consecutive calls to '#{current_tool_name}') - forcing final response")
          loop_hard_break = true
        elsif consecutive_tool_calls >= TOOL_LOOP_WARN_THRESHOLD && !loop_warning_injected
          logger.warn("tool-loop warning: #{consecutive_tool_calls} consecutive calls to '#{current_tool_name}' - injecting stop message")
          loop_warning_injected = true
        end

        logger.info("--- tool_calls (iteration #{iteration}, consecutive: #{consecutive_tool_calls}) ---")
        message[:tool_calls].each do |tc|
          logger.info("  calling #{tc[:function][:name]}(#{tc[:function][:arguments]})")
        end

        # Append assistant message with tool_calls
        assistant_msg = { role: 'assistant', content: message[:content] }
        assistant_msg[:tool_calls] = message[:tool_calls]
        messages << assistant_msg

        # Execute each tool call and append results
        message[:tool_calls].each do |tc|
          result = execute_tool_call(tc)
          messages << {
            role: 'tool',
            tool_call_id: tc[:id],
            content: result
          }
        end

        # If we hit the hard limit, inject a strong "stop" message and force the model to respond
        if loop_hard_break
          messages << {
            role: 'user',
            content: 'STOP. You are stuck in a tool loop. Do NOT call any more tools. ' \
                     'Respond NOW with your final answer. If you were editing files, use the file.write tool to save them. ' \
                     'If this was a query, answer it directly in plain text.'
          }
          next
        end

        # If we hit the warning threshold, inject a gentle reminder
        if loop_warning_injected && consecutive_tool_calls == TOOL_LOOP_WARN_THRESHOLD
          messages << {
            role: 'user',
            content: 'Reminder: You have called the same tool multiple times in a row. ' \
                     'If you have enough information, stop calling the same tool and provide your final answer now.'
          }
        end

        next
      end

      # No tool calls - final response
      elapsed = (Time.now - start_time).round(2)
      stats = {
        elapsed_seconds: elapsed,
        iterations:      iteration,
        usage:           total_usage
      }

      # Commit the successful exchange to the session.
      @session.add_assistant(message[:content])
      @session.record_stats(stats)

      return {
        reasoning: message[:reasoning],
        content:   message[:content],
        stats:     stats
      }
    end
  end

  def print_stats(stats)
    return unless stats

    elapsed = stats[:elapsed_seconds]
    iters   = stats[:iterations]
    usage   = stats[:usage]

    parts = ["⏱ #{elapsed}s"]
    parts << "🔄 #{iters} iteration#{'s' if iters != 1}"
    if usage && usage[:total_tokens] > 0
      parts << "📊 #{usage[:prompt_tokens]}→#{usage[:completion_tokens]} tokens (#{usage[:total_tokens]} total)"
    end
    puts "  [#{parts.join(' | ')}]"
  end
end