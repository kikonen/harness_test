# frozen_string_literal: true

require "shellwords"
require "tmpdir"
require "fileutils"

require_relative "../file_text"

# -- UI::ExternalEditor ---------------------------------------------------
#
# Hands the text the user was typing to a real external editor and brings the
# file back. Design and the measured facts (what Reline does with Ctrl+G today,
# and why the child runs only after Reline has left raw mode): doc/external_editor.md.
#
# The command is split into ARGV WORDS, never handed to a shell: nothing in the
# user's editor setting can be read as a shell construct, so no shell runs here
# and the command denylist is not involved.

module UI
  class ExternalEditor
    # Resolution order. HARNESS_EDITOR is the explicit override tier (the role
    # $HARNESS_CONFIG plays for the config file); the config key is the project
    # setting; EDITOR/VISUAL is what the user's own shell already exports.
    ENV_OVERRIDE  = "HARNESS_EDITOR".freeze
    ENV_FALLBACKS = %w[EDITOR VISUAL].freeze

    # :ok           the editor ran and the file came back
    # :unavailable  no editor command resolved (or it holds no program word)
    # :error        the child could not be started
    # note is the line the caller prints: what ran (:ok) or why nothing ran.
    Result = Struct.new(:status, :text, :note, keyword_init: true)

    # The program the command resolves to (its first argv word).
    attr_reader :program

    # The first non-blank value in the resolution order, or nil when there is
    # none. ENV is a parameter so a spec can pin the order without touching the
    # real environment of the run.
    def self.command(configured, env: ENV)
      candidates = [env[ENV_OVERRIDE], configured, *ENV_FALLBACKS.map { |k| env[k] }]
      candidates.map { |v| v.to_s.strip }.find { |v| !v.empty? }
    end

    def initialize(command)
      @command = command.to_s.strip
      # An unbalanced quote is a bad setting, not a crash: no program word, so
      # open answers :unavailable.
      @argv = begin
        Shellwords.shellsplit(@command)
      rescue ArgumentError
        []
      end
      @program = @argv.first.to_s
    end

    def available?
      !@argv.empty?
    end

    # Writes `draft` to a scratch file, runs the editor on it, and returns the
    # file's content. The draft comes back UNCHANGED on :unavailable / :error: a
    # failed editor must never swallow what the user had typed.
    def open(draft)
      unless available?
        reason = @command.empty? ? "no editor command" : "#{@command} holds no program"
        note = "external editor unavailable (#{reason})"
        return Result.new(status: :unavailable, text: draft, note:)
      end

      dir  = Dir.mktmpdir("harness-editor")
      path = File.join(dir, "draft.md")
      File.binwrite(path, draft.to_s)

      failure = run_editor(path)
      if failure
        note = "could not run #{@program}: #{failure}"
        Result.new(status: :error, text: draft, note:)
      else
        Result.new(status: :ok, text: read_back(path), note: "edited with #{@program}")
      end
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    private

    # The editor is an outside writer, so its bytes cross the same file boundary
    # every other reader uses: LF separators for the text handed on, whatever
    # the editor wrote on disk (doc/file_editing_design.md).
    def read_back(path)
      FileText.from_disk(path).text
    end

    # Returns nil when the editor exited 0, otherwise why it did not.
    # stdin/stdout/stderr are INHERITED: a terminal editor needs the terminal,
    # and Reline has already released it by the time this runs.
    def run_editor(path)
      Process.wait(Process.spawn(*@argv, path))
      code = $?.exitstatus
      return nil if code.zero?

      "exited with status #{code}"
    rescue StandardError => e
      e.message
    end
  end
end
