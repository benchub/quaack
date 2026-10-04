# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "quaack/enclave/config"
require "quaack/enclave/table_name"

# The quaacks config file on the jump server, ~/.quaack/config.json (DESIGN.md,
# inventory). The operator writes it, and it can name anything, so an error
# names only its rule, never the path or what's in the file.
RSpec.describe Quaack::Enclave::Config do
  let(:config) { described_class }
  let(:sentinels) { LeakCheck::Sentinels.new }
  # A directory whose name holds a sentinel, so a path that got into an
  # error would show.
  let(:dir) { File.join(Dir.mktmpdir("quaack-config"), sentinels.word).tap { FileUtils.mkdir_p(it) } }
  let(:path) { File.join(dir, "config.json") }

  after do
    FileUtils.chmod(0o600, path) if File.file?(path) && !File.symlink?(path)
    FileUtils.rm_rf(File.dirname(dir))
  end

  def write(text) = File.write(path, text).then { path }

  def error_of
    yield
    raise "expected a Config::Error"
  rescue Quaack::Enclave::Config::Error => e
    e
  end

  it "lives at ~/.quaack/config.json" do
    expect(config.default_path).to eq(File.join(Dir.home, ".quaack", "config.json"))
  end

  it "reads the memory command" do
    write(%({"memory_command": "aws-memory --host {host}"}))

    expect(config.load(path).memory_command).to eq("aws-memory --host {host}")
  end

  it "has no memory command when the file is missing" do
    expect(config.load(path).memory_command).to be_nil
  end

  it "has no memory command when the file doesn't set one, and ignores keys it doesn't use" do
    write(%({"pii_columns": ["*.users.email"]}))

    expect(config.load(path).memory_command).to be_nil
  end

  it "reads the run server and destroy commands, and has neither by default" do
    expect([config.load(path).run_server_command, config.load(path).destroy_command]).to eq([nil, nil])
    write(%({"run_server_command": "make-rs {server} {run}", "destroy_command": "rm-rs {run}"}))

    expect([config.load(path).run_server_command, config.load(path).destroy_command])
      .to eq(["make-rs {server} {run}", "rm-rs {run}"])
  end

  describe "the PII columns and the cardinality threshold, for DESIGN.md's classify" do
    let(:users) { Quaack::Enclave::TableName.new(schema: "public", name: "users") }

    it "defaults to no PII columns and a threshold of 50" do
      loaded = config.load(path)

      expect([loaded.pii_columns, loaded.cardinality_threshold]).to eq([[], 50])
      expect(loaded.pii_column?(users, "email")).to be(false)
    end

    it "reads the PII globs and the threshold" do
      write(%({"pii_columns": ["*.users.email", "billing.*.card_*"], "cardinality_threshold": 20}))
      loaded = config.load(path)

      expect([loaded.pii_columns, loaded.cardinality_threshold]).to eq([%w[*.users.email billing.*.card_*], 20])
    end

    # * matches any run of characters within one name part, never a dot.
    # Matching ignores case, so a glob can only ever match more columns,
    # which withholds more: the safe way to be wrong.
    it "matches a column against each glob, part by part, ignoring case" do
      write(%({"pii_columns": ["*.users.email", "billing.*.card_*", "public.a+b.c"]}))
      loaded = config.load(path)
      columns = [%w[public users email], %w[app Users EMAIL], %w[billing cards card_number], %w[billing cards card_],
                 %w[public a+b c],
                 %w[public users emails], %w[public users work_email], %w[public user email],
                 %w[public cards card_number], %w[billing cards number], %w[public aab c]]

      matches = columns.map do |schema, name, column|
        loaded.pii_column?(Quaack::Enclave::TableName.new(schema:, name:), column)
      end
      expect(matches).to eq(([true] * 5) + ([false] * 6))
    end
  end

  # Each of these is refused as bad_config.
  {
    "isn't JSON" => "memory_command = echo 1",
    "repeats a key" => %({"memory_command": "echo 1", "memory_command": "echo 2"}),
    "isn't an object" => %(["echo 1"]),
    "has a memory command that isn't a string" => %({"memory_command": 1}),
    "has an empty memory command" => %({"memory_command": ""}),
    "has a blank memory command" => %({"memory_command": "  "}),
    "has a memory command on more than one line" => %({"memory_command": "echo 1\\necho 2"}),
    "has a memory command with a carriage return" => %({"memory_command": "echo 1\\recho 2"}),
    "has a memory command with a NUL" => %({"memory_command": "echo 1\\u0000"}),
    "has a run server command on two lines" => %({"run_server_command": "a\\nb"}),
    "has a destroy command that isn't a string" => %({"destroy_command": ["rm"]}),
    "has a blank destroy command" => %({"destroy_command": " "}),
    "has PII columns that aren't a list" => %({"pii_columns": "*.users.email"}),
    "has a PII glob that isn't a string" => %({"pii_columns": [1]}),
    "has a PII glob with two parts" => %({"pii_columns": ["users.email"]}),
    "has a PII glob with four parts" => %({"pii_columns": ["db.public.users.email"]}),
    "has a PII glob with an empty part" => %({"pii_columns": ["public..email"]}),
    "has a PII glob on more than one line" => %({"pii_columns": ["*.users.email\\n"]}),
    "has a threshold that isn't a number" => %({"cardinality_threshold": "50"}),
    "has a threshold that isn't whole" => %({"cardinality_threshold": 50.5}),
    "has a threshold of zero" => %({"cardinality_threshold": 0}),
    "has a negative threshold" => %({"cardinality_threshold": -5})
  }.each do |what, text|
    it "refuses a file that #{what} as bad_config" do
      write(text)

      expect(error_of { config.load(path) }.rule).to eq("bad_config")
    end
  end

  # Trailing blanks, so the part before the limit is good JSON on its own.
  it "refuses a file past its size limit as bad_config" do
    good = %({"memory_command": "echo 1"})
    write(good.ljust(config::MAX_BYTES))
    expect(config.load(path).memory_command).to eq("echo 1")

    write(good.ljust(config::MAX_BYTES + 1))
    expect(error_of { config.load(path) }.rule).to eq("bad_config")
  end

  it "refuses a symlink as bad_config, even to a good file" do
    target = File.join(dir, "real.json")
    File.write(target, %({"memory_command": "echo 1"}))
    File.symlink(target, path)

    expect(error_of { config.load(path) }.rule).to eq("bad_config")
  end

  it "refuses a symlink that points nowhere as bad_config, not as missing" do
    File.symlink(File.join(dir, "nowhere.json"), path)

    expect(error_of { config.load(path) }.rule).to eq("bad_config")
  end

  it "refuses a file it can't read as bad_config" do
    write(%({"memory_command": "echo 1"}))
    File.chmod(0o000, path)

    expect(error_of { config.load(path) }.rule).to eq("bad_config")
  end

  it "refuses a directory, or a FIFO, as bad_config, without waiting on the FIFO" do
    Dir.mkdir(path)
    expect(error_of { config.load(path) }.rule).to eq("bad_config")
    Dir.rmdir(path)

    File.mkfifo(path)
    expect(error_of { config.load(path) }.rule).to eq("bad_config")
  end

  it "keeps the path and the file's contents out of its errors" do
    s = sentinels
    errors = [
      error_of { config.load(write(%({"memory_command": "#{s.text}\\n#{s.like}"}))) },
      error_of { config.load(write(%({"memory_command": "#{s.text}" #{s.like}}))) },
      error_of { File.chmod(0o000, path).then { config.load(path) } }
    ]

    expect(errors.map(&:rule)).to eq(%w[bad_config] * 3)
    expect_no_leaks(sentinels, objects: { errors: })
  end
end
