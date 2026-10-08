# frozen_string_literal: true

module Quaack
  module Protocol
    # The one list of what may leave the production enclave (DESIGN.md, "Trust
    # boundary"). Each key is a type of message the enclave script prints,
    # and its value is the only fields that message may carry. The enclave's
    # egress function sends each message as its type plus these fields, and
    # drops every other field and every message of a type not listed here.
    #
    # These are the fields of QUAACK's own messages, not database columns, so
    # this changes only when a step changes what it prints. Every field
    # listed here goes out as is, with no check on its value. So add a field
    # only if every value it can ever hold is shape-class data, and treat each
    # change to this file as a change to the trust boundary.
    WHITELIST = {
      # Derived statistics for one column, from classify. mcv_freqs are the
      # MCV frequencies without their values. low_card_values are the MCV
      # values themselves, and classify sets them only for low-cardinality columns.
      column_stats: %i[table column n_distinct null_frac correlation mcv_freqs low_card_values].freeze,
      # A failed step: which step, which rule it broke, and the Postgres
      # SQLSTATE if there was one. Never the error's message text, which can
      # hold a real value. reason is only on a query_unreadable or
      # plan_unreadable refusal from intake: one of the enclave's fixed cause
      # names, such as missing or permission_denied. It never comes from the
      # path or the OS message. function is only on a volatile_function refusal
      # (DESIGN.md's volatility): the volatile function's schema-qualified name, which
      # is schema and so shape. The enclave's ErrorFilter sends it only if
      # it's one plain schema.name identifier pair. clients is only on a
      # run_server_other_clients failure (DESIGN.md's run-server): an Array of
      # { "pid", "backend_start" }, one per other client backend on the run
      # server, oldest first, at most 20. A pid is a positive Integer and a
      # start time a UTC YYYY-MM-DDTHH:MM:SSZ, so both are shape: a process
      # number and a clock time, neither configuration nor free text. No
      # other pg_stat_activity column goes out. The enclave's ErrorFilter
      # sends clients only if every entry has exactly that shape. column is
      # only on an unsupported_type or domain_check refusal from rewrite-test: the
      # { "table", "column", "type" } of the column rewrite-test can't fill, which
      # are schema names, a schema.name pair, a name, and a type as
      # format_type prints it, never a row value. The enclave's ErrorFilter
      # sends it only if each is a plain unquoted name of that shape. cycle
      # is only on an fk_cycle refusal: the tables of a foreign key cycle,
      # 3 to 64 schema.name Strings in the order their foreign keys point,
      # the last the first again. They're schema names, each one checked to
      # be a relation of the run's schema subset, and never a row value.
      # tables is only on a dump_object_unreadable refusal: 1 to 64
      # schema.name Strings, the tables schema-dump needs that the
      # operator's role can't read. They're schema names, for the operator,
      # and never reach the LLM.
      error: %i[step rule sqlstate reason function clients column cycle tables].freeze,
      # The enclave script's version, from `quaacks --version`. It's the
      # gem's VERSION constant, never anything read from a run.
      version: %i[version].freeze,
      # The run `quaacks intake` started, for the driver to name in each
      # later call. run_id is only ever a Store run ID: the UTC time the run
      # started and eight random hex characters, never anything from the
      # operator's inputs.
      run: %i[run_id].freeze,
      # What `quaacks teardown` did with a run. run_id comes from argv, and
      # the CLI sends it back only once it matches the Store run ID form:
      # the UTC time the run started and eight random hex characters. store
      # is deleted or already_gone. next_step is none when the configured
      # destroy_command destroyed the run server, and otherwise
      # destroy_run_server, since the operator must. store and next_step
      # are the enclave's own constants.
      # None of the three is ever read from the run.
      teardown: %i[run_id store next_step].freeze,
      # What `quaacks inventory` recorded, as shape only. major_version is
      # an Integer, production's server_version_num divided by 10,000, such
      # as 18. memory_known is true or false: whether the operator's memory
      # command gave the instance memory. The inventory itself, its settings,
      # locale names, and extensions, stays in the store.
      inventory: %i[major_version memory_known].freeze,
      # DESIGN.md's burndown. Its values are nested Hashes, so unlike
      # every other field, they're checked on the way out: the egress
      # function sends them only if Protocol::Burndown.valid? passes, so
      # every count is an Integer and every key is a stage from
      # Protocol::Burndown::STAGES, a record field, or a lowercase word.
      # The enclave's store makes the same check on its burndown entry.
      # stages maps each stage to its searches and each search to its
      # counts. totals maps each work total to its count.
      burndown: %i[stages totals].freeze,
      # What llm-index-ideas made of one index the LLM proposed (see the enclave's
      # GeneratorThree), never its DDL. index is its 1-based position in
      # the LLM's list. outcome is accepted, set_aside, or dropped. rule is
      # nil or why it was dropped, one of the enclave's own rule constants,
      # such as unqualified_table or covered_by_existing. covered_by is nil
      # or the name of the existing index that covers it, from the catalog,
      # which is schema and so shape. partial_constant_only is true or
      # false: whether it's a partial index, which only works when the
      # predicate's literal is a constant in the application's SQL.
      index_outcome: %i[index outcome rule covered_by partial_constant_only].freeze,
      # DESIGN.md's llm-index-ideas payload for the LLM, from `quaacks index-payload`,
      # built only from shape-class store entries: query is the redacted
      # query; placeholders each placeholder's redact shape and the input row
      # counts; plan the redacted input plan; schema the schema-dump subset;
      # stats the classify outbound statistics, whose only values are the MCV
      # values of low-cardinality columns; and mechanical_results the index-test
      # results, with plans redacted through redact and each candidate's DDL
      # passed through the enclave's CandidateDdlRedaction, which masks
      # every constant but a low-cardinality value compared directly with
      # its own column in the predicate. The plan goes without its Settings.
      # Its values are
      # nested and go out unchecked, so the enclave's IndexPayload step is
      # where this is reviewed.
      index_payload: %i[query placeholders plan schema mechanical_results stats].freeze,
      # DESIGN.md's llm-index-refine feedback for the LLM, from `quaacks index-feedback`:
      # the index-test results for its own candidates, built like index_payload
      # (plans redacted through redact, DDL through CandidateDdlRedaction), with
      # each one's shortfall. Its values are nested and go out unchecked,
      # so the enclave's IndexFeedback step is where this is reviewed.
      index_feedback: %i[revise refined baseline candidates].freeze,
      # Which step outputs a run's store holds, from `quaacks status`:
      # entries maps each of a fixed list of entry names to true or false.
      status: %i[entries].freeze,
      # DESIGN.md's llm-rewrites payload, from `quaacks rewrite-payload`: the same
      # shape-class fields as index_payload, without mechanical_results, plus
      # rule_rewrites: each rule-made rewrite's SQL, with the original's $n
      # placeholders, and its rule names, QUAACK's own constants. Its values
      # are nested and go out unchecked, so the enclave's RewritePayload step
      # is where this is reviewed.
      rewrite_payload: %i[query placeholders plan schema rule_rewrites stats].freeze,
      # What `quaacks rewrite-check` made of one rewrite (llm-rewrites or operator-rewrites), or
      # `quaacks rewrite-rules` of one rule-made rewrite (rewrite-rules), never its SQL
      # or its statements. index is its 1-based position in
      # the input. outcome is accepted or rejected. rule is nil or one of
      # the enclave's rule constants. rewrite is nil or the store entry it
      # was saved as, such as rewrite_2. warnings is an Array of
      # { "assumption", "kind" }, one per unmet inferred assumption
      # (operator-rewrites): its 1-based position and its kind, from the fixed vocabulary.
      rewrite_outcome: %i[index outcome rule rewrite warnings].freeze,
      # rewrite-test's verdict on one stored rewrite, from `quaacks rewrite-test`.
      # rewrite is the entry name, such as rewrite_2. passed is true or
      # false. scenario is nil or a scenario name (s0 to s6), and rule nil
      # or one of the enclave's rule constants, such as row_count or
      # discarded. Never SQL or a row.
      rewrite_test: %i[rewrite passed scenario rule].freeze,
      # DESIGN.md's llm-counterexamples payload, from `quaacks counterexample-payload`:
      # original is the redacted query, candidate { "sql" } the stored
      # rewrite's SQL with $n placeholders (the LLM's own, as the inbound
      # check accepted it), placeholders and schema as in index_payload,
      # and untested_atoms rewrite-test's redacted atom shapes. Its values are
      # nested and go out unchecked, so the enclave's Counterexamples step
      # is where this is reviewed.
      counterexample_payload: %i[original candidate placeholders schema untested_atoms].freeze,
      # One counterexample-compare and counterexample-rollback round, from `quaacks counterexample-round`: match is
      # true, false, or nil; rule and load_order nil or enclave constants;
      # covered the redacted shapes of the untested atoms the round
      # exercised; refused [{ index, rule }], each refused insert's 0-based
      # index and rule constant; load_failed true or false.
      counterexample_round: %i[match rule load_order covered refused load_failed].freeze,
      # DESIGN.md's report, from `quaacks report-payload`.
      # original_sql is the original query, always sent: its $n SQL with
      # the clock-anchor functions put back. original_plan is its plan's node shapes
      # (type, relation, index, rows, selectivity, depth, an Integer, and
      # shared hit and read block counts, each an Integer or nil; never a
      # condition), and
      # original_measurements its block counts with hit/read and stability
      # per literal set. top, excluded, and infinite_sets are the selection
      # selection. labels is every measured label, ranked or not: its
      # search, the built names of the indexes it ran with, its block
      # counts, minimax's per-literal verdicts, and whether it timed out.
      # rewrites is every stored rewrite, ranked or not: its entry name,
      # its $n SQL, its source (rule, llm, or operator) and, if a rewrite-rules rule
      # made it, the rule names and the tables and columns of the
      # denormalized_equal assumptions it rests on (only names its SQL
      # already holds, never the type value), its fate with the scenario,
      # rule, round, or last stage that goes with it (and, for an fk_cycle
      # refusal, the cycle's table names, each a relation of the run's
      # schema subset), its plan's node shapes, its
      # untested atoms (rewrite-test's redacted shapes), the shapes of those
      # the counterexample rounds covered, and its counterexamples
      # evidence. indexes is each built index's DDL through
      # CandidateDdlRedaction with its size and catalog coverage, each
      # existing index as its name and size in bytes. negative is the negative-result
      # negative result: each declined or already existing index once, as
      # redacted DDL, with a reason, a SQLSTATE, the existing index's name
      # and size, and the searches it came up in. burndown is the burndown
      # burndown's stages and totals, as the burndown message carries
      # them. rule_bugs is the rule-made rewrites a test disproved
      # (DESIGN.md's rewrite-rules): each one's entry name, rule names, and the step that
      # disproved it (rewrite-test, counterexamples, or result-comparison). index_sources is,
      # for each of QUAACK's index sources (generator_one, generator_two,
      # llm), how many of the built indexes it proposed, how many of those
      # were not better, and how many were ranked: counts only, under the
      # fixed names of Protocol::IndexSources. Its values are nested.
      # hidden_statistics, when the payload has it, is the names of the
      # expression indexes whose statistics the production role couldn't
      # see, and a count, never the names, of the extended statistics
      # objects whose data it couldn't see; it must pass
      # Protocol::HiddenStatistics.valid?.
      # The plans, original_plan and each rewrite's plan, are checked on
      # the way out: the egress function sends a report only if each passes
      # Protocol::PlanNodes.valid?, so every node has exactly the fields
      # above, each of its type, and only if index_sources passes
      # Protocol::IndexSources.valid?. The rest go out unchecked, so the enclave's
      # ReportPayload step is where they're reviewed. Sources, rule names, fates, scenarios, and steps are the
      # enclave's own constants: its RewriteSource and RewriteFate send
      # one only if it's on their own lists, never what a store entry holds
      # as it is.
      report: %i[original_sql original_plan original_measurements top excluded infinite_sets labels rewrites
                 indexes timed_out_count negative rule_bugs burndown index_sources hidden_statistics].freeze,
      # One line of index-build's progress, sent while `quaacks index-build` works,
      # just before it builds each index: index is its 1-based position,
      # total how many there are, and ddl its DDL through the enclave's
      # CandidateDdlRedaction, as report carries it, with the index's
      # quaack_ name, which report carries too.
      index_build_progress: %i[index total ddl].freeze,
      # What a step did, as counts, for the driver's closing progress line,
      # sent by index-search, index-rank, arena-setup, baseline,
      # index-baseline, candidate-runs, minimax, result-comparison,
      # selection, and rewrite-rules. Each field but rules is a count, and
      # rules is rewrite-rules' fired rules, by name. The values are checked
      # on the way out: the egress function sends it only if
      # Protocol::StepCounts.valid? passes, so every count is a small
      # non-negative Integer and every name is on StepCounts::RULE_NAMES.
      step_counts: %i[found used ranked combined tables sets timed_out combinations measured compared survivors
                      discarded partial top excluded rules].freeze,
      # The last line of every call to the enclave script that succeeded,
      # after the step's own lines. It carries nothing.
      done: [].freeze
    }.freeze

    # The types a step may send while it's still running, ahead of its
    # other lines (see the enclave's CLI). The driver hands only these to a
    # call's progress block, and leaves them out of the call's messages.
    PROGRESS = %i[index_build_progress].freeze
  end
end
