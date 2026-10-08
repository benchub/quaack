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
        # A secret this long is scrubbed anywhere; a shorter one only as a
        # whole token. Real keys are all at least this long.
        ANYWHERE_MIN = 16
        # What keys are made of: a whole token is a run of these.
        KEY_CHAR = "[A-Za-z0-9_-]"

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

        def scrub(text, secrets) = secrets.reduce(text) { |scrubbed, secret| scrubbed.gsub(pattern(secret), SCRUBBED) }

        # A secret as long as a real key goes wherever it shows, even inside a
        # longer token, so no key slips past. A shorter one goes only as a whole
        # token, so it can't cut a word apart.
        def pattern(secret)
          return secret if secret.length >= ANYWHERE_MIN

          /(?<!#{KEY_CHAR})#{Regexp.escape(secret)}(?!#{KEY_CHAR})/
        end

        # The secrets to scrub from a detail, longest first, so one that
        # holds another goes whole: the adapter's own keys, and what base_url
        # can hold a key in, as written and decoded: each query value long
        # enough to be a key, the user and password, and each path segment as
        # long as a real key.
        def secrets(base_url, keys)
          (keys.map(&:to_s) + url_values(base_url)).reject(&:empty?).uniq.sort_by { -it.length }
        end

        def url_values(base_url)
          uri = base_url && URI.parse(base_url) or return []

          query_values(uri.query) + decoded(uri.userinfo.to_s.split(":", 2)) + path_segments(uri.path)
        rescue URI::InvalidURIError
          []
        end

        def query_values(query)
          decoded(query.to_s.split(/[&;]/).map { it.split("=", 2)[1].to_s }).select { it.length >= QUERY_SECRET_MIN }
        end

        def path_segments(path) = decoded(path.to_s.split("/")).select { it.length >= ANYWHERE_MIN }

        # Each value as written, and decoded when it decodes.
        def decoded(values)
          values.flat_map do |value|
            [value, URI.decode_www_form_component(value)]
          rescue ArgumentError
            [value]
          end
        end
      end
    end
  end
end
