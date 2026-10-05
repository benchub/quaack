# frozen_string_literal: true

require "fileutils"
require "find"
require "json"
require "stringio"
require "tmpdir"
require "quaack/enclave/cli"
require "quaack/enclave/store"

# `quaacks teardown --run <run ID>` (DESIGN.md, "Where QUAACK runs"), run
# through the real CLI and its real steps table, with a temporary store
# base. Each run's store holds sentinels, in its entries and in a file name,
# standing in for the production values a real run keeps.
RSpec.describe "quaacks teardown" do
  let(:dir) { Dir.mktmpdir("quaack-teardown") }
  let(:base) { File.join(dir, "runs") }
  let(:out) { StringIO.new }
  let(:sentinels) { LeakCheck::Sentinels.new }

  # Opens each directory a test locked, without following symlinks, so
  # the whole tree can go.
  after do
    Find.find(dir) { File.chmod(0o700, it) if File.lstat(it).directory? }
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

  it "refuses a dangling symlink at the run path as bad_run, and leaves it" do
    FileUtils.mkdir_p(base)
    dangling = File.join(base, "20260923T221500Z-00000004").tap { File.symlink(File.join(dir, sentinels.word), it) }

    expect(teardown("--run", File.basename(dangling))).to eq(70)
    expect(out.string).to eq(error_line("bad_run"))
    expect(File.symlink?(dangling)).to be(true)
  end

  # The run path is swapped for a file after Store.open checked it and
  # before the delete, as another process could.
  it "refuses a run path swapped for a file after it was opened as bad_run, and leaves it" do
    store = planted_run
    allow(Quaack::Enclave::Store).to receive(:open).and_wrap_original do |open, *args, **options|
      open.call(*args, **options).tap do |opened|
        FileUtils.rm_r(opened.path)
        File.write(opened.path, "swapped")
      end
    end

    expect(teardown("--run", store.run_id)).to eq(70)
    expect(out.string).to eq(error_line("bad_run"))
    expect(File.read(store.path)).to eq("swapped")
  end

  # The base closes to search after Store.open refused the run path, so
  # the recheck of the path raises EACCES. The refusal still decides.
  it "keeps open's bad_run when the recheck of the run path can't look" do
    FileUtils.mkdir_p(base)
    dangling = File.join(base, "20260923T221500Z-00000004").tap { File.symlink(File.join(dir, sentinels.word), it) }
    allow(Quaack::Enclave::Store).to receive(:open).and_wrap_original do |open, *args, **options|
      open.call(*args, **options)
    ensure
      File.chmod(0o000, base)
    end

    expect(teardown("--run", File.basename(dangling))).to eq(70)
    expect(out.string).to eq(error_line("bad_run"))
  ensure
    File.chmod(0o700, base)
  end

  # Two teardowns of one run at once: the stand-in rm_r deletes the run
  # first, as the other call would, and then runs the real rm_r.
  it "succeeds as already_gone when the run vanishes while it's being deleted" do
    store = planted_run
    allow(FileUtils).to receive(:rm_r).and_wrap_original do |rm_r, path, **options|
      rm_r.call(path)
      rm_r.call(path, **options)
    end

    expect(teardown("--run", store.run_id)).to eq(0)
    expect(out.string).to eq(teardown_line(store.run_id, "already_gone") + done)
  end

  it "sends bad_store_base, with no path, when the store base is a file or can't be searched" do
    store = planted_run
    file = File.join(dir, sentinels.word).tap { File.write(it, sentinels.text) }

    # The base is a file, and then the base sits under a directory closed
    # to search.
    [file, base].each do |bad_base|
      File.chmod(0o000, dir) if bad_base == base
      cli_out = StringIO.new
      cli = Quaack::Enclave::CLI.new(stdin: StringIO.new, out: cli_out, store_base: bad_base)
      expect(cli.run(["teardown", "--run", store.run_id])).to eq(70), bad_base
      expect(cli_out.string).to eq(error_line("bad_store_base")), bad_base
      expect_no_leaks(sentinels, stdout: cli_out.string, why: bad_base)
    end
  ensure
    File.chmod(0o700, dir)
  end

  # The link's target is named for a sentinel, so a line that named it
  # would show.
  it "sends bad_store_base when the store base is a symlink, and deletes nothing through it" do
    store = planted_run
    target = File.join(dir, sentinels.word)
    File.rename(base, target)
    File.symlink(target, base)
    expect_exposed(File.join(target, store.run_id))

    expect(teardown("--run", store.run_id)).to eq(70)
    expect(out.string).to eq(error_line("bad_store_base"))
    expect(File.directory?(File.join(target, store.run_id))).to be(true)
    expect_no_leaks(sentinels, stdout: out.string)
  end

  # The CLI's error line never reads an error's cause, but a caller that
  # did would find the Store::Error, which names the run's directory.
  it "raises each rule's error with no cause" do
    store = planted_run
    FileUtils.mkdir_p(base)
    File.write(File.join(base, "20260923T221500Z-00000002"), "")
    locked = File.join(store.path, "locked").tap { Dir.mkdir(it) }
    File.write(File.join(locked, "kept.json"), "[]")
    File.chmod(0o500, locked)
    { "20260923T221500Z-00000002" => [base, "bad_run"], store.run_id => [base, "teardown_failed"],
      "20260923T221500Z-00000003" => [File.join(base, "20260923T221500Z-00000002"), "bad_store_base"] }
      .each do |run_id, (store_base, rule)|
      expect { Quaack::Enclave::Steps::Teardown.call(run_id:, store_base:) }
        .to raise_error(Quaack::Enclave::Steps::Teardown::Error) { |e| expect([e.rule, e.cause]).to eq([rule, nil]) }
    end
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

    describe "with destroy_command in the quaacks config" do
      let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base).tap { it.write("server", "prod 1") } }
      let(:gone) { File.join(quaacks.home, "gone") }

      def configure(command)
        FileUtils.mkdir_p(File.join(quaacks.home, ".quaack"))
        File.write(File.join(quaacks.home, ".quaack", "config.json"), JSON.generate("destroy_command" => command))
      end

      it "destroys the run server with the server and the run, then deletes the store, with nothing left to do" do
        configure("printf '%s|%s|' {server} {run} > #{gone}; ls #{quaacks.store_base} >> #{gone}")

        outcome = quaacks.run("teardown", "--run", store.run_id)

        line = %({"type":"teardown","run_id":"#{store.run_id}","store":"deleted","next_step":"none"}\n)
        expect(outcome.stdout).to eq("#{line}#{done}")
        expect(File.read(gone)).to eq("prod 1|#{store.run_id}|#{store.run_id}\n")
        expect(quaacks.runs).to eq([])
      end

      it "fails a failing command as destroy_command_failed, without its output, and keeps the store" do
        configure("echo #{sentinels.word}; exit 1")

        outcome = quaacks.run("teardown", "--run", store.run_id)

        expect([outcome.stdout, outcome.status.exitstatus]).to eq([error_line("destroy_command_failed"), 70])
        expect(quaacks.runs).to eq([store.run_id])
        expect_no_leaks(sentinels, outcome)
      end

      # Task 20261004-60: a server entry teardown can't read, here one that
      # isn't JSON and holds a sentinel, so destroy_command never runs.
      it "fails as destroy_command_not_run when it can't read the run's server, and keeps the store" do
        configure("touch #{gone}")
        File.write(File.join(store.path, "server.json"), sentinels.text)

        outcome = quaacks.run("teardown", "--run", store.run_id)

        expect([outcome.stdout, outcome.status.exitstatus]).to eq([error_line("destroy_command_not_run"), 70])
        expect(File.exist?(gone)).to be(false)
        expect(quaacks.runs).to eq([store.run_id])
        expect_no_leaks(sentinels, outcome)
      end

      it "leaves destroying to the operator for a run that's already gone" do
        configure("touch #{gone}")
        run_id = store.run_id
        FileUtils.rm_rf(store.path)

        expect(quaacks.run("teardown", "--run", run_id).stdout).to eq(teardown_line(run_id, "already_gone") + done)
        expect(File.exist?(gone)).to be(false)
      end
    end
  end
end
