# frozen_string_literal: true

require "json"
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
        # The encodings whose text is read as UTF-8 bytes, not converted.
        BYTES = [Encoding::UTF_8, Encoding::BINARY].freeze

        # The longest detail, cut after the scrub, so no cut splits a key
        # and leaves part of it.
        DETAIL_MAX = 1000

        module_function

        # A JSON array body's message: its first element's, as the block
        # reads a Hash, or with none there, the whole body as JSON.
        def array_message(body)
          first = body.first
          message = yield(first) if first.is_a?(Hash)
          message || (JSON.generate(body) unless body.empty?)
        end

        # A scrubbed detail cut to DETAIL_MAX characters.
        def cut(text) = text.length > DETAIL_MAX ? "#{text[0, DETAIL_MAX - 1]}…" : text

        # The status, then the body's message, if it has one. An adapter
        # that reads more body shapes passes its own reason.
        def answered(status, body, reason: body_message(body))
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

        # The text and each secret are made valid UTF-8 first, so no gsub
        # raises an error whose message could quote a secret.
        def scrub(text, secrets)
          secrets.map { utf8(it) }.reject(&:empty?).reduce(utf8(text)) do |scrubbed, secret|
            scrubbed.gsub(pattern(secret), SCRUBBED)
          end
        end

        # A value as valid UTF-8: text in another encoding converted, and
        # bytes read as UTF-8, with each invalid sequence replaced.
        def utf8(value)
          text = value.to_s
          return text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless BYTES.include?(text.encoding)

          text.b.force_encoding(Encoding::UTF_8).scrub
        rescue EncodingError
          text.b.force_encoding(Encoding::UTF_8).scrub
        end

        # A secret as long as a real key goes wherever it shows, even inside a
        # longer token, so no key slips past. A shorter one goes only as a whole
        # token, so it can't cut a word apart. Either way, it goes URL-encoded
        # too, whole or in part, in either case of hex.
        def pattern(secret)
          body = secret.each_char.map { char_pattern(it) }.join
          return /#{body}/ if secret.length >= ANYWHERE_MIN

          /(?<!#{KEY_CHAR})#{body}(?!#{KEY_CHAR})/
        end

        # A character as written, or, if a URL can encode it, its encoding:
        # a %XX for each byte.
        def char_pattern(char)
          return Regexp.escape(char) if char.match?(/[A-Za-z0-9_.~-]/)

          encoded = char.bytes.map { |byte| "%#{format("%02X", byte).gsub(/[A-F]/) { "[#{it}#{it.downcase}]" }}" }.join
          "(?:#{Regexp.escape(char)}|#{encoded})"
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

        # Each value as written, and decoded when it decodes. A value that
        # decodes to invalid UTF-8 goes with each invalid sequence dropped
        # and replaced, the ways an echo of it would show.
        def decoded(values)
          values.flat_map do |value|
            plain = URI.decode_www_form_component(value)
            [value, *(plain.valid_encoding? ? [plain] : [plain.scrub(""), plain.scrub("\uFFFD")])]
          rescue ArgumentError
            [value]
          end
        end
      end
    end
  end
end
