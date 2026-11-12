# frozen_string_literal: true

require_relative "../command"
require_relative "../param_overrides"

module Commands
  # /param - show and adjust the LLM parameters for this session (issue #219).
  #
  #   /param                     list every parameter (effective value +
  #                              override/default source)
  #   /param <key>               show one parameter
  #   /param <key> <value>       set a session-level override
  #   /param <key> default       reset one back to the profile (config) value
  #
  # Values: 'off' (reasoning_effort: use the server default / no reasoning),
  # 'default' (reset), or a number/word parsed to the parameter's type.
  class ParamCommand < Command
    HELP = CommandHelp.new(
      usage: "param [key [value]]",
      summary: "List, show, override or reset a model parameter for this " \
        "session (value: a number/word, \"off\", or \"default\")",
      group: :model,
      forms: [
        "param",
        "param <key>",
        "param <key> <value>",
        "param <key> default"
      ],
      see_also: %w[model models],
      form_notes: {
        "param" => "list every parameter",
        "param <key>" => "show one parameter",
        "param <key> <value>" => 'set a session override (value: a number/word, "off", or "default")',
        "param <key> default" => "reset one to the profile value"
      })

    def handle(args)
      args  = args.strip
      words = args.split(/\s+/).reject(&:empty?)

      case words.size
      when 0 then list_all
      when 1 then show_one(words[0])
      when 2 then set_one(words[0], words[1])
      else
        render_usage
      end
    end

    private

    def list_all
      emit_list(
        title: ParamOverrides::LIST_TITLE,
        kind: :table,
        columns: %i[key value annotation],
        items: param.list_items,
        origin: "param")
    end

    def show_one(key)
      unless param.overrideable?(key)
        emit_role(
          :note,
          "Unknown parameter '#{key}'. Adjustable: #{param.keys.join(', ')}")
        return
      end

      eff  = param.effective(key)
      mark = param.overridden?(key) ? "session override" : "profile default"
      emit_role(:note, "#{key}: #{param.display_value(eff)} (#{mark})")
    end

    def set_one(key, value)
      emit_role(:note, param.set(key, value))
    end

    # The shared override object (SessionManager owns the single instance).
    def param
      @harness.session_manager.param_overrides
    end
  end
end
