# frozen_string_literal: true

require "fileutils"

require_relative "file_text"
require_relative "harness_error"
require_relative "text_normalizer"

# -- Plans ----------------------------------------------------------------
#
# Durable plans: the agreed approach for a task, stored so it outlives the
# session that produced it and survives context compaction (issue #359). One
# markdown file per plan under .harness/plans/.
#
# THIS CLASS IS THE ONLY READER AND WRITER of that directory. The store path is
# built from the workdir here and a plan name is validated to ONE path segment,
# so a plan tool can never be turned into a general writer inside .harness/ -
# which stays ungrantable to the file tools as every other .harness/ path.
# Design and the open decisions: doc/planning_mode_design.md.
#
# Plans mirror Memories (lib/memories.rb) in shape and consent - one reader,
# name-not-path, no grant, never injected - and differ in the two ways the
# design calls for: a plan is longer than a note (larger body budget) and the
# store is searchable (Memories deliberately omit search because 40 notes are
# listable).
class Plans
  DIR        = ".harness/plans"
  PLAN_EXT   = ".md"

  # Caps are the feature's own limit, not a suggestion: an uncapped store grows
  # into unbounded harness state. A plan is a longer artifact than a memory, so
  # the body budget is larger; the count cap keeps the store listable/searchable
  # in practice. Over either, add refuses and names the way out.
  MAX_PLANS      = 100
  MAX_BODY_CHARS = 8000

  # Truncation of the index line (the same glanceable index as a memory's
  # description, see doc/memory_design.md).
  DESC_MAX = 120

  # Characters a name cannot carry even after the separator rule: the ones a
  # filename rejects on Windows, plus control bytes.
  UNSAFE_NAME = %r{[<>|"?*]|\p{Cntrl}}

  # Mnemonic names (issue #359 owner note): adjective-noun pairs, Heroku-style.
  # A built-in wordlist rather than a gem - the Gemfile justifies every
  # dependency, and a naming nicety does not earn one. 24 x 24 = 576 names.
  ADJECTIVES = %w[
    brave calm clever quiet swift bold keen bright steady sharp gentle eager
    nimble vivid astute lucid poised tireless careful frank crisp deft earnest
    gallant
  ].freeze
  NOUNS = %w[
    curie falcon harbor meadow lantern compass anchor summit river willow
    ember atlas beacon cedar delta forge glade hollow ivory juno kepler lark
    marble nectar
  ].freeze

  Plan = Struct.new(:name, :description, :path, :chars, keyword_init: true)

  attr_reader :dir

  def initialize(workdir)
    @dir = File.expand_path(DIR, workdir)
  end

  def exist?
    File.directory?(@dir)
  end

  # Every plan, sorted by name (a stable order, like the tool registry's).
  def all
    return [] unless exist?

    plan_files.filter_map { |f| plan_at(stem(f), File.join(@dir, f)) }.sort_by(&:name)
  end

  def names
    all.map(&:name)
  end

  def count
    return 0 unless exist?

    plan_files.size
  end

  def full?
    count >= MAX_PLANS
  end

  def find(raw_name)
    name = normalize_name(raw_name)
    return nil if name.nil?

    file = stored_as(name)
    return nil if file.nil?

    plan_at(stem(file), File.join(@dir, file))
  end

  def body(raw_name)
    plan = find(raw_name)
    return nil if plan.nil?

    read_body(plan.path)
  end

  # Case-insensitive substring match over plan NAMES and BODIES (issue #359:
  # the model can search plans - the capability Memories deliberately omit).
  # No ranking: every match is returned, the model reads what it finds. An
  # empty query matches nothing (a search must say something).
  def search(query)
    q = query.to_s.strip.downcase
    return [] if q.empty?
    return [] unless exist?

    plan_files.filter_map do |file|
      path = File.join(@dir, file)
      body = read_body(path)
      next unless stem(file).downcase.include?(q) || body.downcase.include?(q)

      plan_at(stem(file), path)
    end.sort_by(&:name)
  end

  # Writes (or, when overwrite, replaces) one plan and returns it. A name or a
  # text this store will not accept RAISES HarnessError: the message is written
  # for the model to act on, and the tools hand it back as an error line. A
  # nil/empty name gets a generated mnemonic name (always fresh, so overwrite
  # is irrelevant for it).
  def add(raw_name, raw_text, overwrite: false)
    text = normalize_body(raw_text)
    raise HarnessError, "plan text is empty" if text.empty?

    if text.length > MAX_BODY_CHARS
      raise HarnessError,
        "plan text is #{text.length} chars (max #{MAX_BODY_CHARS}): " \
          "a plan is the agreed approach, not a transcript - write it that " \
          "short or split it into sub-plans"
    end

    name =
      if raw_name.to_s.strip.empty?
        generate_name
      else
        normalized = normalize_name(raw_name)
        raise HarnessError, name_error(raw_name) if normalized.nil?

        normalized
      end

    existing = stored_as(name)
    if existing.nil? && full?
      raise HarnessError,
        "plan store is full (#{MAX_PLANS} plans): delete the plans that are " \
          "done or superseded (plan.list, plan.delete) before adding"
    end
    if existing && !overwrite
      raise HarnessError,
        "plan '#{stem(existing)}' already exists - plan.delete it first, " \
          "pass overwrite: true to replace it, or pick a new name"
    end

    FileUtils.mkdir_p(@dir)
    # Overwriting writes INTO the file that already holds the name (its own
    # case on disk is the owner's, not ours to rename); a new plan gets the
    # canonical lowercase name.
    target = existing ? File.join(@dir, existing) : plan_path(name)
    FileText.write(target, "#{text}\n", FileText::LF)

    find(name)
  end

  # Removes one plan and returns its name (nil when there is no such plan).
  def delete(raw_name)
    plan = find(raw_name)
    return nil if plan.nil?

    File.delete(plan.path)
    plan.name
  end

  # What IS available, so a wrong name can be corrected instead of guessed
  # again (the same contract plan.read gives).
  def available_hint
    listed = names
    listed.empty? ? "no plans stored" : "available: #{listed.join(', ')}"
  end

  def name_error(raw)
    "a plan name is one path segment (no separator, no '..', no leading " \
      "dot, no <>|\"?*): #{raw.inspect}"
  end

  # A name is ONE path segment - no separator, no "..", no drive, no leading
  # dot - and is FOLDED TO LOWERCASE. Same rule as Memories#normalize_name: the
  # store is named by the MODEL, which cannot see the filesystem's case rules
  # (Windows folds, Linux does not), so the fold is what makes "this name
  # exists", the cap, and "one plan per topic" mean the same thing on both.
  def normalize_name(name)
    name = name.to_s.strip
    return nil if name.empty?
    return nil if name.include?("/") || name.include?("\\") || name.include?(":")
    return nil if name == "." || name == ".."
    return nil if name.start_with?(".")
    return nil if name.match?(UNSAFE_NAME)

    name.downcase
  end

  # The store path a canonical name writes to, whether or not it exists yet.
  # Returns nil for a name normalize_name refuses.
  def plan_path(name)
    name = normalize_name(name)
    return nil if name.nil?

    File.join(@dir, "#{name}#{PLAN_EXT}")
  end

  private

  # A fresh mnemonic name (adjective-noun). Retries on collision; the wordlist
  # is far larger than the cap, so a free name is essentially always found.
  def generate_name
    50.times do
      name = "#{ADJECTIVES.sample}-#{NOUNS.sample}"
      return name if stored_as(name).nil?
    end

    raise HarnessError, "could not generate a free plan name (#{count} stored)"
  end

  def plan_files
    Dir.children(@dir).select { |file| plan_file?(file) }
  end

  def plan_file?(file)
    file.end_with?(PLAN_EXT) && !stem(file).empty?
  end

  def stem(file)
    file[0...-PLAN_EXT.length]
  end

  # The file that ALREADY holds this canonical name, whatever case its own name
  # on disk has: a hand-authored Plan.md and a model-written plan.md are the
  # same plan, and the store must not grow a twin pair.
  def stored_as(name)
    return nil unless exist?

    plan_files.find { |file| stem(file).downcase == name }
  end

  def plan_at(name, path)
    return nil if path.nil? || !File.file?(path)

    text = read_body(path)
    Plan.new(name:, description: first_line(text), path:, chars: text.length)
  end

  # A plan is read through the same byte boundary every other file is: valid
  # UTF-8 out, LF separators out, whatever the file's own style was on disk.
  def read_body(path)
    FileText.from_disk(path).text.chomp
  end

  # Text arriving from a tool call is an outside boundary (issue #341): it is
  # normalized here, and CR/CRLF are folded so a plan written on Windows reads
  # the same as one written on Unix.
  def normalize_body(text)
    TextNormalizer.normalize(text).gsub(/\r\n?/, "\n").strip
  end

  def first_line(text)
    line = text.to_s.lines.map(&:strip).find { |l| !l.empty? && !l.start_with?("#") }
    return "no description" if line.nil?

    line.length > DESC_MAX ? "#{line[0, DESC_MAX]} ..." : line
  end
end
