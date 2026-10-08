# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "runs"
require_relative "provenance/saving"
require_relative "provenance/shape"

module Quaack
  module Driver
    # DESIGN.md's "Several LLM providers" (Provenance): which provider and
    # model produced each idea, rewrite, and counterexample round. It's all
    # driver-side, on the laptop, in ~/.quaack/runs/<run ID>.llm.json, next
    # to the run's record: mode 0600 in the 0700 runs directory, written
    # whole to a temporary file and renamed into place by save.
    #
    #   provenance = Provenance.open(home, run_id)
    #   provenance.providers!([{ "name" => "groq", "provider" => "openai_compatible", "model" => "..." }])
    #   provenance.rewrites!("groq", rewrite_outcomes, proposed: 3)
    #   provenance.save
    #   provenance.author("rewrite_3")  # => { "name" => "groq", "provider" => ..., "model" => ... }
    #
    # The record holds:
    # - providers: each entry's name, provider type, and model, and down, the
    #   rule the run marked it down or dropped it for, if it did. A resumed
    #   run adds new entries and keeps the old ones, as first recorded.
    # - rewrites: each stored llm-rewrites rewrite, by store name, to the
    #   entry that wrote it; rewrites_proposed: how many each entry wrote.
    # - counterexamples: each rewrite's units, in order: the entry, how many
    #   rounds it asked, and, for a fresh start, after, the rule that ended
    #   the entry before it.
    # - index_ideas: by search, then round (first, replacement, refinement),
    #   then entry, how many statements it wrote and its index_outcomes'
    #   counts by outcome and by rule; and skipped, each replacement round
    #   skipped, with its entry and rule.
    # - operator_inference: the entry that inferred the operator rewrites'
    #   transformations and assumptions.
    #
    # Trust boundary. It holds names (from the operator's own config),
    # models, store names, rules, and counts only: never SQL, DDL, a prompt,
    # or a reply. Each writer takes only those, and a record read back keeps
    # only the parts that have exactly those shapes, so the report reads
    # nothing else from it. Nothing in it goes to the enclave or an LLM.
    class Provenance
      NAME = /\A[a-z0-9_-]{1,32}\z/
      PROVIDER = /\A[a-z_]{1,32}\z/
      MODEL = /\A[^\n\r]{1,256}\z/
      RULE = /\A[a-z0-9_]{1,64}\z/
      REWRITE = /\Arewrite_[1-9]\d{0,8}\z/
      SEARCH = /\A(original|rewrite_[1-9]\d{0,8})\z/
      ROUNDS = %w[first replacement refinement].freeze
      OUTCOMES = %w[accepted set_aside dropped].freeze

      include Saving

      # A record callable for a run with no provenance record: it does
      # nothing.
      NONE = ->(*) {}

      # A callable, given a block, that has the block record what an LLM
      # step did in provenance, with the router's (client's) entries and
      # the providers it marked down or dropped, then saves the record
      # whole. Each LLM step calls it once it's done. NONE without
      # provenance.
      def self.recorder(provenance, client)
        return NONE unless provenance && client

        lambda do |&block|
          provenance.providers!(client.entries)
          block&.call(provenance)
          provenance.down!(client.down).save
        end
      end

      def self.path(home, run_id)
        raise ArgumentError, "not a run ID" unless Runs::RUN_ID.match?(run_id)

        File.join(home, ".quaack", "runs", "#{run_id}.llm.json")
      end

      # The run's record, as far as it's there and well formed.
      def self.open(home, run_id)
        path = path(home, run_id)
        new(path, read(path))
      end

      def self.read(path)
        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? Shape.record(parsed) : {}
      rescue JSON::ParserError, SystemCallError, IOError
        {}
      end

      # path nil keeps the record in memory only, for a report built from
      # a record already read.
      def initialize(path = nil, record = {})
        @path = path
        @record = record
      end

      # The record, as it would be saved.
      def record = JSON.parse(JSON.generate(@record))

      # entries are each provider's name, provider type, and model. An
      # entry already recorded keeps its first record.
      def providers!(entries)
        list = (@record["providers"] ||= [])
        entries.each do |entry|
          clean = Shape.provider(entry.slice("name", "provider", "model"))
          list << clean if clean && list.none? { it["name"] == clean["name"] }
        end
        self
      end

      # downs maps each provider the run marked down or dropped to its rule.
      def down!(downs)
        downs.each do |name, rule|
          entry = Array(@record["providers"]).find { it["name"] == name }
          entry["down"] = rule if entry && RULE.match?(rule.to_s)
        end
        self
      end

      # entry wrote the llm-rewrites rewrites, proposed of them, whose
      # rewrite_outcomes are outcomes: each accepted one's store name.
      def rewrites!(entry, outcomes, proposed:)
        return self unless named?(entry)

        stored = outcomes.map { it["rewrite"] }.grep(REWRITE)
        (@record["rewrites"] ||= {}).merge!(stored.to_h { [it, entry] })
        (@record["rewrites_proposed"] ||= {})[entry] = proposed if count?(proposed)
        self
      end

      # A rewrite's units, each { "entry", "rounds", "after" }, replacing
      # any recorded before, since a rerun's rounds are the ones that count.
      def counterexamples!(rewrite, units)
        clean = units.map { Shape.unit(it.compact) }
        (@record["counterexamples"] ||= {})[rewrite] = clean if REWRITE.match?(rewrite) && clean.all?
        self
      end

      # GeneratorThree's result for search, in the record: each round's
      # statements and outcomes, the first round's even when it wrote
      # none, and a skipped replacement round.
      def index_ideas!(search, result)
        rounds = result.rounds.to_h { [it.round, [it.ddls.size, it.outcomes]] }
        rounds["first"] ||= [0, []]
        rounds.each { |round, (written, outcomes)| index_round!(search, round, result.provider, written, outcomes) }
        result.skipped ? skipped!(search, result.provider, result.skipped) : self
      end

      # RefinementRound's result for search, in the record.
      def refinement!(search, result)
        index_round!(search, "refinement", result.provider, result.ddls.size, result.outcomes)
      end

      # entry wrote written statements in search's round, whose
      # index_outcomes are outcomes.
      def index_round!(search, round, entry, written, outcomes)
        return self unless ROUNDS.include?(round) && named?(entry) && count?(written)

        search(search)&.then { (it[round] ||= {})[entry] = Shape.tallies(written, outcomes) }
        self
      end

      # search's replacement round, entry's, was skipped for rule.
      def skipped!(search, entry, rule)
        return self unless named?(entry) && RULE.match?(rule.to_s)

        search(search)&.then { (it["skipped"] ||= []) << { "entry" => entry, "rule" => rule } }
        self
      end

      def operator_inference!(entry)
        @record["operator_inference"] = entry if named?(entry)
        self
      end

      # The recorded provider that wrote rewrite, or nil.
      def author(rewrite) = provider(@record.dig("rewrites", rewrite))

      # The recorded provider named name, or nil.
      def provider(name) = Array(@record["providers"]).find { it["name"] == name }&.slice("name", "provider", "model")

      private

      def named?(entry) = entry.is_a?(String) && NAME.match?(entry)
      def count?(value) = value.is_a?(Integer) && !value.negative?

      # search's part of index_ideas, or nil for a search that isn't one.
      def search(search) = ((@record["index_ideas"] ||= {})[search] ||= {} if SEARCH.match?(search))
    end
  end
end
