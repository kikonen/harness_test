# frozen_string_literal: true

require_relative "harness_error"

# Structured help data for ONE slash command (issue #323). The command class
# declares it, so /help is generated from the dispatch registry instead of
# being a hand-copied second list that drifts from it.
# Rendering: HelpRenderer; the prose half: HelpTopics.
class CommandHelp
  # Group -> heading, and the order the /help table prints its sections in.
  GROUPS = {
    access: "Access and consent",
    model: "Model and parameters",
    session: "Session, context and rules",
    output: "Output",
    general: "General"
  }.freeze

  attr_reader :usage, :forms, :summary, :group, :see_also

  # usage:  the canonical form shown in the /help table ("param [key [value]]")
  # forms:  every accepted form, listed by /help <command> (defaults to usage)
  # group:  a GROUPS key. An unknown one raises AT LOAD TIME: help that belongs
  # to no group silently disappears from the table.
  def initialize(usage:, summary:, group:, forms: [], see_also: [])
    if usage.to_s.strip.empty? || summary.to_s.strip.empty?
      raise HarnessError, "CommandHelp needs a usage and a summary"
    end
    unless GROUPS.key?(group)
      raise HarnessError,
        "unknown help group #{group.inspect} (known: #{GROUPS.keys.join(', ')})"
    end

    @usage    = usage
    @summary  = summary
    @group    = group
    @forms    = forms.empty? ? [usage] : forms
    @see_also = see_also
  end

  def group_label
    GROUPS[group]
  end

  # Closest registered names for a typo'd command. A prefix match counts as
  # exact - "/res" is a deliberate abbreviation, not a spelling mistake.
  # max_distance 2 is the band measured on this command set: at 3 an unrelated
  # name qualifies ("helo" -> yolo), at 1 only the single nearest does.
  def self.suggestions(typed, candidates, limit: 3, max_distance: 2)
    wanted = typed.to_s.strip.downcase
    return [] if wanted.empty?

    scored = candidates.filter_map do |candidate|
      name = candidate.to_s
      next [0, name] if wanted.start_with?(name) || name.start_with?(wanted)

      steps = edit_distance(wanted, name.downcase)
      next nil unless steps <= max_distance && steps < [wanted.length, name.length].min

      [steps, name]
    end

    scored.sort_by { |steps, name| [steps, name.length, name] }.first(limit).map(&:last)
  end

  # Classic row-wise edit distance (no per-pair memo needed: names are short).
  def self.edit_distance(source, target)
    return target.length if source.empty?
    return source.length if target.empty?

    previous = (0..target.length).to_a
    source.each_char.with_index(1) do |char, row|
      current = [row]
      target.each_char.with_index(1) do |other, column|
        current << [
          previous[column] + 1, current[column - 1] + 1,
          previous[column - 1] + (char == other ? 0 : 1)
        ].min
      end
      previous = current
    end
    previous.last
  end
end
