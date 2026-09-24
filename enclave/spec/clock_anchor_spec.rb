# frozen_string_literal: true

require "quaack/enclave/clock_anchor"

# What 3h rewrites, read from the parse alone. clock_anchor_postgres_spec.rb
# checks on real Postgres that each rewrite keeps the type and the value.
RSpec.describe Quaack::Enclave::ClockAnchor do
  def anchor(sql, settings = nil) = described_class.anchor(sql, settings)

  def deparse(sql) = PgQuery.parse(sql).deparse

  def path(search_path) = { "search_path" => search_path }

  def anchor_error(rule)
    raise_error(described_class::Error, /\A#{rule}: /) { |error| expect(error.rule).to eq(rule) }
  end

  describe "each function it replaces" do
    {
      "now()" => "quaack.clock_anchor()",
      "pg_catalog.now()" => "quaack.clock_anchor()",
      '"pg_catalog"."now"()' => "quaack.clock_anchor()",
      "transaction_timestamp()" => "quaack.clock_anchor()",
      "pg_catalog.transaction_timestamp()" => "quaack.clock_anchor()",
      "statement_timestamp()" => "quaack.clock_anchor()",
      "pg_catalog.statement_timestamp()" => "quaack.clock_anchor()",
      "CURRENT_TIMESTAMP" => "quaack.clock_anchor()",
      "current_timestamp(3)" => "quaack.clock_anchor()::pg_catalog.timestamptz(3)",
      "CURRENT_TIMESTAMP(0)" => "quaack.clock_anchor()::pg_catalog.timestamptz(0)",
      "CURRENT_DATE" => "quaack.clock_anchor()::pg_catalog.date",
      "LOCALTIMESTAMP" => "quaack.clock_anchor()::pg_catalog.timestamp",
      "localtimestamp(2)" => "quaack.clock_anchor()::pg_catalog.timestamp(2)",
      "LOCALTIME" => "quaack.clock_anchor()::pg_catalog.time",
      "localtime(4)" => "quaack.clock_anchor()::pg_catalog.time(4)"
    }.each do |original, anchored|
      it "turns #{original} into #{anchored}" do
        result = anchor("SELECT #{original} FROM public.orders")
        expect(result.sql).to eq(deparse("SELECT #{anchored} FROM public.orders"))
        expect(result.parse.query).to eq(result.sql)
        expect(result.replacements.map(&:anchored)).to eq([deparse("SELECT #{anchored}").delete_prefix("SELECT ")])
      end
    end
  end

  describe "where the functions sit" do
    it "replaces them in every clause, subquery, CTE, and function argument" do
      sql = <<~SQL
        WITH recent AS (SELECT id FROM public.orders WHERE created_at > now() - interval '1 day')
        SELECT date_trunc('day', CURRENT_TIMESTAMP), coalesce(o.created_at, statement_timestamp()),
               CASE WHEN o.created_at < LOCALTIMESTAMP THEN CURRENT_DATE + 1 END,
               (SELECT max(created_at) FROM public.orders WHERE created_at <= transaction_timestamp()),
               count(*) FILTER (WHERE o.created_at::date = CURRENT_DATE) OVER (ORDER BY pg_catalog.now())
        FROM public.orders o
        JOIN public.customers c ON c.created_at < LOCALTIME + o.created_at::date
        JOIN LATERAL (SELECT now() AS t) l ON true
        WHERE o.id IN (SELECT id FROM recent) AND EXISTS (SELECT 1 WHERE localtime(1) IS NOT NULL)
        GROUP BY o.created_at
        HAVING max(o.created_at) < current_timestamp(2)
        ORDER BY o.created_at - now()
      SQL
      expected = <<~SQL
        WITH recent AS (SELECT id FROM public.orders WHERE created_at > quaack.clock_anchor() - interval '1 day')
        SELECT date_trunc('day', quaack.clock_anchor()), coalesce(o.created_at, quaack.clock_anchor()),
               CASE WHEN o.created_at < quaack.clock_anchor()::pg_catalog.timestamp
                    THEN quaack.clock_anchor()::pg_catalog.date + 1 END,
               (SELECT max(created_at) FROM public.orders WHERE created_at <= quaack.clock_anchor()),
               count(*) FILTER (WHERE o.created_at::date = quaack.clock_anchor()::pg_catalog.date)
                 OVER (ORDER BY quaack.clock_anchor())
        FROM public.orders o
        JOIN public.customers c ON c.created_at < quaack.clock_anchor()::pg_catalog.time + o.created_at::date
        JOIN LATERAL (SELECT quaack.clock_anchor() AS t) l ON true
        WHERE o.id IN (SELECT id FROM recent)
          AND EXISTS (SELECT 1 WHERE quaack.clock_anchor()::pg_catalog.time(1) IS NOT NULL)
        GROUP BY o.created_at
        HAVING max(o.created_at) < quaack.clock_anchor()::pg_catalog.timestamptz(2)
        ORDER BY o.created_at - quaack.clock_anchor()
      SQL
      result = anchor(sql)
      expect(result.sql).to eq(deparse(expected))
      expect(result.replacements.length).to eq(13)
    end

    it "keeps a cast the query already had around a replaced function" do
      result = anchor("SELECT now()::date, CURRENT_DATE::date, CURRENT_TIMESTAMP::pg_catalog.date")
      expect(result.sql).to eq(deparse("SELECT quaack.clock_anchor()::date, " \
                                       "quaack.clock_anchor()::pg_catalog.date::date, " \
                                       "quaack.clock_anchor()::pg_catalog.date"))
    end
  end

  describe "the record of what it replaced" do
    it "lists each replacement in the order the query has them, with its original spelling" do
      result = anchor("SELECT pg_catalog.now(), CURRENT_DATE FROM public.orders WHERE created_at < localtime(3)")
      expect(result.replacements).to eq(
        [
          described_class::Replacement.new(original: "pg_catalog.now()", anchored: "quaack.clock_anchor()"),
          described_class::Replacement.new(original: "current_date",
                                           anchored: "quaack.clock_anchor()::pg_catalog.date"),
          described_class::Replacement.new(original: "localtime(3)",
                                           anchored: "quaack.clock_anchor()::time(3)")
        ]
      )
    end

    it "is plain strings, so it can travel as shape" do
      result = anchor("SELECT now(), current_timestamp(1)")
      expect(result.replacements.flat_map(&:to_h).flat_map(&:values)).to all(be_a(String))
    end
  end

  describe "what it leaves alone" do
    it "returns a query with no clock functions unchanged" do
      sql = "SELECT o.id, lower(c.email), date_trunc('day', o.created_at) FROM public.orders o " \
            "JOIN public.customers c ON c.id = o.customer_id WHERE o.status = 'open'"
      result = anchor(sql)
      expect(result.sql).to eq(deparse(sql))
      expect(result.replacements).to eq([])
    end

    it "leaves every other time function and SQL-value function" do
      sql = "SELECT CURRENT_TIME, current_time(2), clock_timestamp(), timeofday(), CURRENT_USER, " \
            "CURRENT_SCHEMA, to_timestamp(0), age(created_at), date_part('year', created_at) FROM public.orders"
      result = anchor(sql)
      expect(result.sql).to eq(deparse(sql))
      expect(result.replacements).to eq([])
    end

    it "leaves a function of the same name in another schema, or one with arguments" do
      sql = 'SELECT public.now(), a.statement_timestamp(), "NOW"(), now(1), pg_catalog.now(1), ' \
            "mydb.pg_catalog.now(), public.localtime()"
      result = anchor(sql)
      expect(result.sql).to eq(deparse(sql))
      expect(result.replacements).to eq([])
    end
  end

  describe "the search path" do
    let(:sql) { "SELECT now() FROM public.orders" }

    it "replaces an unqualified call when pg_catalog comes first, as it does when the path doesn't list it" do
      [nil, {}, path('"$user", public'), path("pg_catalog, public"), path("public")].each do |settings|
        expect(anchor(sql, settings).sql).to eq(deparse("SELECT quaack.clock_anchor() FROM public.orders"))
      end
    end

    it "refuses an unqualified call when the path puts another schema before pg_catalog" do
      expect { anchor(sql, path("public, pg_catalog")) }.to anchor_error("clock_function_search_path")
      expect { anchor("SELECT statement_timestamp()", path('"$user", pg_catalog')) }
        .to anchor_error("clock_function_search_path")
    end

    it "doesn't mind that path for a qualified call or an SQL-value function, which it can't change" do
      result = anchor("SELECT pg_catalog.now(), CURRENT_TIMESTAMP, CURRENT_DATE", path("public, pg_catalog"))
      expect(result.replacements.length).to eq(3)
    end
  end

  describe "restore" do
    [
      "SELECT now(), pg_catalog.now(), transaction_timestamp(), statement_timestamp() FROM public.orders",
      "SELECT CURRENT_TIMESTAMP, current_timestamp(3), CURRENT_DATE + 1, LOCALTIMESTAMP, localtimestamp(2), " \
      "LOCALTIME, localtime(5)",
      "SELECT now()::date, CURRENT_DATE::date, CURRENT_TIMESTAMP::pg_catalog.date, " \
      "CURRENT_TIMESTAMP::pg_catalog.timestamptz(3), localtimestamp(2)::pg_catalog.timestamp(2)",
      "WITH w AS (SELECT now() AS t) SELECT t FROM w WHERE t > (SELECT CURRENT_DATE - 1) ORDER BY LOCALTIME",
      "SELECT id FROM public.orders WHERE status = 'open'"
    ].each do |sql|
      it "puts the original functions back in #{sql[0, 50]}..." do
        result = anchor(sql)
        expect(described_class.restore(result.sql, result.replacements)).to eq(deparse(sql))
      end
    end

    it "works on SQL that changed elsewhere since, such as literals turned into placeholders" do
      result = anchor("SELECT id FROM public.orders WHERE status = 'open' AND created_at > CURRENT_DATE - 7")
      changed = result.sql.sub("'open'", "$1").sub("7", "$2")
      expect(described_class.restore(changed, result.replacements))
        .to eq(deparse("SELECT id FROM public.orders WHERE status = $1 AND created_at > CURRENT_DATE - $2"))
    end

    it "refuses when the SQL has fewer anchors than the record" do
      result = anchor("SELECT now(), CURRENT_DATE")
      expect { described_class.restore("SELECT quaack.clock_anchor()", result.replacements) }
        .to anchor_error("restore_mismatch")
    end

    it "refuses when the SQL has more anchors than the record" do
      result = anchor("SELECT now()")
      expect { described_class.restore("SELECT quaack.clock_anchor(), quaack.clock_anchor()", result.replacements) }
        .to anchor_error("restore_mismatch")
    end

    it "refuses when an anchor doesn't match the one the record has in its place" do
      result = anchor("SELECT CURRENT_DATE")
      expect { described_class.restore("SELECT quaack.clock_anchor()", result.replacements) }
        .to anchor_error("restore_mismatch")
    end
  end

  describe "refusals" do
    it "refuses a query that already calls quaack.clock_anchor(), since restore couldn't tell it apart" do
      expect { anchor("SELECT quaack.clock_anchor()") }.to anchor_error("clock_anchor_in_query")
    end

    it "refuses SQL that SupportedSql doesn't list" do
      expect { anchor("DELETE FROM public.orders WHERE created_at < now()") }
        .to raise_error(Quaack::Enclave::SupportedSql::Error)
    end

    it "refuses SQL that doesn't parse" do
      expect { anchor("SELECT now( FROM") }.to anchor_error("parse_error")
    end
  end

  # A literal in the query is value-class, so no error may quote it.
  describe "error messages" do
    let(:sentinel) { "SENTINEL_7f3a9c" }

    def error_of
      yield
      raise "expected an error"
    rescue described_class::Error => e
      e
    end

    it "never quote a literal from the query, and carry no cause that might" do
      errors = [
        error_of { anchor("SELECT now() WHERE '#{sentinel}' = ('#{sentinel}'") },
        error_of { anchor("SELECT now() WHERE x = '#{sentinel}'", path("public, pg_catalog")) },
        error_of { anchor("SELECT quaack.clock_anchor() WHERE x = '#{sentinel}'") },
        error_of { described_class.restore("SELECT quaack.clock_anchor() WHERE x = '#{sentinel}'", []) },
        error_of { described_class.restore("SELECT '#{sentinel}' WHERE (", []) }
      ]
      expect(errors.map(&:rule)).to eq(%w[parse_error clock_function_search_path clock_anchor_in_query
                                          restore_mismatch parse_error])
      expect(errors.map(&:cause)).to all(be_nil)
      expect(errors.map(&:message).join).not_to include(sentinel)
    end

    it "the check sees a sentinel when one is planted" do
      planted = error_of { raise described_class::Error.new("parse_error", sentinel) }
      expect(planted.message).to include(sentinel)
    end
  end
end
