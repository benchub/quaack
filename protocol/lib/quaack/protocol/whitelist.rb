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
      # Derived statistics for one column, from step 3f. mcv_freqs are the
      # MCV frequencies without their values. low_card_values are the MCV
      # values themselves, and 3f sets them only for low-cardinality columns.
      column_stats: %i[table column n_distinct null_frac correlation mcv_freqs low_card_values].freeze,
      # A failed step: which step, which rule it broke, and the Postgres
      # SQLSTATE if there was one. Never the error's message text, which can
      # hold a real value. function is only on a volatile_function refusal
      # (DESIGN.md 3d): the volatile function's schema-qualified name, which
      # is schema and so shape. The enclave's ErrorFilter sends it only if
      # it's one plain schema.name identifier pair. clients is only on a
      # run_server_other_clients failure (DESIGN.md, step 4): an Array of
      # { "pid", "backend_start" }, one per other client backend on the run
      # server, oldest first, at most 20. A pid is a positive Integer and a
      # start time a UTC YYYY-MM-DDTHH:MM:SSZ, so both are shape: a process
      # number and a clock time, neither configuration nor free text. No
      # other pg_stat_activity column goes out. The enclave's ErrorFilter
      # sends clients only if every entry has exactly that shape.
      error: %i[step rule sqlstate function clients].freeze,
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
      # The DESIGN.md 15b burndown. Its values are nested Hashes, so unlike
      # every other field, they're checked on the way out: the egress
      # function sends them only if Protocol::Burndown.valid? passes, so
      # every count is an Integer and every key is a stage from
      # Protocol::Burndown::STAGES, a record field, or a lowercase word.
      # The enclave's store makes the same check on its burndown entry.
      # stages maps each stage to its searches and each search to its
      # counts. totals maps each work total to its count.
      burndown: %i[stages totals].freeze,
      # What 5a-5 made of one index the LLM proposed (see the enclave's
      # GeneratorThree), never its DDL. index is its 1-based position in
      # the LLM's list. outcome is accepted, set_aside, or dropped. rule is
      # nil or why it was dropped, one of the enclave's own rule constants,
      # such as unqualified_table or covered_by_existing. covered_by is nil
      # or the name of the existing index that covers it, from the catalog,
      # which is schema and so shape. partial_constant_only is true or
      # false: whether it's a partial index, which only works when the
      # predicate's literal is a constant in the application's SQL.
      index_outcome: %i[index outcome rule covered_by partial_constant_only].freeze,
      # The DESIGN.md 5a-5 payload for the LLM, from `quaacks index-payload`,
      # built only from shape-class store entries: query is the 3g redacted
      # query; placeholders each placeholder's 3g shape and the step 1 row
      # counts; plan the 3g redacted step 1 plan; schema the 3b subset;
      # stats the 3f outbound statistics, whose only values are the MCV
      # values of low-cardinality columns; and mechanical_results the 5a-4
      # results, with plans redacted through 3g and each candidate's DDL
      # passed through the enclave's CandidateDdlRedaction, which masks
      # every constant but a low-cardinality value compared directly with
      # its own column in the predicate. The plan goes without its Settings.
      # Its values are
      # nested and go out unchecked, so the enclave's IndexPayload step is
      # where this is reviewed.
      index_payload: %i[query placeholders plan schema mechanical_results stats].freeze,
      # DESIGN.md 5a-6 feedback for the LLM, from `quaacks index-feedback`:
      # the 5a-4 results for its own candidates, built like index_payload
      # (plans redacted through 3g, DDL through CandidateDdlRedaction), with
      # each one's shortfall. Its values are nested and go out unchecked,
      # so the enclave's IndexFeedback step is where this is reviewed.
      index_feedback: %i[revise refined baseline candidates].freeze,
      # Which step outputs a run's store holds, from `quaacks status`:
      # entries maps each of a fixed list of entry names to true or false.
      status: %i[entries].freeze,
      # The DESIGN.md 6a payload, from `quaacks rewrite-payload`: the same
      # shape-class fields as index_payload, without mechanical_results.
      rewrite_payload: %i[query placeholders plan schema stats].freeze,
      # What `quaacks rewrite-check` made of one rewrite (6a or step 7), or
      # `quaacks rewrite-rules` of one rule-made rewrite (6c), never its SQL
      # or its statements. index is its 1-based position in
      # the input. outcome is accepted or rejected. rule is nil or one of
      # the enclave's rule constants. rewrite is nil or the store entry it
      # was saved as, such as rewrite_2. warnings is an Array of
      # { "assumption", "kind" }, one per unmet inferred assumption (step
      # 7): its 1-based position and its kind, from the fixed vocabulary.
      rewrite_outcome: %i[index outcome rule rewrite warnings].freeze,
      # Step 9's verdict on one stored rewrite, from `quaacks rewrite-test`.
      # rewrite is the entry name, such as rewrite_2. passed is true or
      # false. scenario is nil or a scenario name (s0 to s6), and rule nil
      # or one of the enclave's rule constants, such as row_count or
      # discarded. Never SQL or a row.
      rewrite_test: %i[rewrite passed scenario rule].freeze,
      # The DESIGN.md 10a payload, from `quaacks counterexample-payload`:
      # original is the 3g redacted query, candidate { "sql" } the stored
      # rewrite's SQL with $n placeholders (the LLM's own, as the inbound
      # check accepted it), placeholders and schema as in index_payload,
      # and untested_atoms step 9's redacted atom shapes. Its values are
      # nested and go out unchecked, so the enclave's Counterexamples step
      # is where this is reviewed.
      counterexample_payload: %i[original candidate placeholders schema untested_atoms].freeze,
      # One 10b/10c round, from `quaacks counterexample-round`: match is
      # true, false, or nil; rule and load_order nil or enclave constants;
      # covered the redacted shapes of the untested atoms the round
      # exercised; refused [{ index, rule }], each refused insert's 0-based
      # index and rule constant; load_failed true or false.
      counterexample_round: %i[match rule load_order covered refused load_failed].freeze,
      # The DESIGN.md step 15 report, from `quaacks report-payload`: the 14d
      # selection (top, excluded, infinite_sets), minimax verdicts, block
      # counts with hit/read and stability, each top candidate's $n SQL
      # with the 3h functions put back, its untested atoms and step 10
      # evidence, each built index's DDL through CandidateDdlRedaction with
      # its size and catalog coverage, and plan node shapes (type,
      # relation, index, rows, selectivity; never a condition). Its values
      # are nested and go out unchecked, so the enclave's ReportPayload
      # step is where this is reviewed. negative is the 15a negative
      # result: rule, scenario, and round names, redacted DDL, SQLSTATEs,
      # and existing index names. burndown is the 15b burndown's stages and
      # totals, as the burndown message carries them. Each rewrite among
      # candidates and in negative also carries its source (rule, llm, or
      # operator) and, if a 6c rule made it, the rule names. rule_bugs is
      # the rule-made rewrites a test disproved (DESIGN.md 6c): each one's
      # entry name, rule names, and the step that disproved it (step9,
      # step10, or 14c). Sources, rule names, and steps are the enclave's
      # own constants: its RewriteSource sends a source or a rule name only
      # if it's on its own list, never what a store entry holds as it is.
      report: %i[top excluded infinite_sets verdicts measurements candidates indexes original_plan
                 timed_out_count negative rule_bugs burndown].freeze,
      # One line of 12a's progress, sent while `quaacks index-build` works,
      # just before it builds each index: index is its 1-based position,
      # total how many there are, and ddl its DDL through the enclave's
      # CandidateDdlRedaction, as report carries it, with the index's
      # quaack_ name, which report carries too.
      index_build_progress: %i[index total ddl].freeze,
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
