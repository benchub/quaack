# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "quaack/enclave/cli"
require "quaack/enclave/store"

# `quaacks teardown --run <run ID>` (README, "Where QUAACK runs"), run
# through the real CLI and its real steps table, with a temporary store
# base. Each run's store holds sentinels, in its entries and in a file name,
# standing in for the production values a real run keeps.
RSpec.describe "quaacks teardown" do
  let(:dir) { Dir.mktmpdir("quaack-teardown") }
  let(:base) { File.join(dir, "runs") }
  let(:out) { StringIO.new }
  let(:sentinels) { LeakCheck::Sentinels.new }

  after do
    FileUtils.chmod_R("u+rwx", dir)
    FileUtils.rm_rf(dir)
  end

  def teardown(*args)
    Quaack::Enclave::CLI.new(stdin: StringIO.new, out:, store_base: base).run(["teardown", *args])
  end

  # A run holding the sentinels, the way a real run holds production values.
  def planted_run
    store = Quaack::Enclave::Store.create(base:)
    s = sentinels
    store.write("query", "SELECT 1 WHERE a = '#{s.text}' AND b = #{s.number}")
    store.write("literals", [s.text, s.number, s.date.iso8601])
    File.write(File.join(store.path, "#{s.word}.json"), "[#{s.json}]")
    store
  end

  # What the run's files hold, to show the sentinels really were there.
  def expect_exposed(path, kinds = %i[text number word json])
    held = Dir.children(path).map { "#{it}\n#{File.read(File.join(path, it))}" }.join("\n")
    expect(LeakCheck.findings(sentinels, stdout: held).map(&:sentinel)).to include(*kinds)
  end

  def teardown_line(run_id, store)
    %({"type":"teardown","run_id":"#{run_id}","store":"#{store}","next_step":"destroy_run_server"}\n)
  end

  def done = %({"type":"done"}\n)
  def error_line(rule) = %({"type":"error","step":"teardown","rule":"#{rule}"}\n)

  it "deletes the run's store directory and tells the operator to destroy the run server" do
    store = planted_run
    other = Quaack::Enclave::Store.create(base:)
    expect_exposed(store.path)

    expect(teardown("--run", store.run_id)).to eq(0)

    expect(out.string).to eq(teardown_line(store.run_id, "deleted") + done)
    expect(File.exist?(store.path)).to be(false)
    expect(Dir.children(base)).to eq([other.run_id])
    expect_no_leaks(sentinels, stdout: out.string)
  end

  it "succeeds for a run that's already gone, and says so" do
    store = planted_run
    expect(teardown("--run", store.run_id)).to eq(0)
    out.truncate(0) && out.rewind

    expect(teardown("--run", store.run_id)).to eq(0)
    expect(out.string).to eq(teardown_line(store.run_id, "already_gone") + done)
  end

  it "refuses a missing or malformed run ID, or a bare one, as usage, and deletes nothing" do
    store = planted_run
    outside = File.join(dir, store.run_id).tap { Dir.mkdir(it, 0o700) }
    [[], ["--run"], ["--run", sentinels.word], ["--run", "../#{store.run_id}"], [store.run_id],
     ["--run", store.run_id, "--keep"]].each do |args|
      out.truncate(0) && out.rewind
      expect(teardown(*args)).to eq(64), "args #{args.inspect}"
      expect(out.string).to eq(error_line("usage")), "args #{args.inspect}"
    end
    expect(File.directory?(store.path)).to be(true)
    expect(File.directory?(outside)).to be(true)
  end

  it "refuses a run path that isn't a run directory as bad_run, and leaves it and what it points to" do
    outside = File.join(dir, sentinels.word).tap { Dir.mkdir(it, 0o700) }
    File.write(File.join(outside, "#{sentinels.word}.json"), JSON.generate([sentinels.text]))
    FileUtils.mkdir_p(base)
    linked = File.join(base, "20260923T221500Z-00000001").tap { File.symlink(outside, it) }
    loose = planted_run.path.tap { File.chmod(0o755, it) }

    [linked, loose].each do |path|
      out.truncate(0) && out.rewind
      expect(teardown("--run", File.basename(path))).to eq(70), path
      expect(out.string).to eq(error_line("bad_run")), path
      expect_no_leaks(sentinels, stdout: out.string, why: path)
    end
    expect(File.symlink?(linked)).to be(true)
    expect(Dir.children(outside)).to eq(["#{sentinels.word}.json"])
    expect(File.directory?(loose)).to be(true)
  end

  it "sends teardown_failed, with no path or value, when the directory can't be deleted" do
    store = planted_run
    locked = File.join(store.path, sentinels.word).tap { Dir.mkdir(it) }
    File.write(File.join(locked, "#{sentinels.text}.json"), JSON.generate([sentinels.number]))
    File.chmod(0o500, locked)

    expect(teardown("--run", store.run_id)).to eq(70)
    expect(out.string).to eq(error_line("teardown_failed"))
    expect_no_leaks(sentinels, stdout: out.string)
  end

  # The way the operator runs it on the jump server, after intake: the
  # installed quaacks in its own process, outside Bundler, with HOME a
  # temporary directory.
  describe "the installed quaacks" do
    let(:quaacks) { LeakCheck::Quaacks.new }

    after { quaacks.remove }

    it "tears down the run intake started, printing no production literal" do
      query = File.join(quaacks.home, "q.sql").tap { File.write(it, "SELECT 1 WHERE 'x' = '#{sentinels.text}'") }
      plan = File.join(quaacks.home, "plan.json")
      File.write(plan, File.read(File.join(__dir__, "fixtures", "plans", "sentinel_literals.json")))
      intake = quaacks.run("intake", "--query", query, "--plan", plan, "--server", "prod-db-3")
      expect(intake.status.exitstatus).to eq(0), intake.stdout
      run_id = quaacks.runs.fetch(0)
      expect_exposed(File.join(quaacks.store_base, run_id), %i[text])

      outcome = quaacks.run("teardown", "--run", run_id)

      expect(outcome.status.exitstatus).to eq(0), outcome.stdout
      expect(outcome.stderr).to eq("")
      expect(outcome.stdout).to eq(teardown_line(run_id, "deleted") + done)
      expect(quaacks.runs).to eq([])
      expect_no_leaks(sentinels, outcome)
    end
  end
end
