# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/scenarios"
require "quaack/enclave/scenario_tests"

# A standing trust-boundary guard (20261010-47): rewrite-test's report
# crosses the boundary as counts, shapes and fixed words, never values. So
# when only a query's literals change (a LIMIT, an OFFSET, an IN list's
# values, BETWEEN's bounds, a count threshold) and nothing else, everything
# it reports must come out byte-identical: the results, the untested set
# and its states, the retries, dropped, the fixture loads, S1's diagnostics,
# and the spills (which feed the loads).
#
# Each family runs one query shape over several literal values. A literal
# can still decide what a fixture can reach: no scenario has more than one
# child per parent, so count(*) > 0 is reachable and count(*) > 1 isn't,
# and LIMIT 0 returns nothing. Values across such a step are a different
# question, outside this guard; each family's values stay on one side of it.
RSpec.describe "Reports across literals" do
  let(:conn) { racetrack_and_arena.arena.connection }

  # The corpus's schema, read from its spec so as not to load its examples.
  schema = File.read(File.join(__dir__, "vacuity_guard_corpus_postgres_spec.rb"))[/SCHEMA = <<~SQL\n(.*?)\n  SQL\n/m, 1]
               .gsub(/^    /, "")

  before do
    conn.exec(schema)
  end

  # Every field of the report, the paths into the parse aside (they stay in
  # the enclave), and how many spills each scenario has.
  def outgoing(sql, candidates)
    report = Quaack::Enclave::ScenarioTests.run(conn, sql, candidates)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    builder.build
    report.to_h.except(:untested_paths).merge(results: report.results.map(&:to_h),
                                              spills: builder.spills.transform_values(&:size))
  end

  count = ->(child, parent, key) { "(SELECT count(*) FROM fx.#{child} WHERE fx.#{child}.#{key} = fx.#{parent}.id)" }
  posts = "SELECT fx.posts.id FROM fx.posts WHERE"
  users = "SELECT fx.users.id FROM fx.users WHERE"

  families = {
    "LIMIT" => [[1, 2, 3, 5, 10, 25, 100], lambda { |n|
      ["#{posts} fx.posts.published = true AND fx.posts.score > 3 LIMIT #{n}",
       "#{posts} fx.posts.published AND fx.posts.score > 3 LIMIT #{n}"]
    }],
    "ORDER BY ... LIMIT" => [[2, 3, 5, 10, 25, 100], lambda { |n|
      ["#{posts} fx.posts.published = true AND fx.posts.score > 3 ORDER BY fx.posts.id LIMIT #{n}",
       "#{posts} fx.posts.published AND fx.posts.score > 3 ORDER BY fx.posts.id LIMIT #{n}"]
    }],
    "OFFSET" => [[2, 3, 5, 20, 40], lambda { |n|
      ["#{posts} fx.posts.published = true AND fx.posts.score > 3 ORDER BY fx.posts.id LIMIT 20 OFFSET #{n}",
       "#{posts} fx.posts.published AND fx.posts.score > 3 ORDER BY fx.posts.id LIMIT 20 OFFSET #{n}"]
    }],
    "BETWEEN bounds" => [[0, 1, 5, 50, 1000], lambda { |n|
      ["#{posts} fx.posts.score BETWEEN #{n} AND #{n + 7}",
       "#{posts} fx.posts.score >= #{n} AND fx.posts.score <= #{n + 7}"]
    }],
    "BETWEEN bounds, repeated (the search)" => [[0, 1, 5, 50, 1000], lambda { |n|
      ["#{posts} fx.posts.score BETWEEN #{n} AND #{n + 7} AND fx.posts.score BETWEEN #{n} AND #{n + 7}",
       "#{posts} fx.posts.score BETWEEN #{n} AND #{n + 7}"]
    }],
    "IN-list values" => [[1, 2, 7, 100], lambda { |n|
      ["#{posts} fx.posts.user_id IN (#{n}, #{n + 3}, #{n + 9}) AND fx.posts.published",
       "#{posts} (fx.posts.user_id = #{n} OR fx.posts.user_id = #{n + 3} OR fx.posts.user_id = #{n + 9}) " \
       "AND fx.posts.published"]
    }],
    "IN-list values, repeated (the search)" => [[1, 2, 7, 100], lambda { |n|
      list = "(#{n}, #{n + 3}, #{n + 9})"
      ["#{posts} fx.posts.score IN #{list} AND fx.posts.score IN #{list}", "#{posts} fx.posts.score IN #{list}"]
    }],
    "count(*) > threshold" => [[4, 5, 7, 10], lambda { |n|
      c = count.call("posts", "users", "user_id")
      ["#{users} #{c} > #{n}", "#{users} #{c} >= #{n}"]
    }],
    "count(*) = threshold" => [[2, 3, 7, 11], lambda { |n|
      c = count.call("posts", "users", "user_id")
      ["#{users} #{c} = #{n}", "#{users} #{c} = #{n} AND true"]
    }],
    "IN list and count(*) >= threshold" => [[3, 4, 7, 10], lambda { |n|
      c = count.call("comments", "posts", "post_id")
      ["#{posts} fx.posts.user_id IN (1, 2) AND #{c} >= #{n}",
       "#{posts} fx.posts.user_id IN (1, 2) AND #{c} > #{n} - 1"]
    }],
    "HAVING count() > threshold" => [[2, 3, 4], lambda { |n|
      join = "SELECT fx.users.id FROM fx.users %s JOIN fx.posts ON fx.posts.user_id = fx.users.id GROUP BY fx.users.id"
      ["#{format(join, "LEFT")} HAVING count(fx.posts.id) > #{n}",
       "#{format(join, "")} HAVING count(fx.posts.id) > #{n}"]
    }]
  }.freeze

  families.each do |name, (values, make)|
    it "reports the same for every #{name} value" do
      by_value = values.to_h { |n| [n, outgoing(*make.call(n).then { [it.first, it.drop(1)] })] }
      # A repeated condition is redundant, so it stays untested and the
      # search runs on it.
      expect(by_value.values.first[:untested_states]).not_to be_empty if name.end_with?("(the search)")
      expect(by_value.values.uniq.size).to eq(1), by_value.map { |n, report| "#{n}: #{report}" }.join("\n")
    end
  end
end
