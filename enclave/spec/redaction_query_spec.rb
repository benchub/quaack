# frozen_string_literal: true

require "json"
require "timeout"
require "pg_query"
require "quaack/enclave/redaction"

RSpec.describe Quaack::Enclave::Redaction, ".query" do
  def redact(sql) = described_class.query(PgQuery.parse(sql))

  def where(predicate) = "SELECT o.id FROM public.orders o WHERE #{predicate}"

  def shapes(sql) = redact(sql).placeholders.to_h { |p| ["$#{p.number}", p.shape] }

  it "numbers each constant in text order and keeps its value and type in the map" do
    result = redact(where("o.status = 'open' AND o.total_cents > 5 AND o.id < 1.5 AND o.flag = true"))
    expect(result.sql).to eq("SELECT o.id FROM public.orders o WHERE o.status = $1 AND o.total_cents > $2 " \
                             "AND o.id < $3 AND o.flag = $4")
    expect(result.placeholder_map).to eq(
      "$1" => { "value" => "open", "type" => "unknown" }, "$2" => { "value" => "5", "type" => "integer" },
      "$3" => { "value" => "1.5", "type" => "numeric" }, "$4" => { "value" => "true", "type" => "boolean" }
    )
  end

  it "numbers by where the constant sits in the text, not by where the tree keeps it" do
    result = redact("SELECT o.id FROM public.orders o WHERE o.id = 7 ORDER BY o.id LIMIT 3 OFFSET 2")
    expect(result.sql).to eq("SELECT o.id FROM public.orders o WHERE o.id = $1 ORDER BY o.id LIMIT $2 OFFSET $3")
    expect(result.placeholder_map.transform_values { it["value"] }).to eq("$1" => "7", "$2" => "3", "$3" => "2")
  end

  it "types a negative number, a big integer, and a big number the way Postgres types the literal" do
    map = redact(where("o.id = -5 AND o.id = 12345678901 AND o.id = 123456789012345678901234")).placeholder_map
    expect(map.values).to eq([{ "value" => "-5", "type" => "integer" },
                              { "value" => "12345678901", "type" => "bigint" },
                              { "value" => "123456789012345678901234", "type" => "numeric" }])
  end

  it "keeps a cast and its type modifiers, and redacts only the constant under it" do
    result = redact(where("o.created_at > DATE '2031-07-19' AND o.status::varchar(12) = 'x'::varchar(3)"))
    expect(result.sql).to eq("SELECT o.id FROM public.orders o WHERE o.created_at > $1::date " \
                             "AND o.status::varchar(12) = $2::varchar(3)")
    expect(result.placeholder_map.keys).to eq(%w[$1 $2])
  end

  it "keeps constants the parser made, EXTRACT's field, and positional ORDER BY, GROUP BY, and DISTINCT ON" do
    result = redact("SELECT DISTINCT ON (1) o.status, EXTRACT(epoch FROM o.created_at), count(*) " \
                    "FROM public.orders o WHERE o.id = 9 GROUP BY 1, 2 ORDER BY 1, 2 FETCH FIRST ROWS ONLY")
    # pg_query writes FETCH FIRST ROWS ONLY as LIMIT 1, and EXTRACT's field as a string.
    expect(result.sql).to eq("SELECT DISTINCT ON (1) o.status, extract ('epoch' FROM o.created_at), count(*) " \
                             "FROM public.orders o WHERE o.id = $1 GROUP BY 1, 2 ORDER BY 1, 2 LIMIT 1")
    expect(result.placeholder_map.keys).to eq(%w[$1])
  end

  # A quoted field keeps the case it was written in, which could carry
  # data, so it goes out lowercased, the way Postgres reads it.
  it "writes a kept EXTRACT field lowercased" do
    result = redact("SELECT EXTRACT('EpOcH' FROM o.created_at), EXTRACT('ISODOW' FROM o.created_at) " \
                    "FROM public.orders o")
    expect(result.sql).to eq("SELECT extract ('epoch' FROM o.created_at), extract ('isodow' FROM o.created_at) " \
                             "FROM public.orders o")
    expect(result.placeholder_map).to eq({})
  end

  # Unicode lowercases the Kelvin sign (U+212A) to k, but Postgres reads a
  # field in ASCII, so 'wee\u212A' isn't a field. It's a literal.
  it "redacts an EXTRACT field that's a field name only under Unicode lowercasing" do
    result = redact("SELECT EXTRACT('wee\u212A' FROM o.created_at) FROM public.orders o")
    expect(result.sql).to eq("SELECT extract ($1 FROM o.created_at) FROM public.orders o")
    expect(result.sql).not_to include("\u212A")
    expect(result.placeholder_map).to eq("$1" => { "value" => "wee\u212A", "type" => "unknown" })
  end

  it "keeps exactly the EXTRACT fields Postgres documents" do
    expect(described_class.const_get(:Query)::EXTRACT_FIELDS.sort).to eq(
      %w[century day decade dow doy epoch hour isodow isoyear julian microseconds millennium milliseconds
         minute month quarter second timezone timezone_hour timezone_minute week year]
    )
  end

  it "redacts a field name that isn't EXTRACT's: in date_part, AT TIME ZONE, or extract called as a function" do
    result = redact("SELECT date_part('year', o.created_at), o.created_at AT TIME ZONE 'epoch', " \
                    "pg_catalog.extract('year', o.created_at), position('year' IN o.status) FROM public.orders o")
    expect(result.placeholder_map.values.map { it["value"] }).to eq(%w[year epoch year year])
  end

  it "redacts the functions in FROM, LATERAL or not" do
    result = redact("SELECT g, u FROM generate_series(1, 5) g, unnest(ARRAY['a']) u, " \
                    "LATERAL generate_series(g, 7) h")
    expect(result.sql).to eq("SELECT g, u FROM generate_series($1, $2) g, unnest(ARRAY[$3]) u, " \
                             "LATERAL generate_series(g, $4) h")
  end

  it "refuses an interval with a field qualifier, which a placeholder can't bind the same way" do
    ["INTERVAL '1' DAY", "INTERVAL '2' YEAR", "INTERVAL '1 2' DAY TO HOUR"].each do |interval|
      expect { redact(where("o.created_at - o.created_at < #{interval}")) }
        .to raise_error(described_class::Error, "interval_field_qualifier")
    end
    expect(redact(where("o.a < INTERVAL '1 day' AND o.b < INTERVAL(3) '1.5 s'")).placeholder_map.size).to eq(2)
  end

  it "types an integer with millions of digits as numeric without reading it" do
    map = Timeout.timeout(3) { redact(where("o.id = #{"9" * 4_000_000}")).placeholder_map }
    expect(map["$1"]["type"]).to eq("numeric")
  end

  it "gives a big integer the integer class" do
    expect(shapes(where("o.a = 5000000000"))["$1"]["type"]).to eq("integer")
  end

  it "types integers written in hex, octal, binary, or with underscores" do
    map = redact(where("o.a = 0x1F AND o.b = 0o17 AND o.c = 0b101 AND o.d = 1_000 AND o.e = 0xFFFFFFFFFF"))
          .placeholder_map
    expect(map.values.map { it["type"] }).to eq(%w[integer integer integer integer bigint])
  end

  it "redacts a string in EXTRACT's place that isn't a field Postgres documents" do
    result = redact("SELECT extract('quaack-sentinel-field' FROM o.created_at) FROM public.orders o")
    expect(result.sql).not_to include("quaack-sentinel")
    expect(result.placeholder_map.values.map { it["value"] }).to eq(["quaack-sentinel-field"])
  end

  it "redacts a constant in an ORDER BY or GROUP BY expression, which isn't positional" do
    result = redact("SELECT o.status = 'a' FROM public.orders o GROUP BY o.status = 'b' ORDER BY o.status = 'c', " \
                    "count(*) + 1")
    expect(result.sql).to eq("SELECT o.status = $1 FROM public.orders o GROUP BY o.status = $2 " \
                             "ORDER BY o.status = $3, count(*) + $4")
  end

  it "redacts constants everywhere else: the select list, functions, CASE, subqueries, arrays, and NULL" do
    result = redact("SELECT 'a', coalesce(o.status, 'b'), CASE WHEN o.id > 1 THEN 'c' ELSE NULL END " \
                    "FROM public.orders o WHERE o.id IN (SELECT c.id FROM public.customers c WHERE c.name = 'd') " \
                    "AND o.id = ANY (ARRAY[2, 3]) AND o.status LIKE 'e%' ESCAPE '!'")
    expect(result.sql.gsub(/\$\d+/, "")).not_to match(/'|\d|NULL/)
    expect(result.placeholder_map.size).to eq(10)
    expect(result.placeholder_map["$5"]).to eq("value" => nil, "type" => "unknown")
  end

  describe "expressions Postgres requires to match" do
    it "gives a GROUP BY expression the same placeholders in the select list, HAVING, and ORDER BY" do
      result = redact("SELECT date_trunc('day', o.created_at), count(*) FROM public.orders o WHERE o.id > 1 " \
                      "GROUP BY date_trunc('day', o.created_at) " \
                      "HAVING date_trunc('day', o.created_at) > '2020-01-01' ORDER BY date_trunc('day', o.created_at)")
      expect(result.sql).to eq("SELECT date_trunc($1, o.created_at), count(*) FROM public.orders o WHERE o.id > $2 " \
                               "GROUP BY date_trunc($1, o.created_at) HAVING date_trunc($1, o.created_at) > $3 " \
                               "ORDER BY date_trunc($1, o.created_at)")
      expect(result.placeholder_map.values.map { it["value"] }).to eq(%w[day 1 2020-01-01])
    end

    it "shares inside a larger expression and a window, and not with a different literal or elsewhere" do
      result = redact("SELECT upper(o.status || '-x'), rank() OVER (ORDER BY o.status || '-x'), o.status || '-y' " \
                      "FROM public.orders o WHERE o.note = '-x' GROUP BY o.status || '-x', o.status || '-y'")
      expect(result.sql).to eq("SELECT upper(o.status || $1), rank() OVER (ORDER BY o.status || $1), " \
                               "o.status || $2 FROM public.orders o WHERE o.note = $3 " \
                               "GROUP BY o.status || $1, o.status || $2")
    end

    it "shares between DISTINCT ON, SELECT DISTINCT, or an aggregate's DISTINCT, and its ORDER BY" do
      expect(redact("SELECT DISTINCT ON (o.status || 'a') o.id FROM public.orders o " \
                    "ORDER BY o.status || 'a', o.id").sql)
        .to eq("SELECT DISTINCT ON (o.status || $1) o.id FROM public.orders o ORDER BY o.status || $1, o.id")
      expect(redact("SELECT DISTINCT o.status || 'a' FROM public.orders o ORDER BY o.status || 'a'").sql)
        .to eq("SELECT DISTINCT o.status || $1 FROM public.orders o ORDER BY o.status || $1")
      expect(redact("SELECT string_agg(DISTINCT o.status || 'a', ',' ORDER BY o.status || 'a') " \
                    "FROM public.orders o").sql)
        .to eq("SELECT string_agg(DISTINCT o.status || $1, $2 ORDER BY o.status || $1) FROM public.orders o")
    end

    it "doesn't share with a subquery, but does with the expression IN tests" do
      result = redact("SELECT o.status || 'a', (SELECT count(*) FROM public.orders o WHERE o.status || 'a' = 'z') " \
                      "FROM public.orders o GROUP BY o.status || 'a' " \
                      "HAVING o.status || 'a' IN (SELECT c.name FROM public.customers c)")
      expect(result.sql).to eq("SELECT o.status || $1, (SELECT count(*) FROM public.orders o " \
                               "WHERE (o.status || $2) = $3) FROM public.orders o GROUP BY o.status || $1 " \
                               "HAVING o.status || $1 IN (SELECT c.name FROM public.customers c)")
    end

    it "doesn't share a positional GROUP BY's constant with a constant after it" do
      expect(redact("SELECT o.status FROM public.orders o GROUP BY 1 HAVING 1 = 1").sql)
        .to eq("SELECT o.status FROM public.orders o GROUP BY 1 HAVING $1 = $2")
    end

    it "lists a shared placeholder once" do
      result = redact("SELECT o.status || 'a', count(*) FROM public.orders o GROUP BY o.status || 'a' " \
                      "HAVING o.id > 5 ORDER BY o.status || 'a'")
      expect(result.placeholders.map(&:number)).to eq([1, 2])
    end

    it "resolves a key by position or by alias to its select-list entry" do
      expect(redact("SELECT o.status || 'a' AS k FROM public.orders o GROUP BY k ORDER BY o.status || 'a'").sql)
        .to eq("SELECT o.status || $1 AS k FROM public.orders o GROUP BY k ORDER BY o.status || $1")
      expect(redact("SELECT o.id, o.status || 'a' FROM public.orders o GROUP BY 2, o.id " \
                    "HAVING o.status || 'a' <> ''").sql)
        .to eq("SELECT o.id, o.status || $1 FROM public.orders o GROUP BY 2, o.id HAVING (o.status || $1) <> $2")
      expect(redact("SELECT o.status || 'a' AS status FROM public.orders o GROUP BY o.status " \
                    "ORDER BY o.status || 'a'").sql)
        .to eq("SELECT o.status || $1 AS status FROM public.orders o GROUP BY o.status ORDER BY o.status || $2")
      expect(redact("SELECT o.status || 'a' FROM public.orders o GROUP BY 3 ORDER BY o.status || 'a'").sql)
        .to eq("SELECT o.status || $1 FROM public.orders o GROUP BY 3 ORDER BY o.status || $2")
    end

    it "keeps one placeholder per occurrence where Postgres doesn't require a match" do
      expect(redact("SELECT string_agg(o.status || 'a', ',' ORDER BY o.status || 'a') FROM public.orders o").sql)
        .to eq("SELECT string_agg(o.status || $1, $2 ORDER BY o.status || $3) FROM public.orders o")
      expect(redact("SELECT o.status || 'a' FROM public.orders o ORDER BY o.status || 'a'").sql)
        .to eq("SELECT o.status || $1 FROM public.orders o ORDER BY o.status || $2")
      expect(redact("SELECT o.status || 'a' FROM public.orders o WHERE o.status || 'a' <> '' GROUP BY o.status").sql)
        .to eq("SELECT o.status || $1 FROM public.orders o WHERE (o.status || $2) <> $3 GROUP BY o.status")
    end
  end

  describe "shapes" do
    it "gives each placeholder its type class, from the constant or from its cast" do
      sql = where("o.a = 'x' AND o.b = 1 AND o.c = 1.5 AND o.d = false AND o.e = '2031-07-19'::date " \
                  "AND o.f = '1'::bigint AND o.g = 1::text AND o.h = '1'::double precision AND o.i = B'101' " \
                  "AND o.j = '{}'::jsonb AND o.k = NULL AND o.l = INTERVAL '1 day'")
      expect(shapes(sql).values.map { it["type"] })
        .to eq(%w[text integer numeric boolean datetime integer text numeric other other other datetime])
    end

    it "says where a LIKE or ILIKE pattern has its wildcards" do
      sql = where("o.a LIKE 'x%' AND o.b NOT ILIKE '%x' AND o.c LIKE '%x%' AND o.d LIKE 'x' " \
                  "AND o.e LIKE 'x\\%' AND o.f LIKE '_x' AND o.g ~~ 'x_' AND o.h LIKE 'x!%' ESCAPE '!'")
      expect(shapes(sql).values.map { it["pattern"] }.compact)
        .to eq([%w[trailing], %w[leading], %w[leading trailing], [], [], %w[leading], %w[trailing], []])
    end

    it "reads an ESCAPE character under a cast" do
      expect(shapes(where("o.a LIKE 'a!%' ESCAPE '!'::text"))["$1"]["pattern"]).to eq([])
    end

    it "says when a pattern has a wildcard in the middle, and reads an empty pattern" do
      sql = where("o.a LIKE 'a%b' AND o.b LIKE 'a_b%c' AND o.c LIKE '%a%b%' AND o.d LIKE '' AND o.e LIKE '%'")
      expect(shapes(sql).values.map { it["pattern"] })
        .to eq([%w[inner], %w[inner], %w[leading inner trailing], [], %w[leading trailing]])
    end

    it "says where each pattern of LIKE ANY has its wildcards, and a pattern under a cast" do
      sql = where("o.a LIKE ANY (ARRAY['x%', '%y']) AND o.b LIKE 'z%'::text")
      expect(shapes(sql).values.map { it["pattern"] }).to eq([%w[trailing], %w[leading], %w[trailing]])
    end

    it "gives no pattern to a constant that isn't a LIKE pattern" do
      expect(shapes(where("o.a = 'x%'"))["$1"]).not_to have_key("pattern")
    end

    it "counts the elements of an IN list, an ARRAY, and an array literal" do
      sql = where("o.a IN (1, 2, 3) AND o.b = ANY (ARRAY['x', 'y']) AND o.c = ANY ('{4,5,6,7}'::int[]) " \
                  "AND o.d = ANY ('{8}')")
      expect(shapes(sql).values.map { it["elements"] }).to eq([3, 3, 3, 2, 2, 4, 1])
    end

    it "counts an array literal's elements wherever it's cast to an array, and not a string that isn't one" do
      shapes = shapes(where("o.tags @> '{a,b,c}'::text[] AND o.note = '{a,b}'"))
      expect(shapes.values.map { it["elements"] }).to eq([3, nil])
    end

    it "holds no literal, only its class" do
      sql = where("o.status LIKE 'quaack-sentinel-like%' AND o.id IN (918273645, 918273646) " \
                  "AND o.note = 'quaack-sentinel-note'::text")
      result = redact(sql)
      json = JSON.generate(result.placeholder_shapes)
      %w[quaack-sentinel-like quaack-sentinel-note 918273645 918273646].each do |sentinel|
        expect(result.sql).not_to include(sentinel)
        expect(json).not_to include(sentinel)
        expect(JSON.generate(result.placeholder_map)).to include(sentinel)
      end
    end
  end

  describe "a keyset row comparison" do
    let(:sql) do
      "SELECT o.id, o.created_at FROM public.orders o " \
        "WHERE o.status = 'quaack-sentinel-status' AND (o.created_at, o.id) < ('2031-07-19 10:00:00+00', 918273645) " \
        "ORDER BY o.created_at DESC, o.id DESC LIMIT 25"
    end

    it "gives each literal in the tuple its own placeholder, in text order" do
      result = redact(sql)
      expect(result.sql).to eq("SELECT o.id, o.created_at FROM public.orders o " \
                               "WHERE o.status = $1 AND (o.created_at, o.id) < ($2, $3) " \
                               "ORDER BY o.created_at DESC, o.id DESC LIMIT $4")
      expect(result.placeholder_map.transform_values { it["value"] })
        .to eq("$1" => "quaack-sentinel-status", "$2" => "2031-07-19 10:00:00+00", "$3" => "918273645", "$4" => "25")
    end

    it "keeps the tuple's literals out of the SQL and the shapes" do
      result = redact(sql)
      json = JSON.generate(result.placeholder_shapes)
      %w[quaack-sentinel-status 2031-07-19 918273645].each do |sentinel|
        expect(result.sql).not_to include(sentinel)
        expect(json).not_to include(sentinel)
        expect(JSON.generate(result.placeholder_map)).to include(sentinel)
      end
    end
  end

  describe "refusals" do
    # Every SQL-only deparse bug Deparse's specs keep refusing either hangs
    # on a constant, which redaction replaces, or is outside SupportedSql.
    # So this uses a tree changed after parsing, as RelationQualifier's is:
    # the parser cuts a name to 63 bytes, so it comes back as another tree.
    it "refuses a query pg_query would deparse as a different query" do
      parse = PgQuery.parse("SELECT o.id FROM public.orders o WHERE o.id = 5")
      parse.tree.stmts[0].stmt.select_stmt.from_clause[0].range_var.relname = "t" * 64
      expect { described_class.query(parse) }
        .to raise_error(Quaack::Enclave::Deparse::Error) { |e| expect([e.rule, e.cause]).to eq(["deparse_mismatch", nil]) }
    end

    it "refuses a query that already has $n parameters" do
      expect { redact(where("o.id = $1 AND o.status = 'x'")) }
        .to raise_error(described_class::Error, "query_has_parameters")
    end

    it "refuses SQL outside SupportedSql" do
      expect { redact("SELECT o.id FROM public.orders o TABLESAMPLE SYSTEM (10)") }
        .to raise_error(Quaack::Enclave::SupportedSql::Error)
    end
  end

  it "keeps the literals out of inspect" do
    result = redact(where("o.status = 'quaack-sentinel-inspect'"))
    expect([result.inspect, result.to_s, result.placeholders.inspect].join).not_to include("quaack-sentinel")
  end
end
