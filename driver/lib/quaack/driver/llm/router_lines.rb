# frozen_string_literal: true

module Quaack
  module Driver
    module LLM
      # The progress line the router prints when it leaves a provider
      # (DESIGN.md, "Several LLM providers": Progress and failure messages):
      # why, by the rule, then what happens next.
      #
      #   RouterLines.line("groq", "llm_rate_limited", "trying opus (llm-rewrites)", named: true)
      #   # => "groq is rate limited, so the rest of this run skips it; trying opus (llm-rewrites)"
      #
      # Names come from the operator's own config. From an llm block, named
      # is false, and the line calls the provider the LLM.
      module RouterLines
        WHY = { "llm_rate_limited" => "is rate limited", "llm_unavailable" => "is unavailable" }.freeze
        REFUSED = "the API refused the credentials"
        NOT_LOGGED_IN = "the copilot command said it isn't logged in"
        FIX = "Fix its credentials before the next run."
        STILL = "though later asks may still use it"

        module_function

        # copilot says the provider is a copilot command, whose llm_auth
        # means it isn't logged in.
        def line(name, rule, rest, named:, copilot: false)
          who = named ? name : "The LLM"
          case rule
          when "llm_auth" then "#{dropped(name, named, copilot)} #{rest[0].upcase}#{rest[1..]}"
          when "llm_bad_response" then "#{who}'s reply couldn't be used, #{STILL}; #{rest}"
          else "#{who} #{WHY.fetch(rule)}, so the rest of this run skips it; #{rest}"
          end
        end

        def dropped(name, named, copilot)
          why = copilot ? NOT_LOGGED_IN : REFUSED
          return "llm_auth: #{why}, so the rest of this run skips the LLM. #{FIX}" unless named

          "llm_auth: #{name}: #{why}, so the rest of this run skips #{name}. #{FIX}"
        end
      end
    end
  end
end
