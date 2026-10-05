# frozen_string_literal: true

require "quaack/driver/enclave_error"
require "quaack/driver/transport"

# What the operator reads when a call to quaacks failed: the rule, and for
# the driver's own incomplete and ssh_failed, what died and how, from the
# driver's own facts, never the enclave's output.
RSpec.describe Quaack::Driver::EnclaveError, "#rule_with_note" do
  def error(rule, **ending) = described_class.new(subcommand: "counterexample-payload", rule:, **ending)

  it "names the subcommand and its exit status for an incomplete call" do
    expect(error("incomplete", exit_status: 1).rule_with_note)
      .to eq("incomplete: quaacks counterexample-payload ended with exit 1. To go on, resume the run")
  end

  it "names the subcommand and its signal for an incomplete call a signal ended" do
    expect(error("incomplete", signal: "KILL").rule_with_note)
      .to eq("incomplete: quaacks counterexample-payload ended with signal KILL. To go on, resume the run")
  end

  it "says what exit 255 means for an incomplete call, and where to look" do
    expect(error("incomplete", exit_status: 255).rule_with_note)
      .to eq("incomplete: quaacks counterexample-payload ended with exit 255. The ssh session failed or ended, " \
             "or the remote process was killed: check your ssh login, the network, and the jump server's " \
             "kernel log (for the OOM killer) and sshd log. To go on, resume the run")
  end

  it "names only the subcommand for an incomplete call with no ending" do
    expect(error("incomplete").rule_with_note)
      .to eq("incomplete: quaacks counterexample-payload didn't finish. To go on, resume the run")
  end

  # Task 20261004-26: the caller knows whether the run's store is still
  # there to resume.
  it "says what to do next for incomplete in the caller's words, such as starting a new run" do
    expect(error("incomplete", exit_status: 1).rule_with_note(next_step: "start a new run with `quaack start`"))
      .to eq("incomplete: quaacks counterexample-payload ended with exit 1. " \
             "To go on, start a new run with `quaack start`")
  end

  it "says ssh couldn't reach the jump server, and to resume the run" do
    expect(error("ssh_failed", exit_status: 255).rule_with_note)
      .to eq("ssh_failed: couldn't ssh to the jump server; check your ssh login or network, then resume the run")
  end

  it "says what to do next for ssh_failed in the caller's words, such as the resume command" do
    expect(error("ssh_failed", exit_status: 255).rule_with_note(next_step: "resume with `quaack run --run R1`"))
      .to eq("ssh_failed: couldn't ssh to the jump server; check your ssh login or network, " \
             "then resume with `quaack run --run R1`")
  end

  # Task 20261004-17: libpq's message can name the user or the database, so
  # the enclave sends only the rule. The driver knows the jump host and the
  # production server the operator gave quaack start, so the note names
  # them, and says where the rest of the connection comes from.
  describe "production_connection_failed" do
    let(:libpq) do
      "your libpq setup on the jump server: PG* environment variables, ~/.pg_service.conf with PGSERVICE, and " \
        "~/.pgpass. A non-interactive ssh session may not load the shell rc file that sets them."
    end
    let(:resume) { "Otherwise fix your libpq setup, then resume with `quaack setup --run R1`" }

    it "names the server tried, where the rest of the connection comes from, and how to test it" do
      note = error("production_connection_failed", exit_status: 70)
             .rule_with_note(next_step: "resume with `quaack setup --run R1`", jump: "jump-1", server: "prod-1")

      expect(note).to eq("production_connection_failed: couldn't connect to production at prod-1. QUAACK gives " \
                         "libpq only that host. The port, user, database, and password come from #{libpq} Test it " \
                         "with `ssh jump-1 'psql -h prod-1 -c \"select 1\"'`. If production listens on another port " \
                         "than your libpq setup gives, start a new run with `quaack start --port <n>`. #{resume}")
    end

    # Task 20261004-37: the run records quaack start --port, so the test
    # command gives it exactly.
    it "names the port the run recorded, and gives it to psql as -p" do
      note = error("production_connection_failed", exit_status: 70)
             .rule_with_note(next_step: "resume with `quaack setup --run R1`", jump: "jump-1", server: "prod-1",
                             port: "6543")

      expect(note).to eq("production_connection_failed: couldn't connect to production at prod-1, port 6543. " \
                         "QUAACK gives libpq only that host and port. The user, database, and password come from " \
                         "#{libpq} Test it with `ssh jump-1 'psql -h prod-1 -p 6543 -c \"select 1\"'`. If " \
                         "production listens on another port, start a new run with `quaack start --port <n>`. " \
                         "#{resume}")
    end

    # Task 20261004-40: with the server unknown, -p would leave the test
    # command half filled in, so it gives psql neither.
    it "leaves -p out of the test command when it doesn't know the server" do
      note = error("production_connection_failed", exit_status: 70)
             .rule_with_note(next_step: "resume with `quaack setup --run R1`", jump: "jump-1", port: "6543")

      expect(note).to include("Test it with `ssh jump-1 'psql -h <server> -c \"select 1\"'`.")
      expect(note).not_to include("-p 6543")
    end

    it "says the production server you gave quaack start when the driver doesn't know it" do
      note = error("production_connection_failed", exit_status: 70)
             .rule_with_note(next_step: "resume with `quaack setup --run R1`")

      expect(note).to eq("production_connection_failed: couldn't connect to the production server you gave " \
                         "quaack start. QUAACK gives libpq only that host. The port, user, database, and password " \
                         "come from #{libpq} Test it with `ssh <jump server> 'psql -h <server> -c \"select 1\"'`. " \
                         "If production listens on another port than your libpq setup gives, start a new run with " \
                         "`quaack start --port <n>`. #{resume}")
    end
  end

  # Task 20261004-17: the run server's host, port, and databases come from
  # run-server's flags or run_server_command, and may be the stored entry's
  # by now, so the note doesn't name them.
  it "says where the run server's connection comes from for run_server_connection_failed, and how to test it" do
    note = error("run_server_connection_failed", exit_status: 70)
           .rule_with_note(next_step: "resume with `quaack setup --run R1`", jump: "jump-1", server: "prod-1")

    expect(note).to eq("run_server_connection_failed: couldn't connect to the run server. Its host, port, and " \
                       "databases are the ones run-server was given: the --host, --port, --racetrack-db, and " \
                       "--arena-db you gave quaack setup or quaack run, and your run_server_command's for any you " \
                       "didn't. The user and password come from your libpq setup on the jump server: PG* " \
                       "environment variables, ~/.pg_service.conf with PGSERVICE, and ~/.pgpass. A non-interactive " \
                       "ssh session may not load the shell rc file that sets them. Test it with `ssh jump-1 'psql " \
                       "-h <host> -p <port> -d <racetrack db> -c \"select 1\"'`. Then resume with " \
                       "`quaack setup --run R1`")
  end

  it "ignores next_step for every other rule" do
    expect(error("timeout", exit_status: nil, signal: "TERM").rule_with_note(next_step: "resume")).to eq("timeout")
  end

  # Task 20261004-17: a connection failure whose run printed libpq's message,
  # naming the user and the database, on stderr and in its error line. The
  # note carries none of it.
  describe "a connection failure's note, from a real run" do
    let(:sentinel) { "sentinel-4be1d0-user" }
    let(:libpq) { %(FATAL:  password authentication failed for user \\"#{sentinel}\\" database #{sentinel}) }

    def failed(rule)
      line = %({"type":"error","step":"inventory","rule":"#{rule}","reason":"#{libpq}"})
      Quaack::Driver::Transport::Local.new(command: EnclaveCommands.raw(<<~RUBY), timeout: 60).call("inventory")
        $stderr.write(#{libpq.dump}); STDERR.flush; print #{"#{line}\n".dump}; exit 70
      RUBY
    rescue described_class => e
      e
    end

    %w[production_connection_failed run_server_connection_failed].each do |rule|
      it "never carries libpq's message for #{rule}" do
        error = failed(rule)
        note = error.rule_with_note(next_step: "resume the run", jump: "jump-1", server: "prod-1")

        expect([error.rule, note]).to match([rule, start_with("#{rule}: couldn't connect to ")])
        expect(note).not_to include(sentinel)
        expect(error.full_message(highlight: false)).not_to include(sentinel)
      end
    end

    it "would show a sentinel the caller passed, so the check above can catch one" do
      note = failed("production_connection_failed").rule_with_note(server: "prod-#{sentinel}")

      expect(note).to include(sentinel)
    end
  end
end
