# frozen_string_literal: true

require "json"
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
    expect(map.values).to eq([{ "value" => "-5", "type" => "integer" }, { "value" => "12345678901", "type" => "bigint" },
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
        .to eq(%w[trailing_wildcard leading_wildcard both_wildcards no_wildcard no_wildcard leading_wildcard
                  trailing_wildcard no_wildcard])
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

  describe "refusals" do
    it "refuses a query pg_query would deparse as a different query" do
      expect { redact("SELECT (ARRAY(SELECT o.id FROM public.orders o))[1]") }
        .to raise_error(Quaack::Enclave::Deparse::Error, /deparse_mismatch/)
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
