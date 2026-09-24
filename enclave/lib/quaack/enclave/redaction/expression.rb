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
        Redacted = Data.define(:text, :masked, :matches)

        LITERALS = %i[SCONST USCONST ICONST FCONST BCONST XCONST].freeze
        BOOLEANS = %i[TRUE_P FALSE_P].freeze
        SUBPLANS = %w[InitPlan SubPlan].freeze
        # The keywords a type's name can hold, such as character varying and
        # double precision. AT isn't one: it starts AT TIME ZONE.
        TYPE_WORDS = %i[UNRESERVED_KEYWORD COL_NAME_KEYWORD].freeze
        MASK = "$?"

        module_function

        # matches has, for each literal replaced, the numbers of the
        # placeholders it matched (see Matcher#candidates), empty for a
        # mask.
        def redact(text, matcher)
          return nil unless text.is_a?(String) && text.valid_encoding? && !text.include?("\0")

          tokens = PgQuery.scan(text).first.tokens.to_a
          Scan.new(text, tokens, matcher).redacted
        rescue PgQuery::ScanError
          nil
        end

        # One scanned expression.
        class Scan
          def initialize(text, tokens, matcher)
            @text = text
            @tokens = tokens
            @matcher = matcher
            @masked = 0
            @matches = []
            @skipped = typmods
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
            Redacted.new(text: out.force_encoding(Encoding::UTF_8), masked: @masked, matches: @matches.freeze)
          end

          private

          # What a token becomes, or nil if it stays.
          def replacement(token, index)
            if LITERALS.include?(token.token)
              literal(token, index) unless @skipped.include?(index) || subplan_number?(index)
            elsif BOOLEANS.include?(token.token) && !after_is?(index)
              placeholder([:boolean, token.token == :TRUE_P ? "true" : "false"])
            end
          end

          def source(token) = @text.byteslice(token.start...token.end)

          def subplan_number?(index)
            index.positive? && @tokens[index - 1].token == :IDENT && SUBPLANS.include?(source(@tokens[index - 1]))
          end

          # IS TRUE, IS NOT TRUE, and the like.
          def after_is?(index)
            before = @tokens[index - 1]&.token if index.positive?
            before == :IS || (before == :NOT && index > 1 && @tokens[index - 2].token == :IS)
          end

          def literal(token, index)
            value = Value.read(token.token, source(token))
            return placeholder(nil) unless value
            return placeholder(value) unless value.first == :string && array_cast?(index)

            numbers = @matcher.candidates(value)
            return use(numbers) unless numbers.empty?

            array(value.last)
          end

          def placeholder(value)
            use(value ? @matcher.candidates(value) : [])
          end

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

          # Whether the token at index is followed by a cast to an array type.
          def array_cast?(index)
            return false unless @tokens[index + 1]&.token == :TYPECAST

            cast = cast_after(index + 1)
            cast[:array]
          end

          # The indexes of every cast's type modifiers.
          def typmods
            @tokens.each_index.select { |i| @tokens[i].token == :TYPECAST }.flat_map { |i| cast_after(i)[:typmods] }
          end

          # Reads the type after the :: at index: its words, any type
          # modifiers, and any [].
          def cast_after(index)
            i = index + 1
            typmods = []
            array = false
            loop do
              if type_word?(i) then i += 1
              elsif (modifiers = modifiers(i)) then typmods.concat(modifiers)
                                                   i = modifiers.last + 2
              elsif bracket?(i) then array = true
                                     i = @tokens[i + 1].token == :ICONST ? i + 3 : i + 2
              else break
              end
            end
            { typmods:, array: }
          end

          def type_word?(index)
            token = @tokens[index]
            return false unless token

            token.token == :IDENT || token.token == :ASCII_46 ||
              (TYPE_WORDS.include?(token.keyword_kind) && token.token != :AT) ||
              (%i[WITH WITHOUT WITH_LA].include?(token.token) && @tokens[index + 1]&.token == :TIME)
          end

          # The integers of "(12)" or "(10, 2)" at index, or nil.
          def modifiers(index)
            return nil unless @tokens[index]&.token == :ASCII_40 && index.positive? && type_word?(index - 1)

            found = []
            i = index + 1
            loop do
              return nil unless @tokens[i]&.token == :ICONST

              found << i
              i += 1
              return found if @tokens[i]&.token == :ASCII_41
              return nil unless @tokens[i]&.token == :ASCII_44

              i += 1
            end
          end

          def bracket?(index)
            return false unless @tokens[index]&.token == :ASCII_91

            closing = @tokens[index + 1]&.token == :ICONST ? index + 2 : index + 1
            @tokens[closing]&.token == :ASCII_93
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
            target = stmts.first.stmt.select_stmt&.target_list&.first if stmts.size == 1
            target&.res_target&.val&.a_const
          rescue PgQuery::ParseError
            nil
          end
        end

        private_constant :Scan, :Value
      end

      private_constant :Expression
    end
  end
end
