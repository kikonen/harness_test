# frozen_string_literal: true

require "json"

require_relative "stream_reader"

module LLM
  # Turns decoded stream LINES into response payloads. Two framings are
  # accepted because both endpoints are supported:
  #   SSE   (OpenAI-compatible): "data: {...}", "data: [DONE]", and the
  #         non-payload fields "event:" / "id:" / "retry:" / a ":" comment.
  #   NDJSON (native /api/chat): one JSON object per line.
  # A line with no payload yields nil rather than aborting the stream.
  # Framing rules and why: doc/streaming_design.md.
  class StreamDecoder
    # The SSE end-of-stream marker (OpenAI-compatible servers send it after
    # the final chunk).
    DONE = "[DONE]".freeze

    def initialize
      @reader  = StreamReader.new
      @done    = false
    end

    # Feeds one raw transport chunk; returns the payloads it completed (an
    # empty array when the chunk held no complete line).
    def push(chunk)
      @reader.push(chunk).filter_map { |line| decode(line) }
    end

    # Flushes a final unterminated line at end of stream.
    def finish
      @reader.finish.filter_map { |line| decode(line) }
    end

    # True once the end-of-stream marker has been seen.
    def done?
      @done
    end

    def pending_bytes
      @reader.pending_bytes
    end

    private

    def decode(line)
      text = line.strip
      return nil if text.empty?
      return nil if @done

      payload = text.start_with?("data:") ? data_line(text) : json_line(text)
      return nil if payload.nil?

      @done = true if payload == DONE
      payload
    end

    # "data: {...}" -> the parsed object; "data: [DONE]" -> DONE.
    def data_line(text)
      value = text.sub(/\Adata:\s?/, "").strip
      return DONE if value == DONE
      # A ":" comment line and an empty data line carry nothing.
      return nil if value.empty? || value.start_with?(":")

      json_line(value)
    end

    def json_line(text)
      return nil unless text.start_with?("{")

      JSON.parse(text, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end
  end
end
