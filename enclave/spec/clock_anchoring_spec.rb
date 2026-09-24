# frozen_string_literal: true

require "quaack/enclave/clock_anchoring"

# What 3h rewrites, read from the parse alone. clock_anchoring_postgres_spec.rb
# checks on real Postgres that each rewrite keeps the type and the value.
RSpec.describe Quaack::Enclave::ClockAnchoring do
  def anchor(sql, settings = nil) = described_class.anchor(sql, settings)

  def deparse(sql) = PgQuery.parse(sql).deparse

  def path(search_path) = { "search_path" => search_path }

  def restore(sql, result) = described_class.restore(sql, result.replacements, result.added_names)

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
        result = anchor("SELECT #{original} AS x FROM public.orders")
        expect(result.sql).to eq(deparse("SELECT #{anchored} AS x FROM public.orders"))
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
      expect(result.sql).to eq(deparse("SELECT quaack.clock_anchor()::date AS now, " \
                                       "quaack.clock_anchor()::pg_catalog.date::date AS current_date, " \
                                       "quaack.clock_anchor()::pg_catalog.date AS current_timestamp"))
    end
  end

  # Postgres names an output column that has no AS after the function it
  # calls, looking through casts, CASE's ELSE, COLLATE, and a scalar
  # subquery's column. A later reference to that name, by an outer query
  # or by ORDER BY or GROUP BY, must still find it, so anchor names the
  # column what Postgres named the original.
  describe "the names Postgres gives the anchored columns" do
    {
      "now()" => "now", "pg_catalog.now()" => "now", "transaction_timestamp()" => "transaction_timestamp",
      "statement_timestamp()" => "statement_timestamp", "CURRENT_TIMESTAMP" => "current_timestamp",
      "current_timestamp(2)" => "current_timestamp", "CURRENT_DATE" => "current_date",
      "LOCALTIMESTAMP" => "localtimestamp", "localtimestamp(1)" => "localtimestamp", "LOCALTIME" => "localtime",
      "localtime(3)" => "localtime", "now()::date" => "now", "CURRENT_DATE::text" => "current_date",
      "now() COLLATE \"C\"" => "now", "CASE WHEN true THEN 1 ELSE now() END" => "now",
      "(SELECT now())" => nil
    }.each do |expression, name|
      it "keeps the name #{name.inspect} for #{expression}" do
        result = anchor("SELECT #{expression} FROM public.orders")
        target = result.parse.tree.stmts.first.stmt.select_stmt.target_list.first.res_target
        expect(target.name).to eq(name.to_s)
      end
    end

    it "names a scalar subquery's own column, which is where the outer name comes from" do
      result = anchor("SELECT (SELECT now())")
      expect(result.sql).to eq(deparse("SELECT (SELECT quaack.clock_anchor() AS now)"))
    end

    it "leaves a name that doesn't come from a replaced function" do
      sql = "SELECT now() + interval '1 day', now() AS t, date_trunc('day', now()), " \
            "CASE WHEN now() > created_at THEN 1 END, CURRENT_DATE - 1, now() IS NULL FROM public.orders"
      result = anchor(sql)
      expect(result.parse.tree.stmts.first.stmt.select_stmt.target_list.map { |t| t.res_target.name })
        .to eq(["", "t", "", "", "", ""])
      expect(result.added_names).to eq([])
    end

    it "names every column the query's subqueries, CTEs, and set operations have" do
      sql = "WITH w AS (SELECT now()) SELECT s.now, w.now FROM (SELECT CURRENT_DATE UNION SELECT CURRENT_DATE) " \
            "s(now), w"
      expected = "WITH w AS (SELECT quaack.clock_anchor() AS now) SELECT s.now, w.now FROM " \
                 "(SELECT quaack.clock_anchor()::pg_catalog.date AS current_date UNION " \
                 "SELECT quaack.clock_anchor()::pg_catalog.date AS current_date) s(now), w"
      expect(anchor(sql).sql).to eq(deparse(expected))
    end

    it "names a function in FROM that has no alias after the function" do
      sql = "SELECT now.now FROM now(), pg_catalog.statement_timestamp() WITH ORDINALITY, now() AS t"
      expected = "SELECT now.now FROM quaack.clock_anchor() AS now, " \
                 "quaack.clock_anchor() WITH ORDINALITY AS statement_timestamp, quaack.clock_anchor() AS t"
      expect(anchor(sql).sql).to eq(deparse(expected))
    end

    it "records each name it added, by its place among the columns and FROM functions" do
      result = anchor("SELECT 1, now(), now() AS t FROM now(), (SELECT CURRENT_DATE) s")
      expect(result.added_names).to eq(
        [
          described_class::AddedName.new(slot: 1, name: "now"),
          described_class::AddedName.new(slot: 3, name: "now"),
          described_class::AddedName.new(slot: 4, name: "current_date")
        ]
      )
    end

    it "restores the query without the names it added" do
      [
        "SELECT now(), CURRENT_DATE, LOCALTIMESTAMP ORDER BY now",
        "SELECT s.now FROM (SELECT now()) s",
        "SELECT now.now FROM now(), now() WITH ORDINALITY AS t",
        "SELECT (SELECT now()), now() AS now GROUP BY now"
      ].each do |sql|
        result = anchor(sql)
        expect(restore(result.sql, result)).to eq(deparse(sql))
      end
    end

    it "refuses to restore when a name it added isn't there" do
      result = anchor("SELECT now()")
      expect { restore("SELECT quaack.clock_anchor() AS t", result) }
        .to raise_error(described_class::Error, "restore_mismatch: the SQL's names don't match the ones anchor added")
      far = result.with(added_names: [described_class::AddedName.new(slot: 5, name: "now")])
      expect { restore("SELECT quaack.clock_anchor() AS now", far) }
        .to raise_error(described_class::Error, "restore_mismatch: the SQL's names don't match the ones anchor added")
      from = anchor("SELECT 1 FROM now()")
      expect { restore("SELECT 1 FROM quaack.clock_anchor() AS now(x)", from) }
        .to raise_error(described_class::Error, "restore_mismatch: the SQL's names don't match the ones anchor added")
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
      values = (result.replacements + result.added_names).flat_map { |record| record.to_h.values }
      expect(values.length).to eq(8)
      expect(values.grep(String).length).to eq(6)
      expect(values.grep(Integer).length).to eq(2)
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
            "mydb.pg_catalog.now(), pg_catalog.x.now(), public.localtime()"
      result = anchor(sql)
      expect(result.sql).to eq(deparse(sql))
      expect(result.replacements).to eq([])
    end

    # Postgres refuses these for now(), which isn't an aggregate or window
    # function, but the parse has them, so they aren't anchor's to change.
    # A DISTINCT or VARIADIC call has arguments, so now(1) covers those.
    ["now() OVER ()", "now() FILTER (WHERE true)", "now(*)", "now() WITHIN GROUP (ORDER BY 1)"].each do |call|
      it "leaves #{call}, which isn't a plain call" do
        sql = "SELECT #{call} FROM public.orders"
        result = anchor(sql)
        expect(result.sql).to eq(deparse(sql))
        expect(result.replacements).to eq([])
      end
    end

    it "leaves a clock_anchor() in any schema but quaack, and doesn't refuse it" do
      sql = "SELECT public.clock_anchor(), now()"
      result = anchor(sql)
      expect(result.sql).to eq(deparse("SELECT public.clock_anchor(), quaack.clock_anchor() AS now"))
      expect(restore(result.sql, result)).to eq(deparse(sql))
    end
  end

  describe "the search path" do
    let(:sql) { "SELECT now() FROM public.orders" }

    it "replaces an unqualified call when pg_catalog comes first, as it does when the path doesn't list it" do
      [nil, {}, path('"$user", public'), path("pg_catalog, public"), path("public")].each do |settings|
        expect(anchor(sql, settings).sql).to eq(deparse("SELECT quaack.clock_anchor() AS now FROM public.orders"))
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
        expect(restore(result.sql, result)).to eq(deparse(sql))
      end
    end

    it "works on SQL that changed elsewhere since, such as literals turned into placeholders" do
      result = anchor("SELECT id FROM public.orders WHERE status = 'open' AND created_at > CURRENT_DATE - 7")
      changed = result.sql.sub("'open'", "$1").sub("7", "$2")
      expect(restore(changed, result))
        .to eq(deparse("SELECT id FROM public.orders WHERE status = $1 AND created_at > CURRENT_DATE - $2"))
    end

    it "refuses when the SQL has fewer anchors than the record" do
      result = anchor("SELECT now(), CURRENT_DATE")
      expect { restore("SELECT quaack.clock_anchor()", result) }
        .to raise_error(described_class::Error,
                        "restore_mismatch: the SQL has fewer clock anchors than the replacements")
    end

    it "refuses when the SQL has more anchors than the record" do
      result = anchor("SELECT now()")
      expect { restore("SELECT quaack.clock_anchor(), quaack.clock_anchor()", result) }
        .to anchor_error("restore_mismatch")
    end

    it "refuses when an anchor doesn't match the one the record has in its place" do
      result = anchor("SELECT CURRENT_DATE")
      ["SELECT quaack.clock_anchor()", "SELECT quaack.clock_anchor()::pg_catalog.timestamp"].each do |sql|
        expect { restore(sql, result) }
          .to raise_error(described_class::Error,
                          "restore_mismatch: the SQL's clock anchors don't match the replacements")
      end
    end

    it "refuses SQL the deparser would change once the originals are back" do
      now = described_class::Replacement.new(original: "now()", anchored: "quaack.clock_anchor()")
      sql = "SELECT (quaack.clock_anchor() IS NOT DISTINCT FROM quaack.clock_anchor()) IS TRUE"
      expect { described_class.restore(sql, [now, now], []) }
        .to raise_error(Quaack::Enclave::Deparse::Error) { |error| expect(error.rule).to eq("deparse_mismatch") }
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

    it "refuses an anchored query the deparser would change" do
      expect { anchor("SELECT (now() IS NOT DISTINCT FROM now()) IS TRUE") }
        .to raise_error(Quaack::Enclave::Deparse::Error) { |error| expect(error.rule).to eq("deparse_mismatch") }
    end

    it "refuses a search_path it can't read" do
      expect { anchor("SELECT now()", path('public, "x')) }.to anchor_error("bad_search_path")
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
        error_of { described_class.restore("SELECT quaack.clock_anchor() WHERE x = '#{sentinel}'", [], []) },
        error_of { described_class.restore("SELECT '#{sentinel}' WHERE (", [], []) }
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
