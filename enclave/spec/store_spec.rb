# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "timeout"
require "tmpdir"
require "quaack/enclave/store"

# Stands in for a real production value kept in the store. It must never show
# up in an error message.
STORE_SENTINEL = "SENTINEL-4d91e7-customers.ssn"

RSpec.describe Quaack::Enclave::Store do
  around do |example|
    Dir.mktmpdir("quaack-store-spec") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  let(:base) { File.join(@tmp, "runs") }
  let(:store) { described_class.create(base:) }

  def mode(path) = File.lstat(path).mode & 0o7777

  def with_umask(mask)
    old = File.umask(mask)
    yield
  ensure
    File.umask(old)
  end

  def expect_store_error(pattern = nil, &)
    expect(&).to raise_error(described_class::Error) do |error|
      expect(error.message).to match(pattern) if pattern
      expect(error.message).not_to include(STORE_SENTINEL)
      expect(error.cause).to be_nil
    end
  end

  it "is loaded by quaack/enclave" do
    code = 'require "quaack/enclave"; print Quaack::Enclave::Store::RUN_ID'
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", code)

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq(described_class::RUN_ID.to_s)
  end

  describe ".create" do
    it "names the run with a UTC timestamp and eight random hex characters" do
      before = Time.now.utc
      run_id = store.run_id
      after = Time.now.utc

      expect(run_id).to match(/\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/)
      stamp = Time.strptime("#{run_id[0, 16]} UTC", "%Y%m%dT%H%M%SZ %Z")
      expect(stamp).to be_between(Time.at(before.to_i).utc, after)
    end

    it "gives each run its own ID and directory" do
      ids = Array.new(5) { described_class.create(base:).run_id }

      expect(ids.uniq.size).to eq(5)
      expect(Dir.children(base).sort).to eq(ids.sort)
    end

    it "makes the run directory under the base, mode 0700" do
      expect(store.path).to eq(File.join(base, store.run_id))
      expect(File.directory?(store.path)).to be(true)
      expect(mode(store.path)).to eq(0o700)
    end

    it "makes a missing base, and each missing directory above it, mode 0700" do
      deep = File.join(@tmp, "home", ".quaack", "runs")
      described_class.create(base: deep)

      expect([File.join(@tmp, "home"), File.join(@tmp, "home", ".quaack"), deep].map { mode(it) })
        .to eq([0o700, 0o700, 0o700])
    end

    it "sets the run directory to 0700 whatever the umask is" do
      [0o000, 0o277].each do |mask|
        path = with_umask(mask) { described_class.create(base:).path }

        expect(mode(path)).to eq(0o700), "umask #{mask.to_s(8)} gave #{mode(path).to_s(8)}"
      end
    end

    it "sets a missing base to 0700 whatever the umask is" do
      with_umask(0o000) { described_class.create(base:) }

      expect(mode(base)).to eq(0o700)
    end

    it "defaults the base to ~/.quaack/runs" do
      home = File.join(@tmp, "home")
      Dir.mkdir(home)
      code = 'require "quaack/enclave/store"; print Quaack::Enclave::Store.create.path'
      out, err, status = Open3.capture3({ "HOME" => home }, RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"),
                                        "-e", code)

      expect(status).to be_success, "stderr was #{err}"
      expect(File.dirname(out)).to eq(File.join(home, ".quaack", "runs"))
      expect(File.directory?(out)).to be(true)
      expect([File.join(home, ".quaack"), File.dirname(out)].map { mode(it) }).to eq([0o700, 0o700])
    end
  end

  describe "#write and #read" do
    it "keeps a result as a JSON file named for the entry, and reads it back" do
      result = { "query" => "SELECT 1", "plan" => [{ "Node Type" => "Result" }], "rows" => 1 }
      store.write("inputs", result)

      expect(JSON.parse(File.read(File.join(store.path, "inputs.json")))).to eq(result)
      expect(store.read("inputs")).to eq(result)
    end

    it "takes the entry name as a Symbol too" do
      store.write(:literals, ["a"])

      expect(store.read(:literals)).to eq(["a"])
      expect(store.read("literals")).to eq(["a"])
    end

    it "makes each file mode 0600 whatever the umask is" do
      [0o000, 0o277].each do |mask|
        with_umask(mask) { store.write("placeholder_map", { "$1" => "x" }) }
        file = File.join(store.path, "placeholder_map.json")

        expect(mode(file)).to eq(0o600), "umask #{mask.to_s(8)} gave #{mode(file).to_s(8)}"
      end
    end

    it "replaces an entry that's already there, leaving no temp files" do
      store.write("inputs", { "v" => 1 })
      store.write("inputs", { "v" => 2 })

      expect(store.read("inputs")).to eq("v" => 2)
      expect(Dir.children(store.path)).to eq(["inputs.json"])
    end

    it "keeps results nested far deeper than JSON's default limit" do
      deep = 500.times.reduce("leaf") { |inner, _| { "Plans" => [inner] } }
      store.write("plan", deep)

      expect(store.read("plan")).to eq(deep)
    end

    it "rejects entry names that aren't lowercase words, without touching the disk" do
      ["Inputs", "../escape", "a/b", "", "1st", "inputs.json", "in puts", "_x", "inputs\n"].each do |name|
        expect_store_error(/entry name/) { store.write(name, 1) }
        expect_store_error(/entry name/) { store.read(name) }
      end
      expect(Dir.children(store.path)).to be_empty
      expect(Dir.children(@tmp)).to eq(["runs"])
    end

    it "rejects an entry name that isn't a String or Symbol, even one whose to_s is a good name" do
      named = Object.new.tap { |o| o.define_singleton_method(:to_s) { "inputs" } }

      [nil, 1, named].each do |name|
        expect_store_error(/entry name/) { store.write(name, 1) }
        expect_store_error(/entry name/) { store.read(name) }
      end
      expect(Dir.children(store.path)).to be_empty
    end

    it "keeps data nested PlainData::MAX_DEPTH deep" do
      max = Quaack::Enclave::PlainData::MAX_DEPTH
      store.write("plan", max.times.reduce(1) { |inner, _| [inner] })

      # Comparing with eq would recurse too deep, so count the levels.
      value = store.read("plan")
      depth = 0
      (value = value.first) && (depth += 1) while value.is_a?(Array) && value.size == 1
      expect([depth, value]).to eq([max, 1])
      expect(File.read(File.join(store.path, "plan.json"))).to eq("#{"[" * max}1#{"]" * max}")
    end

    it "raises, writing nothing, for data nested deeper than PlainData::MAX_DEPTH, or that contains itself" do
      loop = [STORE_SENTINEL]
      loop << loop
      too_deep = (Quaack::Enclave::PlainData::MAX_DEPTH + 1).times.reduce(STORE_SENTINEL) { |inner, _| [inner] }
      [too_deep, 100_000.times.reduce(1) { |inner, _| [inner] }, loop].each do |bad|
        # Without the depth cap, the loop would never end. Fail instead.
        Timeout.timeout(30) do
          expect_store_error(/plan.*#{store.run_id}/) { store.write("plan", bad) }
        end
      end
      expect(Dir.children(store.path)).to be_empty
    end

    it "raises, rather than crash or recurse without end, reading a file nested deeper than MAX_DEPTH" do
      [Quaack::Enclave::PlainData::MAX_DEPTH + 1, 100_000].each do |depth|
        File.write(File.join(store.path, "plan.json"), "#{"[" * depth}1#{"]" * depth}")

        expect_store_error(/plan.*#{store.run_id}.*isn't valid JSON\z/) { store.read("plan") }
      end
    end

    sentinel_object = Object.new.tap { |o| o.define_singleton_method(:to_s) { STORE_SENTINEL } }
    [
      ["an object", -> { sentinel_object }],
      ["a BasicObject", -> { BasicObject.new }],
      ["a Time", -> { Time.at(0) }],
      ["a Struct", -> { Struct.new(:ssn).new(STORE_SENTINEL) }],
      ["a String subclass", -> { Class.new(String).new(STORE_SENTINEL) }],
      ["an object as a Hash key", -> { { sentinel_object => 1 } }],
      ["an object deep in plain data", -> { { "a" => [{ "b" => sentinel_object }] } }]
    ].each do |name, value|
      it "raises, writing nothing and carrying nothing from the data, for #{name}" do
        expect_store_error(/literals.*#{store.run_id}/) { store.write("literals", [instance_exec(&value)]) }
        expect(Dir.children(store.path)).to be_empty
      end
    end

    it "reads back what it wrote whatever the locale is" do
      code = <<~RUBY
        require "quaack/enclave/store"
        s = Quaack::Enclave::Store.create(base: ARGV[0])
        s.write(:inputs, ["caf\\u00e9 \\u2603"])
        value = Quaack::Enclave::Store.open(s.run_id, base: ARGV[0]).read(:inputs)
        print Encoding.default_external, " ", value.first.encoding, " ", value.first.unpack1("H*")
      RUBY
      env = { "LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => "C" }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), "-e", code, base)

      expect(status).to be_success, "stderr was #{err}"
      expect(out).to eq("US-ASCII UTF-8 #{"café ☃".unpack1("H*")}")
    end

    it "raises, naming the entry and run but not the value, when a result can't be written as JSON" do
      [[Float::NAN], ["#{STORE_SENTINEL}\xFF"]].each do |bad|
        expect_store_error(/literals.*#{store.run_id}/) { store.write("literals", bad) }
      end
      expect(Dir.children(store.path)).to be_empty
    end

    describe "when something is already at the temp file's name" do
      let(:hex) { "0123456789abcdef" }
      let(:temp) { File.join(store.path, ".inputs.json.#{hex}.tmp") }

      # SecureRandom is an edge: stubbing it only makes the temp name known.
      before do
        store
        allow(SecureRandom).to receive(:hex).with(8).and_return(hex)
      end

      it "the stub gives the temp name the store uses" do
        store.write("inputs", [1])

        expect(SecureRandom).to have_received(:hex).with(8)
      end

      it "won't write through a file that's there, and leaves it alone" do
        File.write(temp, STORE_SENTINEL)

        expect_store_error(/inputs.*#{store.run_id}/) { store.write("inputs", [1]) }
        expect(File.read(temp)).to eq(STORE_SENTINEL)
        expect(Dir.children(store.path)).to eq([File.basename(temp)])
      end

      it "won't write through a symlink that's there, and leaves its target alone" do
        outside = File.join(@tmp, "outside.json")
        File.write(outside, STORE_SENTINEL)
        File.symlink(outside, temp)

        expect_store_error(/inputs.*#{store.run_id}/) { store.write("inputs", [1]) }
        expect(File.read(outside)).to eq(STORE_SENTINEL)
        expect(File.symlink?(temp)).to be(true)
        expect(Dir.children(store.path)).to eq([File.basename(temp)])
      end
    end

    it "leaves no temp file behind when the rename fails" do
      Dir.mkdir(File.join(store.path, "inputs.json"))

      expect_store_error(/inputs.*#{store.run_id}/) { store.write("inputs", [STORE_SENTINEL]) }
      expect(Dir.children(store.path)).to eq(["inputs.json"])
    end

    it "raises, naming the entry and run, for an entry that isn't there" do
      expect_store_error(/no entry literals in run #{store.run_id}/) { store.read("literals") }
    end

    it "raises without the file's contents, or the parse error, for an entry that isn't valid JSON" do
      ["{\"literals\": [#{STORE_SENTINEL}", "[\"#{STORE_SENTINEL}\xFF\"]".b].each do |contents|
        File.binwrite(File.join(store.path, "literals.json"), contents)

        expect_store_error(/literals.*#{store.run_id}.*isn't valid JSON\z/) { store.read("literals") }
      end
    end

    it "the sentinel check itself sees the sentinel in a raw parse error" do
      expect { JSON.parse("[#{STORE_SENTINEL}") }.to raise_error(JSON::ParserError, /#{STORE_SENTINEL}/)
    end

    it "won't follow an entry that's a symlink" do
      outside = File.join(@tmp, "outside.json")
      File.write(outside, "[\"#{STORE_SENTINEL}\"]")
      File.symlink(outside, File.join(store.path, "inputs.json"))

      expect_store_error(/inputs.*#{store.run_id}/) { store.read("inputs") }
    end
  end

  describe ".open" do
    it "opens an existing run and reads what an earlier call wrote" do
      store.write("inputs", { "query" => "SELECT 1" })
      reopened = described_class.open(store.run_id, base:)

      expect(reopened.run_id).to eq(store.run_id)
      expect(reopened.path).to eq(store.path)
      expect(reopened.read("inputs")).to eq("query" => "SELECT 1")
    end

    it "rejects a run ID that isn't in the run ID format, before building any path" do
      store # make sure the base exists
      bad = ["../runs", "..", "", "20260923T221500Z-abc", "20260923T221500Z-0123456789", "20260923t221500z-01234567",
             "20260923T221500Z-0123456G", "x/20260923T221500Z-01234567", "20260923T221500Z-01234567\n", nil, 20_260_923,
             :"20260923T221500Z-01234567"]
      bad.each do |run_id|
        expect_store_error(/run ID/) { described_class.open(run_id, base:) }
      end
    end

    it "raises, naming the run, when the run has no directory" do
      expect_store_error(/run 20260923T221500Z-01234567 has no directory/) do
        described_class.open("20260923T221500Z-01234567", base:)
      end
    end

    it "refuses a run directory that isn't mode 0700, naming its mode" do
      File.chmod(0o755, store.path)

      expect_store_error(/#{store.run_id}.*mode 0755, not 0700/) { described_class.open(store.run_id, base:) }
    end

    it "refuses a run directory owned by someone else" do
      other = Process.euid + 1

      expect_store_error(/#{store.run_id}.*owned by uid #{Process.euid}, not the current user \(uid #{other}\)/) do
        described_class.open(store.run_id, base:, current_uid: other)
      end
    end

    it "refuses a run directory that's a symlink" do
      outside = File.join(@tmp, "outside")
      Dir.mkdir(outside, 0o700)
      FileUtils.mkdir_p(base)
      File.symlink(outside, File.join(base, "20260923T221500Z-01234567"))

      expect_store_error(/20260923T221500Z-01234567.*isn't a directory/) do
        described_class.open("20260923T221500Z-01234567", base:)
      end
    end
  end

  describe "#teardown" do
    it "deletes the run directory and everything in it, and leaves the base" do
      store.write("inputs", [1])
      store.write("literals", [2])
      other = described_class.create(base:)
      store.teardown

      expect(File.exist?(store.path)).to be(false)
      expect(Dir.children(base)).to eq([other.run_id])
    end

    it "is safe to call twice" do
      store.teardown

      expect { store.teardown }.not_to raise_error
      expect(File.exist?(store.path)).to be(false)
      expect(File.directory?(base)).to be(true)
    end

    it "doesn't follow a symlink out of the run directory" do
      outside = File.join(@tmp, "outside")
      Dir.mkdir(outside)
      File.write(File.join(outside, "keep.json"), "[]")
      File.symlink(outside, File.join(store.path, "linked"))
      File.symlink(File.join(outside, "keep.json"), File.join(store.path, "keep.json"))
      store.teardown

      expect(File.exist?(store.path)).to be(false)
      expect(Dir.children(outside)).to eq(["keep.json"])
    end

    it "refuses to delete a run path that's been replaced by a symlink" do
      outside = File.join(@tmp, "outside")
      Dir.mkdir(outside)
      File.write(File.join(outside, "keep.json"), "[]")
      FileUtils.rm_r(store.path)
      File.symlink(outside, store.path)

      expect_store_error(/#{store.run_id}.*isn't a directory/) { store.teardown }
      expect(File.symlink?(store.path)).to be(true)
      expect(Dir.children(outside)).to eq(["keep.json"])
    end
  end
end
