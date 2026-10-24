# frozen_string_literal: true

require "fileutils"

require_relative "file_text"
require_relative "harness_error"
require_relative "text_normalizer"

# -- Memories ---------------------------------------------------------------
#
# The project's durable notes: what the model learned that must outlive the
# session it was learned in (issue #10). One markdown file per note under
# .harness/memories/.
#
# THIS CLASS IS THE ONLY READER AND WRITER of that directory. The store path is
# built from the workdir here and a note name is validated to ONE path segment,
# so a memory tool can never be turned into a general writer inside .harness/ -
# which stays as ungrantable to the file tools as every other .harness/ path.
# Scope, caps and the consent decision: doc/memory_design.md.
class Memories
  DIR        = ".harness/memories"
  NOTE_EXT   = ".md"

  # The caps are the feature's own limit, not a polite suggestion: a note store
  # the model can grow freely becomes context the model pays for forever. Over a
  # cap, memory.add refuses and names the way out (consolidate or delete).
  MAX_MEMORIES   = 40
  MAX_BODY_CHARS = 2000

  # Truncation of the index line (the same glanceable-index idea as a skill's
  # description, see doc/skills_design.md).
  DESC_MAX = 120

  # Characters a name cannot carry even after the separator rule: the ones a
  # filename rejects on Windows, plus control bytes.
  UNSAFE_NAME = %r{[<>|"?*]|\p{Cntrl}}

  Memory = Struct.new(:name, :description, :path, :chars, keyword_init: true)

  attr_reader :dir

  def initialize(workdir)
    @dir = File.expand_path(DIR, workdir)
  end

  def exist?
    File.directory?(@dir)
  end

  # Every note, sorted by name (a stable order, like the tool registry's).
  def all
    return [] unless exist?

    note_files.filter_map { |f| note_at(stem(f), File.join(@dir, f)) }.sort_by(&:name)
  end

  def names
    all.map(&:name)
  end

  def count
    return 0 unless exist?

    note_files.size
  end

  def full?
    count >= MAX_MEMORIES
  end

  def find(raw_name)
    name = normalize_name(raw_name)
    return nil if name.nil?

    file = stored_as(name)
    return nil if file.nil?

    note_at(stem(file), File.join(@dir, file))
  end

  def body(raw_name)
    note = find(raw_name)
    return nil if note.nil?

    read_body(note.path)
  end

  # Writes (or, when overwrite, replaces) one note and returns it. A name or a
  # text this store will not accept RAISES HarnessError: the message is written
  # for the model to act on, and the tools hand it back as an error line.
  def add(raw_name, raw_text, overwrite: false)
    name = normalize_name(raw_name)
    raise HarnessError, name_error(raw_name) if name.nil?

    text = normalize_body(raw_text)
    raise HarnessError, "memory text is empty" if text.empty?

    if text.length > MAX_BODY_CHARS
      raise HarnessError,
        "memory text is #{text.length} chars (max #{MAX_BODY_CHARS}): " \
          "one note is one fact, write it that short or split it"
    end

    existing = stored_as(name)
    if existing.nil? && full?
      raise HarnessError,
        "memory store is full (#{MAX_MEMORIES} notes): consolidate what you " \
          "stored (memory.read, then one broader note) and memory.delete the " \
          "narrow ones before adding"
    end
    if existing && !overwrite
      raise HarnessError,
        "memory '#{stem(existing)}' already exists - memory.delete it first, " \
          "pass overwrite: true to replace it, or pick a new name"
    end

    FileUtils.mkdir_p(@dir)
    # Overwriting writes INTO the file that already holds the name (its own
    # case on disk is the owner's, not ours to rename); a new note gets the
    # canonical lowercase name.
    target = existing ? File.join(@dir, existing) : note_path(name)
    # One note file, one terminator: the model's text is stored stripped and
    # written back with exactly one trailing newline (a text file keeps one).
    FileText.write(target, "#{text}\n", FileText::LF)

    find(name)
  end

  # Removes one note and returns its name (nil when there is no such note).
  def delete(raw_name)
    note = find(raw_name)
    return nil if note.nil?

    File.delete(note.path)
    note.name
  end

  # What IS available, so a wrong name can be corrected instead of guessed
  # again (the same contract skills.read gives).
  def available_hint
    listed = names
    listed.empty? ? "no memories stored" : "available: #{listed.join(', ')}"
  end

  def name_error(raw)
    "a memory name is one path segment (no separator, no '..', no leading " \
      "dot, no <>|\"?*): #{raw.inspect}"
  end

  # A name is ONE path segment - no separator, no "..", no drive, no leading
  # dot - and is FOLDED TO LOWERCASE. Same segment rule as Skills#normalize_name
  # (naming "../sessions/<id>/session.json" must stay impossible), plus the fold
  # because the store is named by the MODEL, which cannot see the filesystem's
  # case rules: on Windows Fact and fact are ONE file, on Linux TWO. Folding is
  # what makes "this name already exists" and the note cap mean the same thing
  # on both, and what stops a near-duplicate note the model cannot notice.
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
  def note_path(name)
    name = normalize_name(name)
    return nil if name.nil?

    File.join(@dir, "#{name}#{NOTE_EXT}")
  end

  private

  def note_files
    Dir.children(@dir).select { |file| note_file?(file) }
  end

  def note_file?(file)
    file.end_with?(NOTE_EXT) && !stem(file).empty?
  end

  def stem(file)
    file[0...-NOTE_EXT.length]
  end

  # The file that ALREADY holds this canonical name, whatever case its own name
  # on disk has: a hand-authored Fact.md and a model-written fact.md are the
  # same note, and the store must not grow a twin pair.
  def stored_as(name)
    return nil unless exist?

    note_files.find { |file| stem(file).downcase == name }
  end

  def note_at(name, path)
    return nil if path.nil? || !File.file?(path)

    text = read_body(path)
    Memory.new(name:, description: first_line(text), path:, chars: text.length)
  end

  # A note is read through the same byte boundary every other file is: valid
  # UTF-8 out, LF separators out, whatever the file's own style was on disk. The
  # terminator the store writes is chomped here, so #body returns the note's
  # CONTENT - which is the length the body cap is stated in and the length the
  # tools report.
  def read_body(path)
    FileText.from_disk(path).text.chomp
  end

  # Text arriving from a tool call is an outside boundary (issue #341): it is
  # normalized here, and CR/CRLF are folded so a note written on Windows reads
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
