# frozen_string_literal: true

require "quaack/driver/enclave_error"

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

  it "ignores next_step for every other rule" do
    expect(error("timeout", exit_status: nil, signal: "TERM").rule_with_note(next_step: "resume")).to eq("timeout")
  end
end
