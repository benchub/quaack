# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/enclave_error"
require "quaack/driver/llm/error"
require "quaack/driver/pipeline"
require "quaack/driver/transport/local"
require_relative "../../script/prompt_pack/run"
require_relative "../../e2e/run"

# Replays saved LLM replies through the full driver Pipeline (task
# 20260922-65), for spec/pipeline_replay_spec.rb.
#
# A reply is <root>/<query>/<step>-<n>/reply-<llm>-<k>.md, where <step>-<n>
# is how the prompt pack names an ask (spec/fixtures/llm_corpus/README.md).
# A variant is one (llm, k) pair: a run answers each ask with that ask's
# reply-<llm>-<k>.md, sent as raw text through the real LLM client, and
# falls back to E2ERun::CaseLLM's valid empty answer when there's none.
module PipelineReplay
  CORPUS = PromptPack::CORPUS
  PLANTED = File.join(__dir__, "..", "fixtures", "pipeline_replay")
  ROOTS = [CORPUS, PLANTED].freeze
  REPLY = /\Areply-(?<llm>[a-z0-9]+)-(?<k>\d+)\.md\z/

  Variant = Data.define(:llm, :k) do
    def to_s = llm ? "#{llm}-#{k}" : "all-empty"
  end
  EMPTY = Variant.new(llm: nil, k: nil)

  # What one replayed run did. log has one line per ask: its directory and
  # whether it was replayed or fell back. drift names replayed asks whose
  # prompt doesn't match the saved prompt.md.
  Outcome = Data.define(:variant, :error, :report, :entries, :log, :drift)

  module_function

  # Every (llm, k) with a reply anywhere in query's asks, or just EMPTY.
  def variants(query, roots: ROOTS)
    found = roots.flat_map { Dir.glob(File.join(it, query, "*", "reply-*.md")) }.filter_map do |path|
      m = REPLY.match(File.basename(path))
      Variant.new(llm: m[:llm], k: m[:k].to_i) if m
    end
    found.empty? ? [EMPTY] : found.uniq.sort_by(&:to_s)
  end

  # The directory the prompt pack gives each ask, in order: its step, with
  # step11- for a 5a ask after 6a, and a per-query count of that name.
  class Namer
    def initialize
      @counts = Hash.new(0)
      @rewrites = false
    end

    def next(step)
      @rewrites ||= step == "6a"
      name = @rewrites && step.start_with?("5a-") ? "step11-#{step}" : step
      "#{name}-#{@counts[name] += 1}"
    end
  end

  # The replies seam E2ERun::CaseLLM calls, as `for(step, body)`: the saved
  # reply text for this ask, or nil for the empty answer.
  class Replies
    attr_reader :log, :drift

    def initialize(query, variant, roots: ROOTS)
      @query = query
      @variant = variant
      @roots = roots
      @namer = Namer.new
      @log = []
      @drift = []
    end

    def for(step, body)
      dir = @namer.next(step)
      path = @variant.llm && @roots.map { File.join(it, @query, dir, "reply-#{@variant}.md") }.find { File.file?(it) }
      @log << "#{dir}: #{path ? "replayed" : "empty answer (no reply)"}"
      check_prompt(dir, body) if path
      path && File.read(path)
    end

    private

    def check_prompt(dir, body)
      saved = File.join(CORPUS, @query, dir, "prompt.md")
      return @drift << "#{dir}: no saved prompt.md" unless File.file?(saved)

      sent = system_section(PromptPack.prompt(Ask.new(body)))
      @drift << "#{dir}: the system prompt sent differs from #{saved}" unless sent == system_section(File.read(saved))
    end

    # The rest of a prompt carries the run's plan and timings, which change
    # from run to run, so only the step's fixed system prompt is compared.
    def system_section(prompt) = prompt[/\A# System\n(.*?)\n# User\n/m, 1]

    Ask = Struct.new(:body)
  end

  # Runs query through intake, setup, and the Pipeline once, with variant's
  # replies. An EnclaveError or LLM::Error ends the run cleanly and comes
  # back in the outcome; anything else raises.
  def run(server, query, variant)
    Dir.mktmpdir("quaack-replay") do |home|
      prod, racetrack = PromptPack.databases(server, query)
      PromptPack.with_env(home, server, prod) { start(home, server, query, prod, racetrack, variant) }
    ensure
      drop(server, [prod, racetrack, "#{racetrack}_arena"].compact)
    end
  end

  def start(home, server, query, prod, racetrack, variant) # rubocop:disable Metrics/ParameterLists
    transport = Quaack::Driver::Transport::Local.new(command: PromptPack::QUAACKS)
    run_id = PromptPack.intake(transport, home, server, query, prod)
    PromptPack.setup(transport, run_id, server, racetrack)
    pipeline(transport, run_id, query, variant, File.join(home, "report.html"))
  end

  def drop(server, databases)
    server.admin.exec("SET client_min_messages = warning")
    databases.each { server.admin.exec(%(DROP DATABASE IF EXISTS "#{it}" WITH (FORCE))) }
  end

  def pipeline(transport, run_id, query, variant, out)
    replies = Replies.new(query.name, variant)
    client = E2ERun::CaseLLM.new(replies:).client(burndown: Quaack::Driver::Burndown.new)
    error = drive { Quaack::Driver::Pipeline.new(transport:, client:, run_id:, rewrites: query.rewrites, out:).run }
    Outcome.new(variant:, error:, report: error ? nil : report(transport, run_id),
                entries: Quaack::Driver::Pipeline.status(transport, run_id), log: replies.log, drift: replies.drift)
  end

  # nil, or the EnclaveError or LLM::Error that ended the run.
  def drive
    yield
    nil
  rescue Quaack::Driver::EnclaveError, Quaack::Driver::LLM::Error => e
    e
  end

  def report(transport, run_id)
    transport.call("report-payload", args: { run: run_id }).messages.find { it["type"] == "report" }
  end

  # One run per query and variant in a spec process, shared by its
  # examples. It prints how many asks were replayed and how many fell back.
  def cached(server, query, variant)
    @cached ||= {}
    @cached[[query.name, variant]] ||= run(server, query, variant).tap { puts summary(query, variant, it) }
  end

  def summary(query, variant, outcome)
    replayed = outcome.log.count { it.end_with?("replayed") }
    "\n#{query.name} #{variant}: #{outcome.log.size} asks, #{replayed} replayed, " \
      "#{outcome.log.size - replayed} empty answers (no reply)#{" (#{outcome.error.rule})" if outcome.error}"
  end
end
