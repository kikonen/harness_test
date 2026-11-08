# frozen_string_literal: true

require "json"
require "nokogiri"

require_relative "tool"

# -- TextToolCallParser ---------------------------------------------------

# Recovers a tool call a model wrote as TEXT instead of a structured tool_calls
# array (issue #461, observed with qwen): a <tool_call> wrapper around
# <function=NAME> blocks with <parameter=KEY>value</parameter> bodies. Produces
# the same synthetic [{ id:, function: { name:, arguments: } }] shape the tool
# loop already consumes, so execution stays inside Harness#execute_tool_call.
#
# The one guard against running prose that merely QUOTES a call: a parsed name
# only becomes a call when it maps to a registered tool (Harness keeps a
# TextToolCallParser per run for exactly this registry). Rationale:
# doc/text_tool_call_design.md.
class TextToolCallParser
  # An OPEN marker (a tool_call wrapper or a function tag) is enough to look
  # like a call: the safety is name resolution, not the closing tags, because a
  # truncated call (issue #332) has no closing tags yet is still worth running.
  OPEN = /<tool_call\b|<function[=\s]/i
  # The qwen dialect glues the name to the tag with '=' (<function=read>,
  # <parameter=path>), which is not legal XML. Nokogiri parses the call only
  # after this is rewritten into the '<function name="read">' attribute form.
  EQ_HEADER = %r{<(function|parameter)=([A-Za-z0-9_.]+)>}
  # Pulls the number back out of a synthetic id (text_call_N) so a later
  # recovered round continues the numbering instead of reusing an id.
  ID_PREFIX = "text_call_"
  ID_PATTERN = /^text_call_(\d+)$/

  def initialize(tool_registry)
    @tool_registry = tool_registry
  end

  # True when the content carries an open marker (issue #461).
  def text_call?(content)
    return false if content.nil?

    content.match?(OPEN)
  end

  # Parse text-shaped calls into a synthetic tool_calls array. committed: the
  # tool_calls already in the session chain - their highest text_call_N sets
  # where new ids continue, because a tool result is matched back to its call by
  # tool_call_id and qwen re-emits a call on every round. Returns [] when the
  # content is not a call or no name resolves to a registered tool.
  def parse(content, committed: [])
    return [] unless text_call?(content)

    doc = Nokogiri::XML("<toolcall>#{normalized(content)}</toolcall>") do |cfg|
      cfg.recover
    end
    doc.css("function").filter_map.with_index(next_index(committed)) do |node, index|
      name = resolve_name(node["name"] || node.name.split("=", 2)[1])
      next unless name

      {
        id: "#{ID_PREFIX}#{index}",
        function: { name:, arguments: JSON.generate(parameters(node)) }
      }
    end
  end

  private

  # '<function=name>' / '<parameter=name>' -> '<function name="name">'.
  def normalized(content)
    content.gsub(EQ_HEADER) { "<#{$1} name=\"#{$2}\">" }
  end

  # One more than the highest committed text_call_N, so a recovered round's ids
  # never collide with an earlier one (a duplicate tool_call_id would corrupt
  # the tool-result round trip).
  def next_index(committed)
    ids = committed.filter_map { |tc| tc[:id].to_s[ID_PATTERN, 1] }
    ids.map(&:to_i).max.to_i + 1
  end

  # A name only maps to a tool when it is registered exactly, or is an
  # unambiguous short name (qwen writes 'read' for 'file.read'). An ambiguous or
  # unknown name maps to nil so it falls through to the honest 'NOT executed'
  # report instead of guessing the wrong tool.
  def resolve_name(name)
    return nil if name.nil? || name.empty?
    return name if @tool_registry.get(name)

    matches = @tool_registry.sorted_tools.select { |t| t.short_name == name }
    matches.size == 1 ? matches.first.name : nil
  end

  # Each <parameter>value</parameter> becomes an argument keyed by its name.
  def parameters(function_node)
    function_node.css("parameter").filter_map do |node|
      key = node["name"] || node.name.split("=", 2)[1]
      next unless key

      [key, node.text]
    end.to_h
  end
end
