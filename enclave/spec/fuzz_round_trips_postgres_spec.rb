# frozen_string_literal: true

require "quaack/enclave/fuzz"
require "quaack/enclave/redaction"

# Task 20261110-16: a trial with a binding takes the round trips one without
# takes, and Differ's combined statement reuses the types already read.
RSpec.describe "the fuzz search's round trips with a binding" do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:sql) { "SELECT i.id FROM fx.items i WHERE i.qty * $1 > $2" }
  let(:literal) { "SELECT i.id FROM fx.items i WHERE i.qty * 1.5 > 3" }
  let(:bound) do
    Quaack::Enclave::Redaction.binding(sql, "$1" => { "value" => "1.5", "type" => "numeric" },
                                            "$2" => { "value" => "3", "type" => "integer" })
  end
  let(:items) { Quaack::Enclave::TableName.new(schema: "fx", name: "items") }
  let(:catalog) { Quaack::Enclave::Fuzz::Catalog.new(conn, [items]) }

  before { conn.exec("CREATE SCHEMA fx; CREATE TABLE fx.items (id int PRIMARY KEY, qty int)") }
  after { conn.exec("DROP SCHEMA IF EXISTS fx CASCADE") }

  # Each of these waits on the server once.
  def count_round_trips
    count = 0
    %i[exec exec_params send_query pipeline_sync].each do |name|
      allow(conn).to(receive(name).and_wrap_original { |m, *args| (count += 1) && m.call(*args) })
    end
    yield
    count
  ensure
    RSpec::Mocks.space.proxy_for(conn).reset
  end

  def world(qty) = [Quaack::Enclave::Fuzz::Generator::Row.new(items, { "id" => "1", "qty" => qty.to_s })]

  def trial_trips(queries, binding)
    session = Quaack::Enclave::Fuzz::Session.new(conn, catalog, queries, honour: [], statement_timeout_ms: 5000,
                                                                         binding:)
    session.open
    session.trial(world(5))
    count_round_trips { session.trial(world(1)) }
  ensure
    session&.close
  end

  it "takes no more round trips per trial with a binding than the literal form does" do
    expect(trial_trips([sql, sql], bound)).to eq(trial_trips([literal, literal], nil))
  end

  it "still judges a candidate that fails on the data as a kill, and runs nothing after it" do
    candidate = "SELECT i.id FROM fx.items i WHERE i.qty / ($2 - 3) > $1"
    session = Quaack::Enclave::Fuzz::Session.new(conn, catalog, [sql, candidate], honour: [],
                                                                                  statement_timeout_ms: 5000,
                                                                                  binding: bound)
    session.open

    expect(session.trial(world(5))).to have_attributes(compared: false, rule: :query_failed)
    expect(session.trial(world(5)).signature).not_to be_nil
  ensure
    session&.close
  end

  it "leaves an original that fails on the data illegal, not a kill" do
    original = "SELECT i.id FROM fx.items i WHERE i.qty / ($2 - 3) > $1"
    session = Quaack::Enclave::Fuzz::Session.new(conn, catalog, [original, sql], honour: [],
                                                                                 statement_timeout_ms: 5000,
                                                                                 binding: bound)
    session.open

    expect(session.trial(world(5))).to have_attributes(compared: false, rule: nil)
  ensure
    session&.close
  end

  # An unknown $n takes its type from where it sits, so another query's
  # types can't stand in for it.
  it "doesn't share types read for another query when a value is unknown" do
    unknown = Quaack::Enclave::Redaction::Binding.new(sql: "SELECT $1", types: ["unknown"], values: ["7"])
    typed = Quaack::Enclave::ArenaRunner::Typed.new(unknown)
    typed.params(conn, "SELECT 1 WHERE 1 = $1")

    expect(typed.params(conn, "SELECT 1 WHERE 'a' = $1", shared: true)).to eq([{ value: "7", type: 25 }])
  end

  it "runs Differ's combined statement in one round trip when only the loosened set changed" do
    typed = Quaack::Enclave::ArenaRunner::Typed.new(bound)
    conn.exec("BEGIN; INSERT INTO fx.items VALUES (1, 1), (2, 3)")
    Quaack::Enclave::Fuzz::Differ.multisets(conn, sql, ["SELECT i.id FROM fx.items i"], typed)
    loosened = ["SELECT i.id FROM fx.items i WHERE i.qty > $2", "SELECT i.id FROM fx.items i"]

    flagged = nil
    trips = count_round_trips { flagged = Quaack::Enclave::Fuzz::Differ.multisets(conn, sql, loosened, typed) }

    expect([flagged, trips]).to eq([[0, 1], 1])
  ensure
    conn.exec("ROLLBACK")
  end
end
