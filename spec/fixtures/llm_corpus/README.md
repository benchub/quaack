# The LLM prompt pack

Every prompt the driver sends an LLM, captured from real pipeline runs, for task 20260922-65. You fill in the replies. The end-to-end spec's fake LLM will replay them later.

## What's here

One directory per fixture query, each run through the real pipeline against a throwaway harness Postgres. The schema and data are in `script/prompt_pack/`.

- `orm_join`: an ORM-style join, with equality plus a range, ORDER BY, and LIMIT.
- `group_having`: aggregates with GROUP BY and HAVING.
- `correlated_exists`: a correlated EXISTS subquery.
- `keyset_pagination`: `WHERE (created_at, id) < (...) ORDER BY created_at DESC, id DESC LIMIT n`. The enclave refuses row comparisons today, so this one has no prompts yet.

Each query directory holds one directory per LLM ask, named `<step>-<n>`, where n counts that step's asks within the query in order. Each of those holds a `prompt.md`. If the pipeline stopped before its end, `stopped.md` says at which step and why, and the prompts for steps after it are missing.

The steps:

- `5a-5`: index candidates (GeneratorThree). `5a-5-2` is the follow-up ask for replacements after a candidate was dropped.
- `5a-6`: the index refinement round (RefinementRound).
- `6a`: query rewrites (RewriteGeneration).
- `step7`: inferring what the operator's own rewrites assume (OperatorCandidates).
- `10a`: counterexample inserts (Counterexamples), up to three rounds.

## How to fill it

For every `prompt.md`:

1. Open a fresh chat in each of 3 different LLMs. Name them with short lowercase names, such as `claude`, `gpt`, and `gemini`, and use the same names everywhere.
2. Paste the whole `prompt.md` in as one message. If the chat lets you set a system prompt, you can paste the `# System` section there and the rest as the message instead. Either is fine.
3. Get 3 replies from each LLM. Use a new chat, or regenerate, for each one, so none sees another.
4. Save each reply's text, exactly as the LLM gave it, next to the prompt as `reply-<llm>-<k>.md`, with k from 1 to 3. For example, `orm_join/6a-1/reply-gpt-2.md`.

That makes 9 replies per prompt. Don't fix or tidy a reply. A reply that's wrong, or not valid JSON, is useful: the replay should see what real LLMs send.

Some prompts continue a conversation: they hold a `# User`, then an `# Assistant`, then another `# User` section. The `# Assistant` turn is a placeholder the generator made up, not a real reply. Paste the prompt as it is, and save the reply to the last `# User` section.

## What a reply should look like

Every step asks for one JSON object and nothing else. The driver reads it with the JSON schema at the end of each prompt, under `# Reply format`, which comes from the driver's code:

- `5a-5` and `5a-6`: `{"indexes": ["CREATE INDEX ...", ...]}`. Each item is one CREATE INDEX statement with a schema-qualified table (`GeneratorThree::SCHEMA`). 5a-5 asks for up to five, and a replacement ask or 5a-6 for up to the number it names.
- `6a`: `{"rewrites": [{"sql": "SELECT ...", "transformation": "...", "assumptions": [...]}]}`, at most five rewrites (`RewriteGeneration::SCHEMA`). Each assumption is one of:
  - `{"kind": "not_null", "table": "public.t", "column": "c"}`
  - `{"kind": "unique", "table": "public.t", "columns": ["c", ...]}`
  - `{"kind": "foreign_key", "table": "public.t", "columns": [...], "references_table": "public.p", "references_columns": [...]}`
  - `{"kind": "check", "table": "public.t", "expression": "..."}`
- `step7`: `{"rewrites": [{"transformation": "...", "assumptions": [...]}]}`, one entry per operator rewrite, in order, with the same assumption kinds (`OperatorCandidates::SCHEMA`).
- `10a`: `{"inserts": ["INSERT INTO public.t (cols) VALUES (...)", ...]}` (`Counterexamples::SCHEMA`).

The real driver asks the API for structured output with that schema, so the API holds the model to it. A pasted chat doesn't, so a reply may wrap the JSON in a code fence or add prose. Save it anyway, as it is.

## Regenerating

    PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec ruby script/prompt_pack/run.rb [query ...]

Docker must be running. With no query names it runs all four. It rewrites each `prompt.md` and `stopped.md`, and never touches a `reply-*.md`. It removes an ask directory that's no longer asked only if it holds nothing but its prompt, and warns about one that holds replies. If a prompt changes after you've collected replies for it, the old replies answer the old prompt, so check the diff before reusing them.

Last, it scans every file here for the queries' literals, as LeakCheck sentinels, and fails if any shows up. The prompts carry only shapes. The values of low-cardinality columns, such as `US` and `shipped` in `most_common_vals`, are there by design (README 3f), so they aren't sentinels.
