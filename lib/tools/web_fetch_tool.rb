# frozen_string_literal: true

require_relative "../tool"
require_relative "../ui/dialog"
require_relative "../web_fetcher"
require_relative "../web_host_allowlist"

module Tools
  # Fetches a URL over http(s) and returns the response as text (issue #33).
  #
  # The fetching rules (scheme, address guard, redirect re-validation, byte cap)
  # live in WebFetcher; this class owns the USER side: which host may be asked
  # for, what the user sees before anything is sent, and how much of the response
  # reaches the model's context window. Design: doc/web_fetch_design.md.
  #
  # CONSENT MODEL (the new security surface issue #33 flagged):
  #   - Every host that is not already granted reaches the dialog, in EVERY
  #     posture. The shell postures are NOT reused here: YOLO and AUTO-APPROVE are
  #     the user's decision about SHELL commands (issue #221), and a decision to
  #     stop asking about `git status` says nothing about fetching a URL.
  #   - A grant is for ONE EXACT HOST (WebHostAllowlist), never a domain suffix:
  #     a grant for "example.com" must not cover "evil.example.com".
  #   - A grant says only WHETHER a host may be asked for. It never widens what
  #     WebFetcher may do (no scheme, address or redirect exception is grantable).
  #   - The URL is shown in full before the dialog, exactly like a shell command:
  #     the user must see what will be requested before anything is sent.
  #
  # OUTPUT BUDGET: a fetched page is model-supplied-size text going straight into
  # the context window, so it is truncated to a line limit with the house notice
  # (the same rule as run.command's output), and the byte cap in WebFetcher is
  # what bounds the download itself.
  class WebFetchTool < Tool
    DEFAULT_LIMIT = 200   # output lines
    MAX_LIMIT     = 2000  # hard cap

    TITLE = "The model is requesting to fetch a URL:\n%s\n(host: %s)"

    DESCRIPTION = [
      "Fetches one URL over http or https and returns the response body as text.",
      "Use it for a URL you already have (documentation, an API, a file over http).",
      "Each host must be allowed by the user the first time it is fetched;",
      "a saved grant covers that exact host only.",
      "Guards are not configurable by the model: private/loopback/link-local",
      "addresses are refused, redirects are re-checked, and a body larger than",
      "the fetch cap is stopped.",
      "Output is truncated to a line limit: it enters the context window."
    ].join(" ")

    def initialize(file_list, options, harness: nil)
      @workdir   = file_list.workdir
      @options   = options
      @harness   = harness
      @fetcher   = WebFetcher.new(guard: build_guard)
      @allowlist = WebHostAllowlist.new(@workdir)
      super(
        name: "web.fetch",
        description: DESCRIPTION,
        parameters: {
          type: "object",
          properties: {
            url: {
              type: "string",
              description: "The absolute http(s) URL to fetch. Shown in full to the " \
                "user unless its host is already allowed."
            },
            limit: {
              type: "integer",
              description: "Optional maximum number of body lines returned " \
                "(default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})."
            },
            timeout: {
              type: "integer",
              description: "Optional timeout in seconds per request (default " \
                "#{WebFetcher::DEFAULT_TIMEOUT}, max #{WebFetcher::MAX_TIMEOUT})."
            }
          },
          required: ["url"]
        }
      )
    end

    def execute(args)
      url     = args["url"].to_s
      fetcher = @fetcher
      uri     = fetcher.parse(url)
      return uri if uri.is_a?(String) # the parse error already names the rule

      # A blocked IP literal is refused before the user is asked: the decision
      # needs no lookup, and a consent prompt about an address the guard already
      # decided on is noise. A HOST NAME is the other case - deciding it needs
      # DNS, and DNS is a network side effect, so consent comes first there.
      literal = fetcher.literal_block(uri)
      return literal if literal

      host  = WebHostAllowlist.normalize(uri.host)
      grant = consent(uri, host)
      return grant if grant

      limit   = limit_for(args["limit"])
      timeout = args["timeout"].to_i
      outcome = fetcher.fetch(uri.to_s, timeout:)
      return failure(host, outcome) if outcome.is_a?(String)

      success(host, limit, outcome)
    end

    private

    # The private-address opt-in is the USER's config key, never a model choice:
    # it exists for a local or internal endpoint (a localhost dev server, an
    # intranet wiki), and it lifts the PRIVATE tier only (AddressGuard).
    def build_guard
      AddressGuard.new(allow_private: @options[:web_fetch_allow_private] == true)
    end

    def limit_for(raw)
      limit = raw.to_i
      return DEFAULT_LIMIT if limit <= 0

      [limit, MAX_LIMIT].min
    end

    # Returns nil when the fetch may proceed, or the denial error string.
    def consent(uri, host)
      if @allowlist.allowed?(host)
        status(:ok, "auto-approved (host allowed): #{host}")
        return nil
      end

      decision = handle_choice(ask_dialog(uri, host), host)
      return denial(decision) if decision.key?(:denied)

      saved = Array(decision[:saved])
      saved.each { |granted| @allowlist.add(granted) }
      return nil if saved.empty?

      where = ".harness/#{WebHostAllowlist::FILENAME}"
      status(:ok, "always-allowed host: #{saved.join(', ')} (saved to #{where})")
      nil
    end

    def ask_dialog(uri, host)
      options = [UI::Dialog::Option.new(title: "Allow", value: :allow)]
      # Only a real host can be saved: the dialog must not offer to grant
      # something the allowlist would silently refuse (a path, a port, a blank).
      if WebHostAllowlist.grantable?(host)
        options << UI::Dialog::Option.new(
          title: "Always allow '#{host}'",
          description: "Future fetches of this exact host skip the dialog " \
            "(no other host, no subdomain)",
          value: { always_allow: host })
      end

      dialog = UI::Dialog.new(title: format(TITLE, uri.to_s, host), options:)
      # Single-thread I/O rule (issue #40): inside a Task the dialog is served on
      # the MAIN thread; there is no main-thread (bang-style) fetch path.
      dialog.show(ui: nil)
    end

    # The dialog answer becomes ONE decision Hash: { denied:, note: } or
    # { saved: [...] }. An error String must not come out of here, because the
    # caller reads the decision as a Hash (a String would make that read raise).
    def handle_choice(choice, host)
      # A cancel with a one-line reason arrives as [CANCEL_VALUE, 'reason'].
      if noted_cancel?(choice)
        return { denied: "user denied fetching #{host}", note: choice[1] }
      end
      return { denied: "user denied fetching #{host}" } if plain_cancel?(choice)

      values = choice.is_a?(Array) ? choice : [choice]
      # A bare Allow mixed with a grant: run this one, save nothing (the same
      # reading CommandRunner gives the contradictory line).
      return { saved: [] } if values.include?(:allow)

      { saved: granted_hosts(values) }
    end

    def noted_cancel?(choice)
      choice.is_a?(Array) && choice.size == 2 &&
        choice[0] == UI::Dialog::CANCEL_VALUE && choice[1].is_a?(String)
    end

    def plain_cancel?(choice)
      values = choice.is_a?(Array) ? choice : [choice]
      values.include?(UI::Dialog::CANCEL_VALUE)
    end

    def granted_hosts(values)
      values.select { |value|
        value.is_a?(Hash) && value[:always_allow]
      }.map { |value| value[:always_allow] }
    end

    def denial(decision)
      note = decision[:note]
      status(:fail, note ? "denied by user (note: \"#{note}\")" : "denied by user")
      Tool.denial_error("error: #{decision[:denied]}", note ? { note: } : nil)
    end

    def success(host, limit, result)
      detail = "#{result.status}, #{result.bytes} bytes#{redirect_note(result)}"
      status(:ok, "#{host} (#{detail})")
      body, truncated = truncate_body(result.body, limit)

      [
        "status: #{result.status}",
        "content-type: #{result.content_type}",
        "url: #{result.final_url}",
        "bytes: #{result.bytes}",
        # The model asked for another URL, so it must be told the answer came
        # from a redirect chain (the guards re-checked every hop).
        result.redirects.positive? ? "redirects: #{result.redirects}" : nil,
        "--- body ---",
        body,
        truncated ? truncation_notice(limit) : nil
      ].compact.join("\n")
    end

    def redirect_note(result)
      result.redirects.positive? ? ", via #{result.redirects} redirect(s)" : ""
    end

    # A transport failure is logged (issue #185's rule: a failure must leave a
    # trace even when the returned string carries none) and returned as an error
    # the model must not retry blindly.
    def failure(host, outcome)
      status(:fail, "#{host} #{outcome}")
      @harness&.logger&.warn("web.fetch failed (#{host}): #{outcome}")
      outcome
    end

    # Plain split drops a trailing empty element from a final newline, so the
    # line count is what the model actually sees.
    def truncate_body(text, limit)
      lines = text.split("\n")
      return [text, false] if lines.size <= limit

      [lines.first(limit).join("\n"), true]
    end

    def truncation_notice(limit)
      "... (output truncated: showing the first #{limit} lines - raise 'limit' " \
        "or fetch a narrower URL to see the rest)"
    end
  end
end
