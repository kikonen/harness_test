# frozen_string_literal: true

require "yaml"

require_relative "sensitive_files"
require_relative "text_normalizer"

# A skill is a named markdown procedure the harness reads on demand: a repeatable
# job the owner wrote down once instead of re-explaining every session. Skills are
# NOT injected into the system prompt - only their names and one-line descriptions
# reach the model (via skills.list / /skills), and the body is loaded when a job
# actually needs it. Design: doc/skills_design.md.
class Skills
  DIR        = SensitiveFiles::SKILLS_DIR
  SKILL_FILE = "SKILL.md"

  # Truncation of a generated description (a skill with no front matter is named by
  # its own first line, and the index line must stay glanceable).
  DESC_MAX = 120

  Skill = Struct.new(:name, :description, :path, keyword_init: true)

  attr_reader :dir

  def initialize(workdir)
    @dir = File.expand_path(DIR, workdir)
  end

  def exist?
    File.directory?(@dir)
  end

  # Every skill, sorted by name (a stable order, like the tool registry's).
  def all
    return [] unless exist?

    shapes.flat_map do |entry|
      skill_at(entry[:name], entry[:path])
    end.compact.sort_by(&:name)
  end

  def names
    all.map(&:name)
  end

  def find(name)
    name = normalize_name(name)
    return nil if name.nil?

    skill_at(name, path_for(name))
  end

  # The body a skill's job runs on: its markdown with the front matter stripped.
  # nil when the name matches no skill.
  def body(name)
    skill = find(name)
    return nil if skill.nil?

    read_raw(skill.path)[:body]
  end

  # -- name safety ----------------------------------------------------------

  # A skill name is one path segment: no separator, no "..", no drive. Anything
  # else is refused rather than resolved, so skills.read cannot be turned into a
  # general file reader by naming "../../.git/config".
  def normalize_name(name)
    name = name.to_s.strip
    return nil if name.empty?
    return nil if name.include?("/") || name.include?("\\") || name.include?(":")
    return nil if name == "." || name == ".."
    return nil if name.start_with?(".")

    name
  end

  def path_for(name)
    nested = File.join(@dir, name, SKILL_FILE)
    return nested if File.file?(nested)

    flat = File.join(@dir, "#{name}.md")
    return flat if File.file?(flat)

    nil
  end

  private

  # The two shapes a skill may take: <name>/SKILL.md (a skill that ships with
  # companion files) or a single <name>.md file.
  def shapes
    Dir.children(@dir).filter_map do |child|
      full = File.join(@dir, child)
      if File.directory?(full)
        nested = File.join(full, SKILL_FILE)
        next { name: child, path: nested } if File.file?(nested)
      elsif child.end_with?(".md")
        next { name: child[0..-4], path: full }
      end
      nil
    end
  end

  def skill_at(name, path)
    return nil if path.nil? || !inside?(path) || !File.file?(path)

    parsed   = read_raw(path)
    meta     = parsed[:meta]
    desc     = meta["description"].to_s.strip
    meta_name = meta["name"].to_s.strip
    label = meta_name.empty? ? name : meta_name
    brief = desc.empty? ? first_line(parsed[:body]) : desc
    Skill.new(name: label, description: brief, path:)
  end

  def read_raw(path)
    text = TextNormalizer.normalize(File.read(path)).gsub("\r\n", "\n")
    match = /^---\n(.*?)\n---\n?/m.match(text)
    return { meta: {}, body: text } unless match

    { meta: safe_front_matter(match[1]), body: text[(match.end(0))..].to_s.lstrip }
  end

  # Front matter is read with the plain safe_load defaults: no classes, no aliases,
  # so a skill file can name scalars only (Psych 5 has no permitted_types).
  def safe_front_matter(block)
    data = YAML.safe_load("#{block}\n")
    data.is_a?(Hash) ? data : {}
  rescue Psych::SyntaxError
    {}
  end

  def first_line(body)
    line = body.to_s.lines.map(&:strip).find { |l| !l.empty? && !l.start_with?("#") }
    return "no description" if line.nil?

    line.length > DESC_MAX ? "#{line[0, DESC_MAX]} ..." : line
  end

  def inside?(path)
    path == @dir || path.start_with?("#{@dir}/")
  end
end
