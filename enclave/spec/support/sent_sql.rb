# frozen_string_literal: true

require "delegate"
require "pg_query"

# Connection wrappers for the ordered queries ProductionComparison sends
# without a LIMIT, the runs that read a query's whole result.
module SentSql
  module_function

  def unlimited_ordered?(sql)
    select = PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt
    !select.nil? && !select.sort_clause.empty? && select.limit_count.nil?
  rescue PgQuery::ParseError
    false
  end

  # Records them.
  class Recorder < SimpleDelegator
    def unlimited = (@unlimited ||= [])

    def send_query_params(sql, *)
      unlimited << sql if SentSql.unlimited_ordered?(sql)
      super
    end
  end

  # Makes each sleep for a second first, as a large table's would take.
  class Slow < SimpleDelegator
    attr_reader :slowed

    def send_query_params(sql, *rest)
      return super unless SentSql.unlimited_ordered?(sql)

      @slowed = true
      super("SELECT q.* FROM pg_sleep(1) CROSS JOIN LATERAL (#{sql}) q", *rest)
    end
  end
end
