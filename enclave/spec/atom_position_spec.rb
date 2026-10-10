# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/atom_position"
require "quaack/enclave/predicate_atoms"

# DESIGN.md's unchanged-atoms: an untested atom is unchanged only when the
# rewrite has it at the same structural position. Each example names the
# atoms by their redacted shapes and says which come out unchanged.
RSpec.describe Quaack::Enclave::AtomPosition do
  # Any table has these columns; only the atoms' paths and shapes are used.
  let(:columns) { Class.new { def fetch(*) = %w[id a b x k kind state t_id u_id] }.new }

  # { shape => unchanged? } for the original's atoms with these shapes, all
  # taken as untested.
  def verdicts(original, candidate, *shapes)
    atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(original), column_names: columns)
    atoms = atoms.select { shapes.include?(it.shape) }
    expect(atoms.map(&:shape)).to eq(shapes), "#{shapes} aren't all atoms of #{original}"
    shapes.zip(described_class.unchanged(original, candidate, atoms.map(&:path))).to_h
  end

  let(:from) { "FROM public.t JOIN public.u ON u.t_id = t.id" }

  describe "an atom in the same place of the same scope" do
    it "is unchanged when the rewrite changed a different top-level conjunct" do
      original = "SELECT t.id #{from} WHERE t.a = $1 AND t.b = $2 AND t.b IN ($3, $4)"
      candidate = "SELECT t.id #{from} WHERE t.a = $1 AND t.b = $2"

      expect(verdicts(original, candidate, "t.a = $1", "t.b = $2", "t.b IN ($3, $4)"))
        .to eq("t.a = $1" => true, "t.b = $2" => true, "t.b IN ($3, $4)" => false)
    end

    # A new filter may hide every row the untested atom never exercised, so
    # any new atom in the scope, in the WHERE or an ON, changes every atom.
    it "is changed when the rewrite added a filter anywhere in the scope, whatever it names" do
      plain = "SELECT t.id FROM public.t WHERE t.a = $1"
      joined = "SELECT t.id FROM public.t JOIN public.u ON u.id = t.uid"
      [[plain, "#{plain} AND t.deleted_at IS NULL"], [plain, "#{plain} AND t.b > 0"],
       ["SELECT t.id #{from} WHERE t.a = $1", "SELECT t.id #{from} WHERE t.a = $1 AND u.x = $2"],
       ["#{joined} WHERE t.a = $1", "#{joined} AND u.x = 2 WHERE t.a = $1"]].each do |original, candidate|
        expect(verdicts(original, candidate, "t.a = $1")).to eq("t.a = $1" => false), candidate
      end
    end

    it "is unchanged in a join's ON when the same join keeps it" do
      original = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id AND u.x > $1 WHERE t.a = $2"
      candidate = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id AND u.x > $1 WHERE t.a = $2"
      original = "#{original} AND t.b = $3"

      expect(verdicts(original, candidate, "u.x > $1", "t.a = $2")).to eq("u.x > $1" => true, "t.a = $2" => true)
    end
  end

  describe "an atom whose position moved" do
    it "is changed when the same text now sits under a new self-join subquery (key_in_self_join's shape)" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1"
      candidate = "SELECT t.id FROM public.t WHERE EXISTS (SELECT 1 FROM public.u WHERE u.t_id = t.id AND t.a = $1)"

      expect(verdicts(original, candidate, "t.a = $1")).to eq("t.a = $1" => false)
    end

    it "is changed when it was inside a subquery and is top-level now" do
      original = "SELECT t.id FROM public.t WHERE t.id IN (SELECT t2.id FROM public.t t2 WHERE t2.a = $1)"
      candidate = "SELECT t.id FROM public.t WHERE t.a = $1"

      expect(verdicts(original, candidate, "t2.a = $1")).to eq("t2.a = $1" => false)
    end

    it "is changed when it moved from the WHERE into a join's ON" do
      original = "SELECT t.id #{from} WHERE u.x = $1"
      candidate = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id AND u.x = $1"

      expect(verdicts(original, candidate, "u.x = $1")).to eq("u.x = $1" => false)
    end

    it "is changed when it moved from one join's ON to another" do
      original = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id AND u.x = $1 JOIN public.v ON v.u_id = u.id"
      candidate = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id JOIN public.v ON v.u_id = u.id AND u.x = $1"

      expect(verdicts(original, candidate, "u.x = $1")).to eq("u.x = $1" => false)
    end

    it "is changed when an OR arm beside it changed, and unchanged when the whole OR is the same" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1 OR t.b = $2"

      expect(verdicts(original, "SELECT t.id FROM public.t WHERE t.a = $1 OR t.b = $2", "t.a = $1"))
        .to eq("t.a = $1" => true)
      expect(verdicts(original, "SELECT t.id FROM public.t WHERE t.a = $1 OR t.b = $3", "t.a = $1"))
        .to eq("t.a = $1" => false)
      expect(verdicts(original, "SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $2", "t.a = $1"))
        .to eq("t.a = $1" => false)
    end

    it "is changed when a NOT now wraps it" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1"
      candidate = "SELECT t.id FROM public.t WHERE NOT t.a = $1"

      expect(verdicts(original, candidate, "t.a = $1")).to eq("t.a = $1" => false)
    end

    it "is changed when a dropped duplicate leaves one copy" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1 AND t.a = $1"
      candidate = "SELECT t.id FROM public.t WHERE t.a = $1"

      expect(verdicts(original, candidate, "t.a = $1", "t.a = $1")).to eq("t.a = $1" => false)
    end
  end

  describe "an ON that a rewrite changed" do
    it "changes the ON conjunct and, with a new atom in the scope, the WHERE atom too" do
      original = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id AND u.x > $1 WHERE t.a = $2"
      candidate = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id AND u.y > $3 WHERE t.a = $2"

      expect(verdicts(original, candidate, "u.x > $1", "t.a = $2")).to eq("u.x > $1" => false, "t.a = $2" => false)
    end
  end

  describe "a rewrite that changes the scope" do
    it "changes every atom when the rewrite reuses an alias for another table" do
      original = "SELECT o.id FROM public.orders o WHERE o.kind = $1"
      candidate = "SELECT o.id FROM public.customers o WHERE o.kind = $1"

      expect(verdicts(original, candidate, "o.kind = $1")).to eq("o.kind = $1" => false)
    end

    it "changes every atom when the join type or order changes" do
      original = "SELECT t.id FROM public.t JOIN public.u ON u.t_id = t.id WHERE t.a = $1"

      expect(verdicts(original, "SELECT t.id FROM public.t LEFT JOIN public.u ON u.t_id = t.id WHERE t.a = $1",
                      "t.a = $1"))
        .to eq("t.a = $1" => false)
      expect(verdicts(original, "SELECT t.id FROM public.u JOIN public.t ON u.t_id = t.id WHERE t.a = $1", "t.a = $1"))
        .to eq("t.a = $1" => false)
    end

    it "changes every atom when the select list, ORDER BY, or LIMIT differs" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1 ORDER BY t.id LIMIT 5"

      ["SELECT t.b FROM public.t WHERE t.a = $1 ORDER BY t.id LIMIT 5",
       "SELECT t.id FROM public.t WHERE t.a = $1 ORDER BY t.b LIMIT 5",
       "SELECT t.id FROM public.t WHERE t.a = $1 ORDER BY t.id LIMIT 6"].each do |candidate|
        expect(verdicts(original, candidate, "t.a = $1")).to eq("t.a = $1" => false), candidate
      end
    end

    it "changes every atom when a placeholder number differs, though the shapes read alike" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $2"
      candidate = "SELECT t.id FROM public.t WHERE t.a = $2 AND t.b = $1"

      expect(verdicts(original, candidate, "t.a = $1", "t.b = $2")).to eq("t.a = $1" => false, "t.b = $2" => false)
    end
  end

  describe "what the test refuses to classify" do
    let(:original) { "SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $2" }

    it "changes every atom for a rewrite with a set operation, even when each atom's text is copied" do
      candidate = "SELECT t.id FROM public.t WHERE t.a = $1 UNION SELECT t.id FROM public.t WHERE t.b = $2"

      expect(verdicts(original, candidate, "t.a = $1", "t.b = $2")).to eq("t.a = $1" => false, "t.b = $2" => false)
    end

    it "changes every atom of a query that has one of these itself, though the rewrite is the same query" do
      ["SELECT s.id FROM (SELECT t.id FROM public.t WHERE t.a = $1) s WHERE s.id > $2",
       "SELECT t.id FROM public.t, LATERAL (SELECT 1 WHERE t.a = $1) l WHERE t.b = $2",
       "SELECT t.id FROM public.t, generate_series(1, $1) g WHERE t.b = $2",
       "SELECT t.id FROM public.t WHERE t.b = $2 AND t.a IN (VALUES ($1), ($3))",
       "SELECT t.id FROM public.t WHERE t.b = $2 AND t.a IN (SELECT u.a FROM public.u WHERE u.x = $1 " \
       "UNION SELECT u.a FROM public.u WHERE u.y = $3)"].each do |sql|
        atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: columns)
        top = atoms.select { it.path.size <= 8 }

        expect(top).not_to be_empty, sql
        expect(described_class.unchanged(sql, sql, top.map(&:path))).to all(be(false)), sql
      end
    end

    it "changes every atom for a rewrite with a WITH, a subquery in FROM, or LATERAL" do
      ["WITH w AS (SELECT t.id FROM public.t WHERE t.a = $1) " \
       "SELECT w.id FROM w JOIN public.t ON t.id = w.id WHERE t.b = $2",
       "SELECT s.id FROM (SELECT t.id, t.b FROM public.t WHERE t.a = $1) s WHERE s.b = $2",
       "SELECT t.id FROM public.t, LATERAL (SELECT 1 WHERE t.a = $1) l WHERE t.b = $2"].each do |candidate|
        expect(verdicts(original, candidate, "t.a = $1", "t.b = $2").values).to eq([false, false]), candidate
      end
    end

    it "changes every atom when the original itself has a set operation or a WITH" do
      with = "WITH w AS (SELECT 1) SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $2"
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(with), column_names: columns)

      expect(described_class.unchanged(with, with, atoms.map(&:path))).to all(be(false))
    end

    it "changes every atom for SQL that doesn't parse" do
      expect(described_class.unchanged(original, "SELEC", [["stmts", 0]])).to eq([false])
    end

    it "changes an atom it can't place: one in the select list's CASE or a JOIN ... USING marker" do
      sql = "SELECT CASE WHEN t.a = $1 THEN 1 END FROM public.t JOIN public.u USING (id) WHERE t.b = $2"
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(sql), column_names: columns)
      verdict = atoms.map(&:shape).zip(described_class.unchanged(sql, sql, atoms.map(&:path))).to_h

      expect(verdict).to include("t.b = $2" => true)
      expect(verdict.except("t.b = $2").values).to all(be(false))
    end
  end

  describe "a rewrite that adds, wraps, or restructures the scope" do
    it "changes every atom when it adds a WITH, an INTO, or a locking clause" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1"

      ["WITH w AS (SELECT 1) SELECT t.id FROM public.t WHERE t.a = $1",
       "SELECT t.id INTO public.copy FROM public.t WHERE t.a = $1",
       "SELECT t.id FROM public.t WHERE t.a = $1 FOR UPDATE"].each do |candidate|
        expect(verdicts(original, candidate, "t.a = $1")).to eq("t.a = $1" => false), candidate
      end
    end

    it "changes an untested atom that shares a placeholder with a new predicate (a copied filter)" do
      original = "SELECT t.id #{from} WHERE t.id = u.id AND t.a < $1 AND t.b = $2"
      candidate = "SELECT t.id #{from} WHERE t.id = u.id AND t.a < $1 AND u.a < $1 AND t.b = $2"

      expect(verdicts(original, candidate, "t.a < $1", "t.b = $2")).to eq("t.a < $1" => false, "t.b = $2" => false)
    end

    it "changes every atom when the new predicate shares a column name with only some" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $2"
      candidate = "SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $2 AND t.b IS NOT NULL"

      expect(verdicts(original, candidate, "t.a = $1", "t.b = $2")).to eq("t.a = $1" => false, "t.b = $2" => false)
    end
  end

  describe ".unchanged_shapes" do
    it "keeps a shape only when every untested atom with that shape is unchanged" do
      original = "SELECT t.id FROM public.t WHERE t.a = $1 AND (t.a = $1 OR t.b = $2) AND t.b = $3"
      candidate = "SELECT t.id FROM public.t WHERE t.a = $1 AND t.b = $3"
      atoms = Quaack::Enclave::PredicateAtoms.extract(PgQuery.parse(original), column_names: columns)
      shapes = atoms.map(&:shape)

      expect(shapes).to eq(["t.a = $1", "t.a = $1", "t.b = $2", "t.b = $3"])
      expect(described_class.unchanged(original, candidate, atoms.map(&:path))).to eq([true, false, false, true])
      expect(described_class.unchanged_shapes(original, candidate, shapes, atoms.map(&:path)))
        .to eq(["t.b = $3"])
    end
  end

  describe "a nested atom" do
    it "is unchanged only with the top-level atom that holds it" do
      query = lambda do |key|
        "SELECT t.id FROM public.t WHERE t.b = $2 AND EXISTS (SELECT 1 FROM public.u WHERE u.x = $1 AND u.k = #{key})"
      end
      original = same = query.call("t.id")
      edited = query.call("t.a")

      expect(verdicts(original, same, "u.x = $1")).to eq("u.x = $1" => true)
      expect(verdicts(original, edited, "u.x = $1")).to eq("u.x = $1" => false)
    end
  end
end
