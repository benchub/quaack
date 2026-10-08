# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "quaack/enclave/private_files"
require "quaack/enclave/store"
require "quaack/enclave/store/sweep"

# Store.sweep: what each new run does to the store's orphans, the runs an
# intake started and never finished (DESIGN.md's input).
RSpec.describe "Quaack::Enclave::Store.sweep" do
  around do |example|
    Dir.mktmpdir("quaack-sweep-spec") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  let(:store_class) { Quaack::Enclave::Store }
  let(:base) { File.join(@tmp, "runs").tap { Quaack::Enclave::PrivateFiles.make_directories(it) } }
  let(:now) { Time.utc(2026, 10, 8, 12, 0, 0) }

  # A run directory as Store.create makes one, started at time, holding the
  # entries given.
  def run_at(time, *entries)
    run_id = "#{time.utc.strftime("%Y%m%dT%H%M%SZ")}-#{format("%08x", rand(2**32))}"
    Quaack::Enclave::PrivateFiles.make_directory(File.join(base, run_id))
    store = store_class.open(run_id, base:)
    entries.each { store.write(it, "sentinel-orphan-literal") }
    run_id
  end

  def sweep(**) = store_class.sweep(base:, now:, **)

  def runs = Dir.children(base).sort

  it "deletes a run older than a day that never finished intake" do
    orphan = run_at(now - (25 * 3600), "server", "query")
    bare = run_at(now - (3 * 86_400))

    sweep

    expect(runs).not_to include(orphan, bare)
    expect(runs).to eq([])
  end

  it "keeps a run that finished intake, however old" do
    finished = run_at(now - (30 * 86_400), "server", "query", "plan")

    sweep

    expect(runs).to eq([finished])
  end

  it "keeps an unfinished run less than a day old, as one a concurrent intake is still writing" do
    young = run_at(now - (23 * 3600), "server")
    future = run_at(now + 3600)

    sweep

    expect(runs).to eq([young, future].sort)
  end

  it "leaves names that aren't run IDs alone" do
    other = File.join(base, "notes").tap { Dir.mkdir(it, 0o700) }
    file = File.join(base, "20200101T000000Z-0000000z").tap { File.write(it, "x") }

    sweep

    expect(runs).to eq([File.basename(file), File.basename(other)].sort)
  end

  it "won't delete through a symlink, or a run another user owns, and goes on to the rest" do
    target = File.join(@tmp, "elsewhere").tap { Dir.mkdir(it, 0o700) }
    File.write(File.join(target, "keep"), "x")
    link = "20200101T000000Z-00000001"
    File.symlink(target, File.join(base, link))
    theirs = run_at(now - (2 * 86_400))
    orphan = run_at(now - (2 * 86_400))

    sweep(current_uid: Process.euid + 1)
    expect(runs).to eq([link, theirs, orphan].sort)

    sweep
    expect(runs).to eq([link])
    expect(Dir.children(target)).to eq(["keep"])
  end

  it "keeps a run whose plan entry is anything at all, even a symlink" do
    run = run_at(now - (2 * 86_400), "query")
    File.symlink("/nonexistent", File.join(base, run, "plan.json"))

    sweep

    expect(runs).to eq([run])
  end

  it "returns quietly when the base can't be listed or is a symlink" do
    linked = File.join(@tmp, "linked").tap { File.symlink(base, it) }
    run_at(now - (2 * 86_400))

    expect(store_class.sweep(base: File.join(@tmp, "missing"), now:)).to be_nil
    expect(store_class.sweep(base: linked, now:)).to be_nil
    expect(runs.size).to eq(1)
  end
end
