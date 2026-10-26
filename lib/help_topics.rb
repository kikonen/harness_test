# frozen_string_literal: true

require_relative "harness_error"

# The prose half of /help as DATA (issue #323): named topics whose bodies are
# paragraphs, so a reader can ask for one topic instead of scrolling a dump,
# and so the wrapping/indenting is a rendering decision (HelpRenderer), not
# hand-aligned text. A topic name must not collide with a command name -
# HelpTopics.validate! checks that against the dispatch registry.
module HelpTopics
  Topic = Struct.new(:name, :title, :paragraphs, :see_also, keyword_init: true)

  TOPICS = {
    "access" => Topic.new(
      name: "access",
      title: "File access grants",
      paragraphs: [
        "Type any text that does not start with / to send it directly to the " \
          "model. It reaches files through file.read / file.write / file.patch " \
          "and friends.",
        "When it attempts a path you have not granted, you are prompted for " \
          "the access at the granularity you prefer: the single file, the " \
          "directory only (direct children), or the directory recursively (all " \
          "subdirs). There are no auto-grants.",
        "Read, write and delete are tracked separately. A read grant never " \
          "implies write; a write grant implies read on the same path; delete " \
          "is its own mode - neither read nor write implies it. Sensitive paths " \
          "(.env*, .git/, .harness/) can never be granted, except a nested one " \
          "inside a scratch zone (tmp/scratch/<n>/, tmp/keep/<n>/), where it is " \
          "a disposable clone rather than this project's own state."
      ],
      see_also: %w[grant clear]),
    "shell" => Topic.new(
      name: "shell",
      title: "Local shell mode (!)",
      paragraphs: [
        "A line starting with ! runs a shell command locally, bypassing the " \
          "model. The command and its output are never sent to or stored in the " \
          "model's session.",
        "Approval follows the same model as the run.command tool (Allow / " \
          "always-allow; unsafe constructs can never be auto-approved) but uses " \
          "a SEPARATE allowlist (.harness/shell_commands.yml) - a grant saved " \
          "one way never auto-approves a command on the other.",
        "The confirmation dialog itself is opt-out for the bang path: " \
          "'bang_requires_confirmation: false' in the config, because a human " \
          "confirming a command the same human just typed is consent fatigue. " \
          "The disaster denylist still applies either way."
      ],
      see_also: %w[yolo grant]),
    "consent" => Topic.new(
      name: "consent",
      title: "Shell consent postures and the safety check",
      paragraphs: [
        "Three levels of how much manual approval a run.command call needs, " \
          "always chosen by the USER - the model never flips them:",
        "* MANUAL - every unapproved command asks (the default).",
        "* AUTO-APPROVE - commands the model verdicts \"safe:\" run without " \
          "the dialog (initial posture from config " \
          "'command_safety_auto_approve'; toggled LIVE with Ctrl+A). A " \
          "\"dangerous:\" verdict or a missing verdict still asks.",
        "* YOLO (/yolo) - every run.command call runs with no dialog and no " \
          "model safety check; each run prints a status line and is logged. " \
          "YOLO does not cover the ! bang syntax, which has its own config key.",
        "When the safety check is ON, an unapproved command is offered to the " \
          "model first (\"does this look safe?\") and the verdict appears as an " \
          "advisory note in the consent dialog. Allowlisted commands skip the " \
          "check: it runs on exactly what the runner would otherwise ask about.",
        "The posture is ALWAYS labeled - in the startup banner (\"Command " \
          "consent: ...\"), in the prompt line (\"[model (effort)] [MANUAL] >\") " \
          "and as a badge at the END of the spinner line - so a run's behavior " \
          "is visible before you type anything.",
        "The disaster denylist is the floor under EVERY posture and every " \
          "stored allowlist grant: rm -rf, mkfs, dd of=/dev/, shutdown, sudo, " \
          "git push -f, curl <url> | sh, a fork bomb, format C:, diskpart, " \
          "del /s /q, Remove-Item -Recurse -Force ... always reach the dialog " \
          "with no \"Always allow\" option - a one-off Allow only.",
        "The floor's only exception is the denylist-safe override (issue #389): " \
          "with the safety check on, a real model \"safe:\" verdict may auto-approve " \
          "a denylist match on the run.command path, so a disaster word sitting " \
          "inert inside a quoted string stops costing a dialog. A config-only opt-in " \
          "('command_safety_auto_approve: denylist' or 'safe_denylist', or the " \
          "separate 'command_safety_denylist_safe_approve: true') - no live toggle, " \
          "not a Ctrl+A posture, fires only on a real \"safe:\" verdict, and every " \
          "override is logged naming the verdict."
      ],
      see_also: %w[yolo grant palette]),
    # Named "conversation", not "session": a topic name must not collide with a
    # command name, or /help session could mean two things (HelpTopics.validate!).
    "conversation" => Topic.new(
      name: "conversation",
      title: "Sessions, context and retry",
      paragraphs: [
        "Prompts accumulate in a session, so the model sees the whole " \
          "conversation.",
        "If a request fails mid-turn, the tool work already done stays in the " \
          "session: /retry re-sends from exactly where it stopped instead of " \
          "starting over.",
        "/session shows a summary, /session-clear starts a fresh conversation " \
          "(the saved session file is untouched), /compact summarizes the " \
          "conversation to free context window space, and /ctx reports the " \
          "current token usage, headroom and auto-compact status.",
        "A failed request also leaves a pending prompt in the session - " \
          "/session reports it and /retry consumes it."
      ],
      see_also: %w[retry session session-clear compact ctx save resume sessions]),
    "saving" => Topic.new(
      name: "saving",
      title: "Saving and resuming sessions",
      paragraphs: [
        "The session (conversation history AND the access list) is auto-saved " \
          "to its own directory (.harness/sessions/<session-id>/session.json) " \
          "at every prompt boundary - before each send and after each reply - " \
          "and again on exit, so a crash loses at most one in-flight request.",
        "/save stores it manually at any time and prints the id plus the " \
          "command line that resumes it. Disable auto-save with --no-auto-save " \
          "or 'auto_save: false' in the config.",
        "/sessions lists saved sessions and /resume <id> restores one: the " \
          "whole run is rebuilt under that id (conversation, grants, log and " \
          "history file). Starting the harness with --continue picks up the " \
          "newest saved session in this working directory.",
        "What a resume restores: the conversation and access list, the model " \
          "profile and parameter overrides, the YOLO posture and the output " \
          "palette, and the streaming posture (/stream) the session was saved " \
          "with."
      ],
      see_also: %w[save sessions resume]),
    "rules" => Topic.new(
      name: "rules",
      title: "Project rules (harness.md)",
      paragraphs: [
        "If a harness.md file exists in the working directory its content is " \
          "appended to the system prompt as project-specific rules.",
        "It is re-read automatically when its modification time changes " \
          "(checked before each prompt), and /reload forces a re-read of both " \
          "the base prompt file and harness.md."
      ],
      see_also: %w[reload]),
    "procedures" => Topic.new(
      name: "procedures",
      title: "Skills (written-down procedures)",
      paragraphs: [
        "A skill is a named markdown procedure stored in .harness/skills/: either " \
          "<name>/SKILL.md (when the skill ships with companion files) or a single " \
          "<name>.md. An optional --- front matter block may carry 'name:' and " \
          "'description:'; without it the description is the file's first prose line.",
        "Skills are NOT injected into the system prompt. Only the names and one-line " \
          "descriptions are reachable (through /skills or the skills.list tool), and " \
          "the body is loaded on demand with /skills <name> or skills.read(name) - so " \
          "a project can define many skills without costing context for the ones no " \
          "task uses.",
        ".harness/skills is the one part of .harness/ a grant can cover: a skill is " \
          "repo content the owner chose to keep, so its files are readable, writable " \
          "and deletable through the normal file tools (with a grant, as everywhere). " \
          "A .env* name inside it stays blocked."
      ],
      see_also: %w[skills reload rules access]),
    "input" => Topic.new(
      name: "input",
      title: "Multiline input and the submit key",
      paragraphs: [
        "* Enter adds a NEWLINE inside the prompt - it never submits, so a " \
          "multiline block can be typed or pasted without tricks.",
        "* The submit key sends the whole buffer: Ctrl+Enter or Shift+Enter " \
          "on a Windows console; Alt+Enter in a normal Unix terminal " \
          "(Ctrl/Shift+Enter are indistinguishable from Enter there). " \
          "AltGr+Enter sends the same bytes as Alt+Enter on most layouts.",
        "* Remote host reached THROUGH Windows Terminal (ssh, WSL2): plain " \
          "Alt+Enter is consumed by Windows Terminal (fullscreen toggle). What " \
          "still reaches the remote pty: Ctrl+Enter (arrives as a bare LF, " \
          "bound to submit, paste-guarded so a pasted line break cannot submit " \
          "mid-paste); AltGr+Enter; a quick ESC-then-Enter tap (both bytes " \
          "within ~100 ms); or Ctrl+Enter sent as CSI 13 by terminals with the " \
          "kitty/kcm extended keyboard protocol.",
        "* Optional fallback: 'double_enter_submit: true' in the config makes " \
          "Enter on an EMPTY last line submit the buffer (pasted blank lines " \
          "never trigger it; while enabled the buffer cannot end with a " \
          "trailing blank line).",
        "* Typing a long block somewhere else is often easier: Ctrl+G writes the " \
          "buffer out to the external editor and brings it back as the draft " \
          "(see /help keys; editor: in the config, --editor, or $HARNESS_EDITOR)."
      ],
      see_also: %w[keys notes]),
    "notes" => Topic.new(
      name: "notes",
      title: "Mid-turn steering notes",
      paragraphs: [
        "While the model is working, any keypress opens a note editor on the " \
          "spot WITHOUT interrupting the turn. Finish the note and press the " \
          "submit key: it reaches the model as a \"User note (mid-turn)\" " \
          "message before its next step, so it can course-correct on the fly - " \
          "no Ctrl+C needed.",
        "Enter inserts a NEWLINE inside the note, so multiline text is typed " \
          "or pasted as one note. The harness acknowledges it with a \"[note] " \
          "got it - ...\" line. Submitting an empty note commits nothing and " \
          "returns to the spinner.",
        "Text typed mid-turn is ALWAYS a note - a / or ! prefix has no " \
          "special meaning then. While a dialog (grant prompt or ui.dialog) is " \
          "open the keyboard belongs to the dialog: answer it normally, and its " \
          "answer is never mistaken for a note."
      ],
      see_also: %w[keys input]),
    "keys" => Topic.new(
      name: "keys",
      title: "Keys",
      paragraphs: [
        "* Esc - idle prompt: cancels the read and the text is KEPT as a " \
          "draft, prefilled at the next prompt (the submit key sends it). In " \
          "the note editor it keeps the text as a draft for the next time the " \
          "editor opens.",
        "* Ctrl+A - toggle the command consent mode (MANUAL / AUTO-APPROVE) " \
          "while the safety check is on; works at the idle prompt and inside " \
          "the note editor (the read closes, an ack line prints, the spinner " \
          "badge shows the new mode).",
        "* Ctrl+C - cancel the current input, or interrupt a running request.",
        "* Ctrl+D - quit on an empty prompt; inside a note editor it aborts " \
          "the RUNNING turn like Ctrl+C (a note committed before it is still " \
          "delivered).",
        "* Ctrl+G - write the buffer you are typing out to the external editor " \
          "and take it back as the DRAFT (the submit key still sends it). Works " \
          "at the idle prompt, in a note and in a dialog's typed answer; needs an " \
          "editor to be set (config 'editor', --editor, $HARNESS_EDITOR or " \
          "$EDITOR) - otherwise the key does nothing special. See /help input.",
        "* Up/Down - browse command history."
      ],
      see_also: %w[input notes consent])
  }.freeze

  def self.fetch(name)
    TOPICS[name.to_s.strip.downcase]
  end

  # CommandHandler calls this at construction with its dispatch registry: a name
  # a reader could not reach, or a body nobody wrote, is a startup failure rather
  # than a /help that silently shows nothing.
  def self.validate!(registry_names, topic_set: TOPICS)
    clash = topic_set.keys.map(&:to_s) & registry_names.map(&:to_s)
    raise HarnessError,
      "help topic name collides with a command: #{clash.join(', ')}" unless clash.empty?

    topic_set.each_value do |topic|
      raise HarnessError,
        "help topic #{topic.name.inspect} has no body" if topic.paragraphs.empty?
    end
  end
end
