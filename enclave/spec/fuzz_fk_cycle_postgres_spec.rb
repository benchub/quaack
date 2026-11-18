# frozen_string_literal: true

require "quaack/enclave/fuzz"

# Wrong rewrites over foreign keys that form a cycle, from the fk_cycle
# corpus that went with ScenarioTests (task 20261012-4): fuzz alone must
# disprove each, those on the nullable cycle edge among them, and pass a
# sound one (task 20261012-52), and dropping a Rails where.missing anti
# join on the nullable edge, which needs both edges filled (20261118-185846-1).
RSpec.describe Quaack::Enclave::Fuzz do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:stop) { Quaack::Enclave::Fuzz::StopRule.trials(300) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.accounts (id integer PRIMARY KEY, name text NOT NULL, course_template_id integer);
      CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts,
        title text NOT NULL);
      ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
    SQL
  end

  def verdict(original, candidate) = described_class.run(conn, original, candidate, stop:).verdict

  anti = "SELECT a.id FROM fx.accounts a LEFT JOIN fx.courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id"

  it "passes NOT EXISTS for an anti join on the kept edge" do
    expect(verdict(anti, "SELECT a.id FROM fx.accounts a WHERE NOT EXISTS " \
                         "(SELECT 1 FROM fx.courses c WHERE c.account_id = a.id) ORDER BY a.id")).to eq(:passed)
  end

  {
    "an anti join turned into an inner join" =>
      [anti, "SELECT a.id FROM fx.accounts a JOIN fx.courses c ON c.account_id = a.id " \
             "WHERE c.id IS NULL ORDER BY a.id"],
    "accounts with no courses read as accounts with no template (the nullable edge)" =>
      [anti, "SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NULL ORDER BY a.id"],
    "a template looked up by account_id instead of the nullable edge" =>
      ["SELECT c.id, a.id FROM fx.courses c JOIN fx.accounts a ON a.course_template_id = c.id ORDER BY c.id, a.id",
       "SELECT c.id, a.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id ORDER BY c.id, a.id"],
    "IS NULL on the nullable edge flipped to IS NOT NULL" =>
      ["SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NULL ORDER BY a.id",
       "SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NOT NULL ORDER BY a.id"],
    "a Rails where.missing anti join on the nullable edge dropped" =>
      ["SELECT a.id FROM fx.accounts a LEFT JOIN fx.courses c ON c.id = a.course_template_id " \
       "WHERE c.id IS NULL ORDER BY a.id",
       "SELECT a.id FROM fx.accounts a ORDER BY a.id"]
  }.each do |name, (original, candidate)|
    it "disproves #{name}" do
      expect(verdict(original, candidate)).to eq(:disproved)
    end
  end
end
