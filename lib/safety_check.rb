# frozen_string_literal: true

require_relative "harness_error"

# issue #224: pre-dialog command safety check. Before the confirmation
# dialog for an unapproved run.command, ask the model - using a FORK of the
# current conversation - whether the command(s) look safe, and show the
# verdict as advisory text in the dialog. The verdict NEVER auto-approves,
# never widens the allowlist and never bypasses the user's Allow.
#
# Why this is cheap with local-LLM KV caching:
#   - The fork is a byte-identical PREFIX of the live chain (truncated at
#     the last complete round), so the whole prefix is a cache hit; only
#     the short check question is new prefill.
#   - The fork is disposable and shared: when a batch contains several
#     unapproved run.command calls, ONE check call covers all of them
#     (one verdict line per command), not one call per command.
#   - The main conversation's cache is NOT evicted: the fork's prefix IS
#     the main prefix, so the next real turn re-prefills only the one
#     dropped assistant tool_call message.
#
# PURITY CONTRACT (critical): SafetyCheck is a free function over a plain
# chain array and a client - it NEVER touches Session, Harness state, or
# the Task. It cannot trigger in-loop compaction, prompt-token anchoring
# (spinner ctx estimate), auto-save, or any session mutation. Do not route
# it through Harness#call_llm (that loop owns all of the above).
#
# The check runs BEFORE the confirmation dialog opens, so it never
# competes for the single stdin owner (#198): it is an HTTP call, not a
# dialog. LLM errors or blank answers simply yield no verdict (plain
# dialog) - the check must never break the consent flow.
module SafetyCheck
  # Short read timeout: the verdict is advisory; a slow check must not
  # stall the user's consent dialog (the caller degrades to a plain
  # dialog on error).
  DEFAULT_TIMEOUT = 30

  CHECK_PROMPT = 'I am about to run these shell command(s) in this project:\n' \
                 '%s\n' \
                 "Reply with EXACTLY one line per command (same order), each line: " \
                 '"safe: <short reason>" or "dangerous: <short reason>". ' \
                 "Do NOT call any tools."

  class << self
    # Fork of chain truncated at the last COMPLETE round: the trailing
    # assistant message with tool_calls (whose tool results have not been
    # appended yet - the dialog fires exactly at that point, mid tool
    # loop) is dropped, because backends reject tool_calls without their
    # results. Ends on a tool/user/plain-assistant message, or on the
    # unchanged chain when it is already valid. The original array is
    # never mutated.
    def truncate_for_check(chain)
      forked = chain.dup
      while (last = forked.last) && last[:role] == "assistant" && last[:tool_calls]
        forked.pop
      end
      forked
    end

    # One check call for ALL commands (one verdict line each). Returns
    # { command => one-line verdict or nil }. nil verdicts (blank answer,
    # too few lines, degenerate chain) mean "no verdict" for that command.
    # Raises LLMError etc. - the CALLER must rescue and degrade to a
    # plain dialog.
    def run(client, chain, commands, timeout: DEFAULT_TIMEOUT)
      commands = Array(commands).map(&:to_s)
      results  = commands.to_h { |c| [c, nil] }
      return results if commands.size == 0

      base = truncate_for_check(chain)
      # Degenerate chain (empty, or nothing but the system prompt): there
      # is no conversation to reuse (no cached prefix, nothing to ground
      # the verdict in) - no verdict, no call.
      return results if base.reject { |m| m[:role] == "system" }.empty?

      question = format(CHECK_PROMPT, commands.each_with_index.map { |c, i| "#{i + 1}. #{c}" }.join("\n"))
      fork = base + [{ role: "user", content: question }]

      data = client.chat(fork, tools: nil, timeout: timeout)
      text = data.dig(:choices, 0, :message, :content).to_s
      lines = text.split("\n").map(&:strip).reject(&:empty?)
      lines.each_with_index do |line, idx|
        cmd = commands[idx]
        results[cmd] = line if cmd
      end
      results
    end
  end
end
