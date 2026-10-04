# The LLM prompt pack

Every prompt the driver sends an LLM, captured from real pipeline runs, for task 20260922-65. You fill in the replies. The end-to-end spec's fake LLM will replay them later.

## What's here

One directory per fixture query, each run through the real pipeline against a throwaway harness Postgres. The schema and data are in `script/prompt_pack/`.

- `orm_join`: an ORM-style join, with equality plus a range, ORDER BY, and LIMIT.
- `group_having`: aggregates with GROUP BY and HAVING.
- `correlated_exists`: a correlated EXISTS subquery.
- `keyset_pagination`: `WHERE (created_at, id) < (...) ORDER BY created_at DESC, id DESC LIMIT n`.

All four run through the whole pipeline to the report. Each has an operator rewrite, so operator-rewrites is asked. For `orm_join` and `correlated_exists`, plan-pruning prunes the operator rewrite. For `group_having` and `keyset_pagination`, it survives to llm-counterexamples and rewrite-index-ideas.

The generator's made-up llm-rewrites reply holds two rewrites, both wrapped in a MATERIALIZED CTE so plan-pruning keeps them. The first is the query itself, so it's exactly equivalent and has no counterexample. The second adds one harmless-looking condition that drops rows real data can hold, so it's wrong, and its llm-counterexamples prompts ask for a real counterexample. rewrite-test's fixtures don't catch it, since the condition tests a column the original never mentions:

- `orm_join`: `AND u.name IS NOT NULL` (`users.name` is nullable). `users.id` is `GENERATED ALWAYS`, so a counterexample that sets ids writes `OVERRIDING SYSTEM VALUE`, which counterexamples allows.
- `group_having`: `AND o.total_cents >= 0` (drops refunds from the counts and sums).
- `correlated_exists`: `AND p.sku <> p.name`.
- `keyset_pagination`: `AND o.updated_at <= o.created_at`.

So in every query, `llm-counterexamples-1` to `llm-counterexamples-3` are the equivalent rewrite's rounds, `llm-counterexamples-4` to `llm-counterexamples-6` the wrong one's, and, where the operator rewrite survives, `llm-counterexamples-7` to `llm-counterexamples-9` are its rounds. For the wrong rewrite, a good reply gives inserts that make the two queries' results differ. For the equivalent one, an honest reply can only try and fail.

Each query directory holds one directory per LLM ask, named `<step>-<n>`, where n counts that step's asks within the query in order. Each of those holds a `prompt.md`. If the pipeline stopped before its end, `stopped.md` says at which step and why, and the prompts for steps after it are missing.

The steps:

- `llm-index-ideas`: index candidates (GeneratorThree). `llm-index-ideas-2` is the follow-up ask for replacements after a candidate was dropped.
- `llm-index-refine`: the index refinement round (RefinementRound).
- `llm-rewrites`: query rewrites (RewriteGeneration).
- `operator-rewrites`: inferring what the operator's own rewrites assume (OperatorCandidates).
- `llm-counterexamples`: counterexample inserts (Counterexamples), up to three rounds per surviving rewrite, numbered on across rewrites (`llm-counterexamples-4` is the second rewrite's first round). Each rewrite keeps its block of three numbers even if an earlier one is disproved before its third round, so the pipeline replay finds each reply by rewrite and round.
- `rewrite-llm-index-ideas` and `rewrite-llm-index-refine`: rewrite-index-ideas' index asks for each rewrite that survived rewrite-test and counterexamples, the same prompts as llm-index-ideas and llm-index-refine but for the rewrite. They're numbered on across rewrites too, so with two survivors, `rewrite-llm-index-ideas-1` and `-2` are the first rewrite's and `-3` and `-4` the second's.

## How to fill it

For every `prompt.md`:

1. Open a fresh chat in each of 3 different LLMs. Name them with short lowercase names, such as `claude`, `gpt`, and `gemini`, and use the same names everywhere.
2. Paste the whole `prompt.md` in as one message. If the chat lets you set a system prompt, you can paste the `# System` section there and the rest as the message instead. Either is fine.
3. Get 3 replies from each LLM. Use a new chat, or regenerate, for each one, so none sees another.
4. Save each reply's text, exactly as the LLM gave it, next to the prompt as `reply-<llm>-<k>.md`, with k from 1 to 3. For example, `orm_join/llm-rewrites-1/reply-gpt-2.md`.

That makes 9 replies per prompt. Don't fix or tidy a reply. A reply that's wrong, or not valid JSON, is useful: the replay should see what real LLMs send.

Some prompts continue a conversation: they hold a `# User`, then an `# Assistant`, then another `# User` section. A chat window can't take an assistant turn, so each of these has a `chat.md` next to its `prompt.md`. When `chat.md` exists, paste it instead of `prompt.md`, as one message (or its `# System` section as the system prompt and the rest as the message). It quotes the earlier exchange plainly, then gives the follow-up and the reply format. Save the reply to the follow-up as usual.

The assistant turn is a planted reply the generator made up, not a real one. It's chosen to steer the pipeline to the follow-up. For example, llm-index-ideas-2's planted reply holds an index on an unqualified table on purpose, so the index gets dropped and the replacement ask always happens. Don't chain the follow-up onto your own earlier reply to the first prompt. Paste `chat.md` into a fresh chat, so every reply answers the same planted history.

`prompt.md` stays the real multi-turn transcript the driver sends, because the replay's drift check compares against it.

## What a reply should look like

Every step asks for one JSON object and nothing else. The driver reads it with the JSON schema at the end of each prompt, under `# Reply format`, which comes from the driver's code:

- `llm-index-ideas` and `llm-index-refine`: `{"indexes": ["CREATE INDEX ...", ...]}`. Each item is one CREATE INDEX statement with a schema-qualified table (`GeneratorThree::SCHEMA`). llm-index-ideas asks for up to five, and a replacement ask or llm-index-refine for up to the number it names.
- `llm-rewrites`: `{"rewrites": [{"sql": "SELECT ...", "transformation": "...", "assumptions": [...]}]}`, at most five rewrites (`RewriteGeneration::SCHEMA`). Each assumption is one of:
  - `{"kind": "not_null", "table": "public.t", "column": "c"}`
  - `{"kind": "unique", "table": "public.t", "columns": ["c", ...]}`
  - `{"kind": "foreign_key", "table": "public.t", "columns": [...], "references_table": "public.p", "references_columns": [...]}`
  - `{"kind": "check", "table": "public.t", "expression": "..."}`
- `operator-rewrites`: `{"rewrites": [{"transformation": "...", "assumptions": [...]}]}`, one entry per operator rewrite, in order, with the same assumption kinds (`OperatorCandidates::SCHEMA`).
- `llm-counterexamples`: `{"inserts": ["INSERT INTO public.t (cols) VALUES (...)", ...]}` (`Counterexamples::SCHEMA`).

Every prompt's system section ends with "Reply with only the JSON object, with no code fences, commentary, or trailing text." (`LLM::Client::JSON_ONLY`, added to every ask with a schema). The real driver also asks the API for structured output with that schema, so the API holds the model to it. A pasted chat doesn't, so a reply may still wrap the JSON in a code fence or add prose. Save it anyway, as it is. The driver's client reads the JSON object out of such a reply: if the whole reply isn't JSON, it takes the longest span from the first `{` to a `}` that parses.

## The archive

`archive/equivalent-rewrite/` holds the first 18 replies, to `correlated_exists/10a-1` and `10a-2` from before task 20260927-20, with the prompts they answered. Those prompts asked for a counterexample to the old, exactly equivalent fake rewrite, so they don't match the live prompts. Its README says more. The generator never touches `archive/`.

## Regenerating

    PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec ruby script/prompt_pack/run.rb [query ...]

Docker must be running. With no query names it runs all four. It rewrites each `prompt.md`, `chat.md`, and `stopped.md`, and never touches a `reply-*.md`. It removes an ask directory that's no longer asked only if it holds nothing but its prompt, and warns about one that holds replies. If a prompt changes after you've collected replies for it, the old replies answer the old prompt, so check the diff before reusing them.

Last, it scans every file here for the queries' literals, as LeakCheck sentinels, and fails if any shows up. The prompts carry only shapes. The values of low-cardinality columns, such as `US` and `shipped` in `most_common_vals`, are there by design (DESIGN.md's classify), so they aren't sentinels.
