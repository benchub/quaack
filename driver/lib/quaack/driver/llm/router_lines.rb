# frozen_string_literal: true

module Quaack
  module Driver
    module LLM
      # The progress line the router prints when it leaves a provider
      # (DESIGN.md, "Several LLM providers": Progress and failure messages):
      # why, by the rule and the error's short reason, then what happens
      # next.
      #
      #   error = Error.new("llm_rate_limited", "...", reason: "the API answered 429: slow down")
      #   RouterLines.line("groq", error, "trying opus (llm-rewrites)", named: true)
      #   # => "groq is rate limited (the API answered 429: slow down), so the rest of this run
      #   #    skips it; trying opus (llm-rewrites)"
      #
      # Names come from the operator's own config. From an llm block, named
      # is false, and the line calls the provider the LLM and gives no
      # reason, as it read before several providers. A reason is
      # Error#reason: the adapter's own words, or the API's, scrubbed of keys
      # (APIErrorDetail). The enclave never supplies one.
      module RouterLines
        WHY = { "llm_rate_limited" => "is rate limited", "llm_unavailable" => "is unavailable" }.freeze
        REFUSED = "the API refused the credentials"
        NOT_LOGGED_IN = "the copilot command said it isn't logged in"
        FIX = "Fix its credentials before the next run."
        STILL = "though later asks may still use it"
        # The most of a reason a line or message shows.
        REASON_MAX = 120

        module_function

        # error is the LLM::Error the provider failed with, and copilot says
        # the provider is a copilot command, whose llm_auth means it isn't
        # logged in. llm_auth's line says why itself, so it shows no reason.
        def line(name, error, rest, named:, copilot: false)
          who = named ? name : "The LLM"
          because = named ? because(error.reason) : ""
          case error.rule
          when "llm_auth" then "#{dropped(name, named, copilot)} #{rest[0].upcase}#{rest[1..]}"
          when "llm_bad_response" then "#{who}'s reply couldn't be used#{because}, #{STILL}; #{rest}"
          else "#{who} #{WHY.fetch(error.rule)}#{because}, so the rest of this run skips it; #{rest}"
          end
        end

        # What a provider failed with, for a list of what was tried or a
        # fan-out branch's line: the rule, then the short reason, if any.
        def failed(rule, reason) = short(reason)&.then { "#{rule}: #{it}" } || rule

        # reason on one line, cut to REASON_MAX characters, or nil if blank.
        def short(reason)
          text = reason.to_s.gsub(/\s+/, " ").strip
          return if text.empty?

          text.length > REASON_MAX ? "#{text[0, REASON_MAX - 3]}..." : text
        end

        def because(reason) = short(reason)&.then { " (#{it})" } || ""

        def dropped(name, named, copilot)
          why = copilot ? NOT_LOGGED_IN : REFUSED
          return "llm_auth: #{why}, so the rest of this run skips the LLM. #{FIX}" unless named

          "llm_auth: #{name}: #{why}, so the rest of this run skips #{name}. #{FIX}"
        end
      end
    end
  end
end
