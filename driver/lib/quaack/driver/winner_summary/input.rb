# frozen_string_literal: true

module Quaack
  module Driver
    class WinnerSummary
      # What the winner-summary ask sends the LLM, built from the report
      # payload by allowlist: each field is named here, and nothing else of
      # the payload goes in, so a field the enclave adds later, or a key a
      # plan node or a rewrite carries beyond these, never reaches the LLM.
      #
      # Every value is one the report already shows, or one the other LLM
      # steps already get: the redacted original query and the winner's
      # rewrite, both with $n placeholders; the rule names that made the
      # rewrite; the winner's new indexes' definitions; the two plans' nodes
      # (step, table, index, estimated and actual rows, blocks); and the
      # blocks each read on every set of values. A string that isn't plain
      # (a control character, or too long) is dropped, and a number that
      # isn't a count or a share is too.
      #
      # The baseline is the original query with the indexes the database
      # has now. The summary compares the winner with it, never with another
      # candidate.
      module Input
        NAME = /\A[a-z][a-z0-9_]{0,62}\z/
        # A table, index, or plan step's name, or an index's DDL: one line,
        # with no control character.
        PLAIN = /\A[^\p{Cntrl}]{1,2000}\z/
        SQL = /\A[^\u0000]{1,20000}\z/
        MOST_INDEXES = 20
        MOST_NODES = 200
        ORIGINAL_PLAN = "how Postgres runs the original query now, on the indexes the database has"
        MEASURED = "measured on the slow values, with the winner's new indexes if it has any"
        ESTIMATED = "estimated by Postgres without running the query and without the winner's new indexes, so " \
                    "it counts no blocks"

        module_function

        # The payload, as the report holds it with each rewrite named
        # (Report.named), as the Hash the LLM gets, or nil when it has no
        # winner.
        def build(payload)
          label = Array(payload["top"]).first.then { it["label"] if it.is_a?(Hash) }
          return unless label.is_a?(String)

          { "original" => { "sql" => sql(payload["original_sql"]), "plan" => nodes(payload["original_plan"]),
                            "plan_source" => ORIGINAL_PLAN },
            "winner" => winner_part(label, payload), "blocks_read" => blocks(label, payload) }
        end

        def measured(label, payload) = Array(payload["labels"]).find { it["label"] == label } || {}

        def winner_part(label, payload)
          rewrite = rewrite_of(payload, label)
          measured = measured(label, payload)
          plan, source = winner_plan(measured, rewrite)
          { "is" => label.start_with?("original:") ? "the original query" : "a rewrite of the original query",
            "rewrite" => rewrite && rewrite_part(rewrite),
            "new_indexes" => new_indexes(measured["indexes"], payload["indexes"]),
            "plan" => plan, "plan_source" => source }
        end

        def rewrite_of(payload, label)
          search = label.split(":", 2).first
          Array(payload["rewrites"]).find { it.is_a?(Hash) && it["rewrite"] == search } unless search == "original"
        end

        # The winner's plan and what it is: the one QUAACK measured, else
        # the rewrite's own estimated plan, as the report's section shows.
        def winner_plan(measured, rewrite)
          return [nodes(measured["plan"]), MEASURED] if measured["plan"].is_a?(Array)
          return [nodes(rewrite["plan"]), ESTIMATED] if rewrite && rewrite["plan"].is_a?(Array)

          [nil, nil]
        end

        def rewrite_part(rewrite)
          { "name" => (named = rewrite["name"]).is_a?(String) && PLAIN.match?(named) ? "Rewrite #{named}" : nil,
            "source" => %w[rule llm operator].include?(rewrite["source"]) ? rewrite["source"] : nil,
            "rules" => Array(rewrite["rules"]).grep(String).grep(NAME), "sql" => sql(rewrite["sql"]) }
        end

        def sql(text) = text.is_a?(String) && SQL.match?(text) ? text : nil

        def new_indexes(names, indexes)
          return [] unless names.is_a?(Array) && indexes.is_a?(Hash)

          names.first(MOST_INDEXES).filter_map { plain(indexes.dig(it, "ddl")) if indexes[it].is_a?(Hash) }
        end

        def plain(text) = text.is_a?(String) && PLAIN.match?(text) ? text : nil

        # A plan's steps, in the payload's order, each with only the fields
        # of the report's plan table.
        def nodes(plan) = plan.is_a?(Array) ? plan.first(MOST_NODES).grep(Hash).map { node(it) } : []

        def node(node)
          { "step" => plain(node["node"]), "table" => plain(node["relation"]), "index" => plain(node["index"]),
            "estimated_rows" => count(node["est_rows"]), "actual_rows" => count(node["actual_rows"]),
            "depth" => count(node["depth"]), "blocks" => step_blocks(node) }
        end

        # A step's shared hit and read blocks together, as the report's plan
        # table counts them, or nil unless the payload has both.
        def step_blocks(node)
          counts = node.values_at("shared_hit_blocks", "shared_read_blocks")
          counts.sum if counts.all?(Integer) && counts.none?(&:negative?)
        end

        def count(value) = value.is_a?(Numeric) && value.finite? && !value.negative? ? value : nil

        # The blocks the winner and the original query read on each set of
        # values both were measured on, by set.
        def blocks(label, payload)
          winner = measured(label, payload)["measurements"]
          original = payload["original_measurements"]
          winner = {} unless winner.is_a?(Hash)
          original = {} unless original.is_a?(Hash)
          (winner.keys & original.keys).grep(NAME).to_h do |set|
            [set, { "winner" => measurement(winner[set]), "original" => measurement(original[set]) }]
          end
        end

        def measurement(measured)
          return { "blocks" => nil, "timed_out" => nil } unless measured.is_a?(Hash)

          timed_out = [true, false].include?(measured["timed_out"]) ? measured["timed_out"] : nil
          blocks = measured["total_blocks"]
          { "blocks" => (blocks if blocks.is_a?(Integer)), "timed_out" => timed_out }
        end
      end
    end
  end
end
