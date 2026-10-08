# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "quaack/enclave/error_filter"

# Stands in for a real production value. It must never show up in anything
# the error filter writes or returns.
ERROR_SENTINEL = "SENTINEL-4d71e0-customers.email"

# Stand-ins for the errors the filter gets.
module FilterFakes
  # An error that names its own rule and SQLSTATE, the way an enclave error can.
  class RuledError < StandardError
    attr_reader :rule, :sqlstate

    def initialize(message = ERROR_SENTINEL, rule: nil, sqlstate: nil)
      super(message)
      @rule = rule
      @sqlstate = sqlstate
    end
  end

  # An error whose every way of describing itself raises, with the sentinel in
  # what it raises. The filter must never ask it any of these.
  class LoudError < StandardError
    def rule = "loud_rule"

    %i[message to_s inspect full_message detailed_message backtrace backtrace_locations cause].each do |name|
      define_method(name) { |*| raise ERROR_SENTINEL }
    end
  end

  # Duck types a PG::Error, whose result holds the error fields.
  FakeResult = Struct.new(:sqlstate) do
    def error_field(code) = code == 67 ? sqlstate : ERROR_SENTINEL
  end

  # A volatility refusal, which names the function that caused it.
  class FunctionError < StandardError
    attr_reader :rule, :function

    def initialize(rule:, function:)
      super(ERROR_SENTINEL)
      @rule = rule
      @function = function
    end
  end

  # A run_server_other_clients failure, which names the other clients by
  # pid and start time.
  class ClientsError < StandardError
    attr_reader :rule, :clients

    def initialize(rule:, clients:)
      super(ERROR_SENTINEL)
      @rule = rule
      @clients = clients
    end
  end

  # A rewrite-test refusal, which names the column it can't fill.
  class ColumnError < StandardError
    attr_reader :rule, :column

    def initialize(rule:, column:)
      super(ERROR_SENTINEL)
      @rule = rule
      @column = column
    end
  end

  # An fk_cycle refusal, which names the cycle's tables.
  # A dump_object_unreadable refusal, which names the tables the role
  # can't read.
  class TablesError < StandardError
    attr_reader :rule, :tables

    def initialize(rule:, tables:)
      super(ERROR_SENTINEL)
      @rule = rule
      @tables = tables
    end
  end

  class CycleError < StandardError
    attr_reader :rule, :cycle

    def initialize(rule:, cycle:)
      super(ERROR_SENTINEL)
      @rule = rule
      @cycle = cycle
    end
  end

  # An intake unreadable-file refusal, whose reason is an enclave constant.
  class IntakeUnreadableError < StandardError
    attr_reader :rule, :reason

    def initialize(rule:, reason:)
      super(ERROR_SENTINEL)
      @rule = rule
      @reason = reason
    end
  end

  class ResultError < StandardError
    attr_reader :result

    def initialize(result)
      super(ERROR_SENTINEL)
      @result = result
    end
  end
end

RSpec::Matchers.define_negated_matcher :not_output, :output

RSpec.describe Quaack::Enclave::ErrorFilter do
  let(:filter) { described_class }
  # ERROR_SENTINEL is fixed, since the fakes above are built before any
  # example runs, and it's there to scan for alongside the made ones.
  let(:sentinels) { LeakCheck::Sentinels.new(extra: { planted: ERROR_SENTINEL }) }

  def line(**fields) = JSON.generate({ "type" => "error", **fields.transform_keys(&:to_s) })

  def recurse_forever = 1 + recurse_forever

  def raised
    yield
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  it "is loaded by quaack/enclave" do
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", <<~RUBY)
      require "quaack/enclave"
      print Quaack::Enclave::ErrorFilter.to_egress(RuntimeError.new("x"), step: "classify")
    RUBY

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq(line(step: "classify", rule: "internal_error"))
  end

  describe ".to_egress" do
    it "sends the step, the error's rule, and its SQLSTATE, and nothing else" do
      error = FilterFakes::RuledError.new(rule: "unique_email", sqlstate: "23505")

      out = filter.to_egress(error, step: "classify")

      expect(out).to eq(line(step: "classify", rule: "unique_email", sqlstate: "23505"))
      expect_no_leaks(sentinels, stdout: out)
    end

    it "sends a volatile_function refusal's schema-qualified function name" do
      error = FilterFakes::FunctionError.new(rule: "volatile_function", function: "pg_catalog.random")

      expect(filter.to_egress(error, step: "volatility"))
        .to eq(line(step: "volatility", rule: "volatile_function", function: "pg_catalog.random"))
    end

    it "sends no function for any rule but volatile_function" do
      error = FilterFakes::FunctionError.new(rule: "unique_email", function: "pg_catalog.random")

      expect(filter.to_egress(error, step: "volatility")).to eq(line(step: "volatility", rule: "unique_email"))
    end

    it "sends an intake unreadable refusal's fixed reason" do
      error = FilterFakes::IntakeUnreadableError.new(rule: "query_unreadable", reason: "permission_denied")

      expect(filter.to_egress(error, step: "intake"))
        .to eq(line(step: "intake", rule: "query_unreadable", reason: "permission_denied"))
    end

    it "sends no reason for any rule but intake unreadable refusals" do
      error = FilterFakes::IntakeUnreadableError.new(rule: "bad_config", reason: "permission_denied")

      expect(filter.to_egress(error, step: "inventory")).to eq(line(step: "inventory", rule: "bad_config"))
    end

    ["no such file #{ERROR_SENTINEL}", "missing\n#{ERROR_SENTINEL}", "enoent", :missing].each do |reason|
      it "drops an intake unreadable reason that is not one fixed cause: #{reason.inspect}" do
        error = FilterFakes::IntakeUnreadableError.new(rule: "query_unreadable", reason:)

        out = filter.to_egress(error, step: "intake")

        expect(out).to eq(line(step: "intake", rule: "query_unreadable"))
        expect(out).not_to include("SENTINEL")
      end
    end

    [
      ["an unqualified name", "random"],
      ["a sentinel after the name", "pg_catalog.random(#{ERROR_SENTINEL})"],
      ["a quoted name", '"Sales"."bump me"'],
      ["a three-part name", "a.b.c"],
      ["a Symbol", :"pg_catalog.random"],
      ["a String subclass", Class.new(String).new("pg_catalog.random")]
    ].each do |label, function|
      it "drops a function that's #{label}" do
        error = FilterFakes::FunctionError.new(rule: "volatile_function", function:)

        out = filter.to_egress(error, step: "volatility")

        expect(out).to eq(line(step: "volatility", rule: "volatile_function"))
        expect(out).not_to include("SENTINEL")
      end
    end

    describe "a run_server_other_clients failure's clients" do
      let(:start) { "2026-09-29T16:01:02Z" }
      let(:client) { { "pid" => 4242, "backend_start" => start } }

      def clients_line(clients, rule: "run_server_other_clients")
        filter.to_egress(FilterFakes::ClientsError.new(rule:, clients:), step: "run-server")
      end

      it "sends each other client's pid and start time, in order" do
        other = { "pid" => 5678, "backend_start" => "2026-09-29T17:00:00Z" }

        expect(clients_line([client, other]))
          .to eq(line(step: "run-server", rule: "run_server_other_clients", clients: [client, other]))
      end

      it "sends twenty clients" do
        clients = Array.new(20) { |i| { "pid" => i + 1, "backend_start" => start } }

        expect(JSON.parse(clients_line(clients))["clients"]).to eq(clients)
      end

      it "sends no clients for any rule but run_server_other_clients" do
        expect(clients_line([client], rule: "run_server_guc_mismatch"))
          .to eq(line(step: "run-server", rule: "run_server_guc_mismatch"))
      end

      good = "2026-09-29T16:01:02Z"
      # A subclass of base that writes itself out as a sentinel.
      sneaky = ->(base) { Class.new(base) { def to_json(*) = ERROR_SENTINEL.to_json } }
      [
        ["an application_name beside the pid",
         [{ "pid" => 4242, "backend_start" => good, "application_name" => ERROR_SENTINEL }]],
        ["a sentinel in place of the start time", [{ "pid" => 4242, "backend_start" => ERROR_SENTINEL }]],
        ["a sentinel before the start time", [{ "pid" => 4242, "backend_start" => "#{ERROR_SENTINEL} #{good}" }]],
        ["a sentinel after the start time", [{ "pid" => 4242, "backend_start" => "#{good} #{ERROR_SENTINEL}" }]],
        ["a start time on a line of its own", [{ "pid" => 4242, "backend_start" => "#{good}\n#{ERROR_SENTINEL}" }]],
        ["a start time on a line after a sentinel",
         [{ "pid" => 4242, "backend_start" => "#{ERROR_SENTINEL}\n#{good}" }]],
        ["a start time with a newline after it", [{ "pid" => 4242, "backend_start" => "#{good}\n" }]],
        ["a start time with a fraction", [{ "pid" => 4242, "backend_start" => "2026-09-29T16:01:02.5Z" }]],
        ["a start time with an offset", [{ "pid" => 4242, "backend_start" => "2026-09-29T16:01:02+00:00" }]],
        ["a start time that's a String subclass", [{ "pid" => 4242, "backend_start" => Class.new(String).new(good) }]],
        ["a String pid", [{ "pid" => "4242", "backend_start" => good }]],
        ["a sentinel for a pid", [{ "pid" => ERROR_SENTINEL, "backend_start" => good }]],
        ["a zero pid", [{ "pid" => 0, "backend_start" => good }]],
        ["a negative pid", [{ "pid" => -1, "backend_start" => good }]],
        ["a Float pid", [{ "pid" => 4242.0, "backend_start" => good }]],
        ["a pid that's true", [{ "pid" => true, "backend_start" => good }]],
        ["a missing start time", [{ "pid" => 4242 }]],
        ["a missing pid", [{ "backend_start" => good }]],
        ["Symbol keys", [{ pid: 4242, backend_start: good }]],
        ["its keys in reverse order", [{ "backend_start" => good, "pid" => 4242 }]],
        ["a key that's a String subclass", [{ Class.new(String).new("pid") => 4242, "backend_start" => good }]],
        ["an entry that isn't a Hash", [[4242, good]]],
        ["an entry that's a Hash subclass", [sneaky.call(Hash).new.merge!("pid" => 4242, "backend_start" => good)]],
        ["a good entry and a sentinel", [{ "pid" => 4242, "backend_start" => good }, ERROR_SENTINEL]],
        ["an empty Array", []],
        ["twenty-one entries", Array.new(21) { |i| { "pid" => i + 1, "backend_start" => good } }],
        ["an Array subclass", sneaky.call(Array).new([{ "pid" => 4242, "backend_start" => good }])],
        ["a String", ERROR_SENTINEL],
        ["a lone Hash", { "pid" => 4242, "backend_start" => good }],
        ["nil", nil]
      ].each do |label, clients|
        it "drops clients with #{label}, and still sends the rule" do
          out = clients_line(clients)

          expect(out).to eq(line(step: "run-server", rule: "run_server_other_clients"))
          expect(out).not_to include("SENTINEL")
        end
      end
    end

    describe "a rewrite-test refusal's column" do
      let(:column) { { "table" => "fx.users", "column" => "root_account_ids", "type" => "bigint[]" } }

      def column_line(column, rule: "unsupported_type")
        filter.to_egress(FilterFakes::ColumnError.new(rule:, column:), step: "9")
      end

      it "sends the table, column, and type an unsupported_type or domain_check refusal names" do
        expect(column_line(column)).to eq(line(step: "9", rule: "unsupported_type", column:))
        expect(column_line(column, rule: "domain_check")).to eq(line(step: "9", rule: "domain_check", column:))
      end

      it "sends the types format_type prints, with typmods and schemas" do
        ["numeric(5,2)", "character varying(255)[]", "timestamp(3) with time zone", "bit varying(6)",
         "fx.big_code", "int4range"].each do |type|
          expect(JSON.parse(column_line(column.merge("type" => type)))["column"]["type"]).to eq(type)
        end
      end

      it "sends no column for any other rule" do
        expect(column_line(column, rule: "unsatisfiable_check")).to eq(line(step: "9", rule: "unsatisfiable_check"))
      end

      sneaky = Class.new(Hash) { def to_json(*) = ERROR_SENTINEL.to_json }
      [
        ["a sentinel in the type", { "type" => "pg_lsn #{ERROR_SENTINEL}" }],
        ["a quoted type", { "type" => '"Order Status"' }],
        ["a type on two lines", { "type" => "pg_lsn\n" }],
        ["a type that's a String subclass", { "type" => Class.new(String).new("pg_lsn") }],
        ["an unqualified table", { "table" => "users" }],
        ["a quoted table", { "table" => '"Sales"."Users"' }],
        ["a sentinel for the column", { "column" => ERROR_SENTINEL }],
        ["a qualified column", { "column" => "users.ids" }],
        ["a Symbol column", { "column" => :ids }],
        ["a value beside the type", { "value" => ERROR_SENTINEL }]
      ].each do |label, change|
        it "drops a column with #{label}, and still sends the rule" do
          out = column_line(column.merge(change))

          expect(out).to eq(line(step: "9", rule: "unsupported_type"))
          expect(out).not_to include("SENTINEL")
        end
      end

      [
        ["Symbol keys", { table: "fx.users", column: "ids", type: "pg_lsn" }],
        ["its keys in another order", { "column" => "ids", "table" => "fx.users", "type" => "pg_lsn" }],
        ["a missing type", { "table" => "fx.users", "column" => "ids" }],
        ["a Hash subclass", sneaky.new.merge!("table" => "fx.users", "column" => "ids", "type" => "pg_lsn")],
        ["a key that's a String subclass",
         { Class.new(String) { def to_s = ERROR_SENTINEL }.new("table") => "fx.users", "column" => "ids",
           "type" => "pg_lsn" }],
        ["a String", ERROR_SENTINEL],
        ["nil", nil]
      ].each do |label, bad|
        it "drops a column that's #{label}" do
          out = column_line(bad)

          expect(out).to eq(line(step: "9", rule: "unsupported_type"))
          expect(out).not_to include("SENTINEL")
        end
      end
    end

    describe "an fk_cycle refusal's tables" do
      let(:cycle) { %w[public.accounts billing.courses public.accounts] }

      def cycle_line(cycle, rule: "fk_cycle")
        filter.to_egress(FilterFakes::CycleError.new(rule:, cycle:), step: "counterexample-round")
      end

      it "sends the cycle's tables, in order, for an fk_cycle refusal" do
        expect(cycle_line(cycle)).to eq(line(step: "counterexample-round", rule: "fk_cycle", cycle:))
      end

      it "sends no tables for any other rule" do
        expect(cycle_line(cycle, rule: "complex_check"))
          .to eq(line(step: "counterexample-round", rule: "complex_check"))
      end

      sneaky = Class.new(Array) { def to_json(*) = ERROR_SENTINEL.to_json }
      [
        ["a sentinel table", ["public.accounts", ERROR_SENTINEL, "public.accounts"]],
        ["an unqualified table", %w[accounts public.courses accounts]],
        ["a quoted table", ['"Sales"."Accounts"', "public.courses", '"Sales"."Accounts"']],
        ["a table that's a String subclass", [Class.new(String).new("public.a"), "public.b", "public.a"]],
        ["a table that isn't a String", [%w[public a], "public.b", %w[public a]]],
        ["no second table", %w[public.a public.a]],
        ["an end that isn't its start", %w[public.a public.b public.c]],
        ["more than 64 tables", [*Array.new(64) { "public.t#{it}" }, "public.t0"]],
        ["an Array subclass", sneaky.new(%w[public.a public.b public.a])],
        ["a String", ERROR_SENTINEL],
        ["nil", nil]
      ].each do |label, bad|
        it "drops a cycle with #{label}, and still sends the rule" do
          out = cycle_line(bad)

          expect(out).to eq(line(step: "counterexample-round", rule: "fk_cycle"))
          expect(out).not_to include("SENTINEL")
        end
      end
    end

    # 20261001-10: they go to the operator, through the driver's words.
    describe "a dump_object_unreadable refusal's tables" do
      let(:tables) { %w[dba.secrets public.accounts] }

      def tables_line(tables, rule: "dump_object_unreadable")
        filter.to_egress(FilterFakes::TablesError.new(rule:, tables:), step: "schema-dump")
      end

      it "sends the tables, in order, for a dump_object_unreadable refusal" do
        expect(tables_line(tables)).to eq(line(step: "schema-dump", rule: "dump_object_unreadable", tables:))
      end

      it "sends one table, and 64" do
        many = Array.new(64) { "dba.t#{it}" }
        expect([tables_line(%w[dba.a]), tables_line(many)])
          .to eq([line(step: "schema-dump", rule: "dump_object_unreadable", tables: %w[dba.a]),
                  line(step: "schema-dump", rule: "dump_object_unreadable", tables: many)])
      end

      it "sends no tables for any other rule" do
        expect(tables_line(tables, rule: "pg_dump_failed")).to eq(line(step: "schema-dump", rule: "pg_dump_failed"))
      end

      sneaky = Class.new(Array) { def to_json(*) = ERROR_SENTINEL.to_json }
      [
        ["a sentinel table", ["public.accounts", ERROR_SENTINEL]],
        ["an unqualified table", %w[accounts]],
        ["a quoted table", ['"Sales"."Accounts"']],
        ["a table that's a String subclass", [Class.new(String).new("public.a")]],
        ["no tables", []],
        ["more than 64 tables", Array.new(65) { "public.t#{it}" }],
        ["an Array subclass", sneaky.new(%w[public.a])],
        ["a String", ERROR_SENTINEL],
        ["nil", nil]
      ].each do |label, bad|
        it "drops tables with #{label}, and still sends the rule" do
          out = tables_line(bad)

          expect(out).to eq(line(step: "schema-dump", rule: "dump_object_unreadable"))
          expect(out).not_to include("SENTINEL")
        end
      end
    end

    it "sends none of an error's text, however it's reached, while the error itself holds every sentinel" do
      error = raised do
        raise FilterFakes::RuledError.new(sentinels.text, rule: "unique_email", sqlstate: "23505")
      rescue FilterFakes::RuledError
        raise FilterFakes::RuledError.new("Key (email)=(#{sentinels.word}) #{sentinels.number}", rule: "cause_rule")
      end
      error.set_backtrace(["#{sentinels.like_prefix}.rb:1 #{sentinels.date}"])
      error.instance_variable_set(:@detail, sentinels.json)
      held = LeakCheck.findings(sentinels, objects: { error: }).map(&:sentinel).uniq
      expect(held).to match_array(LeakCheck::Sentinels::KINDS)

      expect_no_leaks(sentinels, stdout: filter.to_egress(error, step: "fixture-load"))
    end

    it "takes a rule given as a Symbol" do
      expect(filter.to_egress(FilterFakes::RuledError.new(rule: :bad_search_path), step: "qualify"))
        .to eq(line(step: "qualify", rule: "bad_search_path"))
    end

    it "takes steps named the way DESIGN.md and the subcommands name them" do
      ["classify", "index-from-query", "counterexample-compare", "intake", "qualify_relations", "a" * 63].each do |step|
        expect(filter.to_egress(RuntimeError.new, step:)).to eq(line(step:, rule: "internal_error"))
      end
    end

    it "sends internal_error, and no SQLSTATE, for an error with neither" do
      out = filter.to_egress(RuntimeError.new("Key (email)=(#{ERROR_SENTINEL}) already exists."), step: "fixture-load")

      expect(out).to eq(line(step: "fixture-load", rule: "internal_error"))
    end

    it "never sends the cause chain, even when a cause has a rule and a SQLSTATE" do
      error = raised do
        raise FilterFakes::RuledError.new(rule: "cause_rule", sqlstate: "23505")
      rescue FilterFakes::RuledError
        raise "wrapped: #{ERROR_SENTINEL}"
      end
      expect(error.cause.message).to eq(ERROR_SENTINEL)

      expect(filter.to_egress(error, step: "classify")).to eq(line(step: "classify", rule: "internal_error"))
    end

    it "never asks the error for its message, backtrace, inspect, or cause" do
      out = filter.to_egress(FilterFakes::LoudError.new, step: "classify")

      expect(out).to eq(line(step: "classify", rule: "loud_rule"))
    end

    it "sends internal_error when the error's rule method raises" do
      error = FilterFakes::RuledError.new(sqlstate: "23505")
      def error.rule = raise(ERROR_SENTINEL)

      expect(filter.to_egress(error,
                              step: "classify")).to eq(line(step: "classify", rule: "internal_error",
                                                            sqlstate: "23505"))
    end

    it "keeps the step when asking for the rule, SQLSTATE, or result raises something that isn't a StandardError" do
      cases = {
        rule: [{ sqlstate: "23505" }, line(step: "classify", rule: "internal_error", sqlstate: "23505")],
        sqlstate: [{ rule: "r" }, line(step: "classify", rule: "r")],
        # With no sqlstate method answer, the filter goes on to ask for the result.
        result: [{ rule: "r" }, line(step: "classify", rule: "r")]
      }
      cases.each do |method, (fields, expected)|
        error = FilterFakes::RuledError.new(**fields)
        error.define_singleton_method(method) { raise NoMemoryError, ERROR_SENTINEL }

        expect(raised { filter.to_egress(error, step: "classify") }).to eq(expected), "for #{method}"
      end
    end

    it "sends internal_error for a rule that isn't a short lowercase identifier" do
      tricky = Class.new(String) { def to_s = ERROR_SENTINEL }
      [ERROR_SENTINEL, :"Unique-Violation", "unique-violation", "unique_violation\n", "", "_rule", "9rule", "a" * 64,
       "rule\xFF".b, "rule".encode("UTF-16LE"), tricky.new("tricky_rule"), 42, nil, [:rule]].each do |rule|
        out = filter.to_egress(FilterFakes::RuledError.new(rule:), step: "classify")

        expect(out).to eq(line(step: "classify", rule: "internal_error")), "for rule #{rule.inspect}"
      end
    end

    it "takes a rule of up to 63 characters" do
      rule = "a" * 63

      expect(filter.to_egress(FilterFakes::RuledError.new(rule:),
                              step: "classify")).to eq(line(step: "classify", rule:))
    end

    it "drops a SQLSTATE that isn't five digits or capital letters" do
      odd = Class.new(String) { def to_s = ERROR_SENTINEL }
      [ERROR_SENTINEL, "2350", "235055", "23505\n", "2350a", "2350\xFF".b, "23505".encode("UTF-16LE"), 23_505,
       :"23505", odd.new("23505"), nil]
        .each do |sqlstate|
        out = filter.to_egress(FilterFakes::RuledError.new(rule: "r", sqlstate:), step: "classify")

        expect(out).to eq(line(step: "classify", rule: "r")), "for sqlstate #{sqlstate.inspect}"
      end
    end

    it "reads the SQLSTATE from a PG-style error's result" do
      expect(filter.to_egress(FilterFakes::ResultError.new(FilterFakes::FakeResult.new("40P01")), step: "baseline"))
        .to eq(line(step: "baseline", rule: "internal_error", sqlstate: "40P01"))
    end

    it "takes the error's own sqlstate over its result's" do
      error = FilterFakes::ResultError.new(FilterFakes::FakeResult.new("40P01"))
      def error.sqlstate = "23505"

      expect(filter.to_egress(error,
                              step: "baseline")).to eq(line(step: "baseline", rule: "internal_error",
                                                            sqlstate: "23505"))
    end

    it "drops a bad SQLSTATE from a PG-style error's result, or a result that isn't there" do
      results = [FilterFakes::FakeResult.new(ERROR_SENTINEL), FilterFakes::FakeResult.new(nil), nil, ERROR_SENTINEL]
      results.each do |result|
        out = filter.to_egress(FilterFakes::ResultError.new(result), step: "baseline")

        expect(out).to eq(line(step: "baseline", rule: "internal_error")), "for result #{result.inspect}"
      end
    end

    it "drops a step that isn't a short lowercase name" do
      [ERROR_SENTINEL, "3F", "", "-3f", "3f\n", "a" * 64, 3, nil].each do |step|
        out = filter.to_egress(RuntimeError.new, step:)

        expect(out).to eq(line(rule: "internal_error")), "for step #{step.inspect}"
      end
    end

    it "filters an Egress::Error that came from a real value" do
      error = raised { Quaack::Enclave::Egress.serialize(type: :error, rule: "#{ERROR_SENTINEL}\xFF".b) }
      expect(error).to be_a(Quaack::Enclave::Egress::Error)

      expect(filter.to_egress(error, step: "classify")).to eq(line(step: "classify", rule: "internal_error"))
    end

    it "filters an Egress::Error with the sentinel in its message" do
      error = Quaack::Enclave::Egress::Error.new(ERROR_SENTINEL)

      expect(filter.to_egress(error, step: "classify")).to eq(line(step: "classify", rule: "internal_error"))
    end

    describe "when the egress function fails" do
      it "has a fallback line that the egress function would send itself" do
        expect(described_class::FALLBACK).to eq(Quaack::Enclave::Egress.serialize(type: :error, rule: "internal_error"))
      end

      # The egress function never fails for the fields the filter checks, so
      # these fake it, to test the fallback that's there in case it ever does.
      it "sends the fallback line when the egress function returns nil" do
        allow(Quaack::Enclave::Egress).to receive(:serialize).and_return(nil)

        expect(filter.to_egress(FilterFakes::RuledError.new(rule: "r"),
                                step: "classify")).to eq(described_class::FALLBACK)
      end

      it "sends the fallback line, and doesn't raise, when the egress function raises" do
        allow(Quaack::Enclave::Egress).to receive(:serialize).and_raise(Quaack::Enclave::Egress::Error, ERROR_SENTINEL)

        expect(filter.to_egress(FilterFakes::RuledError.new(rule: "r"),
                                step: "classify")).to eq(described_class::FALLBACK)
      end

      it "sends the fallback line when the egress function raises something that isn't a StandardError" do
        allow(Quaack::Enclave::Egress).to receive(:serialize).and_raise(NoMemoryError, ERROR_SENTINEL)

        # RSpec lets a NoMemoryError end the run, so raised turns an escape into a plain failure.
        expect(raised { filter.to_egress(FilterFakes::RuledError.new(rule: "r"), step: "classify") })
          .to eq(described_class::FALLBACK)
      end
    end
  end

  describe ".guard" do
    let(:out) { StringIO.new }

    it "returns the block's value, and writes nothing, when the block succeeds" do
      result = nil
      expect { result = filter.guard(step: "classify", out:) { 0 } }.not_to output.to_stderr

      expect(result).to eq(0)
      expect(out.string).to eq("")
    end

    it "writes one filtered error line and returns a nonzero status for anything raised" do
      errors = {
        "an error" => -> { raise FilterFakes::RuledError.new(rule: "unique_email", sqlstate: "23505") },
        "a stack overflow" => -> { recurse_forever },
        "running out of memory" => -> { raise NoMemoryError, ERROR_SENTINEL },
        "a load error" => -> { require "quaack/enclave/#{ERROR_SENTINEL}" },
        "a script error" => -> { raise NotImplementedError, ERROR_SENTINEL },
        "an egress error" => -> { raise Quaack::Enclave::Egress::Error, ERROR_SENTINEL },
        "a loud error" => -> { raise FilterFakes::LoudError }
      }
      errors.each do |name, block|
        out = StringIO.new
        status = nil

        expect { status = filter.guard(step: "classify", out:, &block) }.not_to output.to_stderr

        expect(status).to eq(described_class::EX_SOFTWARE), "for #{name}"
        expect(out.string.lines.size).to eq(1), "for #{name}"
        expect(JSON.parse(out.string)).to include("type" => "error", "step" => "classify"), "for #{name}"
        expect_no_leaks(sentinels, stdout: out.string, why: "for #{name}")
      end
    end

    it "fails with EX_SOFTWARE, which is nonzero" do
      status = filter.guard(step: "classify", out:) { raise ERROR_SENTINEL }

      expect(status).to eq(70)
    end

    it "writes what to_egress gives, as a line" do
      filter.guard(step: "classify", out:) { raise FilterFakes::RuledError.new(rule: "unique_email", sqlstate: "23505") }

      expect(out.string).to eq("#{line(step: "classify", rule: "unique_email", sqlstate: "23505")}\n")
    end

    it "lets exit pass, with its status" do
      expect { filter.guard(step: "classify", out:) { exit 3 } }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(3)
      }
      expect(out.string).to eq("")
    end

    it "writes one filtered error line for a signal, then raises it again so the process still dies" do
      signals = { "an interrupt" => Interrupt.new(ERROR_SENTINEL), "a signal" => SignalException.new("TERM") }
      signals.each do |name, signal|
        out = StringIO.new

        expect { filter.guard(step: "classify", out:) { raise signal } }
          .to raise_error(be(signal)).and(not_output.to_stderr), "for #{name}"
        expect(out.string).to eq("#{line(step: "classify", rule: "internal_error")}\n"), "for #{name}"
      end
    end

    it "still returns a nonzero status when writing the error line raises something that isn't a StandardError" do
      out = Object.new
      def out.write(*) = raise(NoMemoryError)

      # RSpec lets a NoMemoryError end the run, so raised turns an escape into a plain failure.
      expect(raised do
        filter.guard(step: "classify", out:) do
          raise ERROR_SENTINEL
        end
      end).to eq(described_class::EX_SOFTWARE)
    end

    # A signal that arrives while guard is already reporting an error must
    # still end the process, not leave guard returning EX_SOFTWARE.
    describe "a signal that arrives while it reports an error" do
      it "raises one that arrives while it asks the error for its rule" do
        error = RuntimeError.new(ERROR_SENTINEL)
        def error.rule = raise(Interrupt)

        expect(raised { filter.guard(step: "classify", out:) { raise error } }).to be_a(Interrupt)
      end

      it "raises one that arrives inside the egress function" do
        allow(Quaack::Enclave::Egress).to receive(:serialize).and_raise(SignalException, "TERM")

        expect(raised { filter.guard(step: "classify", out:) { raise ERROR_SENTINEL } }).to be_a(SignalException)
      end

      it "raises one that arrives while it writes the line" do
        loud = Object.new
        def loud.write(*) = raise(Interrupt)

        expect(raised { filter.guard(step: "classify", out: loud) { raise ERROR_SENTINEL } }).to be_a(Interrupt)
      end
    end

    it "flushes the line it writes" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "out")
        File.open(path, "w") do |file|
          file.sync = false
          filter.guard(step: "classify", out: file) { raise ERROR_SENTINEL }

          expect(File.read(path)).to eq("#{line(step: "classify", rule: "internal_error")}\n")
        end
      end
    end

    it "still returns a nonzero status when it can't write the error line" do
      closed = StringIO.new.tap(&:close)
      status = nil

      expect { status = filter.guard(step: "classify", out: closed) { raise ERROR_SENTINEL } }.not_to output.to_stderr
      expect(status).to eq(described_class::EX_SOFTWARE)
    end
  end

  describe "a SIGTERM inside a looped guard" do
    # The child sends itself SIGTERM in the first of three guarded steps.
    def looped_child
      run_ruby("-I", File.join(GEM_ROOT, "lib"), "-r", "quaack/enclave/error_filter", "-e", <<~RUBY)
        3.times do |i|
          Quaack::Enclave::ErrorFilter.guard(step: "loop") do
            Process.kill("TERM", Process.pid) if i.zero?
            sleep 5
          end
        end
        print "survived"
      RUBY
    end

    it "writes exactly one error line and ends the process with the signal" do
      out, _err, status = looped_child

      expect(out).to eq("#{line(step: "loop", rule: "internal_error")}\n")
      expect(status.termsig).to eq(Signal.list.fetch("TERM"))
    end

    it "prints nothing to stderr for the re-raised signal once stderr is silenced" do
      out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-r", "quaack/enclave/error_filter", "-e", <<~RUBY)
        Quaack::Enclave::ErrorFilter.silence_stderr!
        Quaack::Enclave::ErrorFilter.guard(step: "loop") { raise Interrupt, #{ERROR_SENTINEL.dump} }
      RUBY

      expect([out, err]).to eq(["#{line(step: "loop", rule: "internal_error")}\n", ""])
      expect(status.termsig).to eq(Signal.list.fetch("INT"))
    end
  end

  describe ".silence_stderr!" do
    # Every way a child process can reach stderr: $stderr, warn, the STDERR
    # constant, the raw file descriptor, a dying thread's report, and an
    # uncaught exception's backtrace.
    def loud_script
      <<~RUBY
        sentinel = #{ERROR_SENTINEL.dump}
        $stderr.puts "stderr " + sentinel
        warn "warn " + sentinel
        STDERR.syswrite "syswrite " + sentinel
        IO.new(2, autoclose: false).write "fd " + sentinel
        Thread.new { raise "thread " + sentinel }.join rescue nil
        $stdout.print "reached"
        raise "uncaught " + sentinel
      RUBY
    end

    # $stderr starts out as a copy of stderr, not the STDERR constant, so
    # silencing has to point $stderr back at STDERR too.
    def loud_child(silence:)
      silencing = silence ? "Quaack::Enclave::ErrorFilter.silence_stderr!" : ""
      run_ruby("-I", File.join(GEM_ROOT, "lib"), "-r", "quaack/enclave/error_filter", "-e",
               "$stderr = STDERR.dup\n#{silencing}\n#{loud_script}")
    end

    it "sees the sentinel on stderr without it, so the check works" do
      _out, err, _status = loud_child(silence: false)

      %w[stderr warn syswrite fd thread uncaught].each do |way|
        expect(err).to include("#{way} #{ERROR_SENTINEL}")
      end
    end

    it "keeps everything off stderr, however it's written" do
      out, err, status = loud_child(silence: true)

      expect(status).not_to be_success
      expect(err).to eq("")
      expect(out).to eq("reached")
      expect_no_leaks(sentinels, stdout: out, stderr: err, status:)
    end
  end
end
