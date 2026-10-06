# frozen_string_literal: true

module LeakCheck
  # Puts a Sentinels set into a harness database (spec/support/postgres),
  # where production values would be, so a step that reads rows, statistics,
  # or plans is exposed to them:
  #
  # - Row data and most common values: ROWS customers named with the text
  #   sentinel and with the json sentinel as preferences, and ROWS orders
  #   with the word as status, the number as total_cents, and noon on the
  #   date as created_at. That many repeats
  #   make each one a most common value after ANALYZE, so pg_stats holds
  #   them.
  # - Histogram bounds: each planted customer's email starts with the LIKE
  #   prefix, and emails are unique, so they land in the histogram instead.
  # - Query literals: Planted#query is a supported query, one a step could
  #   be given, whose literals are the sentinels, and that finds the
  #   planted rows. Its EXPLAIN shows them too.
  #
  # The json sentinel is also for step input on stdin.
  module Fixture
    ROWS = 300

    Planted = Data.define(:query)

    module_function

    # conn is a PG::Connection, or a TestPostgres::Database. It runs
    # ANALYZE on both tables, and returns a Planted.
    def plant(conn, sentinels)
      conn = conn.connection if conn.respond_to?(:connection)
      conn.exec(customers_sql(sentinels))
      conn.exec(orders_sql(sentinels))
      conn.exec("ANALYZE public.customers, public.orders")
      Planted.new(query: query(sentinels))
    end

    def customers_sql(sentinels)
      <<~SQL
        INSERT INTO public.customers (name, email, created_at, preferences)
        SELECT '#{sentinels.text}', '#{sentinels.like_prefix}-' || i || '@example.com', timestamptz '2025-06-01 00:00:00+00',
               '#{sentinels.json}'::jsonb
        FROM generate_series(1, #{ROWS}) AS i
      SQL
    end

    def orders_sql(sentinels)
      <<~SQL
        INSERT INTO public.orders (customer_id, status, total_cents, created_at)
        SELECT c.id, '#{sentinels.word}', #{sentinels.number}, timestamptz '#{sentinels.date.iso8601} 12:00:00+00'
        FROM public.customers c WHERE c.name = '#{sentinels.text}'
      SQL
    end

    def query(sentinels)
      "SELECT c.id, o.total_cents FROM public.customers c JOIN public.orders o ON o.customer_id = c.id " \
        "WHERE c.name = '#{sentinels.text}' AND c.email LIKE '#{sentinels.like}' AND o.status = '#{sentinels.word}' " \
        "AND o.total_cents = #{sentinels.number} AND o.created_at >= DATE '#{sentinels.date.iso8601}'"
    end
  end
end
