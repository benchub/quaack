# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks inventory --run <run ID>` (README, step 2) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler,
# connecting the way an operator's does. Its HOME is a temporary directory
# holding the operator's ~/.pgpass, ~/.pg_service.conf, and
# ~/.quaack/config.json, and only the libpq environment variables a test
# gives are set. The production server is a stand-in database on the test
# harness's Postgres (see ProductionServer), whose name, text search config,
# and search_path hold sentinels.
RSpec.describe "quaacks inventory, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  # The run intake would have made. Its server is the host to connect to,
  # and its plan's SETTINGS names settings production's values are wanted
  # for. The plan's own values are the operator's session's, not
  # production's.
  let(:plan_settings) { { "enable_hashjoin" => "off", "search_path" => "elsewhere", "quaack.no_such_setting" => "1" } }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("plan", [{ "Plan" => { "Node Type" => "Result", "Actual Rows" => 1, "Shared Hit Blocks" => 0 },
                             "Settings" => plan_settings }])
    end
  end

  after do
    quaacks.remove
    production.drop
  end

  def home_file(name, text, mode: 0o600)
    path = File.join(quaacks.home, name)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, text)
    File.chmod(mode, path)
    path
  end

  def pgpass(user: production.user, password: production.password)
    home_file(".pgpass", "#{production.host}:#{production.port}:#{production.name}:#{user}:#{password}\n")
  end

  def service_file
    home_file(".pg_service.conf", <<~CONF)
      [prod]
      port=#{production.port}
      dbname=#{production.name}
      user=#{production.user}
    CONF
  end

  def config(object) = home_file(".quaack/config.json", JSON.generate(object))

  # Every libpq variable this process has is unset, so only the operator's
  # setup a test builds is used.
  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  def inventory(**vars) = quaacks.run("inventory", "--run", store.run_id, env: libpq_env(**vars))

  def done = %({"type":"done"}\n)
  def error_line(rule) = %({"type":"error","step":"inventory","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  # What the run's store holds, to show the sentinels reached the step.
  def expect_exposed(inventory, kinds)
    expect(LeakCheck.findings(sentinels, stdout: JSON.generate(inventory)).map(&:sentinel)).to include(*kinds)
  end

  it "records the inventory from the operator's service file and ~/.pgpass, and prints only its shape" do
    pgpass
    service_file
    config(memory_command: "echo #{sentinels.like_prefix} >&2; test {host} = #{production.host} && echo 64GB")

    outcome = inventory(PGSERVICE: "prod")

    expect(outcome.stdout).to eq(%({"type":"inventory","major_version":18,"memory_known":true}\n#{done}))
    expect(outcome.stderr).to eq("")
    expect(outcome.status.exitstatus).to eq(0)
    recorded = stored.read("inventory")
    expect(recorded).to include(
      "major_version" => 18, "memory_bytes" => 64 * (1024**3),
      "plan_settings" => { "enable_hashjoin" => "on", "search_path" => production.search_path,
                           "quaack.no_such_setting" => nil },
      "database" => include("datname" => production.name, "datlocprovider" => "b", "datlocale" => "C.UTF-8"),
      "default_text_search_config" => "public.#{production.ts_config}"
    )
    expect(recorded.keys).to contain_exactly("server_version_num", "major_version", "extensions", "memory_bytes",
                                             "settings", "parallel_settings", "plan_settings", "database",
                                             "default_text_search_config")
    expect(recorded["extensions"]).to include("hypopg", "plpgsql")
    expect_exposed(recorded, %i[word text tsconfig])
    expect_no_leaks(sentinels, outcome)
  end

  it "takes the port, user, and database from PG variables too, and records memory as unknown with no config" do
    pgpass

    outcome = inventory(PGPORT: production.port.to_s, PGUSER: production.user, PGDATABASE: production.name)

    expect(outcome.stdout).to eq(%({"type":"inventory","major_version":18,"memory_known":false}\n#{done}))
    expect(outcome.status.exitstatus).to eq(0)
    expect(stored.read("inventory"))
      .to include("memory_bytes" => nil, "database" => include("datname" => production.name))
  end

  it "records memory as unknown with a config that sets no memory command" do
    pgpass
    config(pii_columns: ["*.users.email"])

    outcome = inventory(PGPORT: production.port.to_s, PGUSER: production.user, PGDATABASE: production.name)

    expect(outcome.stdout).to eq(%({"type":"inventory","major_version":18,"memory_known":false}\n#{done}))
  end

  it "takes a plan with no SETTINGS" do
    pgpass
    service_file
    store.write("plan", [{ "Plan" => { "Node Type" => "Result", "Actual Rows" => 1, "Shared Hit Blocks" => 0 } }])

    outcome = inventory(PGSERVICE: "prod")

    expect(outcome.status.exitstatus).to eq(0), outcome.stdout
    expect(stored.read("inventory")["plan_settings"]).to eq({})
  end

  it "fails a bad password as production_connection_failed, naming neither the host nor the user" do
    s = sentinels
    pgpass(user: s.word, password: s.text)
    service_file

    outcome = inventory(PGSERVICE: "prod", PGUSER: s.word)

    expect(outcome.stdout).to eq(error_line("production_connection_failed"))
    expect(outcome.stderr).to eq("")
    expect(outcome.status.exitstatus).to eq(70)
    expect(stored.entry?("inventory")).to be(false)
    expect(outcome.stdout).not_to include(production.host)
    expect_no_leaks(sentinels, outcome)
  end

  it "fails a server it can't reach as production_connection_failed" do
    outcome = inventory(PGPORT: "1", PGUSER: production.user, PGDATABASE: production.name)

    expect(outcome.stdout).to eq(error_line("production_connection_failed"))
    expect(outcome.status.exitstatus).to eq(70)
    expect(stored.entry?("inventory")).to be(false)
  end

  it "fails a memory command that fails, keeping its output out, and records nothing" do
    pgpass
    service_file
    config(memory_command: "echo #{sentinels.text}; echo #{sentinels.like_prefix} >&2; exit 3")

    outcome = inventory(PGSERVICE: "prod")

    expect(outcome.stdout).to eq(error_line("memory_command_failed"))
    expect(outcome.stderr).to eq("")
    expect(outcome.status.exitstatus).to eq(70)
    expect(stored.entry?("inventory")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  it "fails a memory command whose output it can't read as memory_command_bad_output" do
    pgpass
    service_file
    config(memory_command: "echo #{sentinels.text}")

    outcome = inventory(PGSERVICE: "prod")

    expect(outcome.stdout).to eq(error_line("memory_command_bad_output"))
    expect_no_leaks(sentinels, outcome)
  end

  it "refuses a symlinked config as bad_config, before connecting" do
    real = home_file("real-config.json", JSON.generate(memory_command: "echo 1GB"))
    FileUtils.mkdir_p(File.join(quaacks.home, ".quaack"))
    File.symlink(real, File.join(quaacks.home, ".quaack", "config.json"))

    # No libpq setup at all, so a connection attempt would fail differently.
    outcome = inventory

    expect(outcome.stdout).to eq(error_line("bad_config"))
    expect(outcome.status.exitstatus).to eq(70)
  end

  it "refuses a call with no run as usage" do
    outcome = quaacks.run("inventory", env: libpq_env)

    expect(outcome.stdout).to eq(%({"type":"error","step":"inventory","rule":"usage"}\n))
    expect(outcome.status.exitstatus).to eq(64)
  end
end
