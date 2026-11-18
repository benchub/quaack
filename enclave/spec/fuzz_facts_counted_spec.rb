# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/fuzz/facts"

# Task 20261113-210241-1: the integers a count is compared with, which a
# spread world's copy counts come from. Only count(*) or count(x) with no
# window, alone or as a scalar subquery's one target with no GROUP BY.
RSpec.describe Quaack::Enclave::Fuzz::Facts, "#counted" do
  def counted(sql) = described_class.new([PgQuery.parse(sql).tree.to_h]).counted

  correlated = "(SELECT count(*) FROM s.comments c WHERE c.post_id = p.id)"

  it "reads a correlated count's threshold, on either side" do
    expect(counted("SELECT p.id FROM s.posts p WHERE #{correlated} > 7 AND 2 <= #{correlated}")).to eq([7, 2])
  end

  it "reads a HAVING count's threshold, for count(*) and count(x)" do
    sql = "SELECT u.id FROM s.users u GROUP BY u.id HAVING count(*) >= 3 OR count(u.name) = 9"
    expect(counted(sql)).to eq([3, 9])
  end

  it "reads nothing from a non-count subquery, a grouped one, a window, a distinct count or another aggregate" do
    sql = "SELECT p.id FROM s.posts p WHERE (SELECT q.score FROM s.posts q WHERE q.user_id = p.user_id) > 3 " \
          "AND (SELECT count(*) FROM s.comments c GROUP BY c.post_id LIMIT 1) > 4 " \
          "AND (SELECT count(DISTINCT c.id) FROM s.comments c) > 5 AND p.score > 6 " \
          "AND (SELECT max(c.id) FROM s.comments c WHERE c.post_id = p.id) > 8"
    expect(counted(sql)).to eq([])
    expect(counted("SELECT count(*) OVER () > 2 FROM s.posts p")).to eq([])
  end
end
