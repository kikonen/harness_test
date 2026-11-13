# frozen_string_literal: true

module Commands
  # The owner-side shape a numbered store shares (issue #474): the listing rows,
  # the numeric selector and the rule a body is printed under. /plans and /memory
  # both read through it so one mechanism serves both instead of each carrying its
  # own copy (the same rule doc/memory_design.md recorded for the body render).
  #
  # A store entry is addressed BY NAME first: the ordinal is the position in the
  # store's sorted `all`, so it is honoured only while IN RANGE - an entry genuinely
  # named with digits stays reachable by that name, and adding or deleting an entry
  # shifts the numbering, which is why a name always works.
  module StoreListing
    def listing_rows(all)
      all.map.with_index do |entry, i|
        {
          number: i + 1,
          name: entry.name,
          description: entry.description,
          chars: entry.chars
        }
      end
    end

    def list_index(requested, count)
      return nil unless requested.match?(/\A\d+\z/)

      number = requested.to_i
      number.between?(1, count) ? number - 1 : nil
    end

    # The rule a body is printed under. The number shows only when the entry was
    # asked for BY number: a nil index means a name lookup, which prints no number.
    def store_rule(dir, name, index)
      title = index.nil? ? "--- #{name}" : "--- #{index + 1}. #{name}"
      title = "#{title} (#{dir})"
      "#{title} #{'-' * [1, 60 - title.length].max}"
    end

    def show_body(rule, body)
      return if body.nil?

      emit_role(:rule, rule)
      emit_role(:body, body)
    end
  end
end
