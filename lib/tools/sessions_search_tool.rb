# frozen_string_literal: true

require_relative "../tool"
require_relative "../session_locator"

# Searches the workdir's saved sessions by what they were ABOUT (issue #279):
# the model cannot answer "which session was I doing X in?" from /sessions
# alone, because /sessions only reports counts. This matches each saved
# session's message text (and its id) by case-insensitive substring and shows
# a short window around the first hit per session, so the model can point the
# user at the right id to resume. It is read-only: it never resumes or deletes.
module Tools
  class SessionsSearchTool < Tool
    def initialize(locator)
      @locator = locator
      super(
        name: "sessions.search",
        description: "Searches the saved sessions in this working directory by " \
          "content (case-insensitive substring over each session's message text " \
          "and id). Returns the matching sessions newest-first with a snippet " \
          "around a hit - the way to find 'the session where I was doing X'. " \
          "Resume a match with /resume <id> (or the --resume flag).",
        parameters: {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Substring to match against session message text and ids"
            }
          },
          required: ["query"]
        }
      )
    end

    def execute(args)
      query = args["query"].to_s.strip
      if query.empty?
        status(:fail, "empty query")
        return "error: sessions.search needs a non-empty query " \
          "(the user can list what is saved with /sessions)"
      end

      matches = @locator.search(query)
      if matches.empty?
        status(:info, "no sessions match #{query.inspect}")
        return "no saved sessions match #{query.inspect} " \
          "(the user can list what is saved with /sessions)"
      end

      status(:info, "#{matches.size} session(s) match #{query.inspect}")
      header = "Sessions matching #{query.inspect} (#{matches.size}), " \
        "newest first; resume one with /resume <id>:"
      rows = matches.map do |m|
        detail = "  #{m[:id]}  saved #{m[:saved_at].strftime('%Y-%m-%d %H:%M:%S')}  " \
          "#{m[:messages]} messages, #{m[:hits]} hit(s)  [workdir: #{m[:workdir]}]"
        "#{detail}\n    #{m[:snippet]}"
      end
      ([header] + rows).join("\n")
    end
  end
end
