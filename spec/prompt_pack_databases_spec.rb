# frozen_string_literal: true

require_relative "spec_helper"

# Task 20260929-13: PromptPack.databases loads the pack's schema and data
# once per server, into PromptPack::TEMPLATE, and makes each run's
# production database a copy of it, rather than loading data.sql again.
RSpec.describe "PromptPack.databases" do
  let(:server) { TestPostgres.server }
  let(:first_query) { PromptPack::QUERIES[0] }
  let(:second_query) { PromptPack::QUERIES[1] }

  before { @made = [] }

  after { PipelineReplay.drop(server, @made) }

  # A run's production and racetrack databases, dropped after the example
  # along with the arena the run would make. databases closes the admin
  # connection, so its setting is made again each time.
  def databases(query)
    server.admin.exec("SET client_min_messages = warning")
    PromptPack.databases(server, query).tap { @made.push(*it, "#{it.last}_arena") }
  end

  def values(db, sql)
    conn = PG.connect(host: server.host, port: server.port, dbname: db, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec(sql).values
  ensure
    conn&.close
  end

  def template_oid
    server.admin.exec_params("SELECT oid FROM pg_database WHERE datname = $1", [PromptPack::TEMPLATE])
          .column_values(0).first
  end

  # A relation's OID is kept when a database is copied, and is new each
  # time a table is created.
  def orders_oid(db) = values(db, "SELECT 'public.orders'::regclass::oid")

  def tables = %w[users products orders line_items]
  # data.sql's rows are the same on every load, but ANALYZE samples 30,000
  # rows at random from a bigger table, so only these tables, which are
  # smaller than that, get the same statistics from every load.
  def fully_sampled = %w[users products]

  def stats(db, only = tables)
    values(db, "SELECT tablename, attname, null_frac, avg_width, n_distinct, most_common_vals::text, " \
               "most_common_freqs::text, histogram_bounds::text, correlation, most_common_elems::text, " \
               "elem_count_histogram::text FROM pg_stats WHERE schemaname = 'public' ORDER BY 1, 2")
      .select { only.include?(it[0]) }
  end

  # Each table's row count, and a hash of its rows in id order.
  def rows(db)
    tables.to_h { [it, values(db, "SELECT count(*), md5(string_agg(t::text, ',' ORDER BY t.id)) FROM #{it} t")] }
  end

  def facts(db)
    { extensions: values(db, "SELECT extname, extversion FROM pg_extension ORDER BY 1"),
      rows: rows(db),
      classes: values(db, "SELECT relname, relkind::text, reltuples, relpages FROM pg_class c " \
                          "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE nspname = 'public' ORDER BY 1"),
      analyzed: stats(db).map { it.first(2) },
      stats: stats(db, fully_sampled) }
  end

  it "loads the data once, and makes every run's production database a copy of that load" do
    prod1, racetrack1 = databases(first_query)
    oid = template_oid
    prod2, = databases(second_query)
    expect(oid).not_to be_nil
    expect(template_oid).to eq(oid)
    expect(orders_oid(prod2)).to eq(orders_oid(prod1))
    expect(orders_oid(racetrack1)).to eq(orders_oid(prod1))
  end

  it "gives every copy the same statistics, the template's" do
    prod1, = databases(first_query)
    prod2, = databases(second_query)
    expect(stats(prod2)).to eq(stats(prod1))
    expect(stats(prod1).map(&:first).uniq).to match_array(tables)
  end

  it "gives a copy the schema, data, extensions, and statistics of a fresh load" do
    prod, = databases(first_query)
    fresh = "pack_fresh_load_check"
    @made << fresh
    PromptPack.build(server, fresh)
    expected = facts(fresh)
    expect(expected[:extensions].map(&:first)).to include("hypopg")
    expect(expected[:rows]["line_items"].first.first).to eq("300000")
    expect(facts(prod)).to eq(expected)
  end

  it "leaves no connection to the template, and lets no run connect to it and change it" do
    databases(first_query)
    connected = server.admin.exec_params("SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
                                         [PromptPack::TEMPLATE])
    expect(connected.getvalue(0, 0)).to eq("0")
    expect { values(PromptPack::TEMPLATE, "SELECT 1") }
      .to raise_error(PG::ConnectionBad, /"#{PromptPack::TEMPLATE}" is not currently accepting connections/)
  end

  it "refuses a query whose databases would take the template's name" do
    query = first_query.with(name: "template")
    expect { PromptPack.databases(server, query) }
      .to raise_error(ArgumentError, /template.*#{PromptPack::TEMPLATE}/)
  end
end
