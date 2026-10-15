# frozen_string_literal: true

# -- DeferredLogger -----------------------------------------------------------
#
# A stand-in logger that forwards to a logger its SOURCE only has LATER.
#
# WHY (issue #270): the Harness logger is deferred on purpose (issue #123 - a
# run that resumes a saved session must not leave a throwaway log directory
# behind for the fresh random id it started with), so at Harness#initialize
# there is deliberately NO logger yet; Harness#logger builds one on first use.
# But the LLM backend captures its logger reference at construction and logs
# unconditionally on the first attempt of every request
# (@logger.info("REQ: POST ...")), so it was handed that nil and the first
# prompt of a run died with "undefined method 'info' for nil" - whenever
# nothing else happened to touch Harness#logger first, which is exactly the
# shape of verbose off + auto_save off. Rebinding the client inside the lazy
# accessor does not help: the crash happens before anything ever asks for the
# logger, so the rebind never runs.
#
# The lesson is the ordering, not the nil: a deferred value is only correct if
# RESOLVING it is deferred too. A nil placeholder is not a deferred value, it
# is a snapshot of "not yet". This object is what the backend gets instead -
# it can never hold a nil, and it asks the source for the logger at CALL time,
# which is the moment the harness actually knows which session it logs to.
class DeferredLogger
  # The severity methods the harness logs. :fatal is included although nothing
  # calls it yet, so a future call site cannot fail on this stand-in.
  SEVERITIES = %w[debug info warn error fatal].freeze

  # source: any object whose #logger returns the real logger (Harness).
  def initialize(source)
    @source = source
  end

  SEVERITIES.each do |severity|
    define_method(severity) do |*args, &block|
      @source.logger.public_send(severity, *args, &block)
    end
  end

  # This object never OWNS the real logger - its owner (Harness) closes it.
  # Answering #close with a no-op keeps an owner-style `logger.close` from
  # silently killing the live session log through the stand-in.
  def close; end

  # Deliberately NOT forwarded: #level=, #formatter= and friends configure the
  # real logger, which its owner builds and configures itself (see
  # Harness#build_logger). Configuring them through the stand-in would write
  # to a logger that is about to be replaced.
end
