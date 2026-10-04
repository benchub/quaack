# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/enclave_error"
require "quaack/driver/counterexamples"
require "quaack/driver/llm/error"
require "quaack/driver/llm/reply_json"
require "quaack/driver/pipeline"
require "quaack/driver/rewrite_generation"
require "quaack/driver/teardown"
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
module PipelineReplay # rubocop:disable Metrics/ModuleLength
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
  # wrong holds the numbers n of the replayed 6a rewrites, stored as
  # rewrite_<n>, whose SQL carries the query's subtly wrong condition, and
  # rewrites_text the replayed 6a reply's text, or nil. html is the report
  # file the run wrote, or nil.
  Outcome = Data.define(:variant, :error, :report, :html, :entries, :log, :drift, :wrong, :rewrites_text, :store_left,
                        :teardown)

  # A query DESIGN.md 6c's key_in_self_join rule fires on (task 20261001-23):
  # orders whose id is in a UNION ALL of two subqueries that each read orders
  # again by its primary key. The rule drops both subqueries and joins their
  # conditions with OR. The subquery has two arms on purpose: Postgres 18's
  # planner removes a single self-join on a key by itself, so the rule's
  # rewrite of a one-arm IN plans as the original does, and step 8 prunes
  # it before it reaches the report.
  #
  # It isn't one of PromptPack::QUERIES, so it has no prompts in the corpus,
  # and it runs with empty LLM answers and no operator rewrites: its only
  # rewrite is the rule's.
  RULE_QUERY = PromptPack::Query.new(
    name: "key_in_self_join",
    sql: "SELECT o.id, o.total_cents FROM public.orders o WHERE o.id IN " \
         "(SELECT o2.id FROM public.orders o2 WHERE o2.created_at >= '#{PromptPack::SINCE}' " \
         "AND o2.created_at < '#{PromptPack::UNTIL}' " \
         "UNION ALL SELECT o3.id FROM public.orders o3 WHERE o3.status = 'refunded') ORDER BY o.id",
    rewrites: nil, indexes: [], order: "id", bug: nil
  )

  module_function

  # Every (llm, k) with a reply anywhere in query's asks, or just EMPTY.
  def variants(query, roots: ROOTS)
    found = roots.flat_map { Dir.glob(File.join(it, query, "*", "reply-*.md")) }.filter_map do |path|
      m = REPLY.match(File.basename(path))
      warn "pipeline replay: ignoring #{path}, not named reply-<llm>-<k>.md" unless m
      Variant.new(llm: m[:llm], k: m[:k].to_i) if m
    end
    found.empty? ? [EMPTY] : found.uniq.sort_by(&:to_s)
  end

  def selected_variants(query, full: false, roots: ROOTS)
    all = variants(query, roots:)
    return all if full

    planted, recorded = all.partition { it.llm == "planted" }
    recorded = recorded.reject { it == EMPTY }
    raise "pipeline replay: no recorded replay variants for #{query}" if recorded.empty?

    [recorded.first, *planted]
  end

  # The directory the prompt pack gives each ask, in order: its step, and
  # a per-query count of that step. A
  # 10a ask is named by rewrite and round instead (task 20260927-24): each
  # rewrite gets a block of Counterexamples::ROUNDS numbers, in rewrite
  # order, so one disproved early doesn't shift the next rewrite's asks.
  # The pack's per-step count gives the same names, since its placeholder
  # replies never disprove, so every rewrite runs all its rounds.
  class Namer
    ROUNDS = Quaack::Driver::Counterexamples::ROUNDS

    def initialize
      @counts = Hash.new(0)
      @rewrite = 0
    end

    def next(step, body)
      return counterexample(body) if step == "10a"

      "#{step}-#{@counts[step] += 1}"
    end

    # A round's ask holds one user turn per round so far.
    def counterexample(body)
      round = body[:messages].count { it[:role].to_s == "user" }
      @rewrite += 1 if round == 1
      "10a-#{((@rewrite - 1) * ROUNDS) + round}"
    end
  end

  # The replies seam E2ERun::CaseLLM calls, as `for(step, body)`: the saved
  # reply text for this ask, or nil for the empty answer.
  class Replies
    attr_reader :log, :drift, :rewrites_text

    def initialize(query, variant, roots: ROOTS)
      @query = query
      @variant = variant
      @roots = roots
      @namer = Namer.new
      @log = []
      @drift = []
    end

    def for(step, body)
      dir = @namer.next(step, body)
      path = @variant.llm && @roots.map { File.join(it, @query, dir, "reply-#{@variant}.md") }.find { File.file?(it) }
      @log << "#{dir}: #{path ? "replayed" : "empty answer (no reply)"}"
      check_prompt(dir, body, File.dirname(path)) if path
      text = path && File.read(path)
      @rewrites_text = text if step == "6a" && text
      text
    end

    private

    # The prompt.md next to the reply, or else the corpus one.
    def check_prompt(dir, body, reply_dir)
      saved = [File.join(reply_dir, "prompt.md"), File.join(CORPUS, @query, dir, "prompt.md")].find { File.file?(it) }
      return @drift << "#{dir}: no saved prompt.md" unless saved

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
    outcome = pipeline(transport, run_id, query, variant, File.join(home, "report.html"))
    outcome.with(store_left: File.exist?(File.join(home, ".quaack", "runs", run_id)))
  end

  def drop(server, databases)
    server.admin.exec("SET client_min_messages = warning")
    databases.each { server.admin.exec(%(DROP DATABASE IF EXISTS "#{it}" WITH (FORCE))) }
  end

  # The Pipeline and what's read back from the store, then the run's
  # teardown, as `quaack run` does it (Driver::Teardown), with its message.
  def pipeline(transport, run_id, query, variant, out)
    stderr = StringIO.new
    outcome = Quaack::Driver::Teardown.around(transport:, run_id:, stderr:) do
      replayed(transport, run_id, query, variant, out)
    end
    outcome.with(teardown: stderr.string)
  end

  def replayed(transport, run_id, query, variant, out)
    replies = Replies.new(query.name, variant)
    client = E2ERun::CaseLLM.new(replies:).client(burndown: Quaack::Driver::Burndown.new)
    error = drive { Quaack::Driver::Pipeline.new(transport:, client:, run_id:, rewrites: query.rewrites, out:).run }
    Outcome.new(variant:, error:, report: error ? nil : report(transport, run_id),
                html: (File.read(out) if File.exist?(out)),
                entries: Quaack::Driver::Pipeline.status(transport, run_id), store_left: nil, teardown: nil,
                **read_back(query, replies))
  end

  def read_back(query, replies)
    text = replies.rewrites_text
    { log: replies.log, drift: replies.drift, wrong: wrong(query, text), rewrites_text: text }
  end

  # The 6a rewrites become rewrite_1, rewrite_2, and so on, in reply order.
  # Their SQL is read out of the reply text, with the client's own
  # tolerant parse, only to tell which are wrong.
  def wrong(query, text)
    sqls = rewrites(text).map { it.is_a?(Hash) ? it["sql"].to_s : "" }
    sqls.each_index.select { sqls[it].include?(condition(query)) }.map { it + 1 }
  end

  # The subtly wrong condition query.bug adds.
  def condition(query) = query.bug.last.delete_prefix(query.bug.first).delete_prefix(" AND ")

  def rewrites(text)
    return [] unless text

    Quaack::Driver::LLM::ReplyJSON.parse(text, Quaack::Driver::RewriteGeneration::SCHEMA)["rewrites"]
  rescue Quaack::Driver::LLM::Error
    []
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
