# frozen_string_literal: true

require "json"

require_relative "harness_error"
require_relative "error_text"
require_relative "image_delivery"
require_relative "output_budget"
require_relative "safety_check"
require_relative "task"
require_relative "command_allowlist"
require_relative "text_normalizer"
require_relative "tool"
require_relative "tool_result"

# The tool-call half of a turn, cut off from Harness (issue #582): it OWNS the
# step counter and the truncation budget, and reaches the run only through the
# narrow ports TurnRunner hands it, so nothing here reads back into Harness.
# The ports: logger, settings, tool_registry, session, client (a callable),
# model_config, file_list, spill_reader, text_tool_call_parser, tool_wait_suffix.
class ToolCallRunner
  # The two NORMAL ends of an answer; every other value a server reports
  # ('length', 'content_filter', one this harness has never seen) gets a line.
  # What each endpoint reports: doc/truncation_design.md.
  FINISH_EXPECTED = %w[stop tool_calls].freeze

  def initialize
    # The "step N" label is a monotonic counter over the owning Harness' whole
    # job, not the per-turn loop counter: a turn that restarts (retry, a context
    # re-send, or continuing after an interrupt) must not re-issue step numbers
    # already on the console (issue #577).
    @step_number = 0
  end

  # A parse failure on a truncated call is reported as truncation - the honest
  # cause - not a malformed call the model is invited to repeat.
  def execute(tool_call, ports, truncated: false)
    func_name = tool_call[:function][:name]
    args, parse_error = parse_arguments(tool_call[:function][:arguments])
    if parse_error
      ports.logger.warn "tool #{func_name} arguments did not parse (#{parse_error})"
      if truncated
        return "error: the response was cut off by the token budget before " \
          "this call's arguments arrived complete, so the call was NOT " \
          "executed. Re-send it as a SMALLER call (shorter content / " \
          "fewer options)."
      end
      return "error: tool call arguments are not valid JSON (#{parse_error})"
    end

    tool = ports.tool_registry.get(func_name)
    unless tool
      return "error: unknown tool '#{func_name}'"
    end

    unwrapped = tool.normalize_arguments(args)
    if unwrapped != args
      ports.logger.info "tool #{func_name} arguments arrived wrapped in an " \
        "extra 'arguments' key - unwrapped"
    end
    args = unwrapped

    announce(func_name, ports)

    begin
      result = tool.execute(args)
      ports.logger.info "tool #{func_name} → #{OutputBudget.log_excerpt(result)}"
      # A ToolResult is normalized where its text is built and carries raw image
      # bytes beside it; flattening the object to #to_s would lose the images.
      text = result.is_a?(ToolResult) ? result : TextNormalizer.normalize(result)
      budget_result(func_name, text, ports)
    rescue => e
      ports.logger.error ErrorText.detailed(e, "tool #{func_name} failed")
      "error: #{ErrorText.label(e)}"
    end
  end

  # A String passes through; a ToolResult goes to ImageDelivery, which names each
  # image's fate and returns the base64 a vision request carries.
  def result_message(tool_call, raw, delivery, ports)
    msg = { role: "tool", tool_call_id: tool_call[:id], content: raw.to_s }
    return msg unless raw.is_a?(ToolResult)

    decisions = delivery.plan(raw)
    msg[:content] = append_notes(msg[:content], delivery.describe(decisions))
    payloads = delivery.inlineable?(decisions).map do |decision|
      {
        mime_type: decision.image.mime_type,
        base64: ImageDelivery.base64_of(decision)
      }
    end
    msg[:images] = payloads unless payloads.empty?
    log_image_decision(tool_call[:function][:name], decisions, ports)
    msg
  end

  # Buffered so it survives the transient tool result and reaches the chain on commit.
  def capture_note(tool_call, result, ports)
    return unless tool_call[:function][:name] == "session.note"
    return unless result.is_a?(String) && result.start_with?("ok: noted")

    args, parse_error = parse_arguments(tool_call[:function][:arguments])
    if parse_error
      ports.logger.warn "session.note arguments did not parse " \
        "(#{parse_error}) - note not buffered"
      return
    end
    ports.session.add_note(args["text"])
  rescue StandardError
    # A malformed note must never break the turn.
  end

  # Text naming the stored file stays; only base64 is dropped.
  def strip_image_payloads(messages)
    messages.each { |m| m.delete(:images) }
  end

  def emit_step(message, ports)
    return if step_display_disabled?(ports)

    log_response(message[:reasoning], message[:content], ports.logger)

    first_line = ->(key) {
      [message[key]].map { |m|
        m.to_s.strip
      }.reject(&:empty?).first
    }
    reason  = first_line.call(:reasoning)
    content = first_line.call(:content)

    tools = message[:tool_calls].map { |tc| tc[:function][:name] }
    # One ROLE per event so UI::Renderer does not regex markers back out; only
    # the number and call count are emitted here, "step"/"[]" are the
    # renderer's words. The number is the job-wide counter, not the turn-local
    # iteration (issue #577).
    @step_number += 1
    Task.emit(
      :step_label,
      origin: :harness,
      content: { number: @step_number, calls: tools.size })
    Task.emit(:plan, origin: :harness, content: reason) if reason
    Task.emit(:interstitial, origin: :harness, content:) if content
    Task.emit(:tool_plan, origin: :harness, content: tools.join(", "))
  end

  def step_number
    @step_number
  end

  # Only 'length' makes the tool round report truncation, not a malformed call.
  def truncated_by_finish_reason?(data, iteration, ports)
    reason = data[:finish_reason]
    return false if reason.nil? || FINISH_EXPECTED.include?(reason)

    message =
      if reason == "length"
        "response cut off by the token budget (iteration #{iteration}, " \
          "#{budget_note(data, ports)})"
      else
        "finish reason '#{reason}' (iteration #{iteration})"
      end
    ports.logger.warn message
    Task.emit(:warn, origin: :harness, content: message)
    reason == "length"
  end

  # An unset key means the server's own default is what cut the answer.
  def budget_note(data, ports)
    limit = [
      ports.model_config.max_tokens,
      ports.model_config.num_predict
    ].map(&:to_i).find(&:positive?)
    parts = []
    completion = data.dig(:usage, :completion_tokens)
    parts << "#{completion} completion tokens" if completion
    parts << (limit ? "limit #{limit}" : "no token limit configured (server default)")
    parts.join(", ")
  end

  # SafetyCheck never touches Session, so a batch check cannot trigger compaction.
  def precheck_batch_safety(message_calls, ports)
    return nil unless ports.settings.command_safety_check

    # YOLO consumes no verdicts, so pre-checking it pays for a forked round trip.
    if ports.settings.yolo?
      ports.logger.info "safety pre-check skipped (YOLO consumes no verdicts)"
      return nil
    end

    commands = batch_run_commands(message_calls, ports)
    return nil if commands.size < 2

    unapproved = commands.reject { |c| tool_allowlist(ports).allowed?(c) }
    return nil if unapproved.size < 2

    skipped = commands.size - unapproved.size
    if skipped.positive?
      ports.logger.info "safety pre-check: #{skipped} allowlisted commands skipped"
    end

    ports.logger.info "safety pre-check (#{unapproved.size} run.command in batch)"
    Tool.push_status(
      label: "safety",
      verdict: :info,
      message: "checking #{unapproved.size} commands before the consent dialog...")

    Task.emit(
      :spinner_detail,
      origin: :harness,
      content: { message: "Model safety check (#{unapproved.size} commands)" })

    ports.settings.safety_verdicts = SafetyCheck.run(
      ports.client.call,
      ports.session.messages,
      unapproved,
      tools: ports.tool_registry.to_openai,
      logger: ports.logger)
  rescue StandardError => e
    ports.logger.info "safety pre-check failed (#{ErrorText.label(e)}) " \
      "- continuing without verdicts"
    nil
  end

  # Fires only for a text-shaped call with no resolvable name (a recoverable
  # one is parsed and run by the loop first).
  def warn_unresolved_text_tool_call?(content, ports)
    return false unless ports.text_tool_call_parser.text_call?(content)

    msg = "the model wrote a tool call as text the harness could not run " \
      "(no structured tool call was returned and its name matched no tool) " \
      "- it was NOT run. Re-send the request; the model may need the " \
      "call asked differently."

    ports.logger.warn "text-shaped tool call in response (issue #461) - NOT executed\n" \
      "-----text_tool_call-----\n#{content}\n----------------"

    Task.emit(:warn, origin: :harness, content: msg)
    true
  end

  # Log-only variant: the user-facing warn is left to the re-issue path.
  def log_unresolved_text_tool_call?(content, ports)
    return false unless ports.text_tool_call_parser.text_call?(content)

    ports.logger.warn "text-shaped tool call in response (issue #461) - NOT executed\n" \
      "-----text_tool_call-----\n#{content}\n----------------"
    true
  end

  private

  def log_response(reasoning, content, logger)
    logger.info "--- reasoning ---\n#{log_text_or_none(reasoning)}"
    logger.info "--- response ---\n#{log_text_or_none(content)}"
  end

  def log_text_or_none(text)
    s = text.to_s.strip
    s.empty? ? "(none)" : s
  end

  def announce(name, ports)
    Task.emit(
      :spinner_detail,
      origin: :harness,
      content: { message: name, suffix: ports.tool_wait_suffix })
  end

  # The harness' spill plumbing is a port, not a back reference.
  def budget_result(name, result, ports)
    return result if result.is_a?(ToolResult)

    if (capped = spill_read_result?(name, result))
      return capped
    end

    text = result.to_s
    fit  = OutputBudget.fit(text, limit: ports.output_result_bytes)
    return text unless fit.truncated?

    @result_seq = (@result_seq || 0) + 1
    spill       = ports.result_spill.call.write(name, @result_seq, text)
    ports.logger.warn "tool #{name} result #{text.bytesize} B capped to " \
      "#{fit.text.bytesize} B (#{spill || 'not spilled'})"
    fit.text + OutputBudget.notice(fit.bytes_dropped, spill:)
  end

  # The mark FileReadTool#read_spilled sets: returns the stripped text, or nil.
  def spill_read_result?(name, result)
    return nil unless name == "file.read" && result.is_a?(String)
    return nil unless result.start_with?(ResultSpill::ALREADY_CAPPED_MARK)

    result[ResultSpill::ALREADY_CAPPED_MARK.length..]
  end

  def append_notes(text, notes)
    return text if notes.to_s.empty?
    return notes if text.to_s.empty?

    "#{text}\n#{notes}"
  end

  # Logged inline or not: "the model cannot see it" matters when an answer looks
  # blind to a screenshot.
  def log_image_decision(tool_name, decisions, ports)
    decisions.each do |d|
      detail = d.inline? ? "inlined" : "#{d.mode} (#{d.reason})"
      ports.logger.info "tool #{tool_name} image: #{d.image.mime_type} " \
        "#{d.image.byte_size}B -> #{detail}"
    end
  end

  # [args, nil] or [{}, err]: rescuing straight to {} hides a call that lost shape.
  def parse_arguments(raw)
    return [{}, nil] if raw.nil? || raw.to_s.strip.empty?

    [JSON.parse(raw), nil]
  rescue JSON::ParserError => e
    [{}, e.message]
  rescue StandardError => e
    [{}, ErrorText.label(e)]
  end

  # Must match the runner's auto-approve exactly: same list, same matching.
  def tool_allowlist(ports)
    CommandAllowlist.new(ports.file_list.workdir, file: CommandAllowlist::TOOL_FILENAME)
  end

  # Duplicates stay: the batch order must remain intact.
  def batch_run_commands(message_calls, ports)
    calls = Array(message_calls)
    calls.filter_map do |tc|
      next unless tc.dig(:function, :name) == "run.command"

      args, parse_error = parse_arguments(tc.dig(:function, :arguments))
      if parse_error
        ports.logger.warn "run.command arguments did not parse (#{parse_error}) - " \
          "this command is NOT safety pre-checked"
        next
      end
      tool = ports.tool_registry.get("run.command")
      args = tool ? tool.normalize_arguments(args) : args
      args["command"].to_s
    end.reject(&:empty?)
  end

  def step_display_disabled?(ports)
    ENV.fetch("HARNESS_STEP_DISPLAY", "") == "off" || ports.settings.step_display == false
  end
end
