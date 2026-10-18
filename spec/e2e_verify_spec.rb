# frozen_string_literal: true

require "open3"
require "rbconfig"
require "socket"
require_relative "spec_helper"
require_relative "../e2e/verify"

# Task 20261018-18: a run of e2e/verify.rb removed every container carrying
# its label at start, so one run started while another was going killed that
# run's server. Rule builders prove e2e cases in parallel. A run now removes
# only leftovers whose owner is gone, the way spec/support/test_postgres.rb
# does. Each example uses a label of its own, so it never touches the
# container of a real run, and removes everything carrying it afterward.
RSpec.describe E2E::Postgres do
  let(:label) { "quaack.e2e.spec-#{Process.pid}" }
  let(:this_host) { Socket.gethostname }

  after do
    ids = docker("ps", "-aq", "--no-trunc", "--filter", "label=#{label}").split
    docker("rm", "-f", "-v", *ids) unless ids.empty?
  end

  def docker(*args)
    out, status = Open3.capture2e("docker", *args)
    raise "docker #{args.first} failed:\n#{out}" unless status.success?

    out.strip
  end

  # A container that was created but never started: all a leftover needs to
  # be is something `docker ps -a` lists with the labels.
  def create_container(*labels)
    docker("create", "--label", label, *labels.flat_map { ["--label", it] }, E2E::IMAGE)
  end

  def owner(pid, host = this_host) = ["#{E2E::OWNER_LABEL}=#{pid}", "#{E2E::HOST_LABEL}=#{host}"]
  def listed?(id) = !docker("ps", "-aq", "--no-trunc", "--filter", "id=#{id}").empty?
  def running?(id) = docker("ps", "-q", "--no-trunc", "--filter", "id=#{id}", "--filter", "status=running") == id

  def dead_pid
    Process.spawn(RbConfig.ruby, "-e", "exit").tap { Process.wait(it) }
  end

  it "doesn't remove the container of another run that's still going" do
    first = described_class.new(label: label)
    second = described_class.new(label: label)

    expect(second.id).not_to eq(first.id)
    expect(running?(first.id)).to be(true)
    expect(first.psql("SELECT 1", "postgres")).to eq("1\n")
  end

  it "removes leftovers whose owner on this host is gone, and keeps the rest" do
    live_owner = Process.spawn("sleep", "60")
    stale = create_container(*owner(dead_pid))
    unowned = create_container
    owned_by_live = create_container(*owner(live_owner))
    owned_by_other_host = create_container(*owner(dead_pid, "not-#{this_host}"))

    described_class.new(label: label)

    expect([stale, unowned].map { listed?(it) }).to eq([false, false])
    expect([owned_by_live, owned_by_other_host].map { listed?(it) }).to eq([true, true])
  ensure
    Process.kill("TERM", live_owner) if live_owner
    Process.wait(live_owner) if live_owner
  end

  it "labels its container with its pid and this host" do
    id = described_class.new(label: label).id
    labels = %w[OWNER_LABEL HOST_LABEL].map do |name|
      docker("inspect", "--format", "{{index .Config.Labels \"#{E2E.const_get(name)}\"}}", id)
    end

    expect(labels).to eq([Process.pid.to_s, this_host])
  end
end
