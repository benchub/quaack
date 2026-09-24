# frozen_string_literal: true

require "pg_query"
require_relative "../pg_array"

module Quaack
  module Enclave
    module Redaction
      # Redacts one expression as Postgres prints it in a plan, such as a
      # Filter, a Sort Key, or an Output column. It reads the text with
      # pg_query's scanner, not its parser, since Postgres prints forms no
      # SQL has, such as "(hashed SubPlan 2).col1". Each literal token is
      # replaced with the placeholder it matches (see Matcher), or with $?
      # when none does. Everything else stays exactly as Postgres printed
      # it, casts included, so '-5'::integer becomes $2::integer.
      #
      # A literal token is a string, a number, a bit string, or TRUE or
      # FALSE (but not in IS TRUE or IS NOT FALSE). These look like
      # literals but aren't, and stay:
      # - A subplan's number, as in "InitPlan 1" and "SubPlan 2".
      # - A cast's type modifiers, as in ::character varying(12) and
      #   ::numeric(10,2): only integers in parentheses right after a type
      #   name. A $n parameter stays too: it's already a placeholder.
      #
      # A string cast to an array, such as '{1,2,3}'::bigint[] (Postgres's
      # form for an IN list), that matches no placeholder as a whole
      # becomes ARRAY[$1, $2, $3]: each element is matched on its own,
      # masked as $? if nothing matches, and a NULL element stays NULL.
      #
      # redact returns nil for text the scanner can't read, such as an
      # unclosed quote, so the caller can drop it. It never raises with the
      # text in a message.
      module Expression
        # matches has, for each literal replaced, the numbers of the
        # placeholders it matched (see Matcher#candidates), empty for a
        # mask.
        Redacted = Data.define(:text, :masked, :matches)

        LITERALS = %i[SCONST USCONST ICONST FCONST BCONST XCONST].freeze
        BOOLEANS = %i[TRUE_P FALSE_P].freeze
        SUBPLANS = %w[InitPlan SubPlan].freeze
        MASK = "$?"

        module_function

        def redact(text, matcher)
          return nil unless text.is_a?(String) && text.valid_encoding? && !text.include?("\0")

          Scan.new(text, PgQuery.scan(text).first.tokens.to_a, matcher).redacted
        rescue PgQuery::ScanError
          nil
        end

        # One scanned expression.
        class Scan
          def initialize(text, tokens, matcher)
            @text = text
            @tokens = tokens
            @sources = tokens.map { |token| text.byteslice(token.start...token.end) }
            @cast = Cast.new(tokens, @sources)
            @matcher = matcher
            @masked = 0
            @matches = []
          end

          def redacted
            out = +""
            last = 0
            @tokens.each_with_index do |token, i|
              replacement = replacement(token, i)
              next unless replacement

              out << @text.byteslice(last...token.start) << replacement
              last = token.end
            end
            out << @text.byteslice(last..)
            Redacted.new(text: out, masked: @masked, matches: @matches.freeze)
          end

          private

          # What a token becomes, or nil if it stays.
          def replacement(token, index)
            if LITERALS.include?(token.token)
              literal(token, index) unless @cast.modifier?(index) || subplan_number?(index)
            elsif BOOLEANS.include?(token.token) && !after_is?(index)
              placeholder([:boolean, token.token == :TRUE_P ? "true" : "false"])
            end
          end

          def subplan_number?(index)
            index.positive? && @tokens[index - 1].token == :IDENT && SUBPLANS.include?(@sources[index - 1])
          end

          # IS TRUE, IS NOT TRUE, and the like.
          def after_is?(index)
            before = @tokens[index - 1]&.token if index.positive?
            before == :IS || (before == :NOT && index > 1 && @tokens[index - 2].token == :IS)
          end

          def literal(token, index)
            value = Value.read(token.token, @sources[index])
            return placeholder(value) unless value&.first == :string && @cast.array?(index + 1)

            numbers = @matcher.candidates(value)
            numbers.empty? ? array(value.last) : use(numbers)
          end

          def placeholder(value) = use(value ? @matcher.candidates(value) : [])

          def use(numbers)
            @matches << numbers
            return "$#{numbers.first}" unless numbers.empty?

            @masked += 1
            MASK
          end

          def array(text)
            elements = PgArray.parse(text)
            "ARRAY[#{elements.map { |e| e.nil? ? "NULL" : placeholder([:string, e]) }.join(", ")}]"
          rescue ArgumentError
            placeholder(nil)
          end
        end

        # The types of an expression's casts.
        class Cast
          # The keywords a type's name can hold, such as character varying and
          # double precision. AT isn't one: it starts AT TIME ZONE.
          TYPE_WORDS = %i[UNRESERVED_KEYWORD COL_NAME_KEYWORD].freeze
          WITH = %i[WITH WITHOUT WITH_LA].freeze

          def initialize(tokens, sources)
            @tokens = tokens
            @sources = sources
            casts = tokens.each_index.select { |i| tokens[i].token == :TYPECAST }.map { |i| [i, read(i)] }
            @modifiers = casts.flat_map { |_i, (modifiers, _array)| modifiers }.to_set
            @arrays = casts.filter_map { |i, (_modifiers, array)| i if array }.to_set
          end

          # Whether the token at index is one of a cast's type modifiers.
          def modifier?(index) = @modifiers.include?(index)

          # Whether the token at index is a :: to an array type.
          def array?(index) = @arrays.include?(index)

          private

          # The type after the :: at index: the indexes of its modifiers, and
          # whether it ends in [].
          def read(index)
            i = index + 1
            modifiers = []
            array = false
            while (after = after_part(i))
              found = modifiers(i)
              modifiers.concat(found) if found
              array ||= @sources[i] == "["
              i = after
            end
            [modifiers, array]
          end

          # The index after the part of a type's name at index, or nil if
          # the type ended before it.
          def after_part(index)
            return index + 1 if word?(index)

            found = modifiers(index)
            found ? found.last + 2 : brackets(index)
          end

          def word?(index)
            token = @tokens[index]
            return false unless token
            return true if token.token == :IDENT || @sources[index] == "."
            return @tokens[index + 1]&.token == :TIME if WITH.include?(token.token)

            TYPE_WORDS.include?(token.keyword_kind) && token.token != :AT
          end

          # The indexes of the integers of "(12)" or "(10, 2)" right after a
          # type's name at index, or nil.
          def modifiers(index)
            return nil unless @sources[index] == "(" && after_word?(index)

            found = []
            i = index + 1
            while @tokens[i]&.token == :ICONST
              found << i
              return found if @sources[i + 1] == ")"
              break unless @sources[i + 1] == ","

              i += 2
            end
          end

          def after_word?(index) = index.positive? && word?(index - 1)

          # The index after "[]" or "[3]" at index, or nil.
          def brackets(index)
            return nil unless @sources[index] == "["

            closing = @tokens[index + 1]&.token == :ICONST ? index + 2 : index + 1
            closing + 1 if @sources[closing] == "]"
          end
        end

        # A literal token's value, read the way Postgres reads it.
        module Value
          module_function

          # [kind, text], or nil if pg_query won't read it alone.
          def read(token, source)
            case token
            when :ICONST, :FCONST then [:number, source]
            when :BCONST, :XCONST then constant(source)&.bsval&.then { [:bits, it.bsval] }
            else constant(source)&.sval&.then { [:string, it.sval] }
            end
          end

          def constant(source)
            stmts = PgQuery.parse("SELECT #{source}").tree.stmts
            select = stmts.first.stmt.select_stmt if stmts.size == 1
            target = select.target_list.first&.res_target if select
            target&.val&.a_const
          rescue PgQuery::ParseError
            nil
          end
        end

        private_constant :Scan, :Cast, :Value
      end

      private_constant :Expression
    end
  end
end
