# frozen_string_literal: true

require "uri"

module Quaack
  module Driver
    module LLM
      # The detail of an error from an API on the Anthropic Messages API,
      # for the anthropic and bedrock adapters: the status and the body's
      # own error message, never the whole body or the URL, with the keys
      # scrubbed out. base_url can name a gateway or proxy, such as LiteLLM,
      # whose body echoes a key or anything else.
      module APIErrorDetail
        # What a secret in a detail is replaced with.
        SCRUBBED = "[key]"
        # A base_url query value shorter than this is taken for a setting,
        # such as a version, not a key, so it isn't scrubbed.
        QUERY_SECRET_MIN = 8

        module_function

        # The status, then the body's message, if it has one.
        def answered(status, body)
          reason = body_message(body)
          reason ? "the API answered #{status}: #{reason}" : "the API answered #{status}"
        end

        # The message of the body's error object, as Anthropic sends it, or
        # the body's own message, as Bedrock sends it, if it's text. The gem
        # decodes a JSON body with symbol keys.
        def body_message(body)
          return unless body.is_a?(Hash)

          inner = body[:error]
          [inner.is_a?(Hash) ? inner[:message] : nil, body[:message]].find { it.is_a?(String) && !it.empty? }
        end

        def scrub(text, secrets) = secrets.reduce(text) { |scrubbed, secret| scrubbed.gsub(secret, SCRUBBED) }

        # The secrets to scrub from a detail, longest first, so one that
        # holds another goes whole: the adapter's own keys, and each query
        # value in base_url, as written and decoded, that's long enough to be
        # a key.
        def secrets(base_url, keys)
          (keys.map(&:to_s) + query_values(base_url)).reject(&:empty?).uniq.sort_by { -it.length }
        end

        def query_values(base_url)
          query = base_url && URI.parse(base_url).query or return []

          query.split(/[&;]/).flat_map { query_value(it) }.select { it.length >= QUERY_SECRET_MIN }
        rescue URI::InvalidURIError
          []
        end

        def query_value(pair)
          value = pair.split("=", 2)[1].to_s
          [value, URI.decode_www_form_component(value)]
        rescue ArgumentError
          [value]
        end
      end
    end
  end
end
