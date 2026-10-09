# QUAACK completed backlog.

Old step IDs here, such as `5a-7` or `steps 9-10`, are mapped to their slugs in DESIGN.md's "Old step IDs" table.

Finished tasks move here from BACKLOG.md with their full entries. Don't reopen them. If one needs more work, add a new task to BACKLOG.md that points back to it.

## Foundations.

### 20260922-1. Project skeleton.

Set up the repo: package layout with separate driver and enclave packages, dependency management, test runner, and linting. The two packages must not import each other's internals, since they run on different machines.

- **Depends on:** None.
- **README:** Where QUAACK runs.
- **Status:** done
- **Decided:**
  - Ruby 3.4, with the pg_query gem. Ruby is already on the jump servers, and adding pg_query is simple. Locally, Ruby 3.4 is Homebrew's keg-only `ruby@3.4`.
  - Postgres 18 only.
  - Separate gems in one repo: a driver gem, an enclave gem, and a small shared gem for the protocol between them. The enclave gem never depends on the driver gem or the LLM SDK.
  - RSpec for tests. No hosted CI: the user has no use for GitHub CI, so the local `bundle exec rake` is the whole check.
  - The jump servers are ARM (`aarch64-linux`). Nothing needs x86_64.
- **Landed:** Merged into `main` after two reviews. The first review's findings were fixed in the builder's one fix round. The second review found no blockers, and its findings became 20260923-4 through 20260923-7. At landing, the main session removed the GitHub Actions workflow and the x86_64 lockfile platform, and corrected docs that overstated the runtime boundary check.

### 20260922-6. LLM client.

Build the driver's LLM client, with a test double so tests never make real LLM calls. Count every call by step for the 15b burndown.

- **Depends on:** 20260922-1.
- **README:** Where QUAACK runs, 15b.
- **Status:** done
- **Decided:**
  - Use the Anthropic API through the official `anthropic` Ruby gem. The key comes from `ANTHROPIC_API_KEY` on the laptop. The default model is `claude-opus-5-5`, and config can override it.
  - Don't build a provider abstraction yet, but don't make one hard to add later. The user may want other providers, or several models working in parallel, someday.
- **Landed:** Merged into `main` after two reviews. The first review's findings were fixed in the builder's one fix round. The second review found no blockers, and its minor findings went to 20260924-14.

### 20260922-66. Run teardown.

At the end of a run, delete the governed store directory and tell the operator to destroy the run server.

- **Depends on:** 20260922-3.
- **README:** Where QUAACK runs.
- **Status:** done
- **Decided:** Teardown runs when a run ends, whether it succeeded or aborted. A `--keep` flag leaves the run server and store directory in place for debugging, and `quaacks teardown --run <run>` removes the store later. It only reminds the operator to destroy the run server.
- **Landed:** The enclave side was merged into `main` after a review, a fix round, and a clean second review. It adds `quaacks teardown --run <id>`, `Store.teardown`, the `teardown` whitelist type (`run_id`, `store`, `next_step`), and the rules `bad_run`, `bad_store_base`, and `teardown_failed`. The driver side (automatic teardown when a run ends, and `--keep`) is wiring, so it moved to 20260922-65 as a note. The minor findings went to 20260924-17.

### 20260922-5. Driver transport.

Build the driver side of the link: call enclave subcommands over ssh, pass arguments and untrusted inputs, and parse the results. Include a local transport so tests can run the enclave script without ssh.

- **Depends on:** 20260922-4.
- **README:** Where QUAACK runs.
- **Note (from the reviews of 20260922-4 and 20260922-8):** The driver's contract for reading `quaacks` output:
  - Skip blank lines, and lines that aren't JSON.
  - Treat any run as failed if it printed an error line, exited nonzero, or died by a signal, and discard its other lines. A signal in the middle of a write can leave a cut-off line, and valid-looking lines can come before the error line.
  - Exit codes are 0 for success, 64 when the CLI refuses a call, and 70 when a step fails. A signal death means the process died by that signal after writing its error line.
- **Note (from the second review of 20260922-4):** A step can end the process with `exit!(0)`, which prints nothing, so an empty stdout isn't proof of success. 20260923-53 adds a final `done` line to every successful run. Treat a run as failed unless `done` is its last non-blank line. A flush failure can print `done` and then an error line.
- **Status:** done
- **Decided:** Larger inputs go to the enclave script as a JSON document on stdin, piped into `ssh <jump server> quaacks <subcommand>`. The local test transport pipes the same JSON.
- **Landed:** Merged into `main` after a review, a fix round, a second review, a tests-only round, and a fresh check of those tests. It has `Transport::Local` and `Transport::Ssh` with `call(subcommand, args:, input:)`, and `EnclaveError` with only shaped fields. Any line that breaks the whitelist fails the run as `unexpected_output`. The minor findings went to 20260924-20.

## Added later.

### 20260923-3. Rename the enclave gem to quaacks.

Rename the `quaack-enclave` gem and its executable to `quaacks`. The "s" stands for server, which pairs it with the driver's `quaack`. Update every reference, including the gemspec, the executable, the boundary and runtime specs, the allowlists, `CLAUDE.md`, and the backlog.

- **Depends on:** 20260922-1.
- **Came from:** The user, during 20260922-1.
- **README:** Where QUAACK runs.
- **Status:** done
- **Decided:**
  - The gem and executable are named `quaacks`.
  - Internal names stay as "enclave," such as the `enclave/` directory and the `Quaack::Enclave` module, to match the README's "enclave script." The README doesn't change.
- **Landed:** Merged into `main` after two reviews. The builder found that a check keyed on the literal `quaack-enclave` would have gone vacuous after the rename. Checks now read gem names from the gemspecs through a new `RepoGems` test helper. The first review found one vacuous test, which the fix round replaced. The second review found no blockers, and its minor findings became 20260923-8.

### 20260923-5. Discover spec suites instead of listing them.

Removing the root suite from `SPEC_SUITES` in the `Rakefile` turns off every boundary check, and `rake` stays green. That's because the spec that pins `SPEC_SUITES` lives in the root suite itself. Derive the suites from the directories that have a `spec/` folder, so there's nothing to forget.

- **Depends on:** 20260922-1.
- **Came from:** Second review of 20260922-1, finding 3.
- **README:** None. This is test infrastructure.
- **Status:** done
- **Landed:** Merged into `main` after two reviews. The Rakefile finds the suites from the root and each top-level directory with a `spec/` folder, leaving out `vendor/` and hidden directories. It runs every suite in its own process from its own directory, fails at the end if any suite failed or ran no examples, and fails if the root suite didn't run. The first review found that small edits could still drop the root suite with `rake` green, and the fix round added the root guard. The second review found no blockers, and its findings became 20260923-9 and 20260923-10.

### 20260923-4. Harden the runtime boundary check.

The runtime check in `spec/runtime_boundary_spec.rb` has two gaps:
- **It trusts the gemspec.** It builds its allowed set from the enclave gemspec's own dependency closure. If the enclave gains a dependency on `quaack-driver`, the check installs the driver and allows loading it. Only the dependency allowlist in `spec/boundary_spec.rb` catches that today. The runtime check should take the closure from that same allowlist, or assert that nothing loads from the driver gem or a known LLM gem.
- **It only runs `--version`.** A forbidden require in any other code path, such as `Kernel.enum_for("require", "quaack/driver").first` in the usage branch, passes every check. Make it also require every file under the installed gem's `lib/`. Write down what it still can't catch, like lazy loads inside method bodies.

- **Depends on:** 20260922-1.
- **Came from:** Second review of 20260922-1, findings 1 and 2.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Squash-merged into `main` after two reviews, under the user's accident-only threat model: the boundary guards against honest mistakes, not a deliberate insider. The runtime check now takes the enclave's allowed gems from `Boundary::ENCLAVE_ALLOWED_GEMS`, the same allowlist the static check uses. It rejects anything loaded from the other side, and for the enclave any LLM SDK, whatever the gemspec says. Besides `--version` and the usage branch, it requires every file under each shipped repo gem's `lib/`, including `quaack-protocol`. The first review found that the protocol gem was never loaded, and the fix round covered it. The second review found no blockers. At landing, the main session corrected CLAUDE.md, which implied the driver can't load an LLM SDK. The review's other findings became 20260923-13.

### 20260923-11. Index candidate and statistics shapes.

Define the two shapes that 5a-1 and 5a-2 share, so both generators can be built in parallel without conflicting:
- **`IndexCandidate`** is an immutable value. It holds the table (schema qualified), the key columns with their sort directions, the `INCLUDE` columns, the index method, an optional partial predicate, and the generators that proposed it. Two candidates with the same definition compare equal whatever their sources are. It can render itself as `CREATE INDEX` DDL through pg_query.
- **The statistics input** is what the generators read about each table and column. Per table, it holds `reltuples`. Per column, it holds `n_distinct`, `null_frac`, and `correlation`. It includes a helper for the distinct count: when `n_distinct` is negative, take its absolute value times `reltuples`.

- **Depends on:** 20260922-1.
- **Came from:** The user, who asked to build 5a-1 and 5a-2 in parallel with the main line.
- **README:** 5a, 5a-1, 5a-2, and 5a-3.
- **Status:** done

- **Landed:** Merged into `main` together with 20260923-14, which finished it. Its own loop ran a build, a review, a fix round, and a second review. The second review found a pattern-matching predicate leak, vacuous freeze and guard tests, and no UNIQUE support, so the work couldn't land until 20260923-14 fixed them.

### 20260923-14. Finish the index candidate and statistics shapes.

Start from the unlanded 20260923-11 branch (`shapes-20260923-11`, `324f495`) and fix what its second review found:
- **UNIQUE indexes (sufficiency).** `IndexCandidate.from_ddl` returns nil for every UNIQUE index, primary keys included, because the shape has no uniqueness. So `TableStatistics#indexes` never shows those indexes' columns. 5a-2 can't extend `orders_pkey`, and 5a-3 can't see that `(id)` is already covered.
- **Pattern-matching leak (trust boundary).** `case cand in {...}` with no match raises `NoMatchingPatternError`, whose message holds the raw predicate. The public `definition` exposes the predicate the same way. Close both, or document them next to `to_h` if closing isn't reasonable, and add sentinel tests.
- **Vacuous tests.** These mutants survive:
  - dropping `name.dup.freeze` in `KeyColumn` and in the column-name helper, since the "deeply frozen" test only passes literals, which are already frozen
  - dropping the `is_a?(IndexCandidate)` guard in `==` and `eql?`, where `cand == nil` must be false
  - `column_names.dup.freeze` in place of freezing each name
  - dropping `by_name.freeze` in `Statistics`
  - dropping the CONCURRENTLY and IF NOT EXISTS reset in `from_ddl`
- **Unchecked definitions (correctness, low).** The constructor accepts some definitions Postgres rejects: `$1`, subqueries, and volatile or aggregate functions in predicates, BRIN with INCLUDE, and multicolumn hash. Reject the cheap ones, or document that the shape doesn't check them.
- **Minor.** A `Complex` `n_distinct` raises RangeError, not ArgumentError. Duplicate `column_names` are accepted.

- **Depends on:** 20260923-11 (unlanded branch).
- **Came from:** Second review of 20260923-11.
- **README:** 5a, 5a-2, and 5a-3.
- **Status:** done
- **Landed:** Merged into `main` with 20260923-11, after a build, a review, a fix round, and a second review. It added `unique`, closed the pattern-matching leak, refused definitions Postgres rejects, and killed the surviving mutants. The first review found two vacuous tests, a require that was wrongly called equivalent, and overstated aggregate comments, and the fix round fixed them. The second review found no blockers, and its minor findings became 20260923-17.

### 20260922-2. Test database harness.

Give the test suite throwaway Postgres instances with HypoPG installed, plus a small sample schema like the README's `orders` and `customers` example. Integration tests for most later tasks need this.

- **Depends on:** 20260922-1.
- **README:** Steps 4, 5a, and 9.
- **Status:** done
- **Decided:**
  - Postgres 18 runs in Docker, from our own image: `postgres:18` plus the `postgresql-18-hypopg` package, since the official image doesn't include HypoPG.
  - A small Ruby test helper builds the image and drives it with the `docker` command. No testcontainers gem and no Compose.
  - One container per test run. Each test that needs a database gets a fresh one, created from a template and dropped afterward. Tests that need racetrack and arena side by side get two databases in the same container, like the real run server.
- **Landed:** Merged into `main` together with 20260923-15, which finished it. Its own loop found that a failed launch was never remembered, and that a forked child removed the parent's container. The fix round fixed both, but also added `ForkGuard`, which leaked every connection a test dropped. The second review blocked it on that leak, and 20260923-15 removed `ForkGuard`.

### 20260923-15. Finish the test database harness without ForkGuard.

Start from the unlanded 20260922-2 branch (`harness-20260922-2`, `1bd288f`) and fix what its second review found:
- **Remove `TestPostgres::ForkGuard` and the connection tracking (correctness).** `TestPostgres.open` keeps a strong reference to every connection. So a connection a test opens with `Database#connect` and never closes never gets its socket back. With the default macOS limit of 256 open files, about 250 such examples crash the run with `Errno::EMFILE`, and the container leaks because the `at_exit` `docker rm` can't open a pipe. Nothing in QUAACK forks. Keep the owner-pid guard on the `at_exit` cleanup. Document that a spec must not fork after using a database, or that the child must `exit!`.
- **Fork test (vacuous in part).** After ForkGuard is gone, the fork test should check what's still promised: a forked child that exits with `exit!` doesn't remove the parent's container, and the parent's own example connection still works in the same example.
- **"Dropped afterward" isn't pinned (test quality).** Changing `config.after` to `config.before` keeps every test green. Check within the example's own lifecycle that its databases exist during the example and are gone after it.
- Add a regression test for the connection leak. For example, open many connections through `connect` and drop them, then check the process doesn't keep their sockets open.

- **Depends on:** 20260922-2 (unlanded branch).
- **Came from:** Second review of 20260922-2, findings 1 through 4.
- **README:** Steps 4, 5a, and 9.
- **Status:** done
- **Landed:** Merged into `main` with 20260922-2 after a build, a review, a fix round, and a second review. It removed `ForkGuard` and its connection tracking, kept the owner-pid guard, and documented that a spec must not fork after using a database. It added a regression test for the leaked connections, rewrote the fork tests, and pinned down when databases get dropped. The fix round made a failed drop forget that example's databases, and made a lost connection raise `TestPostgres::ConnectionLost`. The second review found no blockers, and its minor findings went into 20260923-16.

### 20260923-13. Tighten the runtime boundary checker tests.

The second review of 20260923-4 found no boundary holes, since every in-scope plant in the real repo turns the runtime spec red. But some tests prove less than their names say:
- **Three checker tests pass with their plant removed.** In `spec/runtime_boundary_checker_spec.rb`, the tests for an orphan enclave lib file, an orphan protocol lib file, and the driver loading the enclave from a file `--version` never reaches each add the other side as a dependency. The every-file run then loads that gem's own files, which get flagged whether or not the planted `hidden.rb` exists. Drop the added dependency, or assert that the message names the planted file. Also add a deliberate test that a bare driver dependency, with no require, is flagged.
- **The real-gem every-file test can't tell every file from the entry file.** `spec/runtime_boundary_spec.rb` asserts that the entry file and `cli.rb` loaded, but the entry file loads `cli.rb` itself. Requiring only the first file keeps it green.
- **Code no test observes.** Nothing tests the trailing `/` in `under?`. The `rubyarchdir` entry in `stdlib_dirs` is redundant. `forbidden_require?` tries every `/lib/` split when the last one would do. `Check#closure`'s custom lookup can be replaced with `Boundary.installed_spec` and stay green. Simplify or test each one.
- **Known-gaps comment.** Mention `begin; require "openai"; rescue LoadError; end`. A rescued LoadError passes the runtime check, and only the static check catches it.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260923-4, findings 1, 2, 3, and 5. Finding 4 was a CLAUDE.md wording fix, made at landing.
- **Note:** This task came before the rule that vacuous tests block landing. It fixes the vacuous tests that landed with 20260923-4, so it comes before version 1.
- **README:** None. This is test infrastructure.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The orphan tests now require the other side from the repo checkout with no added dependency, and they assert the planted file's path. New tests show that a bare dependency is flagged on both sides. The real-gem test now asserts that every installed lib file loaded. Rules unit tests cover the trailing `/` and the last-`lib/` split, and `Check#closure` uses `Boundary.dependency_closure`. `rubyarchdir` stays, because Debian's packaged Ruby puts it outside `rubylibdir`, which a reviewer checked in Docker. The second review found no blockers, and its findings became 20260923-18.

### 20260923-19. MCV frequencies in the statistics input.

5a-2 needs to know how often a specific literal occurs to decide whether `col = literal` removes most rows on its own. Add the column's most-common values and their frequencies to `ColumnStatistics`, plus a helper that estimates one literal's frequency the way Postgres does. If the literal is an MCV, use its frequency. Otherwise use `(1 - sum of MCV frequencies - null_frac) / (distinct count - number of MCVs)`.

- **Depends on:** 20260923-14.
- **Came from:** First review of 20260922-31. The user chose MCV frequencies over a low-cardinality rule.
- **README:** 3c, 3f, and 5a-2.
- **Status:** done
- **Decided:**
  - The new fields are optional, so existing callers keep working. 5a-1 is being built against this shape right now.
  - MCV values are real data, so they're value-class. `inspect`, `to_s`, `pp`, pattern matching, and every error message must redact them, the way `IndexCandidate` redacts predicates. Add sentinel tests.
  - A literal is compared to MCV values by its text form, as `pg_stats` prints them. Document what that can't match.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `ColumnStatistics` has optional `most_common_vals` and `most_common_freqs`, and `TableStatistics#value_frequency` follows Postgres's `var_eq_const`. `PgArray.parse` reads `pg_stats` array text. MCV values are redacted everywhere except `to_h` and the readers. Real-Postgres tests compare the estimates with EXPLAIN. The first review found that booleans missed the MCV list, so the fix round maps boolean spellings when the MCVs are only `t` and `f`. The second review found that `bool = false` on a nullable column differs from EXPLAIN, because Postgres counts NULLs there. Our value is the true one, so at landing the main session documented the difference and narrowed a test name. Its minor findings became 20260923-22.

### 20260922-30. 5a-1 generator one.

Build index candidates from the parse: ranked equality columns, one range column, matching `ORDER BY` columns, a capped key, `INCLUDE` columns, every leading prefix, and BRIN on a well-correlated range column of a large table.

- **Depends on:** 20260923-11 and 20260923-14. It takes a parsed, fully qualified query and the 20260923-11 statistics input, so it doesn't need 20260922-14 or 20260922-19 to exist. Those tasks must produce the same input later.
- **README:** 5a-1.
- **Status:** done
- **Decided:**
  - Cap the key at three columns.
  - Emit a BRIN candidate when the range column's absolute correlation is 0.9 or more and the table's `reltuples` is at least 1,000,000.
  - All three limits are configurable.
  - The user approved building this in parallel with 20260922-31 and the main line, once 20260923-11 lands. It's a pure function over its inputs, in new files in the enclave gem.
  - Join columns: build every table's keys twice, once with its join columns counted as equality columns and once without them, then drop duplicates. A parse alone can't tell which way the join runs. On the README example this gives both `(customer_id, status, created_at)` and `(status, created_at DESC)`.
  - A column filtered only by `IS NULL` is ranked by `null_frac`, not `equality_selectivity`.
  - When the range column and ORDER BY conflict, emit two keys: equality plus range, and equality plus ORDER BY.
- **Note:** Built, fixed once, and reviewed twice, but not landed. The work is on branch `gen1-20260922-30` at `f2a1408`. The second review found an `IS NULL` in an upper join's ON that still lands on a nullable table, plus four vacuous tests. So 20260923-20 finishes the task from that branch, and both land together.
- **Landed:** Squash-merged into `main` together with 20260923-20, which finished it. Its own loop found four correctness bugs against real Postgres with HypoPG: `IS NULL` pinning ORDER BY, a prefix LIKE taking the range slot, ordinals after a star, and outer joins. The fix round fixed them. The second review found a remaining `IS NULL` hole and vacuous tests, so the work continued in 20260923-20.

### 20260923-20. Finish 5a-1 generator one.

Start from the unlanded 20260922-30 branch (`gen1-20260922-30`, `f2a1408`) and fix what its second review found:
- **`IS NULL` on a nullable table (correctness).** WHERE conjuncts on a nullable table are skipped, but ON conjuncts aren't checked against nullability from lower joins. `c LEFT JOIN o ON o.customer_id = c.id JOIN i ON i.id = c.id AND o.note IS NULL` still proposes `orders (note)`, and HypoPG shows it's never used. Replace the broad rule with a narrower one. Every predicate kind 5a-1 reads is strict except `IS NULL`, and Postgres turns an outer join into an inner join and pushes a strict qual down. So skip only an `IS NULL` conjunct, in WHERE or in any ON, when it touches a table made nullable by an outer join below the place the conjunct applies. Keep the rule for ON conjuncts that touch only the preserved side of an outer join. Check the result with HypoPG, including the `o.status = 1 AND o.region = 7` case, which should now propose `orders(region, status)` or `(status, region)`.
- **Vacuous tests.**
  - The three-column tie-break tests stay green without their position terms. Fold them into the 50-column tests or delete them.
  - The ordinal-after-star test only puts the star first. Add `SELECT id, *, created_at ... ORDER BY 3 DESC`.
  - The filter-plus-join test reads the filter before the join. Add a fixture with the join written first.
- **Untested code.**
  - `pinned?` survives as `kinds.first == :one`. Add a test that mixes predicate kinds on one column.
  - Two CTE scoping mutants survive: outer scope inside CTE bodies, and forward references under `WITH RECURSIVE`.
  - `cap.is_a?(Integer)` survives.

- **Depends on:** 20260922-30 (unlanded branch).
- **Came from:** Second review of 20260922-30, findings 1, 3, 4, and 5.
- **README:** 5a-1.
- **Status:** done
- **Landed:** Squash-merged into `main` with 20260922-30. It narrowed the outer-join rule to skipping only `IS NULL` on a table made nullable below, and fixed the vacuous tests. Both reviews found no correctness blockers. The second review found two vacuous tests. The tests-only round fixed the alias test, but the repeated-ORDER-BY test was still vacuous. At the user's choice, the dedupe it covered was removed before landing and split out to 20260923-23. The other findings went into 20260923-21.

### 20260922-31. 5a-2 generator two.

Build index candidates from problem patterns in a plan. Use the production plan for the original query and the racetrack plan for rewrites.

- **Depends on:** 20260923-11, 20260923-14, and 20260923-19. It takes the production plan JSON and the 20260923-11 statistics input, so it doesn't need 20260922-13 or 20260922-19 to exist.
- **README:** 5a-2.
- **Status:** done
- **Decided:**
  - This task covers the production plan only. Rewrites move to 20260923-12.
  - Thresholds, all configurable:
    - **Most rows:** the filter removes at least 90% of the rows scanned.
    - **Many rows:** the filter removes at least 50% of the rows scanned, and at least 1,000 rows.
    - **Expensive inner side:** inner loops times actual rows is at least 10,000.
    - **Large inner build:** the Hash node has at least 100,000 rows, or more than one batch.
  - Tests use real Postgres 18 `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` output, captured once from Docker and committed as fixtures. Don't hand-write plan JSON.
  - A partial-index candidate holds a real literal, so it's value-class data until 5a-3 filters it. Nothing here sends it anywhere.
  - **Partial-index signal:** a `col = literal` conjunct removes most rows on its own when that literal's estimated frequency, from the MCV frequencies added in 20260923-19, is at most `1 - most_rows_removed`. The user chose this after the first review found the old per-column average only fired on columns 5a-3 drops.
  - The user approved building this in parallel with 20260922-30 and the main line, once 20260923-11 lands.
- **Notes from the 20260923-14 review:**
  - `EXPLAIN` without `VERBOSE` gives `"Relation Name"` and `"Alias"` but no schema. So this task has to map each plan relation to a `TableName` itself, and handle a table name that exists in more than one schema.
  - Plan filter strings can qualify columns by alias, like `(o.a = 1)`. Strip the qualifiers before building a predicate. Postgres rejects `o.a` in `CREATE INDEX`, and `t.lag > 0` and `lag > 0` count as different definitions.
  - To extend an existing index, use `existing.with(key: ..., unique: false, sources: [...])`, as the `IndexCandidate` docs say.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. Generator two walks a production EXPLAIN ANALYZE plan and proposes candidates for each README 5a-2 pattern. It's tested against 35 real PG 18 fixtures that `capture.rb` regenerates from the harness data. The first review found that the partial-index signal fired only on columns 5a-3 drops. The user chose MCV frequencies (20260923-19), and the fix round switched to them. The fix round also fixed Parallel Hash row counts, a `pp` leak, a vacuous test, eight surviving mutants, and swallowed refusals. The second review found no leaks and no vacuous tests. Its findings became 20260923-24.

### 20260923-7. Simplify and relax the static boundary checker.

The static checker in `spec/support/boundary.rb` is about 220 lines, is still easy to get around, and flags ordinary code the next tasks need. It flags `public_send("cmd_#{sub}")` (the natural shape of the 20260922-4 dispatcher), `define_method("step_#{n}")`, `%i[save load]`, `{ require: true }`, and `JSON.load(x)`. It also applies every rule to the driver, where loading enclave code doesn't leak production data. Cut it back:
- For the driver, a plain require check that forbids `quaack/enclave` is enough.
- For the enclave, keep plain string requires plus the shebang rule. Review whether the send, lookup, symbol, eval, and `$LOAD_PATH` rules earn their cost once 20260923-4 lands.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260922-1, findings 5 and 6.
- **README:** Where QUAACK runs.
- **Status:** done
- **Note:** Do this before 20260922-4, or the dispatcher will trip the checker.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. It dropped the send, lookup, symbol, eval, and `$LOAD_PATH` rules, so `public_send("cmd_#{sub}")`, `define_method`, `%i[save load]`, `{ require: true }`, and `JSON.load(x)` are accepted. For the enclave and protocol gems it keeps these checks: plain requires of forbidden names, requires that leave the gem, `./` paths, `Bundler.require`, parse failures, the shebang, and, added in the fix round, `require` or `require_relative` of a path that isn't a plain string. The driver gets only the forbidden-name check. The second review found no blockers. Its findings became 20260923-25, and the computed-require consequence was noted on 20260922-4.

### 20260922-7. Egress function and whitelist.

Build the single egress function. It only accepts fields on a whitelist, and it drops anything else entirely rather than scrubbing it. The whitelist lives in one place so every change to it gets reviewed.

- **Depends on:** 20260922-1.
- **README:** Trust boundary.
- **Status:** done
- **Decided:**
  - The whitelist is one file in the protocol gem that maps each output type to its allowed field names, such as `column_stats: [table, column, n_distinct, null_frac, correlation, mcv_freqs, low_card_values]` and `error: [step, rule, sqlstate]`. It lists the fields of QUAACK's own output messages, not database columns, so it changes only when QUAACK changes what a step outputs.
  - The egress function drops any field not on its type's list, and drops any output of an unknown type. There are no field types.
  - Changes to the whitelist get reviewed through the normal git diff. There's no snapshot test and no CODEOWNERS.
- **Defaults the main session chose (the user was away):** The whitelist is in the protocol gem, and the egress function is in the enclave gem. The whitelist starts with only `error` and `column_stats`. An unknown type sends nothing.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `Quaack::Protocol::WHITELIST` maps each type to its fields. `Quaack::Enclave::Egress.serialize` returns one JSON line with `type` first and only the allowed fields. It returns nil for an unknown type or a non-Hash, and raises a fixed-message `Egress::Error` with no cause for a value that isn't plain JSON data. The first review found that exceptions and other objects leaked through `to_s` or `to_json`. `strict: true` doesn't close that on Ruby's default json 2.9.1, which the enclave uses outside Bundler. So the fix round allows only exact-class nil, booleans, Integer, Float, String, Symbol, Array, and Hash with String or Symbol keys, and sends the type as the whitelist's own name. The second review found no blockers. Its findings became 20260923-26.

### 20260922-14. Fully qualify relations.

Rewrite the query AST so every relation is schema qualified and `search_path` never matters.

- **Depends on:** 20260922-13.
- **README:** Step 1.
- **Status:** done
- **Decided:** The operator's query should already qualify every relation. If it doesn't, resolve the unqualified names with the `search_path` from the input plan's `SETTINGS`, since that's what the session used when the plan was made.
- **Decided:** When `SETTINGS` has no `search_path`, assume the default `"$user", public`. Resolve `"$user"` as the connecting role, then `public`, in `pg_catalog`. Abort if a name resolves nowhere.
- **Built early:** Built before 20260922-13 lands. `RelationQualifier.qualify(sql, settings, connection)` takes the query text, the plan's `Settings` hash, and a connection as plain inputs.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. It follows Postgres's resolution rules. `pg_catalog` comes first unless it's listed. Schemas that are missing or lack USAGE are skipped. It handles quoted and mixed-case entries, `"$user"`, and 63-byte truncation. CTE names in scope are left alone, and DML targets are always qualified. The first review found `FOR UPDATE OF` aliases treated as relations, DML targets given CTE scope, a hidden `pg` constant, and missing truncation, and the fix round fixed all of them. The second review found no blockers. Its findings became 20260923-27.

### 20260922-15. Canonical plan form.

Define the canonical plan: keep node type, relation, index, join type, strategy, quals, and sort keys, and strip costs, row counts, buffers, and aliases. Build the comparison every later step uses.

- **Depends on:** 20260922-1.
- **README:** Step 1.
- **Status:** done
- **Decided:** Parse each qual with pg_query, replace each alias with the relation it stands for, and compare the pg_query fingerprints, which ignore constants. Two plans that differ only in literal values or alias names compare equal.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `CanonicalPlan.new(explain, hypothetical_indexes: nil)` walks the plan with `PlanNode`. It keeps node type, parallel awareness, relation, index, join type, strategy, parent relationship, subplan name, partial mode, and scan direction, plus fingerprints of each qual and sort key with aliases mapped to relations. `#matches?` compares two plans. Postgres 18 subplan forms such as `(InitPlan 1).col1` are rewritten so they parse. Any qual that still won't parse makes the plan not `comparable?`, and such a plan matches nothing. The first review found that different HypoPG indexes compared equal, because their automatic names match. So a caller can now map each hypothetical oid to an identity, such as `hypopg_get_indexdef`, and the plan compares a digest of it. The second review found no blockers. Its findings became 20260923-28.
- **Known limits, which follow from the fingerprint decision:** The fingerprint ignores the order of function arguments and AND/OR arms. It collapses repeated arms that differ only in literals, and it treats `= ANY(array)` like `= const`. Two aliases of one table can't be told apart. Workers Planned, Inner Unique, Memoize Cache Key and Mode, the WindowAgg definition, SetOp Command, and Schema are dropped.

### 20260922-43. 9 predicate atom extraction.

Pull every predicate atom out of the parse: equality, range, `LIKE`, `IN`, `IS NULL`, and every join condition. Give each a redacted shape for reporting.

- **Depends on:** 20260922-14, 20260922-23.
- **README:** Step 9.
- **Status:** done
- **Decided:** Extract atoms everywhere, including under `OR`, `NOT`, `CASE`, and in subqueries. The 9c vacuity guard catches any that fixtures can't exercise.
- **Note:** Built on branch `task/20260922-43`, with a build, a review, a fix round, and a second review, but not landed. The second review found that `extract` raises on a recursive CTE with `CYCLE` inside an atom, and that the explicit `normalize(x, 'lit')` redaction is untested. 20260923-29 finishes it on top of that branch, and 20260923-30 holds the rest.
- **Landed:** Merged into `main` together with 20260923-29. `PredicateAtoms.extract(parse, column_names:)` returns atoms from every position, each with its kind, operator, negation, columns, a redacted shape, and a path. `with_true` gives the query with one atom replaced by TRUE, and `node` gives an atom's parse node. The first review found a JSON_TABLE deparser segfault, TABLESAMPLE and table functions missing from scope, and functions in FROM not treated as LATERAL. The fix round fixed all of them. The second review's blockers went to 20260923-29, and its minor findings went to 20260923-30.

### 20260923-29. Finish predicate atom extraction.

Split out of 20260922-43, whose branch `task/20260922-43` holds the work so far. Build on that branch, then land both together. Fix what the second review of 20260922-43 found:
- **A recursive CTE with `CYCLE` inside an atom makes `extract` raise** `PgQuery::ParseError: deparse: unpermitted node type in AexprConst`. The deparser needs `CTECycleClause.cycle_mark_value` and `cycle_mark_default` to be `A_Const`. Keep them, or swap them for string placeholders, the way JSON paths are handled. Repro: `SELECT 1 FROM public.orders o WHERE EXISTS (WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t) CYCLE n SET c USING p SELECT 1 FROM t WHERE t.n = o.id)`.
- **The explicit `normalize` call isn't tested.** Removing `node.funcformat == :COERCE_SQL_SYNTAX &&` from `Literals.normal_form?` stays green, and then `pg_catalog.normalize(o.note, 'SENTINEL')` keeps its literal. Add a sentinel test.
- **XMLROOT shapes are wrong.** The `version no value` and `standalone` arguments are keywords that the deparser reads as `A_Const`. Keep them, the way the normal form is kept.
- **Surviving mutants for nested atoms:**
  - `null_test` in `boolean?`
  - `SUBQUERY_TESTS` shrunk (nested `IN (SELECT ...)` and `ALL`)
  - `EXPRESSIONS.key?` in `boolean_expression?` (`NULLIF`)
  - the ELSE and the argument of a simple CASE
  - the unreachable `path_placeholder` branch (drop it)

- **Depends on:** 20260922-43's branch.
- **Came from:** Second review of 20260922-43.
- **README:** Step 9.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. A constant with location -1 is parser-made (a grammar default or keyword), so it's kept and not numbered. The reviewers checked that rule against the vendored grammar and with about 150 sentinel probes. Written CYCLE marks, including typed ones, become string placeholders. The second review found no blockers. Its findings went into 20260923-30.

### 20260922-3. Governed store.

Build the per-run store directory on the jump server: its layout, a run ID, and reads and writes of every intermediate result. Also build the teardown that deletes the run's directory when the run ends.

- **Depends on:** 20260922-1.
- **README:** Where QUAACK runs (the storage table), and the note about destroying state after each run.
- **Status:** done
- **Note:** Built on branch `task/20260922-3` through a build, a review, a fix round, and a second review, but not landed. The second review found `SystemStackError` on Hash nesting inside `MAX_DEPTH` on aarch64 Linux, and tests that miss a walk that skips sibling values. 20260923-32 finishes it on top of that branch.
- **Defaults the main session chose (the user was away):** the base is `~/.quaack/runs/`, run IDs look like `20260923T221500Z-<8 hex>`, entry names match `/\A[a-z][a-z0-9_]*\z/`, writes are atomic, and opening a run checks that it's 0700 and owned by the current user.
- **Decided:**
  - Each stored result is a JSON file in the run's directory.
  - The run directory is mode 0700 and its files are 0600, in the operator's home directory. Encryption at rest comes from the jump server's disk encryption. There's no encryption in the app.
- **Landed:** Merged into `main` together with 20260923-32. `Store.create`, `Store.open`, `#write`, `#read`, and `#teardown` are in `enclave/lib/quaack/enclave/store.rb`, with atomic 0600 writes in `private_files.rb`. The shared exact-class `PlainData.check` in `plain_data.rb` is now used by both store and egress. The first review found reads failing under a C locale, and non-JSON objects stored as `to_s`, and the fix round fixed both. The second review's blockers went to 20260923-32.

### 20260923-32. Finish the governed store.

Split out of 20260922-3. The work so far is on branch `task/20260922-3`. Build on that branch, then land both together. It also changes egress, which now shares `PlainData.check`. Fix what the second review of 20260922-3 found:
- **Hash nesting within `MAX_DEPTH` raises `SystemStackError` on aarch64 Linux.** json 2.9.1 on `ruby:3.4-slim` writes nested Hashes only about 9,700 deep on the main thread, and about 1,200 in a thread. The comment on `MAX_DEPTH = 10_000` promises more than that. The deepest real pg_query tree is about 1,500 levels. Lower `MAX_DEPTH` with room to spare. Add Hash and Array round-trip tests at `MAX_DEPTH`. Also turn `SystemStackError` from JSON into `Store::Error` and `Egress::Error`.
- **Tests miss a walk that skips sibling values.** Each of these changes stays green:
  - `hash.values` changed to `first(1)` or `last(1)`
  - an Array walk using `item.last(1)`
  - egress checking only the last field

  Put bad values first, in the middle, and in a field other than `rule`.
- **Egress now honors a singleton `to_json` on a plain Array or Hash,** because it generates the original object, not a copy. That's evasion, not an honest mistake, so just say so in a comment.

- **Depends on:** 20260922-3's branch.
- **Came from:** Second review of 20260922-3.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `MAX_DEPTH` is 3,000, measured on aarch64 Linux json 2.9.1. `SystemStackError` becomes `Store::Error`. Egress keeps json's default `max_nesting` of 100, so it needs no stack rescue, and the reviewers agreed. Sibling-position tests were added. `create` and `teardown` now raise `Store::Error`. The second review found no blockers. Its findings became 20260923-34.

### 20260922-20. 3d volatility check.

Check `provolatile` for every function in the query, including the select list. Abort and name any volatile function. Reusable for rewrite candidates.

- **Depends on:** 20260922-14.
- **README:** 3d.
- **Status:** done
- **Decided:** Yes. Resolve each operator's `oprcode` and each cast's `castfunc` in `pg_catalog`, and abort if any of them is volatile.
- **Defaults the main session chose (the user was away):** It doesn't try to resolve the exact overload. A call is volatile if any overload with the same name that could take that many arguments is volatile. Operators work the same way, by name and arity. A cast is volatile if any cast function to the target type, or the target type's input function, is volatile. On Postgres 18 and 11 common extensions, this caused no false positives for ordinary queries.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review. `VolatilityCheck.check(sql, settings, connection)` walks every call, including operators hidden in syntax, casts, aggregates and all eight of their support functions, and functions in FROM. It raises `volatile_function` and names the object, quoted with quote_ident. The first review found ordered-set aggregates slipping through, and support functions with no tests. The second review found one vacuous test, which the tests-only round fixed. The leftover findings became 20260923-35.

### 20260922-32. 5a-3 dedupe and filter.

Normalize definitions. Drop candidates covered by an existing index or by an earlier proposal in the same search, recording the source generators and the covering index. Drop partial indexes on columns that aren't low-cardinality. Set GIN and GiST aside, untested, for step 12. Scope must be per search, so each rewrite's search is independent.

- **Depends on:** 20260922-19, 20260922-22.
- **README:** 5a-3, step 8.
- **Status:** done
- **Note:** Built on branch `task/20260922-32` through a build, a review, a fix round, and a second review, but not landed. The second review found that an array check on the partial filter had a vacuous test, and that generator two's partials on `varchar` columns were always dropped. 20260923-31 finishes the task on top of that branch.
- **Landed:** Merged into `main` together with 20260923-31. `Dedupe.new(statistics:, low_cardinality:)` is one search. `#filter` takes one generator's output and returns the survivors, recording each drop with a reason (`:partial_not_low_cardinality`, `:covered_by_existing`, or `:duplicate`) and what covered it. GIN, GiST, and SP-GiST are set aside. The first review found literals that weren't tied to a column getting through, which led to the rule that every constant must be compared directly with a bare low-cardinality column. The second review's blockers went to 20260923-31.

### 20260923-31. Finish 5a-3 dedupe and filter.

Split out of 20260922-32. The work so far is on branch `task/20260922-32`. Build on that branch, then land both together. Fix what the second review of 20260922-32 found:
- **Vacuous test on the trust-boundary check.** In `predicate_check.rb` `constant?`, changing `elements.all?` to `elements.any?` stays green. With that mutant, `status = ANY(ARRAY['open', lower('bob@x.com')])` keeps its partial. Add a mixed-element array to the drop list.
- **Generator two's partials on `varchar` columns are always dropped.** Postgres prints `((status)::text = 'open'::text)`, so the predicate has a cast on the column side, and `constants_compared_with_columns?` wants a bare column. Accept a column under casts, but not under any other expression. Test it with real generator two output from a Postgres plan.
- **Allowed forms no test pins:** `AEXPR_OP_ALL`, `AEXPR_NOT_DISTINCT`, `AEXPR_ILIKE`, `AEXPR_NOT_BETWEEN`, and both SYMMETRIC forms.
- **Dead code:** the BETWEEN special case in `column_comparison?` can't be reached. Drop it.
- **Type modifiers in an allowed comparison aren't checked,** as in `status = 'x'::mytype(lower('bob'))`. Check them, or drop anything that isn't an integer constant.

- **Depends on:** 20260922-32's branch.
- **Came from:** Second review of 20260922-32.
- **README:** 5a-3.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The column side may sit under casts and COLLATE. Typmods must be integer constants. Operators must be comparisons (`= <> < <= > >= ~~ !~~ ~~* !~~*`), and a schema-qualified operator counts only from pg_catalog. Real generator-two output on varchar columns survives end to end. The second review found no blockers. Its findings went into 20260923-36.

### 20260922-46. 9a, 9b, and 9e arena transaction runner.

Open a transaction on arena with `statement_timeout`, load a fixture, run queries, and always roll back.

- **Depends on:** 20260922-27.
- **README:** 9a, 9b, and 9e.
- **Status:** done
- **Built early:** built before 20260922-27, against the test harness. The main session chose the defaults: a 10s `SET LOCAL statement_timeout`, FixtureRows plus raw step-10 INSERTs as inputs, and results kept as plain data inside the enclave.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. `ArenaRunner.new(conn).with_fixture(rows, inserts:) { |tx| tx.query(sql) }` always rolls back. It drops Postgres notices while it runs and restores the caller's receiver afterward. A pg_query StatementCheck lets through exactly one INSERT for inserts and one SELECT for queries, and refuses everything else before it runs. Errors carry a fixed message, rule, SQLSTATE, step, and index, with `cause: nil`. The first review found NOTICE text leaking fixture values to stderr, and `COMMIT AND CHAIN` getting past the rollback. The fix round fixed both. The second review found no blockers. Its findings became 20260923-37.

### 20260922-8. Error filtering.

Send every enclave error through the egress function, including Postgres errors and stack traces. A unique-violation message, for example, can contain a real key value. Errors should still say which step and which rule failed.

- **Depends on:** 20260922-7.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - `ErrorFilter.to_egress(exception, step:)` sends only the step, a rule (the exception's own rule if it's identifier-shaped, otherwise `internal_error`), and a 5-character SQLSTATE. It never reads the message, backtrace, class, or cause, and it never raises.
  - `guard(step:, out:)` writes one line for anything raised, and re-raises signals after writing.
  - `silence_stderr!` points fd 2 at /dev/null.
  - `drop_notices(conn)` drops libpq notices. Callers must call it again after `conn.reset`.
  - The main session chose to let step names match `/\A[a-z0-9][a-z0-9_-]{0,62}\z/`, since steps such as `5a-1` start with a digit or contain a hyphen.
  - The first review found that SIGTERM inside a looped guard didn't end the process. The fix round fixed that. The second review found no blockers. Its findings became 20260923-38.

### 20260923-33. Fail closed on unsupported SQL constructs.

The user decided that enclave code that walks SQL supports an explicit list of constructs and refuses everything else. That covers predicate atoms, relation qualification, the volatility check, and the inbound checks (20260922-10, 11, and 12). The reviews of 20260922-43, 20260922-14, and 20260922-20 kept finding bugs in rare constructs, such as JSON_TABLE, XMLTABLE, typed CYCLE marks, TABLESAMPLE, and ordered-set aggregates. Specs like "no literal survives" covered the whole grammar, so each review found more.
- Define one shared allowlist of pg_query node types, and of the fields within them where it matters, in the enclave gem. Start with the common constructs: SELECT, joins, CTEs (not CYCLE or SEARCH), subqueries, CASE, aggregates, window functions, the usual operators, casts, IN, ANY, LIKE, BETWEEN, and IS NULL.
- Before any walker runs, check the parse against the allowlist. Abort on anything else with the rule `unsupported_construct`, naming the node type. That's shape, and it holds no literals.
- **Constructs outside the list are refused in version 1.** Supporting each one becomes its own task under "After version 1", which the main session adds when this task defines the list. Group them by family, such as JSON_TABLE and the JSON functions, XMLTABLE and the XML functions, CTE CYCLE and SEARCH, and TABLESAMPLE. The user decided this. Special-case code already written for refused constructs, such as the JSON_TABLE path swap, CYCLE marks, and XMLROOT keywords, can stay if its tests still reach it. The after-v1 task for that construct decides whether to enable it or remove it.
- Update README "What goes into the enclave" and step 1 to say that queries using constructs outside the list are refused.
- Review this against the supported list, not the whole grammar. Correctness findings still block landing, since the user kept review severity strict.

- **Depends on:** 20260922-14, 20260922-43, and 20260922-20.
- **Came from:** The user's decision after the reviews of 20260922-43, 20260923-29, and 20260922-20.
- **README:** What goes into the enclave, step 1, and step 9.
- **Status:** done
- **Decided (by the user):** Use the default list: SELECT, joins, CTEs without CYCLE or SEARCH, subqueries, CASE, aggregates, window functions, the usual operators, casts, IN, ANY, LIKE, BETWEEN, and IS NULL. There are no sample queries to check it against.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review.
  - `SupportedSql.check!` (`enclave/lib/quaack/enclave/supported_sql.rb`) walks every protobuf field and raises `unsupported_construct`, naming only the node type. It's called first by RelationQualifier, VolatilityCheck, GeneratorOne, and PredicateAtoms.
  - Code that only refused constructs could reach was removed, last present in 6507105. That covered DML targets and locking-clause skips in RelationQualifier, TABLESAMPLE in FunctionCalls, and in PredicateAtoms the JSON_TABLE path swap, CYCLE marks, normal-form keywords, TABLESAMPLE FROM items, and SIMILAR TO. GeneratorOne's own statement checks went too.
  - EXTRACT's field keyword is kept in shapes when it's a documented field name.
  - The review ran 60 realistic ORM and reporting queries, and every construct on the list passed.
  - Support for each refused family became an after-v1 task, 20260923-41 through 20260923-52. The minor findings became 20260923-40.

### 20260922-10. Inbound check for rewrite candidates.

Parse each rewrite candidate with pg_query. Accept exactly one `SELECT`. Reject data-modifying CTEs, `SELECT INTO`, and locking clauses. Run the 3d volatility check on it. Each rejection names the rule it broke.

- **Depends on:** 20260922-1, 20260922-20.
- **README:** What goes into the enclave.
- **Note (from the review of 20260922-20):** Run the 3a relation check on rewrite candidates too. Reject views, and relations the original query doesn't use, because a view's body can call a volatile function that the 3d check never sees.
- **Note (from the review of 20260922-46):** The arena runner relies on this check to refuse function calls with side effects that persist or change the session. Examples are `set_config` (which can turn off `statement_timeout`), session-level `pg_advisory_lock` (it survives ROLLBACK), and `lo_import`. The 3d volatility check refuses all of them. Test that it does, and call `SupportedSql.check!` (20260923-33) on every candidate.
- **Status:** done
- **Built early:** built before 3a and 3g. The original's relations and its placeholder count are a plain `Original` input.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review.
  - `RewriteCandidateCheck.check(sql, original, settings, connection)` runs these checks in order: parse (`unparsable`), `SupportedSql`, placeholders `$1..$N` (`bad_placeholder`), relations (qualified, in the original's set as `unknown_relation`, relkind `r` only as `not_a_table`), then `VolatilityCheck`.
  - It returns `Accepted(sql:, parse:)`. Errors carry a rule, a message with shape-only names, and `cause: nil`.
  - The second review found two vacuous tests, which the tests-only round fixed. It also found that deparse can change a query's meaning, which became 20260923-55.
  - The rest became 20260923-57.

### 20260922-4. Enclave command-line script.

Build the stateless enclave script: a subcommand dispatcher that reads from the governed store, does one step's work, writes new state back, and prints its result. Nothing stays in memory between calls. All output goes through the egress function.

- **Depends on:** 20260922-3, 20260922-7, 20260922-8.
- **README:** Where QUAACK runs.
- **Note (from the reviews of 20260922-8 and 20260922-46):** use `ErrorFilter` (20260922-8) this way:
  - Call `ErrorFilter.silence_stderr!` first.
  - Run the dispatcher inside a single top-level `ErrorFilter.guard`, since nested guards write two lines for one signal.
  - Call `ErrorFilter.drop_notices` on every connection, including production and racetrack, and again after any `conn.reset`.
  - The current CLI prints USAGE to stderr, which will be silenced, so it has to go through egress instead.
  - An error line written after a partial stdout write lands on the same line.
  - A process killed by a signal dies with the signal, so the driver should treat a signal death as a failure and use the error line it already got.
  - Merge the arena runner's local notice receiver with `drop_notices`.
  - Consider `conn.cancel` or a `statement_timeout` when SIGTERM arrives mid-query.
- **Status:** done
- **Note:** Built on branch `task/20260922-4` through a build, a review, a fix round, and a second review, but not landed. The second review found that the input comment scan uses 60 to 80 times the input size in memory. 20260923-53 finishes the work on top of that branch.
- **Note (from the review of 20260922-46):** The enclave's stderr goes over ssh to the laptop, so it's a path around egress. The CLI must control stderr as well as stdout. That covers uncaught exceptions and backtraces, Ruby warnings, and libpq NOTICE and WARNING output on every connection, including production. A PL/pgSQL `RAISE NOTICE` in a stable function can print a row value. Install a notice receiver that drops notices, and send anything else on stderr through egress or discard it.
- **Note:** The static boundary check (20260923-7) flags `require` or `require_relative` of a computed path in the enclave, such as `require_relative "steps/#{name}"` or requiring every file in a directory. So the dispatcher lists its requires by hand and maps subcommands through a table or `public_send`, which is still allowed. That also keeps argv from choosing which file gets loaded.
- **Landed:** Merged into `main` together with 20260923-53.
  - **Step contract:** `CLI` dispatches through a frozen `STEPS` table with requires written out by hand. A step returns message Hashes, and egress serializes them.
  - **Input:** stdin JSON, only for steps that take it, capped at 64 MB. Repeated keys, comments, unknown escapes, and non-finite floats are refused under both json 2.9.1 and 3.0.2.
  - **Output:** buffered, with a final `{"type":"done"}` line on success.
  - **Streams and exits:** `silence_stderr!` and `claim_stdout!`, then one top-level guard. Exits are 0, 64, or 70, or death by the signal. A SystemExit from a step becomes `internal_error`.
  - **Connections:** `Connections.register` drops notices.
  - **Whitelist:** gained `version: [version]` and `done: []`.
  - **Reviews:** the first review asked for fixes to step exits, json parity, and output quirks. The second review's memory blocker went to 20260923-53.

### 20260923-53. Finish the enclave CLI.

Split out of 20260922-4. The work so far is on branch `task/20260922-4`. Build on that branch, then land both together. Fix what the second review of 20260922-4 found:
- **The input comment scan uses 60 to 80 times the input size in memory.** Onigmo pushes a backtrack entry for every character that `+`, `++`, or `*+` repeats. A 64 MB run of spaces took 5 GB, and a 64 MB string took 3.7 GB. An OOM kill is a SIGKILL, so the driver gets no error line. Skip ahead with `skip_until` or `String#index` instead of a repeated class. Pin memory in a test, for example by checking RSS growth in a subprocess on a large input.
- **Unknown escapes mean different things on the two json versions.** json 2.9.1, which the jump server uses, accepts `\q`, `\x41`, `\a`, `\'`, `\0`, and `\U0041` and keeps the escaped character. json 3.0.2 refuses them. Refuse any `\` followed by a character other than `"\/bfnrtu` inside a string, and add these to `INPUT_REFUSED_ON_EVERY_JSON`.
- **Exponent overflow becomes Infinity.** `1e400` parses to `Float::INFINITY` on both versions. Refuse non-finite floats in Input.
- **The driver can't tell `exit!(0)` from an empty success.** The main session's default: every successful run ends with a final `{"type":"done"}` line, and a whitelist `done` type with no fields. The driver treats a run without it as failed. Record that in 20260922-5.

- **Depends on:** 20260922-4's branch.
- **Came from:** Second review of 20260922-4.
- **README:** Where QUAACK runs.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The input comment scan uses `skip_until`, with no repeating regex, so memory stays flat, and a peak-RSS test with a sanity guard checks it. Unknown escapes and non-finite floats are refused. Every successful run ends with a `done` line. The second review found no blockers. Leftover findings became 20260923-58.

### 20260922-29. 5a-4 single-candidate testing.

For each candidate: reset HypoPG, create the hypothetical index, `EXPLAIN` the query once per literal set, and record index use, cost, canonical plan, and `hypopg_relation_size`. Keep results for unused candidates. Must work for the original query and for rewrite candidates.

- **Depends on:** 20260922-26, 20260922-21, 20260922-15, 20260922-23.
- **README:** 5a-4.
- **Note (from the review of 20260923-32):** Egress uses json's default `max_nesting` of 100, and a plan takes two levels per node. So a redacted or canonical plan more than about 48 nodes deep can't go out. Decide whether to flatten plans, set an explicit `max_nesting` together with a stack rescue, or refuse them with a clear rule.
- **Status:** done
- **Note:** This task was built on branch `task/20260922-29` through a build, a review, a fix round, and a second review, but not landed. The second review found that dropping `SET LOCAL plan_cache_mode = force_custom_plan` lets a session or database `force_generic_plan` setting make every plan generic. 20260923-39 finishes it on top of that branch.
- **Landed:** Merged into `main` together with 20260923-39 and 20260923-56.
  - `SingleCandidateTest.run(conn, query:, literal_sets:, candidates:)` runs inside one transaction that it rolls back. It sets `SET LOCAL plan_cache_mode = force_custom_plan` and `hypopg.enabled = on`, calls `hypopg_reset`, and refuses (`indexes_hidden`) if any indexes are hidden.
  - For each candidate, it creates the index in a savepoint. Then for each literal set, it prepares the query fresh, runs EXPLAIN EXECUTE, and deallocates.
  - It records whether the index was used (matched by exact name), the cost, a CanonicalPlan keyed by the candidate's `to_ddl`, and the size. It also records a baseline.
  - Literals are validated up front. SQLSTATEs are sorted into refusals and session failures. The first error is kept, notices are dropped, and deep plans parse.
  - The two second reviews found regressions (`force_generic_plan`, then `hypopg.enabled` and hidden indexes), each fixed in a split-off task.

### 20260923-39. Finish 5a-4 single-candidate testing.

This was split out of 20260922-29. The work so far is on branch `task/20260922-29`. Build on that branch, then land both together. Fix what the second review of 20260922-29 found:
- **`plan_cache_mode = force_generic_plan` makes every plan generic.** Postgres checks the setting before the execution count, so it applies even on a statement's first EXECUTE. The reviewer reproduced it on a session and on a database: the Filter was `(s = $1)`, and both literal sets showed the index as used. Put `SET LOCAL plan_cache_mode = force_custom_plan` back inside the transaction. Test it with the setting on the database, asserting that the literal sets differ and that the Filter holds the literal. Fix the module comment too.
- **The session-failure SQLSTATE classes are untested.** Dropping any of `08`, `25`, `40`, `53`, `58`, or the `XX001`/`XX002` pattern stays green. Add a table test that raises each one (`RAISE ... USING ERRCODE`) during create and expects `hypopg_failed`.
- **A lock timeout (`55P03`) during create counts as a refusal.** Consider adding it to the session-failure list.

- **Depends on:** 20260922-29's branch.
- **Came from:** Second review of 20260922-29.
- **README:** 5a-4.
- **Status:** done
- **Note:** Built on branch `task/20260923-39` with a build, a review, a fix round, and a second review, but not landed. The second review found that hidden real indexes skew the plans, and that deep plans raise a raw `JSON::NestingError`. 20260923-56 finishes it on top of that branch.
- **Landed:** Merged into `main` together with 20260922-29 and 20260923-56. It restored `force_custom_plan`, tested every session-failure SQLSTATE, and added `hypopg.enabled = on`, keep-the-first-error, and exact index-name matching.

### 20260923-56. Finish 5a-4, second pass.

Split out of 20260923-39. The work so far is on branch `task/20260923-39`, which carries 20260922-29. Build on that branch, then land all three together. Fix what the second review of 20260923-39 found:
- **A real index hidden with HypoPG skews every plan without warning.** HypoPG keeps hidden indexes per session, and `hypopg_reset()` doesn't clear hidden real ones. In the reproduction, the baseline cost went from 8.31 to 1887.0 and the run returned normally. Refuse when `hypopg_hidden_indexes()` isn't empty, with a new rule such as `indexes_hidden`. Don't unhide them, since that isn't transactional. Add a comment that HypoPG older than 1.4 fails closed.
- **A plan more than about 48 nodes deep raises a raw `JSON::NestingError`.** A 60-table join chain is enough. Parse EXPLAIN output with `max_nesting: false`, or with a documented cap that gives a clear refusal rule, and test it with a deep plan. This settles the parsing half of the note on 20260922-29. Sending plans through egress is still open.
- **Surviving mutants:**
  - Unanchored SQLSTATE class alternatives. Pin them with a refusal code such as `22025` or `42P08` that contains one of the class pairs.
  - An index-name match on `start_with?("<")`.
  - The `RELEASE SAVEPOINT` line, which you can delete, or explain why it's there.

- **Depends on:** 20260923-39's branch.
- **Came from:** Second review of 20260923-39.
- **README:** 5a-4.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. It refuses when HypoPG has hidden indexes, parses plans with `max_nesting: false`, and pins the anchored SQLSTATE classes. It also has tests for the check order, a leftover prepared statement, and a real index with a hypothetical-looking name. The first review listed every piece of state the runner depends on, and that list went to 20260922-25. The second review found no blockers. Its findings became 20260924-1.

### 20260922-13. Input intake.

Read the three operator inputs from the governed store (query text, `EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT JSON)` output, and server name) and check that they're well formed.

- **Depends on:** 20260922-3, 20260922-4.
- **README:** Step 1.
- **Note (from 20260923-33):** Call `SupportedSql.check!` on the input query, so unsupported constructs are refused at intake.
- **Status:** done
- **Decided:** The operator runs a `quaacks` subcommand on the jump server, such as `quaacks intake --query q.sql --plan plan.json --server prod-db-3`. It checks the inputs, creates the run, and prints the run ID for the driver to use.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - **Usage:** `quaacks intake --query F --plan F --server NAME [--captured-at T]`.
  - **Files:** it reads regular files only, no symlinks, up to 16 MB each, and strips one leading BOM.
  - **Query checks:** UTF-8, no NUL bytes, it parses, exactly one statement, `SupportedSql`, and no `$n` parameters.
  - **Plan checks:** strict JSON, shaped `[{"Plan":...}]`, with ANALYZE and BUFFERS present. `Settings` can be missing or `{}`.
  - **Other checks:** a hostname-shaped server, and `--captured-at` in ISO-8601 with a zone, from 1970 up to one day after intake.
  - **On success:** a `CLI::Step new_run: true` run stores `query`, `plan`, `server`, and `clock_anchor` (UTC ISO-8601 with microseconds), then outputs `run: [run_id]` and `done`.
  - **On failure:** the run is deleted, and the error carries only the rule. Arguments are parsed before the run is created.
  - The second review found no blockers. Its findings went into 20260924-3.

### 20260923-55. Round-trip guard for deparsed SQL.

pg_query's deparser can change what a query means. `WHERE (status = $1) IS NOT DISTINCT FROM (true AND false)` deparses as `status = $1 IS NOT DISTINCT FROM true AND false`, which returned 0 rows where the original returned 20000. `(ARRAY(SELECT ...))[1]` deparses as `ARRAY(SELECT ...)[1]`, which doesn't parse. `RelationQualifier` (20260922-14) returns deparsed SQL, so both the original query in step 1 and every rewrite candidate that passes 20260922-10 can silently become a different query.
- After deparsing, reparse the SQL and compare its tree with the tree that was deparsed, ignoring locations. Refuse on a mismatch or a parse failure, with a rule such as `deparse_mismatch` and a fixed message. Put the guard in one shared place and use it in RelationQualifier. It also covers the `with_true` guard in 20260923-30.
- In 20260922-10, wrap the reparse so a parse failure raises `RewriteCandidateCheck::Error`, not a raw `PgQuery::ParseError`. Also run `SupportedSql` and the placeholder check on `Accepted.parse`, not only on the candidate's own parse.
- Test with the two repros above against real Postgres, plus the other deparse cases listed in 20260923-30.

- **Depends on:** 20260922-14, 20260922-10.
- **Came from:** Second review of 20260922-10.
- **README:** Step 1, and "What goes into the enclave".
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - **The guard:** `Deparse.faithfully`, `expression`, and `statement` deparse, reparse, and compare whole protobuf trees after clearing `version` and the int32 location fields. A mismatch raises `deparse_mismatch`.
  - **Where it's wired in:** RelationQualifier (which now returns `parse`), RewriteCandidateCheck, `with_true`, IndexSql `normalize_predicate` and `from_ddl`, `IndexCandidate#to_ddl`, and `PlanExpression.unqualified_sql`. GeneratorTwo skips a partial that doesn't round-trip. Shapes, which are report-only, aren't guarded.
  - **Checked against:** about 270 realistic queries, with no over-refusal.
  - Constructs that the guard now refuses because pg_query drops their parentheses became 20260924-4.

### 20260922-47. 9d result comparator.

Compare results using the rules for no `ORDER BY`, a partial `ORDER BY` (add a tiebreaker), `LIMIT` without `ORDER BY` (subset check), and float tolerance.

- **Depends on:** 20260922-46.
- **README:** 9d.
- **Status:** done
- **Note:** Built on branch `task/20260922-47` through a build, a review, a fix round, and a second review, but not landed. The second review found false matches when a tie crosses a LIMIT or OFFSET cut or a DISTINCT ON pick, and when a column is an enum. 20260923-54 finishes it on top of that branch.
- **Decided:** `float4` and `float8` values are equal within a relative 1e-9, with an absolute 1e-12 near zero. Numeric and integer columns compare exactly.
- **Landed:** Merged into `main` together with 20260923-54 and 20260924-2. `ResultComparator` compares two ArenaRunner Results, and `ResultComparison` shapes the queries with pg_query and runs them. The comparison works like this:
  - With no ORDER BY, it compares multisets.
  - With ORDER BY, it compares in order twice, once with an ascending tiebreaker and once with a descending one, on the output positions of faithful types.
  - For LIMIT with no ORDER BY, it does a subset check.
  - It refuses as `unsupported_order` for WITH TIES, for an original whose two runs differ (a tie at a cut), for left-out types (interval, jsonb, and containers of numeric or float) when either query has a top-level cut or a hidden difference, and for nondeterministic collations.
  - Floats use a relative 1e-9 and an absolute 1e-12 tolerance, which the user decided. Numeric is compared by value, and bpchar ignores trailing spaces.
  - The verdict holds no values.
  - The reviews found three kinds of false match, each fixed in a split-off task. The leftovers became 20260924-5, 20260924-6, and 20260924-7.

### 20260923-54. Finish the 9d result comparator.

Split out of 20260922-47. The work so far is on branch `task/20260922-47`. Build on that branch, then land both together. Fix what the second review of 20260922-47 found:
- **A false match when a tie crosses a LIMIT or OFFSET cut, or a DISTINCT ON pick.** The two tiebreaker runs, ascending and then descending, only expose the first and last row of each tie group. So a candidate can widen the tie at the cut and still match both runs. The reviewer reproduced this for LIMIT, DISTINCT ON, and OFFSET on real Postgres.
  - The main session's default is to fail closed. If the original's ascending and descending runs return different row multisets, the original depends on how ties break, so refuse the comparison with `unsupported_order` and never report a match.
  - Otherwise the two-run scheme is sound. Test all three repros.
  - A precise check could come later: the rows before the tied group must match exactly, and the rest must be drawn from that group.
- **Enum columns are left out of the tiebreaker, which allows a false match.** For example, `ORDER BY m` on an enum matched a candidate that sorted by another column. Include enums by looking up the catalog (`typtype = 'e'`), and ranges and composites too if that's cheap. Test it.
- **The comment claiming `max` and `min` are equivalent is wrong.** 7.603 against 7.603000007603 is equal under `max` and unequal under `min`. Fix the comment, and pin that pair in a test.

- **Depends on:** 20260922-47's branch.
- **Came from:** Second review of 20260922-47.
- **README:** 9d.
- **Status:** done
- **Note:** Built on branch `task/20260923-54` through a build, a review, a fix round, a second review, a tests-only round, and a tests-only review, but not landed. The tests-only review found the tie-of-three test still vacuous against a first-versus-last mutant in `hidden_differences?`. 20260924-2 fixes that test, and then both land together.
- **Landed:** Merged into `main` together with 20260922-47 and 20260924-2. It added the fail-closed tie-at-cut refusal, catalog-driven enums, ranges, and composites, the faithful-types principle, bpchar trailing-space equality, and the collation refusal.

### 20260924-2. Pin hidden_differences? for every row in a tie group.

Split out of 20260923-54. Build on its branch `task/20260923-54`, then land both together. The tests-only review of 20260923-54 found "refuses an interval column when a tie of three hides a different interval behind a repeat" still vacuous. Changing `hidden_differences?` in `result_comparison/tiebreaker.rb` to compare only `rows.first` and `rows.last` survives the whole suite, because the fixture ['1 day', '1 day', '24 hours'] puts the odd value last. Add a fixture with the odd value in the middle, such as ['1 day', '24 hours', '1 day'] or a group of four. It must go red under the first-two, first-and-last, and `all?` mutants.

Also, from the same review:
- The two composite tests (numeric and interval) should assert `rule: :unsupported_order`, not just `match? == false`.

- **Depends on:** 20260923-54's branch.
- **Came from:** Tests-only review of 20260923-54.
- **README:** 9d.
- **Status:** done
- **Landed:** Merged into `main` together with 20260922-47 and 20260923-54, after a build and two reviews. A four-row fixture pins `hidden_differences?`, and the composite tests assert `unsupported_order`.

### 20260922-61. Burndown counters.

Record per-stage counts (in, added, dropped by reason, out) in the governed store as each enclave step runs, and in the driver for LLM calls. Every stage task should call into this as it's built.

- **Depends on:** 20260922-3, 20260922-7.
- **README:** 15b.
- **Status:** done
- **Note:** This should be built early, right after the foundations, even though it lives in this section.
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - `Quaack::Enclave::Burndown` keeps a single `burndown` Store entry, keyed by stage and search, plus work totals. Every write checks `in + added - dropped - set_aside == out`.
  - Adapters: `record_dedupe` (5a-3), `record_single_candidate_test` (5a-4), and `record_llm_round` (one combined 5a-5 or 5a-6 record per round).
  - The shape predicate `Protocol::Burndown.valid?` lives in the protocol gem. Egress and the store both use it, so a hand-built `burndown` message can't carry a value.
  - The driver's `Burndown` counts LLM calls by step.
  - The whitelist gained `burndown: [stages, totals]`.
  - The second review found no blockers. Its findings became 20260924-8.

### 20260924-5. Rerun 9d comparisons with the fixture loaded in reverse.

High priority. A rewrite that drops a secondary sort key below the top level matches by luck, because fixtures load in id order and small sorts keep input order. Examples are a subquery `ORDER BY grp, id LIMIT 2` becoming `ORDER BY grp LIMIT 2`, and a LATERAL top-1 that drops `, id`. That's a realistic LLM mistake, and README 9d only covers the top level. Run each 9d comparison a second time with the same fixture loaded in reverse physical order, and require both runs to match. This also covers the DISTINCT and GROUP BY representative gaps and the multiset collation gap that the reviews of 20260923-54 documented. It belongs in step 9 orchestration (20260922-49) or ArenaRunner. Decide which, and update README 9d.

- **Depends on:** 20260922-47.
- **Came from:** Second review of 20260923-54.
- **README:** 9d.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review.
  - `ResultComparison.compare_in_both_orders(runner, rows, original:, candidate:, inserts: [])` runs 9d twice, once with the fixture loaded forward and once reversed within each same-table run, and both runs must match.
  - The verdict records `load_order`. Raw inserts aren't reversed.
  - Both runs use `ArenaRunner#with_fixture(index_scans: false)`, which turns off index, index-only, and bitmap scans with SET LOCAL, so an index can't return ties in a fixed order.
  - A reverse-only load failure is `reverse_load_failed`.
  - In the second review, randomized probes found 15 survivors in about 1,900 wrong candidates. Its findings became 20260924-9.

### 20260922-35. 5a-7 combination and ranking.

Combine candidates greedily up to three indexes. Rank by worst-case cost reduction across literals, and break ties by size. Keep the top three plus the best combination if it wins. Each kept entry carries DDL, size, costs per literal, canonical plan, and partial-index tag.

- **Depends on:** 20260922-29.
- **README:** 5a-7.
- **Status:** done
- **Defaults the main session chose (the user was away):**
  - Reduction is `1 − after/before` per literal set, and the worst case is the minimum across sets.
  - Rank by worst case, highest first. Break ties by size, smallest first, then by DDL.
  - Combine greedily from the best single index. Keep an added partner only when the worst case strictly improves and every index gets used. Stop at three indexes.
- **Landed:** Merged into `main` after a build, a review, a fix round, a second review, a tests-only round, and a tests-only review.
  - `IndexRanking.rank(conn, query:, literal_sets:, baseline:, results:)` returns `Ranking(top:, combination:)`. Each entry carries the DDL, the size, the cost before and after for each literal set, `used`, the canonical plans, and `partial`. Inspect leaves out the DDL.
  - 5a-4's runner became a public `SingleCandidateTest::Session`, with `measure(candidates)` for several hypothetical indexes at once. All of 5a-4's safety moved over with it (the reviewers checked 28 mutants). Every measure resets HypoPG, and a closed session refuses to measure.
  - Leftover findings became 20260924-10.

### 20260922-9. Leak tests.

Build a reusable test helper that runs a step on data with known sentinel values and fails if any sentinel shows up in enclave output. Every later enclave task should use it.

- **Depends on:** 20260922-7, 20260922-2.
- **README:** Trust boundary.
- **Status:** done
- **Landed:** Merged into `main` after a build, a review, a fix round, and a second review. The helper is in `enclave/spec/support/leak_check*`:
  - `LeakCheck::Sentinels` makes text, word, number, date (Gregorian, 1100 to 1899), json, and LIKE sentinels.
  - `LeakCheck.findings` scans stdout, stderr, status, and objects: inspect, to_s, messages, backtraces, causes, ivars, members, and a StringIO's `#string`. It refuses a StringIO or IO where a String belongs.
  - `expect_no_leaks` runs an isolated positive control first, with every needle in every place.
  - `LeakCheck::Quaacks` runs the installed gem outside Bundler with a temporary HOME.
  - `LeakCheck::Fixture.plant` seeds sentinels into `pg_stats`.
  - The intake and error_filter specs use it.

  The second review found no blockers. Its findings became 20260924-13.

### 20260922-24. 3h clock anchoring.

Replace the listed time functions with `quaack.clock_anchor()` in the AST. Keep a way to put the original functions back for the report.

- **Depends on:** 20260922-14.
- **README:** 3h.
- **Note (from 20260922-13):** Intake stores `clock_anchor` as a UTC ISO-8601 string with microseconds, such as `2026-09-24T07:35:44.661129Z`.
- **Status:** done
- **Note:** Built on branch `task/20260922-24` through a build, a review, a fix round, and a second review, but not landed. The second review found that anchoring renames implicit output columns and function-in-FROM aliases, which can silently rebind `ORDER BY now`. 20260924-12 finishes it on top of that branch.
- **Decided:** `quaacks intake` takes an optional `--captured-at` flag, the time the production plan ran. Without it, the anchor is the time of intake. The run stores the anchor, and `clock_anchor()` returns it.
- **Landed:** Merged into `main` together with 20260924-12, which finished it.

### 20260924-12. Finish 3h clock anchoring.

Split out of 20260922-24. The work so far is on branch `task/20260922-24`. Build on that branch, then land both together. Fix what the second review of 20260922-24 found:
- **Anchoring changes implicit names.** Postgres names an unaliased `now()` column `now`, and it looks through casts, so `now()::date` is also `now`. `CURRENT_DATE` is `current_date`, and `LOCALTIMESTAMP` is `localtimestamp`. After anchoring, the names become `clock_anchor`, `date`, or `timestamp`. So each of these fails after anchoring:
  - `SELECT s.now FROM (SELECT now()) s`
  - `WITH w AS (SELECT now()) SELECT w.now FROM w`
  - `SELECT now() ORDER BY now`
  - `SELECT now.now FROM now()`

  The worst case is silent. In `SELECT id, now()::date FROM public.ev ORDER BY now`, where `ev` has a column named `now`, `ORDER BY now` rebinds to the table column and the order changes. Keep the original names: set `ResTarget.name` when it's empty, and add an alias when an unaliased function in FROM is anchored. Make `restore` handle or remove what anchoring added. Test each case on Postgres, including the silent one and `GROUP BY` by name.
- **Minor:**
  - `NodeRewrite` has no spec of its own.
  - The "is plain strings" test passes on an empty list.

- **Depends on:** 20260922-24's branch.
- **Came from:** Second review of 20260922-24.
- **README:** 3h.
- **Status:** done
- **Landed:** Merged into `main` with 20260922-24 after a review, a fix round, and a second review. The second review found no blockers, and its minor findings went to 20260924-15.

### 20260923-34. Governed store loose ends.

Minor findings from the second review of 20260923-32:
- **`Store.open` and `#teardown` still let a raw `SystemCallError` out of `PrivateFiles.lstat`.** For example, after `File.chmod(0, base)`, both raise `Errno::EACCES` naming `<base>/<run_id>`. A base that's a regular file gives `Errno::ENOTDIR`. Nothing below the run directory is named, so nothing leaks, but the class promises `Store::Error`.
- **The 4 MB-thread test pins `MAX_DEPTH` loosely on macOS.** A value of 6,000 still passes there, though it would likely fail on aarch64 Linux.
- **Reading an entry that's a FIFO blocks forever.** Only the owner can plant one, so this is informational.

- **Depends on:** 20260923-32.
- **Came from:** Second review of 20260923-32.
- **README:** Where QUAACK runs.
- **Status:** done
- **Note (from the review of 20260922-66):** A symlinked store base (`~/.quaack/runs`) is followed by create, open, and teardown. Decide whether to refuse it.
- **Decided:** A symlinked store base (`~/.quaack/runs` or `~/.quaack`) is refused, failing closed. Only QUAACK's own components are checked, not the operator's home directory. The CLI sends `bad_store_base` for any base it can't use.
- **Landed:** Merged into `main` after a review, a fix round, and a clean second review. The minor findings went to 20260924-18.

### 20260922-17. 3a relations.

List the query's relations with pg_query and check each `relkind`. Abort on views and materialized views.

- **Depends on:** 20260922-14.
- **README:** 3a.
- **Status:** done
- **Decided:** Allow only plain tables (`relkind` `r`). Abort on views, materialized views, partitioned tables, and foreign tables, and name the relation and its kind in the message.
- **Decided (main session, pending the user):** Each kind gets its own rule: `view_relation`, `matview_relation`, `partitioned_relation`, `foreign_relation`, `sequence_relation`, `composite_type_relation`, `toast_relation`, `index_relation`, and `not_a_table`. The relation name stays in the enclave. Unless every reference says ONLY, every inheritance descendant is checked, and the first one that isn't `r` is refused. Relations are checked in the query's text order.
- **Landed:** Merged into `main` after a review, a fix round, a second review, a tests-only round, and a fresh check of those tests. The entry point is `Relations.check(sql, settings, connection)`. The minor findings went to 20260924-19.

### 20260922-18. 3b schema dump and subset.

Run the full schema-only dump on every namespace the query touches, plus `public`. Build the subset: the query's tables and their FK parent tables.

- **Depends on:** 20260922-17.
- **README:** 3b.
- **Status:** done
- **Decided:**
  - Include the whole FK chain up, not only direct parents, so arena can satisfy every FK.
  - Don't parse the dump. Find the subset tables and their FK ancestors from `pg_catalog`, and get the subset from `pg_dump --table` for each one. This came from 20260923-1.
- **Decided (user, September 24):** For v1, schema DDL is assumed to hold no PII, so the subset can go to the LLM as is.
- **Landed:** Merged into `main` after a review, a fix round, a second review, a tests-only round, and a fresh check of that test. The entry point is `SchemaDump.run(store:, relations:, connection:, conninfo:, pg_dump:)`, and it stores `schema_dump` and `schema_subset`. The leftover findings went to 20260924-22.

### 20260924-4. Parenthesize what pg_query deparses wrong.

The round-trip guard (20260923-55) now correctly refuses supported constructs that pg_query's deparser prints without needed parentheses, which would change their meaning:
- `(a OR b) IS NULL`
- `(a AND b) IS NOT NULL`
- `(NOT a) IS NULL`
- `(a AND b) IN (true)`
- `(a AND b) = ANY(...)`
- `(a = 1) = ANY(ARRAY[true])`
- `a IS NOT DISTINCT FROM (b AND c)`
- `a BETWEEN (b AND c) AND d`
- `created_at AT TIME ZONE ('UTC' || '')`

Before deparsing, wrap the operand in an explicit parenthesis node, or post-process the SQL, so these round-trip and stop being refused. Keep the guard in place as the check. Also consider fixing shapes, which use `deparse_expr` and so turn `EXISTS (SELECT WHERE x)` into `EXISTS (x)`.

- **Depends on:** 20260923-55.
- **Came from:** The reviews of 20260923-55.
- **README:** Step 1.
- **Status:** done
- **Landed:** Merged into `main` after two reviews. The second review was clean: 77,000 fuzzed supported queries round-trip with none refused, and 2,798 gave the same rows on PG18. `Deparse::Parentheses.add!` wraps operands before deparsing, and the round-trip guard still runs last. The leftovers went to 20260924-23.

### 20260922-16. Production inventory.

Check the connection to the production server and record the version, extensions, memory, planner settings, parallel settings, non-default GUCs from the plan's `SETTINGS`, `pg_database` locale fields, and `default_text_search_config`.

- **Depends on:** 20260922-4, 20260922-13.
- **README:** Step 2.
- **Status:** done
- **Decided:**
  - Connect with the operator's own libpq setup on the jump server: the host from the input, plus `PGUSER`, `~/.pgpass`, and `~/.pg_service.conf`. QUAACK stores no credentials, and it reads inside a read-only transaction.
  - A `quaacks` config value holds a one-line shell command for finding instance memory, with the hostname filled in. The enclave script runs it on the jump server. That leaves room for any cloud provider.
- **Open questions:** What does the memory command print (bytes, or a size like `64GB`)? What happens when it isn't configured, or when it fails?
- **Answered (main session default, pending the user):** The memory command prints bytes, or a number with a kB, MB, GB, TB, KiB, MiB, GiB, or TiB unit (all binary). If it isn't configured, memory is unknown and the run continues. If it's configured and fails, the run aborts with `memory_command_failed`, `memory_command_timed_out`, or `memory_command_bad_output`. The config is `~/.quaack/config.json`, with `memory_command` and a `{host}` placeholder.
- **Landed:** Merged into `main` after a review, a fix round with only the one blocker (`enable_gathermerge`), and a clean second review. It adds `quaacks inventory --run <id>` and the whitelist type `inventory: [major_version, memory_known]`, and makes `pg` a runtime dependency of quaacks. The minor findings went to 20260924-24.

### 20260922-23. 3g redaction.

Replace literals with numbered, shape-preserving placeholders. Annotate each with estimated and actual rows from the consuming plan node. Strip literals from plan quals. Keep the placeholder map in the store. Bind real literals with `PREPARE` when running placeholder queries. Make the plan redaction reusable for racetrack plans.

- **Depends on:** 20260922-13, 20260922-15.
- **README:** 3g.
- **Note (from the review of 20260923-32):** Egress uses json's default `max_nesting` of 100, and a plan takes two levels per node. So a redacted or canonical plan more than about 48 nodes deep can't go out. Decide whether to flatten plans, set an explicit `max_nesting` together with a stack rescue, or refuse them with a clear rule.
- **Status:** done
- **Note:** Built on branch `task/20260922-23` through a build, a review, a fix round, and a second review, but not landed. The second review found that a string like `'1e99999999'` hangs `Rational()` in the matcher. 20260924-11 finishes it on top of that branch.
- **Decided:** Match each literal in a racetrack plan to the placeholder map by value, after normalizing casts. Replace anything still unmatched with a generic `$?` marker, so no literal leaks, and count the masks for the 15b burndown.
- **Landed:** Merged into `main` together with 20260924-11 and 20260924-16, which finished it.

### 20260924-11. Finish 3g redaction.

Split out of 20260922-23. The work so far is on branch `task/20260922-23`. Build on that branch, then land both together. Fix what the second review of 20260922-23 found:
- **A huge exponent hangs redaction.** `Matcher#number` calls `Rational(text)` on any text that looks like a decimal, with any exponent. `Rational("1e99999999")` doesn't finish in 60 seconds. An untyped string placeholder is `unknown`, which is in `NUMBERS_FROM`, so `WHERE t.s = '1e99999999'` hangs. Cap the exponent and the digit count before converting, or compare some other bounded way. Test it with a timeout.
- **Bit strings never match real plans.** PG18 prints `B'10110'` as `'10110'::bit varying`, and `X'1F'` as `'00011111'::"bit"`. The matcher never compares a string token with a bit placeholder, so the `bits?` branch never runs for real plans. Match them, and test with real PG18 output.
- **Surviving mutants:**
  - The retry-cap guard (`@types[number - 1] == "unknown"`). Test it with a fake connection that repeats 42P18 for the same parameter.
  - The ESCAPE `uncast`. Test `ESCAPE '!'::text`.

- **Depends on:** 20260922-23's branch.
- **Came from:** Second review of 20260922-23.
- **README:** 3g.
- **Status:** done
- **Note:** Built on branch `task/20260924-11` (on top of `task/20260922-23`) through a build, a review, a fix round, and a second review, but not landed. This task's own items are fixed and verified. The second review found three new blockers, and 20260924-16 finishes the work on the same branch.
- **Landed:** Merged into `main` with 20260922-23 and 20260924-16.

### 20260924-16. Finish 3g redaction, part two.

Split out of 20260924-11. The work so far is on branch `task/20260924-11`, which also carries 20260922-23. Build on that branch, then land all three together. Fix what the second review of 20260924-11 found:
- **A number like `5.e3` crashes redaction, and the error message quotes the literal.** `DECIMAL` accepts `\d+\.` followed by an exponent, but `Rational("5.e3")` raises `ArgumentError: invalid value for convert(): "5.e3"`. It fires while the map is built, for any `unknown` or number placeholder (`t.s = '918273.e5'`, or the numeric literal `t.n = 918273.e5`), and in `Redaction.plan` on plan tokens. Match or mask the literal, and never raise with it in the message. Look for other texts that `DECIMAL` accepts but `Rational` or `Literal` refuse.
- **An expression that appears in both GROUP BY and the select list, ORDER BY, or HAVING gets two placeholders, so it can't be prepared.** `SELECT date_trunc('day', o.created_at), count(*) FROM public.orders o GROUP BY date_trunc('day', o.created_at)` becomes `date_trunc($1, ...) ... GROUP BY date_trunc($2, ...)`, and `Binding#prepare` fails with 42803. `o.status || '-x'` fails the same way. **Main session default, pending the user:** where Postgres requires two expressions to match (GROUP BY against the target list, ORDER BY, and HAVING; DISTINCT ON against the leading ORDER BY; SELECT DISTINCT against ORDER BY; and any others you find), equal literals in matching positions of structurally identical expressions share one placeholder. Everywhere else, keep one placeholder per occurrence. The map still sends each placeholder to exactly one value. Record the rule in README 3g. Test by binding and running the redacted query on real PG18, and check that the rows match the original's. The existing "GROUP BY and HAVING" sentinel query has to bind, too.
- **Vacuous test: "refuses SQL that isn't one SELECT".** Changing `unless stmts.size == 1 && stmts.first.stmt.select_stmt` to `unless stmts.size == 1` survives, because the only input has two statements. Add a single non-SELECT, such as `DELETE ... WHERE id = $1`.
- **Binding accepts a data-modifying CTE and `FOR UPDATE`,** which SupportedSql refuses. Refuse them in Binding too, or narrow the doc's "exactly one SELECT" claim to what's checked.
- **Surviving mutants worth killing:**
  - `literal.rb`: `digits = text.delete("_")` → `text` (PREPARE would declare `1_000_000_000_000` as numeric). The `INT8` bounds (±1). `> MAX_DIGITS` → `>=`. Dropping `.delete_prefix("+")`. `class_of` for a Float node (the shape of 5000000000).
  - `matcher.rb`: the `MAX_NUMBER` boundary (`>=`, 99, 101). `NUMBER_TYPES` without `bigint`. `[eE]` and `[+-]?` in `DECIMAL`. `TRUE_TEXT` and `FALSE_TEXT` members. The `strip` and `downcase` in `word`. The `.sort` on the number and boolean branches.
  - `expression.rb`: the array `rescue ArgumentError` not counting its mask.
  - `binding.rb`: dropping `raise unless postgres_error?(e)`. The 42P18 sqlstate check and the regex anchors in `untyped_parameter`. Deleting `RELEASE SAVEPOINT`. Capping retries at two (test a query with two untyped parameters, such as `concat('a', 'b')`).
- **The huge-exponent test's `Timeout` can't interrupt `Rational()`.** Make the test fail fast without the cap, for example by running the call in a subprocess with a kill.

The three `Cast` survivors in `expression.rb` (the WITH line in `Cast#word?`, `after_word?` in `modifiers`, and the `break` on `","`) couldn't be reached from a real PG18 plan. Kill them if you can build a reachable case. Otherwise, say so.

- **Depends on:** 20260924-11's branch.
- **Came from:** Second review of 20260924-11.
- **README:** 3g.
- **Status:** done
- **Decided (user, September 24):** Where Postgres requires two expressions to match, equal literals in matching positions share one placeholder. Otherwise, each occurrence gets its own.
- **Landed:** Merged into `main` with 20260922-23 and 20260924-11, after a review, a fix round with only the blockers, a second review, a tests-only round, and a fresh check of those tests. The leftovers went to 20260924-25.

### 20260924-21. 9d Shape deparses without the round-trip guard.

**High priority. It's a correctness bug in the 9d comparison.** `ResultComparison::Shape#build` in `enclave/lib/quaack/enclave/result_comparison.rb` calls raw `PgQuery.deparse`, with no round-trip guard and no parentheses. It runs on the real 9d path: `without_limit`, `with_tiebreaker`, and `probe`. For example, `Shape.parse("SELECT id FROM t WHERE (a OR b) IS NULL ORDER BY id LIMIT 5", nil).without_limit` returns `SELECT id FROM t WHERE a OR b IS NULL ORDER BY id`. That's a different query, and it silently changes what 9d compares. Route it through `Deparse.faithfully` (with the parentheses fix from 20260924-4 once that lands), and refuse cleanly when the guard refuses. Add a PG18 test where the raw deparse would change the rows. Also check for other raw `PgQuery.deparse` or `deparse_expr` calls in the enclave that build SQL to run, and route each one through the guard.

- **Depends on:** 20260922-47, 20260923-55.
- **Came from:** First review of 20260924-4.
- **README:** 9d, Step 1.
- **Status:** done
- **Landed:** Merged into `main` after two clean lean reviews. `Shape#build` uses `Deparse.faithfully`, and a refusal raises `ResultComparison::Error` with rule `deparse_mismatch`. `without_limit` also resets `limit_option`. A grep found no other enclave code that deparses SQL for running without the guard. A minor note: `LIMIT ALL` and `LIMIT NULL` use subset mode, which is harmless.

### 20260922-19. 3c statistics.

Pull planner statistics (including extended statistics), index definitions, and index sizes for the query's tables. Keep them in the governed store as value-class data.

- **Depends on:** 20260922-17.
- **README:** 3c.
- **Note (from the review of 20260922-32):** Leave out invalid indexes (`indisvalid = false`), or a failed `CREATE INDEX CONCURRENTLY` counts as covering in 5a-3. Also fill `TableStatistics#indexes`, and the low-cardinality set for 3f, in the shapes `Dedupe` takes.
- **Status:** done
- **Landed:** Merged into `main` after two clean lean reviews. The entry point is `PlannerStatistics.run(store:, relations:, connection:)`, and `PlannerStatistics.load(store)` reads it back. It stores the `statistics` entry, and returns `Statistics` shapes with `TableStatistics#indexes` filled, plus `few_distinct` (fewer than 50 distinct values) for 3f and Dedupe. Invalid indexes are left out, and inheritance parents are refused. The leftovers went to 20260924-26.

### 20260922-22. 3f PII and low-cardinality classification.

Classify each column as PII or not, using a configured list and a high-cardinality text heuristic. Mark low-cardinality columns (fewer than 50 distinct values, not PII). Decide which derived scalars and MCV values may leave.

- **Depends on:** 20260922-19.
- **README:** 3f.
- **Status:** done
- **Decided:** The PII list is a set of `schema.table.column` globs, such as `*.users.email`, in the `quaacks` config file on the jump server. A text column is high-cardinality when it has 50 or more distinct values, the same line 3f uses for low-cardinality. The config can change the threshold.
- **Decided (user, September 24):** Low-cardinality also requires a positive pg_stats `n_distinct`, meaning the values repeat. So a small table's unique values, such as 40 emails in a 40-row table, never leave.
- **Landed:** Merged into `main` after a review, a fix round for the user's rule, and a second review. The entry point is `PiiClassification.run(store:, config:)`, and `.load` reads it back. It stores the `classification` entry with the `outbound_statistics` projection, and `Result#low_cardinality` feeds Dedupe. The config gains `pii_columns` globs and `cardinality_threshold`. `few_distinct` was removed from 3c. The leftovers went to 20260924-27.

### 20260922-21. 3e literal set.

Build the slow, worst-case, and typical literal sets and keep them in the governed store.

- **Depends on:** 20260922-14, 20260922-19.
- **README:** 3e.
- **Status:** done
- **Decided:** Pick values by operator.
  - **Ranges:** the worst case is the histogram bound that selects the most rows, and the typical value is the middle bound.
  - **`IN` lists:** each element follows the equality rule, and the list keeps its length.
  - **`LIKE` and any other operator:** use the slow literal in all three sets.
- **Decided (builder and main session, where the rules were silent):**
  - For BETWEEN, and for a lower and an upper range on the same column in the same AND, the typical value is the middle histogram bucket, and the worst case is the first and last bounds.
  - IN elements take distinct MCVs, and consecutive bounds for the typical set.
  - An `= ANY` array falls back as a whole.
  - Only plain `=` counts as equality.
  - `$n::type` cast placeholders keep the slow literal.
- **Landed:** Merged into `main` after a review, a fix round for the range-pair blocker, and a second review. The entry point is `LiteralSet.run(store:, sql:)`, and `.load` reads it back. It stores `literal_sets` (slow, worst_case, and typical placeholder maps, plus fallback reasons), and any set binds through `Redaction.binding`. The leftovers went to 20260924-28.

### 20260922-25. Run server checks.

Verify the run server: same major version and extensions as production plus HypoPG, same planner GUCs and locale settings, superuser access, no other clients, no background jobs, and autovacuum off. Abort and name the failed check.

- **Depends on:** 20260922-16.
- **README:** Step 4.
- **Note (from the review of 20260923-56):** The 5a-4 runner pins `plan_cache_mode` and `hypopg.enabled` itself, and refuses when HypoPG has hidden indexes. It relies on this step for everything else. The reviewer found these change plans without warning, so compare them with production too:
  - `enable_*`, the cost GUCs, `geqo`, the collapse limits, and `max_parallel_*`.
  - The developer GUC `debug_parallel_query`. It moved a baseline cost from 1887 to 2887.
  - `TimeZone`, `DateStyle`, and `IntervalStyle`, which change how a quoted literal is read.
  - Per-tablespace `random_page_cost`.
  - Also note that the required superuser bypasses row-level security. Plans for tables with RLS can differ from production. The step 5 plan gate catches that for the original query.
- **Status:** done
- **Decided:** Require that `pg_stat_activity` shows no other client backends. If pg_cron is installed, also require that no job in `cron.job` is active. Document that schedulers outside Postgres are the operator's responsibility.
- **Decided (builder, accepted by the main session):**
  - Production's value for a GUC is its own recorded value from step 2, not the plan session's value.
  - Step 2 also records TimeZone, DateStyle, IntervalStyle, and default_statistics_target, because they aren't EXPLAIN-flagged.
  - A GUC with no recorded value must be EXPLAIN-flagged and at its boot_val.
- **Landed:** Merged into `main` after two clean lean reviews. The entry point is `RunServerCheck.run(store:, connection:, own_connections:)`. It raises on the first failure, with a `run_server_*` rule and a message of the form `rule: name`. The leftovers went to 20260924-29.

### 20260922-26. 4a racetrack setup.

In the restored racetrack database, create `hypopg`, the `quaack` schema, and `clock_anchor()`.

- **Depends on:** 20260922-25, 20260922-24.
- **README:** 4a.
- **Status:** done
- **Landed:** Merged into `main` after two clean lean reviews. The entry point is `Racetrack.setup(store:, connection:)`. `quaack.clock_anchor()` is plpgsql, STABLE, PARALLEL SAFE, and COST 1, which matches `now()` and isn't inlined, so plans and runtime pruning match production's `now()` on PG18. A foreign object in the `quaack` schema is refused, checked through pg_depend.

### 20260922-11. Inbound check for index DDL.

Accept exactly one `CREATE INDEX` statement on a table the query uses. Reject anything else, naming the rule it broke.

- **Depends on:** 20260922-1, 20260922-17.
- **README:** What goes into the enclave.
- **Status:** done
- **Decided:**
  - Reject `CONCURRENTLY`, `TABLESPACE`, and `UNIQUE`.
  - Don't reject any index method. The user sees real room for improvement in methods beyond btree.
  - The table name must be schema-qualified. Refuse an unqualified one. Don't resolve it through the search path.
  - Refuse volatile functions and operators in key expressions and the WHERE predicate, using the 3d rule. Leave STABLE to Postgres: HypoPG (5a-4) and the real CREATE INDEX (step 12) refuse it with exact type resolution. (The first plan was to require IMMUTABLE here, but the catalog lookup can't pick overloads, and `=`, `<`, `||`, and `date_trunc` each have STABLE versions, so almost every partial index would be refused.)
  - Also reject `NULLS NOT DISTINCT` and `ON ONLY`. Accept `WITH (...)` storage options and `IF NOT EXISTS`.
  - Drop any index name the DDL gives, so later steps name indexes themselves.
- **Open questions:** How should later steps treat index methods other than btree? 5a-3 sets GIN and GiST candidates aside today. (Not needed for this task.)
- **Landed:** Merged into `main` after a build, a first review, and a second review. Both reviews found nothing blocking, so there was no fix round. The builder stopped once to ask about the IMMUTABLE rule, and the user changed it to refuse volatile only.
  - `IndexDdlCheck.check(sql, tables, settings, connection)` runs these rules in order: `unparsable`, `not_create_index`, `concurrently`, `unique`, `nulls_not_distinct`, `tablespace`, `on_only`, `unqualified_table`, `unknown_relation`, `forbidden_in_index` (parameters, subqueries, and aggregate, window, or grouping calls), `unsupported_construct`, `volatile_function` or `bad_search_path`, and `deparse_mismatch`.
  - It returns `Accepted(sql:, parse:, table:)`. The SQL has the name, IF NOT EXISTS, and comments dropped. Errors carry a rule and shape-only names, with `cause: nil`.
  - It reuses `VolatilityCheck.check_parse` (new) and `IndexSql.forbidden` (split out of `check_predicate_node`).
  - The first review's minor finding (the attribute-notation and domain CHECK gaps reach index DDL) went to 20260923-35. The second review's two minor findings became 20260925-1.

### 20260922-12. Inbound check for step 10 inserts.

Accept only plain `INSERT` statements into tables in the 3b subset schema. Reject `INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, and anything else that isn't a plain insert.

- **Depends on:** 20260922-1, 20260922-18.
- **README:** What goes into the enclave.
- **Note (from the review of 20260922-46):** The arena runner accepts any single InsertStmt, including `WITH ... INSERT`, `ON CONFLICT`, and `RETURNING`. This check is the real guard. It must refuse those forms, plus `set_config`, advisory locks, and any function that isn't immutable.
- **Status:** done
- **Decided:** A plain insert is `INSERT INTO <subset table> (<columns>) VALUES (...), ...`. The values can be constants, casts, `DEFAULT`, and calls to immutable functions that pass the 3d volatility check. Reject `INSERT ... SELECT`, `ON CONFLICT`, `RETURNING`, `WITH`, `OVERRIDING`, and any function that isn't immutable.
- **Landed:** Merged into `main` after a build and a first review. The review found nothing blocking, so there was no fix round and no second review.
  - `InsertCheck.check(sql, tables, settings, connection)` runs these rules in order: `unparsable`, `not_insert`, `with`, `on_conflict`, `returning`, `overriding`, `missing_columns`, `insert_select`, `alias`, `unqualified_table`, `unknown_relation`, `unknown_column`, `not_plain_value`, `not_immutable` or `bad_search_path`, `volatile_function`, and `deparse_mismatch`. It returns `Accepted(sql:, parse:, table:)`.
  - Function calls must be IMMUTABLE. Casts are held only to the 3d no-volatile rule, because the date and timestamptz input functions are STABLE.
  - The review's four minor findings became 20260925-2.

### 20260922-28. 5 plan gate.

`EXPLAIN` the original query on the racetrack with the slow literals and compare canonical forms with the step 1 plan. On mismatch, abort and name stale racetrack statistics as the likely cause.

- **Depends on:** 20260922-26, 20260922-15, 20260922-21, 20260922-23.
- **README:** Step 5.
- **Status:** done
- **Note (from 20260922-26):** CanonicalPlan fingerprints include function names, so a racetrack qual like `created_at > quaack.clock_anchor()` won't match production's `created_at > now()`. Map the anchor back to the original functions (as `ClockAnchoring.restore` does), or normalize both sides, before comparing.
- **Landed:** Merged into `main` after a build and a first review. The review found nothing blocking, so there was no fix round and no second review.
  - `CanonicalPlan` now always swaps the clock functions 3h replaces for their anchored form before fingerprinting, and drops `pg_catalog` from casts of `quaack.clock_anchor()`.
  - `PlanGate.check(store:, connection:, sql:)` takes the redacted, anchored SQL, binds the stored placeholder map, EXPLAINs through `SingleCandidateTest.run`, and raises `plan_gate_bad_plan`, `plan_gate_not_comparable`, or `plan_gate_mismatch_likely_stale_statistics`. The cause is in the rule name, because only the rule leaves the enclave.
  - Parameter types are inferred by Postgres. The review found no realistic query where that changes the plan.
  - The review's two minor findings became 20260925-3.

### 20260925-7. Enclave subcommand: `quaacks run-server` (step 4).

Record the run server in the run store and run the step 4 checks against it. `quaacks run-server --run <run ID> --host <host> --port <port> --racetrack-db <name> --arena-db <name>`. Credentials come from the operator's libpq setup (the `PG` environment variables, `~/.pg_service.conf`, `~/.pgpass`), as they do for production. QUAACK stores none. Later racetrack and arena steps connect using what this step recorded. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260922-25, 20260922-16.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** Step 4.
- **Decided:** The user chose to give the run server at its own step and store it in the run, with the port recorded too.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks run-server` checks its arguments and refuses a run with no inventory. It runs `RunServerCheck` on the racetrack database only, because 4b makes arena. It records the `run_server` entry (host, port, racetrack_db, arena_db) only after every check passes. It prints only DONE.
  - `RunServer.connect(store, :racetrack | :arena)` opens later steps' connections. A libpq failure becomes `run_server_connection_failed` with no cause.
  - Refusals: `bad_run_server_host`, `bad_run_server_port`, `bad_run_server_database`, `run_server_same_database`, and `run_server_no_inventory`. IPv6 and Unix sockets are unsupported in v1.
  - The review's minor finding became 20260925-17.

### 20260925-8. Enclave subcommand: `quaacks qualify` (step 1 qualification and 3a relations).

Fully qualify the query against production and find its relations. Store the qualified query and the relation list. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260922-14, 20260922-17, 20260922-13.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** Step 1, 3a.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks qualify --run ID` reads `query`, `plan` and `server`, connects to production with libpq, and runs `Relations.check` (qualification through the plan's `search_path`, and the 3a relkind check). Only after every check passes does it store `qualified_query` (a String that still holds literals) and `relations` (an Array of `{schema, name}` in first-named order). It prints only DONE.
  - `CLI::Step` moved to `cli/step.rb`.
  - The review's minor findings became 20260925-18.

### 20260925-9. Enclave subcommand: `quaacks schema-dump` (3b).

Dump the schema and build the subset. Store the subset. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260922-18.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3b.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks schema-dump --run ID` reads `server` and `relations`, and runs `SchemaDump.run` inside `Inventory::Production.read_only`. pg_dump comes from PATH and gets only the host; libpq supplies the rest, the same way the connection gets it. It stores `schema_dump` (namespaces and the full DDL) and `schema_subset` (tables and DDL), and prints only DONE. The 5a-5 payload step will send the subset.
  - The review's minor findings became 20260925-19.

### 20260925-10. Enclave subcommand: `quaacks statistics` (3c).

Gather the planner statistics and existing indexes for the query's tables (README 3c). Store them for generators one and two and for Dedupe. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260922-19.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3c.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks statistics --run ID` reads `server` and `relations` and calls `PlannerStatistics.run`, which reads inside `read_only` and writes the `statistics` entry only after the transaction closes. It prints only DONE. `PlannerStatistics.load` rebuilds the objects.
  - It uses `relations`, not the subset tables. The review confirmed that no consumer needs statistics for FK parents: 4a's restore brings production's statistics with it.
  - The review's minor finding became 20260925-20.

### 20260925-11. Enclave subcommand: `quaacks volatility` (3d).

Run the volatility check on the qualified query. Store the result. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260922-20.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3d.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks volatility --run ID` reads `server`, `plan` and `qualified_query`, and runs `VolatilityCheck.check` inside `read_only` with the plan's `search_path`. After the transaction closes it stores the marker `volatility: {"passed" => true}`. It prints only DONE. Stable clock functions pass, for 3h to anchor.
  - The refusal names only its rule for now. The user wants the function named, so that became 20260925-21.

### 20260925-13. Enclave subcommand: `quaacks classify` (3f).

Classify PII and low-cardinality columns. Store the classification, and send `outbound_statistics` out as `column_stats`. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-10, 20260922-22.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3f.
- **Status:** done
- **Decided:** The user changed this: classify stores the stats and sends nothing. The 5a-5 payload step (20260925-4) sends `outbound_statistics`.
- **Landed:** Merged into `main` after a build, a first review, a fix round for the user's change, and a clean second review.
  - `quaacks classify --run ID` loads the config, runs `PiiClassification.run`, and stores `classification` (`{columns, outbound_statistics}`). It never touches production, prints only DONE, and stores nothing on failure.

### 20260925-14. Enclave subcommand: `quaacks redact` (3g).

Redact the query. Store the placeholder map and the redacted SQL (the redacted SQL isn't stored today). Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260925-13, 20260922-23.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3g.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks redact --run ID` reads `qualified_query` and `plan`, and runs `Redaction.redact`. It computes everything before the first write, then stores `placeholder_map`, `placeholder_shapes`, `redacted_query`, and `redacted_plan` (`{explain, masked, dropped}`). It prints only DONE and needs no production connection.
  - The review's minor findings became 20260925-22.

### 20260925-12. Enclave subcommand: `quaacks literals` (3e).

Build the literal set and store it. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-8, 20260925-10, 20260925-14, 20260922-21.
- **Note (from the first build attempt):** `LiteralSet.run(store:, sql:)` reads 3g's `placeholder_map` and 3c's `statistics`, and checks the redacted SQL against the map. So this step runs after `quaacks redact`, not before it. It reads `placeholder_map`, the redacted SQL, and `statistics`, and refuses cleanly if any is missing. It writes the existing `literal_sets` entry and needs no production connection. It should also refuse unless the `volatility` marker exists.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3e.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks literals --run ID` refuses with `volatility_not_passed` unless `volatility` is `{"passed" => true}`. It then runs `LiteralSet.run(store:, sql: redacted_query)`, which reads `placeholder_map` and `statistics` and writes `literal_sets`. It prints only DONE and needs no production connection.
  - The review's minor finding went into 20260925-22.

### 20260925-15. Enclave subcommand: `quaacks anchor` (3h).

Anchor the clock in the redacted query. Store the anchored SQL. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-14, 20260922-24.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 3h.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks anchor --run ID` runs `ClockAnchoring.anchor(redacted_query, plan settings)`, and stores `anchored_query` (the `sql:` for `PlanGate` and 5a-4) and `clock_replacements` (names only, for `restore`). It prints only DONE. The CLI `STEPS` table moved to `cli/steps.rb`.
  - The review's minor findings became 20260925-23.

### 20260925-16. Enclave subcommand: `quaacks racetrack-setup` (4a).

Set up the racetrack on the run server recorded by `run-server`, using the stored schema and statistics. Each subcommand takes `--run <run ID>`, reads its inputs from the governed store, saves its output there, and sends only whitelisted shape through egress. Reuse an existing whitelist type where one fits. Add the subcommand to the README.

- **Depends on:** 20260925-7, 20260925-9, 20260925-10, 20260922-26.
- **Came from:** The builder of 20260925-6 found that no enclave subcommands exist for steps 3 and 4, so their outputs never reach the store.
- **README:** 4a.
- **Status:** done
- **Landed:** Merged into `main` after a build and a first review with nothing blocking.
  - `quaacks racetrack-setup --run ID` refuses with `racetrack_setup_no_run_server` when there's no `run_server` entry. Otherwise it connects with `RunServer.connect(store, :racetrack)`, runs `Racetrack.setup` (hypopg and `quaack.clock_anchor()`), and writes `racetrack_setup: true` only on success. It prints only DONE.
  - The review's minor findings went into 20260925-22.

### 20260925-6. Enclave subcommand for the mechanical half of step 5.

Add `quaacks` subcommands that open the racetrack connection and run the mechanical half of step 5: the plan gate, 5a-1, 5a-2, 5a-3, and 5a-4. They save the mechanical proposals and Dedupe state, the 5a-4 results, and the redacted plan in the governed store, so the 5a-5 subcommands (20260925-4) can read them. The driver side of step 5 is wired in 20260922-36.

- **Depends on:** 20260922-26, 20260922-28, 20260922-29, 20260922-30, 20260922-31, 20260922-32, 20260925-7 through 20260925-16.
- **README:** Step 5, 5a.
- **Note:** `IndexCandidate` and `Dedupe` can't be saved to and read back from the store yet. This task must add that, because the 20260925-4 `index-test` loads the Dedupe state it saves. Key the saved entries per search (for example `index_search_original`, and later `index_search_rewrite_<n>`).
- **Decided:** The user chose to build this as its own prerequisite task, ahead of the 5a-5 subcommands and 20260922-36.
- **Status:** done
- **Landed:** Merged into `main` after a build, a first review with four blocking findings, a fix round, and a clean second review.
  - `quaacks index-search --run ID [--search original]` refuses without `racetrack_setup`, runs PlanGate on `anchored_query`, builds a Dedupe from the stored statistics and low-cardinality columns, filters generators one and two, and runs SingleCandidateTest on each survivor for each literal set (slow, worst_case, typical). It prints only DONE.
  - It stores `index_search_original` as `{dedupe, baseline, results}`. Each set gets `{used, total_cost, plan}`, where `plan` is the EXPLAIN redacted through 3g. Candidates can hold real literals, which is allowed inside the store (see the note on 20260925-4).
  - `IndexStore` round-trips IndexCandidate and Dedupe, through a new `Dedupe.restore`.
  - The minor findings became 20260925-24. 5a-7 ranking is left for 20260925-4 and 20260922-36.

### 20260925-4. 5a-5 generator three: the LLM loop.

The rest of 20260922-33. Build the shape-only payload, ask the LLM for up to five candidates it hasn't seen covered, filter them through 5a-3, ask once for replacements of dropped ones, tag partial indexes, and test survivors with 5a-4. It must work for the original query and for rewrites.

- **Depends on:** 20260922-33 piece one (landed), 20260925-6.
- **README:** 5a-5.
- **Decided:** Use two enclave subcommands. `quaacks index-payload [--candidate ID]` sends the shape-only payload out through egress, using a new whitelisted type. `quaacks index-test` reads the LLM's DDL on stdin and runs `IndexDdlCheck`, then `from_ddl` with `sources: [:llm]`, then Dedupe against the mechanical proposals saved in the store, then 5a-4. It saves the results in the store and returns a shape-only outcome for each candidate: accepted, or dropped with its rule. The driver runs the replacement round by calling `index-test` again.
- **Note (from the review of 20260925-6):** The stored `index_search_<search>` entries hold real literals. Generator two runs on the unredacted step 1 plan, so partial predicates and key expressions, in `dedupe` proposals, drops, `covered_by`, and `results[].candidate`, can embed real quals such as `status = 'held'`. `index-payload` must not send candidate DDL or predicates as they are. Redact them through 3g, or allow only the 5a-3 low-cardinality values plus an explicit egress check. Add a sentinel test with a partial candidate whose predicate holds a sentinel. `index-test` should save its results under the same per-search key.
- **Note (from 20260925-13):** `index-payload` must send `classification.outbound_statistics` as the payload's `stats`. By the user's decision, classify stores it and sends nothing.
- **Note:** The prompt must say plainly that an unqualified table name gets the candidate refused and counts against the LLM.
- **Note:** `IndexDdlCheck` accepts `WITH (...)` storage options, but `from_ddl` returns nil for them. Strip them or refuse them, so LLM DDL that uses them isn't silently lost. The "proportion" bullet of 20260923-17 can be decided in light of piece one.
- **Status:** done
- **Landed (piece two):** Merged into `main` after a build, a first review with two blocking leaks, a fix round, and a clean second review.
  - `quaacks index-payload` sends the new `index_payload` type: query, placeholders, the plan with `Settings` stripped (the user's decision), schema, mechanical_results, and stats. `CandidateDdlRedaction` masks every constant in candidate DDL as `?`, except an MCV value compared directly with its own low-cardinality column.
  - `quaacks index-test` reads `{"ddls": [...]}`, filters through the stored Dedupe and GeneratorThree, runs SingleCandidateTest for each set, appends `llm_results`, replaces `dedupe`, and sends `index_outcome` lines. The driver's `index_test` calls the transport.
  - Left out, and moved to 20260926-3: the 5a-5 burndown record. Rewrite searches come with step 8 and 11.


### 20260922-33. 5a-5 generator three.

Build the shape-only payload, ask the LLM for up to five candidates it hasn't seen covered, filter them through 5a-3, ask once for replacements of dropped ones, tag partial indexes, and test survivors with 5a-4. Must work for the original query and for rewrites.

- **Depends on:** 20260922-6, 20260922-5, 20260922-11, 20260922-22, 20260922-23, 20260922-29, 20260922-32, 20260923-11.
- **README:** 5a-5.
- **Status:** done
- **Note:** The `IndexCandidate` shape from 20260923-11 only holds plain column keys. 5a-5 asks the LLM for expression indexes and operator classes such as `text_pattern_ops` and trigram GIN. So this task has to extend the shape with expression keys, opclasses, and probably collations, and teach 5a-3's dedupe to handle them.
- **Note (from 20260922-11):** The inbound check refuses index DDL whose table name isn't schema-qualified. The LLM prompt must say so plainly: an unqualified table name gets the candidate refused and counts against the LLM, so it should always write the schema.
- **Progress:** Piece one landed on `main` after a build, a first review, a fix round and a clean second review. `IndexCandidate::KeyColumn` now holds expression keys (normalized through pg_query, redacted like predicates), opclasses and collations (with `pg_catalog` dropped). `from_ddl` and `to_ddl` round-trip them, and Dedupe matches key columns only when all of them agree, including when a btree is read backward. The LLM loop is left, and it's split out as 20260925-4. Close this task when 20260925-4 lands.
- **Landed:** Covered by piece one of this task and by 20260925-4.


### 20260925-5. Generator three piece one loose ends.

Minor findings from the first review of 20260925-4:
- **`covered_by` going out through egress is untested.** In `enclave/lib/quaack/enclave/generator_three.rb` `messages`, setting `covered_by: nil` stays green. Add a DDL covered by an existing index to the egress sentinel case in `generator_three_postgres_spec.rb`.
- **The replacement ask can ask for more than five.** `driver/lib/quaack/driver/generator_three.rb` `replacement_ask` asks for `dropped.size` replacements, including `too_many` drops. Cap it at five, and leave `too_many` drops out of the request.

- **Depends on:** 20260925-4 piece one (landed).
- **Came from:** The first review of 20260925-4.
- **README:** 5a-5.
- **Status:** done
- **Landed:** Both fixes were folded into piece two of 20260925-4.

### 20260922-54. 12b run discipline.

Run every measurement statement in a `READ ONLY` transaction with `statement_timeout`, one at a time.

- **Depends on:** 20260922-26.
- **README:** 12b.
- **Status:** done
- **Decided:** `statement_timeout` is 3× the original query's baseline time, clamped to at least 5 seconds and at most 5 minutes. We should always be willing to wait 5 seconds, and anything needing more than 5 minutes needs a human. A candidate whose measurement times out is dropped and counted in the report as timed out.

### 20260923-12. 5a-2 on rewrite plans.

20260922-31 builds generator two from the production plan only. The task also wanted it to run on rewrites, with the racetrack plan. A racetrack plain `EXPLAIN` has no actual rows and no rows removed, so most of the patterns can't fire there. Decide how the patterns work on estimates, then build it.

- **Depends on:** 20260922-31, 20260922-26.
- **Came from:** Splitting 20260922-31, at the user's request to build it early.
- **README:** 5a-2, step 8.
- **Status:** done
- **Decided:** On rewrite plans, run only the patterns that need neither actual rows nor rows removed, and skip the rest. The LLM in step 11 covers the gaps.

### 20260922-40. 8 structural discards.

Discard candidates that fail to plan on the racetrack, or whose output column count or types differ from the original. Count inbound-check rejections here too, for the report.

- **Depends on:** 20260922-10, 20260922-23, 20260922-26.
- **README:** Step 8.
- **Status:** done

### 20260922-41. 8 mechanical index search per candidate.

For each remaining candidate, run 5a-1, 5a-2, 5a-3, and 5a-4 on its own parse and racetrack plan. Save the 5a-4 results for step 11.

- **Depends on:** 20260922-40, 20260922-29, 20260922-30, 20260922-31, 20260922-32, 20260923-12.
- **README:** Step 8.
- **Status:** done

### 20260922-42. 8 three-configuration pruning.

`EXPLAIN` each candidate with no hypothetical indexes, with the original's top three, and with its own top three. Discard it only if its canonical plan matches the original's in all three.

- **Depends on:** 20260922-41, 20260922-35, 20260922-15.
- **README:** Step 8.
- **Status:** done
- **Decided:** Compare against the original's plan under the same index configuration.

## Step 9: Predicate-aware fixtures.

### 20260922-34. 5a-6 refinement round.

If any LLM candidate went unused or lost to a simpler mechanical candidate, send the LLM its own 5a-4 results and ask for one revision. Filter and test what comes back. Only one round.

- **Depends on:** 20260922-33.
- **README:** 5a-6.
- **Status:** done
- **Decided:** An LLM candidate qualifies for the revision round if the planner didn't use it, or if a mechanical candidate with fewer key and INCLUDE columns (ties broken by smaller estimated size) has a worst-case cost across the literal sets no higher than the LLM candidate's.

### 20260922-36. Step 5 orchestration.

Wire the plan gate and 5a-1 through 5a-7 together in the driver, in the order the README gives.
- **Decided (driver CLI):** `quaack start` (20260926-1) creates the run, and `quaack run --run ID` drives every remaining step in order. It can resume, skipping steps whose outputs are already in the store. Each orchestration task adds its stage to that sequence.

- **Depends on:** 20260922-28, 20260922-30, 20260922-31, 20260922-32, 20260922-33, 20260922-34, 20260922-35.
- **README:** 5a.
- **Status:** done
- **Note (from 20260922-22):** Feed `PiiClassification#low_cardinality` into Dedupe, and send `outbound_statistics` through egress. Update from 20260925-13: the 5a-5 `index-payload` step (20260925-4) sends it, and Dedupe's low-cardinality input comes from the stored `classification` entry.

## Steps 6 and 7: Rewrite candidates.

### 20260926-1. Driver finds the jump server with a configured command.

The driver has no way to know which jump server serves a production server. Add a driver config file on the laptop, `~/.quaack/driver.json`, with `jump_command`: a shell one-liner with `{server}` that prints the ssh host, following the pattern of `memory_command` (quoting, timeout, output checks). The operator starts a run from the laptop with something like `quaack start --server <prod> --query <path on jump server> --plan <path on jump server>`. The driver runs `jump_command`, then runs `quaacks intake` remotely over `Transport::Ssh` (the query and plan files stay on the jump server), and remembers run ID to jump host locally, so later commands take only the run ID. Update README "Where QUAACK runs" and step 1.

- **Depends on:** 20260922-5, 20260922-13.
- **README:** Where QUAACK runs, Step 1.
- **Decided:** The user chose a driver-side config command over a static map or a `--jump` flag.
- **Status:** done

### 20260926-2. Build and record the run server with a configured command.

Add `run_server_command` to the quaacks config on the jump server (`~/.quaack/config.json`). It's given `{server}` and `{run}`, builds or finds the run server from production, and prints JSON `{host, port, racetrack_db, arena_db}`. `quaacks run-server --run ID` with no flags calls it, validates the output the same way it validates the flags, and runs the step 4 checks. Flags still override. Add an optional matching `destroy_command` that `quaacks teardown` calls, so the run server is destroyed too, not just announced. Follow the `memory_command` pattern for quoting, timeouts, and discarding stderr. Nothing the command prints goes out except through the existing rules. Update README step 4 and teardown.

- **Depends on:** 20260925-7, 20260922-66.
- **README:** 4, Run teardown.
- **Decided:** The user chose a provision command in the quaacks config over having the operator build the server by hand.
- **Status:** done

### 20260924-30. Include extensions in the 3b schema dump.

pg_dump with `--schema` emits no CREATE EXTENSION. So the full dump that 4b loads into arena fails on columns like `public.citext`. Found while building 20260922-27. The user picked this fix on September 24.
- For each extension in production's `pg_extension` other than plpgsql, pass a quoted `--extension=<name>` to the full dump. pg_dump then emits `CREATE EXTENSION IF NOT EXISTS ... WITH SCHEMA ...`.
- Add each extension's schema to the full dump's namespaces, so `WITH SCHEMA ext` doesn't fail on a schema that doesn't exist.
- Test with real pg_dump 18 output: citext in public, and pgcrypto in a separate schema `ext`. Load the dump into a fresh template0 database, and check that it succeeds.
- Known and accepted: CREATE EXTENSION carries no VERSION, so arena gets the run server's default versions.

- **Depends on:** 20260922-18.
- **Came from:** The build of 20260922-27.
- **README:** 3b.
- **Status:** done

### 20260922-37. 6a rewrite generation.

Ask the LLM for rewrites of the redacted query, each stating its transformation and every assumption it relies on. Send candidates through the inbound check.

- **Depends on:** 20260922-6, 20260922-5, 20260922-10, 20260922-18, 20260922-23.
- **README:** 6a.
- **Status:** done
- **Decided (wiring):** `quaacks rewrite-payload` sends the redacted query, plan, schema, and stats, reusing the `index_payload` fields where it can. `quaacks rewrite-check` reads the LLM's rewrites on stdin (SQL, transformation, and structured assumptions). It runs the inbound check, 6b, and step 8's structural discards on the racetrack, stores survivors under `rewrite_<n>`, and returns shape-only outcomes.
- **Decided:** Ask for up to five rewrites per run. Assumptions use a structured format, and the vocabulary is exactly: a `NOT NULL` column, a unique column set, a foreign key, and a `CHECK` constraint. A candidate stating any other kind of assumption is rejected.

### 20260922-38. 6b assumption check.

Check each stated assumption against `pg_constraint` and `pg_index`, treating `NOT VALID` constraints as absent. Reject candidates with unmet assumptions.

- **Depends on:** 20260922-37.
- **README:** 6b.
- **Status:** done
- **Decided:** The vocabulary is fixed by 20260922-37, so an assumption outside it rejects the candidate. A `CHECK` assumption is met only by a validated `CHECK` constraint on that table whose expression, normalized through pg_query, is identical to the stated one. Implied constraints don't count in v1.

### 20260922-39. 7 operator candidates.

Let operators submit placeholder-based rewrites through the driver. Ask the LLM to infer their transformation and assumptions, marked as inferred. Unmet inferred assumptions only add a report warning.

- **Depends on:** 20260922-37, 20260922-38.
- **README:** Step 7.
- **Status:** done
- **Decided:** A file flag on the laptop, `--rewrites <file>`, with one placeholder-SQL rewrite per `;`-terminated statement. They go through the same `quaacks rewrite-check` as 6a's rewrites, flagged as inferred.

## Step 8: Plan-based pruning.

### 20260924-27. 3f classification loose ends.

Findings from the build and reviews of 20260922-22:
- **text[], json, and jsonb columns aren't text-like for the heuristic,** so their MCV frequencies leave unless a glob names them. Their values never leave. The reviewer judged this low risk: a frequency vector over a large domain doesn't re-identify anyone. Decide whether they should fail closed as PII anyway.
- **Expression-index and extended-statistics MCVs are left out of the projection entirely.** If 5a-5 needs them, they'll need rules of their own.

- **Decided:** Leave text[], json and jsonb as they are: their frequencies may leave, and their values never do. Add rules that send expression-index and extended-statistics MCVs, classified under the rules of their base columns. An expression that touches any PII column is treated as PII.
- **Depends on:** 20260922-22.
- **Came from:** The build and reviews of 20260922-22.
- **README:** 3f.
- **Status:** done

### 20260922-44. 9 value pools.

Build each atom's pool: a satisfying value, a failing value, boundary values, pattern and case variants, `NULL` for nullable columns, and type boundary values.

- **Depends on:** 20260922-43, 20260922-21, 20260922-19.
- **README:** Step 9.
- **Status:** done

### 20260922-45. 9 scenario builder.

Build scenarios S0 through S6 from the pools, with hit rows, one near-miss row per atom, and join partners created or withheld. Every row satisfies every `VALID` constraint.

- **Depends on:** 20260922-44, 20260922-18.
- **README:** Step 9.
- **Note (from 20260924-5):** 9d reverses each run of consecutive same-table rows. So every table's rows must be contiguous in the fixture, or the reverse load does nothing. Tables with self-referencing FKs fail the reverse load (see 20260924-9).
- **Status:** done
- **Open questions:** This is likely the largest task in the backlog, so we'll probably split it when we pick it up. How do we satisfy `CHECK` constraints and required columns the query never mentions?
- **Decided:** Use the column's DEFAULT if it has one, or else a type-typical value (0, empty string, epoch). For a simple CHECK (column op constant, an IN list, or BETWEEN), pick a value that satisfies it. Refuse a query whose CHECKs are too complex, and list that as unsupported in v1.

### 20260922-48. 9c vacuity guard.

On S1, run the original with and without each atom replaced by `TRUE`. Retry vacuous atoms up to three times with other pool values. Mark any that stay vacuous as untested, by redacted shape.

- **Depends on:** 20260922-43, 20260922-45, 20260922-46, 20260922-47.
- **README:** 9c.
- **Status:** done

### 20260922-49. Step 9 orchestration.

Run every scenario through 9a to 9e for each candidate, and report pass or fail with the disproving scenario.

- **Depends on:** 20260922-45, 20260922-46, 20260922-47, 20260922-48.
- **README:** Step 9.
- **Status:** done

## Step 10: Adversarial fixtures.

### 20260922-50. 10a counterexample generation.

Ask the LLM for constraint-satisfying inserts that make a candidate and the original return different results, aimed at any untested atoms. Send them through the inbound check. Fill FK gaps by adding parent rows.

- **Depends on:** 20260922-6, 20260922-5, 20260922-12, 20260922-48.
- **README:** 10a.
- **Status:** done
- **Decided:** The enclave writes FK parent rows mechanically, using the step 9 fixture rules. The LLM writes shape-level inserts with placeholders, and the enclave binds the real literals.

### 20260922-51. 10b and 10c compare and roll back.

Load the inserts, run the 9d comparator, recheck untested atoms with the 9c test, and roll back. Up to three rounds per candidate.

- **Depends on:** 20260922-50, 20260922-47, 20260922-48.
- **README:** 10b and 10c.
- **Status:** done
- **Decided:** All three rounds always run.

## Step 11: Per-candidate index ranking.

### 20260926-7. Wire `quaack run` into the driver CLI.

Add `quaack run --run ID [--rewrites <file>]` to `driver/lib/quaack/driver/cli.rb`. It looks up the jump host with `Runs#host` (20260926-1), builds `Transport::Ssh` and the LLM client, and calls `Pipeline#run` (20260922-36). If `--rewrites` is given, it sends the file through `OperatorCandidates.from_file` (20260922-39).

- **Depends on:** 20260926-1, 20260922-36, 20260922-39.
- **Came from:** Track A, B, and F build reports.
- **README:** Where QUAACK runs, and step 7.
- **Status:** done

### 20260926-11. Structural discard: compare typmods.

The output-type check compares only type OIDs, so a `varchar(10)` column and a `varchar(20)` column count as the same. Decide whether a difference in typmod should count as an output mismatch.
- **Decided:** No. Compare OIDs only, so the task is dropped.

- **Depends on:** 20260922-40.
- **Came from:** Track C build report.
- **README:** Step 8.
- **Status:** dropped

### 20260926-6. Step 8 wiring.

The step 8 library pieces have landed: `StructuralDiscard`, `Steps::IndexSearch.rewrite_entry` and `ThreeConfigurationPruning` (20260922-40, -41, -42), along with `rewrite-check` (20260922-37). Wire them together:
- `quaacks index-search --search rewrite_<n>`.
- A per-candidate loop: search, rank the rewrite's top three with `IndexRanking`, then prune against `index_ranking_original`.
- Record the step 8 burndown, including the count of inbound-check rejections (`StructuralDiscard.record`).
- A driver stage in `Pipeline::STAGES`.

- **Depends on:** 20260922-37, -40, -41, -42, -36.
- **Came from:** Track C and track B build reports.
- **README:** Step 8.
- **Status:** done

### 20260922-27. 4b arena setup.

Create arena from `template0` with matching locale settings, load the full schema and extensions, create `clock_anchor()`, keep `VALID` constraints, and disable user triggers only.

- **Depends on:** 20260922-25, 20260922-18, 20260922-24, 20260924-30.
- **README:** 4b.
- **Status:** done
- **Note (from the first build attempt):** Waiting on 20260924-30. The plan once it lands: load the dump through the connection with the `\restrict` and `\unrestrict` lines removed, as one implicit transaction. Drop the empty `public` schema before loading, since the dump runs `CREATE SCHEMA public`. Map the locale provider (`c` to libc, `i` to ICU_LOCALE, `b` to BUILTIN_LOCALE). Name the database from the run ID, with a COMMENT tag, and on a rerun drop and rebuild a tagged database. Reuse Racetrack's anchor code. Run DISABLE TRIGGER USER on every table. Don't create hypopg. The inventory doesn't record the database encoding, so arena gets the run server's default.
- **Note (from 20260925-7):** The user chose to take the arena database name at `quaacks run-server --arena-db`. Use the recorded name and connect with `RunServer.connect(store, :arena)`, rather than naming the database from the run ID. The COMMENT tag and drop-and-rebuild on a rerun still apply.
- **Note (from 20260922-26):** Reuse `Racetrack.create_clock_anchor` and `anchor_literal` for arena, perhaps through a shared module.

## Step 5: Plan gate and index candidates.

### 20260926-10. Arena database: handle the dump's `CREATE SCHEMA public`.

When the full dump is loaded into a fresh database, its `CREATE SCHEMA public` clashes with that database's own `public` schema. The 20260924-30 test gets around this by dropping `public` first. Step 4b's arena creation has to handle it the same way. Check whether it already does.

- **Depends on:** 20260924-30.
- **Came from:** Track F build report.
- **README:** Step 4b.
- **Status:** done

### 20260926-12. Assumption check loose ends.

These are minor findings from the review of 20260922-38:
- A `check` assumption is compared as-is with `pg_get_constraintdef`, so casts that Postgres adds (`(0)::numeric`) break the match. Normalize the casts.
- A `NO INHERIT` suffix doesn't parse.
- A `unique` assumption is met by a unique index on nullable columns (NULLS DISTINCT), which can wrongly pass. Also require NOT NULL or `indnullsnotdistinct`.
- Deferrable unique indexes count as met.
- `rewrite-check` plans the SQL before it checks the assumptions. The spec's name and the README 6b order should say so.

- **Depends on:** 20260922-38.
- **Came from:** Track B review.
- **README:** 6b.
- **Status:** done

### 20260926-5. Run discipline: tell timeouts apart from cancels, and allow one statement only.

Both of these are minor findings from the 20260922-54 review. First, `rescue PG::QueryCanceled` counts every cancel as a timeout, so an operator's `pg_cancel_backend` is also recorded as timed out. Check that the error really is a statement timeout. Second, `connection.exec` accepts several statements in one string, so a `COMMIT` in the SQL could end the READ ONLY transaction. Refuse SQL that holds more than one statement, or run it with `exec_params`.

- **Depends on:** 20260922-54.
- **Came from:** 20260922-54 review, minor findings.
- **README:** Step 12b.
- **Status:** done

### 20260922-52. 11 LLM index search per candidate.

For each candidate that survived steps 9 and 10, run 5a-5, 5a-3, 5a-4, 5a-6, and 5a-7 using the step 8 results, with the candidate's plan redacted through 3g.

- **Depends on:** 20260922-33, 20260922-34, 20260922-35, 20260922-41, 20260922-51.
- **README:** Step 11.
- **Status:** done

## Steps 12 through 14: Measurement.

### 20260926-18. Parallel spec runs remove each other's Postgres containers.

A full rake run died with 1216 enclave failures and "docker rm … removal already in progress". The stale-container cleanup in `spec/support/test_postgres.rb` removes every container labelled `quaack.test-postgres`, including ones that another spec process started a moment ago. Only remove containers whose owner process is gone, for example by labelling each container with its PID and checking whether that process is alive.

- **Depends on:** none.
- **Came from:** Build of 20260926-12 and -5, with several worktrees running rake at once.
- **README:** none (see CLAUDE.md, Development).
- **Status:** done

### 20260926-9. Driver start and run server loose ends.

These are minor findings from the review of 20260926-1, 20260926-2 and 20260924-30:
- `Runs#record` has a run-ID guard that no test covers.
- The README should show flags in the space-separated form.
- The docs should say `destroy_command` must be idempotent.
- The child process for `jump_command` isn't in its own process group, so a timeout doesn't kill what the shell started.
- Some spec wrote an empty run-ID file into `enclave/`. Find it and make it write to a temp dir.

- **Depends on:** 20260926-1, 20260926-2.
- **Came from:** Track F review.
- **README:** Where QUAACK runs, step 4, and teardown.
- **Status:** done

### 20260926-13. Expression MCV classification: tests for the paths that aren't covered.

These are minor findings from the review of 20260924-27. The code handles each case, but no spec covers it:
- A partial index whose only PII column appears in its WHERE clause.
- A definition that won't parse.
- A definition that names a column the table doesn't have.

- **Depends on:** 20260924-27.
- **Came from:** 20260924-27 review.
- **README:** 3f.
- **Status:** done

### 20260926-16. `quaack run` loose ends.

These are minor findings from the review of 20260926-7:
- No spec covers a failing enclave or LLM call (exit 1 and `quaack run failed: <rule>`). Changing the exit code to 0, or narrowing the rescue list, stays green.
- No spec covers a rewrites file that won't parse.
- A reply to rewrite-payload with no `rewrite_payload` message passes nil on and crashes with a stack trace.
- Step 7 runs after the whole pipeline, not next to 6a.
- Nothing prints on success.

- **Depends on:** 20260926-7.
- **Came from:** 20260926-7 build report and review.
- **README:** Step 7.
- **Status:** done

### 20260926-14. Wire steps 9 and 10 into the CLI and the pipeline.

`StepNine.run`, `Enclave::Counterexamples` and `Driver::Counterexamples` (20260922-44 to -51) have landed, but nothing calls them yet. They need:
- `quaacks` subcommands for step 9 and for 10b/10c. These read the stored rewrites and candidates, and send only shape-level outcomes.
- A driver stage in `Pipeline::STAGES` after step 8.

- **Depends on:** 20260922-49, -51, 20260926-6.
- **Came from:** Track D build report.
- **README:** Steps 9 and 10.
- **Status:** done

### 20260926-19. Assumption and run discipline loose ends, part two.

These are minor findings from the build and review of 20260926-12 and -5:
- A stated `CHECK (col IN (...))` never matches, because Postgres stores it as `col = ANY (ARRAY[...])`. Normalize IN lists to that form.
- Telling a timeout from a cancel relies on Postgres's English message text, since both use SQLSTATE 57014. A non-English `lc_messages` breaks it. Set `lc_messages` for the session, or find another signal.

- **Depends on:** 20260926-12, 20260926-5.
- **Came from:** Their build report and review.
- **README:** 6b, 12b.
- **Status:** done

### 20260926-17. Arena setup loose ends.

These are minor findings from the build and review of 20260922-27:
- Check with real `pg_dump` 18 output from an ordinary database that the dump runs `CREATE SCHEMA public`, since arena setup drops `public` first. If a dump doesn't, every load fails.
- Every dump-load error comes out as one rule.
- The ICU and libc locale mapping is untested.
- Nothing in the driver pipeline runs `arena-setup`, and the arena steps don't check for its marker.

- **Depends on:** 20260922-27.
- **Came from:** 20260922-27 build report and review.
- **README:** 4b.
- **Status:** done

### 20260922-53. 12a build and hide indexes.

Build every distinct index from 5a and step 11 with raised maintenance settings. Record built sizes. Hide them with `indisvalid`, touching only proposed non-unique indexes, and confirm with `EXPLAIN` that the right set is hidden.

- **Depends on:** 20260922-35, 20260922-52.
- **README:** 12a.
- **Status:** done
- **Decided:** Each measurement unhides only its own combination. Build and measure the GIN and GiST candidates set aside in 5a-3 too.

### 20260926-8. Step 5 orchestration loose ends.

These are minor findings from the review of 20260922-34 and -36:
- If the LLM's 5a-6 answer is empty, `refined` is never set, so every resume asks the LLM again (`refinement_round.rb:57`). Call `index-test --round refinement` with an empty list.
- After a partial crash, a resume can leave the ranking stale.
- `index-payload` runs on every resume.
- Same for 6a: an empty rewrite reply never writes `rewrites_generated`, so every resume asks the LLM again (`rewrite_generation.rb:90`, from the review of 20260926-6).
- `IndexRanking` entries don't carry the canonical plans that README 5a-7 says they should.

- **Depends on:** 20260922-36.
- **Came from:** 20260922-34 and -36 build report and review.
- **README:** 5a-6, 5a-7.
- **Status:** done

### 20260926-22. Steps 9 and 10 wiring loose ends.

- A rewrite whose inserts failed to load in every round is still marked survived, with no fixture ever compared. The report should flag it (from the 20260926-14 review).
- A resume restarts step 10 at round 1, which repeats LLM calls.
- The driver doesn't check that a reply holds the message it expects (`rewrite_test`, `counterexample_payload`), so a missing one crashes.
- The payload's untested-atom test seeds the store directly rather than getting the atoms from a real step 9 run.

- **Depends on:** 20260926-14.
- **Came from:** 20260926-14 build and reviews.
- **README:** Steps 9 and 10, 15.
- **Status:** done

### 20260926-15. Scenario builder and counterexample loose ends.

These are minor findings from the build and reviews of 20260922-44 to -51:
- A statement timeout while loading an LLM's inserts becomes `:statement_timeout`, which isn't in `LOAD_RULES`, so it wrongly disproves the candidate (`arena_runner.rb:214`). Check the step, not the rule.
- `Counterexamples.covered` skips atoms it can't replace, and no test covers that.
- Only equality joins between plain columns tie keys together.
- A join near miss is skipped when a foreign key touches either column.
- Groups that collide on a unique key are dropped without saying so.
- Self-joins merge aliases into one row.
- Domain CHECK constraints are ignored.
- Bound literals are uncast (bit strings).
- 3e literal sets and 3c statistics aren't used for pools.
- The rule that an atom, once exercised, stays exercised across rebuilds has no test.

- **Depends on:** 20260922-51.
- **Came from:** Track D build report and reviews.
- **README:** Steps 9 and 10.
- **Status:** done

### 20260922-55. 13 baseline runs.

Run the original three times per literal set with `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`. Record total blocks and the hit-versus-read split. Mark a literal unstable if the count moves, and record each run's plan.
- **Decided:** For an unstable literal, 14a and 14b use the maximum of the three runs, for the original and for the candidates alike. The report flags that literal.

- **Depends on:** 20260922-53, 20260922-54.
- **README:** Step 13.
- **Status:** done

### 20260926-26. Scenario and counterexample loose ends, part two.

- `counterexamples/parent_rows.rb` calls `Values#typical` in strict mode, so a parent row whose domain column fails the typical value is refused with `unsupported_type` (this fails safe). Pass `strict: false`, and add a test.
- The `dropped` group count isn't carried through to the driver's report.
- A timeout during the fixture load step (as opposed to the insert step) has no direct test.
- The typed-binding item from 20260926-15 was judged stale (untyped binding works for bit strings) but wasn't independently checked.

- **Depends on:** 20260926-15.
- **Came from:** 20260926-15 build and review.
- **README:** Steps 9 and 10.
- **Status:** done

### 20260926-24. Assumption and timeout loose ends, part three.

- Postgres may store a one-element IN list as plain `=`, so a stated `x IN ('a')` wouldn't match (this fails safe). Check it, and leave one-element lists as `=` when normalizing.
- The timeout heuristic counts an operator cancel that lands in the few milliseconds after `timeout_ms` as a timeout. That's harmless.

- **Depends on:** 20260926-19.
- **Came from:** Review of 20260926-19.
- **README:** 6b, 12b.
- **Status:** done

### 20260922-56. 13a index baselines.

Repeat the baseline runs for each index combination kept in 5a.

- **Depends on:** 20260922-55.
- **README:** 13a.
- **Status:** done

### 20260922-57. 14 candidate runs.

Run each candidate with its index combinations, using the step 13 process.

- **Depends on:** 20260922-55.
- **README:** Step 14.
- **Status:** done

### 20260926-4. Wire run discipline into steps 13 and 14.

`RunDiscipline` (20260922-54) exists, but nothing calls it yet. Steps 13 and 14 have to run every timed statement through it, drop any candidate whose statement timed out, and give the report a count of timed-out candidates.

- **Depends on:** 20260922-54, and the step 13 and 14 tasks.
- **Came from:** 20260922-54 build report.
- **README:** Step 12b.
- **Status:** done

### 20260926-20. Step 11 loose ends.

- A rewrite's index payload reuses the original's placeholder row counts, because a rewrite has no EXPLAIN ANALYZE of its own.
- The driver specs for `RewriteIndexStage` weren't mutation-tested.

- **Depends on:** 20260922-52.
- **Came from:** 20260922-52 build report and review.
- **README:** Step 11.
- **Status:** done

### 20260926-21. Harness and driver loose ends, part three.

- Test containers: no test covers the "same host label, dead PID, so remove it" path separately from the path for containers with no label (20260926-18 review).
- The driver's SIGKILL timing test (`Transport limits kills a run that ignores SIGTERM with SIGKILL`) flakes under heavy parallel load.
- An earlier run hit 1216 enclave failures from containers being removed mid-run, even though main already had the PID-scoped cleanup. The cause is unknown, so watch for it.
- Step 7 (`--rewrites`) runs after the whole pipeline, not next to 6a (from 20260926-16).

- **Depends on:** 20260926-18, 20260926-16.
- **Came from:** Builds and reviews of 20260926-18 and -16.
- **README:** Step 7; CLAUDE.md Development.
- **Status:** done

### 20260926-25. Pipeline loose ends, part four.

- A resumed run restarts step 10 at round 1. Continuing mid-way would need the earlier rounds' LLM conversation.
- The sentinel check in `index_rank_step_postgres_spec.rb` doesn't bite by itself. Plant a sentinel literal in the fixture's literal sets.

- **Depends on:** 20260926-8, 20260926-22.
- **Came from:** Their build and review.
- **README:** 5a-7, step 10.
- **Status:** done

### 20260922-59. 14c production result comparison.

Run the original and each candidate as plain queries per literal and compare in the enclave with the 9d rules. Stream and use an order-independent hash with float rounding when results are large. Mark `LIMIT` without `ORDER BY` as partial if it times out. Report any divergence prominently.

- **Depends on:** 20260922-47, 20260922-57.
- **README:** 14c.
- **Note (from the reviews of 20260922-47):** 9d runs the ordered comparison twice, once with an ascending tiebreaker and once with a descending one. It refuses WITH TIES, and it refuses originals whose own result depends on how ties break. README 14c says to "add the same tiebreaker here before hashing", so hashing needs the same treatment.
- **Status:** done
- **Decided:** Hash each row, sort the hashes, and hash the sorted list together with the row count.

### 20260926-23. Index build loose ends.

These are minor findings from the build and review of 20260922-53:
- The hiding guard in `IndexBuild.set_valid` is untested: removing the `quaack_` name filter or the unique/primary/exclusion filter keeps every test green. Add a test that tries to hide a primary key and a user unique index named `quaack_x`, and asserts both stay valid.
- `set_valid` and `valid_names` match on `relname`, not schema.
- Unqualified DDL makes the lookup of existing indexes miss on rerun.
- `status` has no `index_build` entry, so a resume can't skip the step, and the pipeline doesn't run it yet.
- The maintenance settings (1GB, 4 workers) are hard-coded.

- **Depends on:** 20260922-53.
- **Came from:** 20260922-53 build and review.
- **README:** 12a.
- **Status:** done

### 20260922-58. 14a and 14b metric and minimax rule.

Compare on total blocks only, with a 5% threshold. A candidate must beat the original on the slow literal and be no worse on the rest. Break ties by smallest index footprint.

- **Depends on:** 20260922-56, 20260922-57.
- **README:** 14a and 14b.
- **Status:** done
- **Note (from the review of 20260922-26):** The plpgsql `quaack.clock_anchor()` adds about 0.2 µs per row in a per-row filter, compared with `now()`: 70 ms against 27 ms on 187k rows. Plans don't change, but anchored runtimes carry that fixed extra cost, which shrinks a candidate's apparent speedup. Lean on blocks rather than time alone, or account for the cost.
- **Decided (original timeouts):** Baseline gives the original up to 15 minutes per run, not the 3x clamp. If the original still times out on a literal set, that set's count counts as infinite, so any candidate that finishes beats the original there. The report flags that set. The timeout for candidates stays 3x the original, clamped.
- **Decided:** "No worse" means an increase within the 5% threshold.
- **Decided:** Two candidates tie when their total blocks on the slow literal are within 5% of each other. Discard the one with the larger index footprint.
- **Decided:** For an unstable literal, use the maximum of the three runs.

### 20260926-28. Operator rewrites skip steps 8 to 11.

`quaack run --rewrites` runs step 7 after the whole pipeline, so the operator's rewrites never go through step 8 (index search and pruning), steps 9 and 10 (equivalence testing), or step 11. Run step 7 next to 6a, inside or right after `RewriteStage`, before step 8. Add an enclave status marker so a resume doesn't run step 7 again.

- **Depends on:** 20260926-7, 20260926-14.
- **Came from:** Build of 20260926-21.
- **README:** Step 7.
- **Status:** done

### 20260922-60. 14d selection.

Keep the top three candidates by total blocks.
- **Decided:** Rank the candidates that survive minimax by total blocks on the slow literal. Break ties by the sum across all literals.

- **Depends on:** 20260922-58, 20260922-59.
- **README:** 14d.
- **Status:** done

## Step 15: Report.

### 20260926-27. Baseline loose ends.

- If the original times out on a literal set during baseline, that set is only listed in `timed_out`. Decide how 14a and 14b treat that set, and how the report shows it.
- No real-Postgres test produces an unstable literal. Only the `summarize` unit test covers that path.
- Nothing in the pipeline calls `quaacks baseline` yet (see -65).

- **Depends on:** 20260922-55.
- **Came from:** 20260922-55 build and reviews.
- **README:** Step 13.
- **Status:** done

### 20260926-30. Result comparison loose ends.

- No test pins `BEGIN READ ONLY` in `ProductionComparison`. Changing it to plain `BEGIN` passes every spec, so a data-modifying CTE could write to the racetrack before the rollback. Add a spec where a write fails as read-only.
- The row count inside the digest duplicates the separate count comparisons. That's harmless, but untested.
- A candidate that times out during 14c is discarded (`fail`, `timed_out`). The task only defined partial for the LIMIT case, so this was the builder's choice.
- Two floats within tolerance, on either side of a rounding boundary, compare as a mismatch. This fails safe.
- `partial_count` is only tested at 0.

- **Depends on:** 20260922-59.
- **Came from:** 20260922-59 build and review.
- **README:** 14c.
- **Status:** done

### 20260926-31. Minimax and operator rewrite loose ends.

- No test covers an empty `--rewrites` file (`rewrites: []`): removing the `rewrites.empty?` check stays green. Add a spec asserting no rewrite-check call and no LLM call (from the 20260926-28 review).
- The timed-out guard in `Minimax.decide` wasn't separately mutation-tested.
- No end-to-end Postgres test sends a real racetrack run through `quaacks minimax`. The step test uses a hand-built store.

- **Depends on:** 20260922-58, 20260926-28.
- **Came from:** Their builds and reviews.
- **README:** 14b, step 7.
- **Status:** done

### 20260922-62. 15 main report.

Rank candidates per literal and overall with the minimax rule. List untested atoms and whether step 10 covered them. For each index, give built size, prefix coverage, and redundancy. Explain why the winner touches fewer blocks using only plans and selectivities. Show the query with the 3h functions put back.

- **Depends on:** 20260922-60, 20260922-24.
- **README:** Step 15.
- **Status:** done
- **Decided:** The report is written to a file on the laptop, `./quaack-<run>.html` or `--out <path>`, and its path is printed.
- **Note:** Scenario groups dropped on a unique-key collision are counted in `StepNine::Report#dropped` (20260926-15), but the count isn't sent to the driver yet. Add it here if the report shows it.
- **Decided:** HTML output. The explanation is templated from the measurements, not LLM-written.

### 20260925-17. Possible flake in the run-server success test.

`enclave/spec/run_server_postgres_spec.rb:65` needs no other clients on the shared test server. It closes the harness's admin connection, but if another spec in the same process leaves a connection open, the test fails with `run_server_other_clients`. It hasn't happened yet. If it shows up, give that test its own server or close every harness connection first.

- **Depends on:** 20260925-7.
- **Came from:** The first review of 20260925-7.
- **README:** 4.
- **Status:** done

### 20260925-20. Statistics step: test the read failure.

The `statistics` step spec has no `production_read_failed` case, but README 3c promises that the refusal stores nothing. Add a step-level test that pins it end to end.

- **Depends on:** 20260925-10.
- **Came from:** The first review of 20260925-10.
- **README:** 3c.
- **Status:** done

### 20260925-22. Name the missing input when a step's store entry is absent.

The new step subcommands (redact, classify, and others) report a missing upstream entry as `internal_error`. The README says a failure names only its rule, and the rule should name what's missing, such as `missing_plan` or a shared `missing_entry` naming the entry. Fix this in one place, for all the steps. The racetrack-setup success test should also check that `hypopg` exists, and a run with `run_server` but no `clock_anchor` should fail with a clean rule. Also add a test for `quaacks literals` refusing a `volatility` entry that's present but not passed (`literals.rb:27`), which no test covers yet. Also note, or fix, that `redact` writes its entries one at a time, so a crash partway through can leave some of them stored. A rerun overwrites them.

- **Depends on:** 20260925-14.
- **Came from:** The first reviews of 20260925-14, 20260925-12, and 20260925-16.
- **README:** Step 3.
- **Status:** done

### 20260925-21. Name the function in a 3d refusal.

README 3d says to abort and say which function caused it. Today the `volatile_function` error line carries only the step, the rule and the SQLSTATE, and 20260925-11 added a README paragraph calling that a v1 limitation. The user decided the function should be named. Function names are schema, so they're shape. Add a whitelisted field, such as `function` holding the schema-qualified name, to the `volatile_function` refusal, for both the step and the other `VolatilityCheck` callers where it makes sense. Remove the README limitation paragraph so 3d no longer contradicts itself. Prove with a sentinel that only the name goes out, never an argument or literal.

- **Depends on:** 20260925-11.
- **Came from:** The first review of 20260925-11, and the user's decision.
- **README:** 3d, What leaves the enclave.
- **Status:** done

### 20260926-33. Wire steps 4b and 12 to 14 into the pipeline.

The enclave steps exist, but `Pipeline` doesn't run them: `arena-setup` (4b), `index-build` (12a), `baseline` (13), `index-baseline` (13a), `candidate-runs` (14), `minimax` (14a/b), `result-comparison` (14c) and `selection` (14d). Until it does, a real `quaack run` never writes the report. Add resumable stages in README order, with status entries for each step's store output, and put `arena-setup` before steps 9 and 10.

- **Depends on:** 20260922-27, -53, -55, -56, -57, -58, -59, -60, -62.
- **Came from:** 20260922-62 build report.
- **README:** Steps 4b and 12-14.
- **Status:** done

### 20260922-63. 15a negative result.

When nothing beats the original, explain which rewrites were disproved and by which scenario, which indexes the planner declined, and which proposed indexes already existed.

- **Depends on:** 20260922-62.
- **README:** 15a.
- **Status:** done

### 20260922-64. 15b burndown tables.

Render the three burndown sections from the recorded counts.

- **Depends on:** 20260922-61, 20260922-62.
- **README:** 15b.
- **Status:** done

## End to end.

### 20260924-31. Keyset pagination with row comparisons.

**Decided:** Yes, support keyset pagination with row comparisons in v1. (The original question was whether this should be part of the v1 profile.) `WHERE (created_at, id) > ($1, $2)` is refused today as `unsupported_construct: RowExpr`, because 20260923-33's allowlist leaves out row comparisons. ORMs generate it often for cursor pagination, so it's arguably an ordinary query under the lean v1 profile. If the answer is yes, allow RowExpr only in a row comparison (`(a, b) op (x, y)` with `<`, `<=`, `>`, `>=`, `=`, or `<>`), and check every walker that SupportedSql guards: qualification, volatility, predicate atoms, 3g redaction, and 3e literals, where a row comparison falls back to the slow literal.

- **Depends on:** 20260923-33.
- **Came from:** The review of 20260923-33 and the second review of 20260924-16.
- **README:** Step 1.
- **Status:** done

### 20260926-37. Step 9 fixtures fail to load on realistic schemas.

The prompt pack (20260922-65, part one) ran the pipeline on an ordinary users/products/orders/line_items schema, and every supported query stopped at step 9 with `fixture_load_failed`:
- **23505, unique violation:** the scenario builder honors unique constraints but not unique indexes created with `CREATE UNIQUE INDEX` (for example `users_email_key`). It also skips columns that have a default, which can collide.
- **23503, foreign-key violation:** fixture rows reference a parent table the query doesn't name (`orders.user_id` pointing to `users`), and the parent rows are never loaded.
Both are correctness bugs on realistic setups: a correct rewrite is rejected. Fix the scenario builder so fixtures honor unique indexes (including partial unique indexes and expression unique indexes, or refuse cleanly) and load parent rows for every FK, including FKs to tables outside the query, recursively. Test on the prompt pack's schema (`script/prompt_pack/schema.sql`).

- **Depends on:** 20260922-45, -49.
- **Came from:** The 20260922-65 prompt pack run.
- **README:** Step 9.
- **Status:** done

### 20260926-34. Report loose ends.

- If `IndexCandidate.from_ddl` can't parse a built index's DDL, the report shows an empty cell and doesn't say why.
- The `StepNine::Report#dropped` count isn't included.
- "Whether step 10 covered them" shows only the `evidence` flag, because per-round covered shapes aren't stored.
- A plan node with no `Schema` field is matched to a table by name only when exactly one subset table has that name.

- **Depends on:** 20260922-62.
- **Came from:** 20260922-62 build and review.
- **README:** Step 15.
- **Status:** done

### 20260926-35. Statistics spec restores the pg_stats grant.

The read-failure test in `enclave/spec/statistics_step_postgres_spec.rb` revokes `SELECT ON pg_catalog.pg_stats FROM PUBLIC` and never restores it. The container is shared per process, so a later spec that reads pg_stats as a non-superuser could fail depending on test order. Add `GRANT SELECT ON pg_catalog.pg_stats TO PUBLIC` to the `after` block. Also mention the `missing_<entry>` rules in the README.

- **Depends on:** 20260925-20, -22.
- **Came from:** Review of 20260925-20.
- **README:** 3c, "What leaves the enclave".
- **Status:** done

### 20260926-36. Pipeline wiring and 3d follow-ups.

- ReportStage's "selection missing" guard can no longer trigger from the pipeline. Remove it, or test it by calling ReportStage directly.
- The driver's `EnclaveError` doesn't show the new `function` field from a `volatile_function` refusal to the operator (`transport/reply.rb` `error_fields`).

- **Depends on:** 20260926-33, 20260925-21.
- **Came from:** Their builds and reviews.
- **README:** 3d, `quaack run`.
- **Status:** done

### 20260926-38. Report loose ends, part two.

- The `existing` list's DDL redaction has no sentinel coverage (the planted drops carry no literal).
- `NegativeResult.disproved` fails at `store.read` if `rewrite_round_<n>` is missing for a non-survivor.
- 15a finds rewrites by counting up until one is missing, so it assumes no gaps.
- A rewrite that passed steps 9 and 10 but was knocked out by minimax or 14c isn't explained in 15a.
- LLM call counts aren't passed to the report (part of -65).

- **Depends on:** 20260922-63, -64.
- **Came from:** Their build and review.
- **README:** 15a, 15b.
- **Status:** done

### 20260926-39. LLM payload fidelity.

The prompt pack showed two things wrong with what the LLM is sent:
- **Placeholder types:** the `created_at` placeholders in the ORM join are typed `text` in the payload, though the plan casts them to `timestamptz`. The payload should give each placeholder the type Postgres infers for it (for example from a PREPARE, as `Measurement` does).
- **pg_dump's `\restrict` token:** the schema DDL sent to the LLM includes pg_dump's random `\restrict`/`\unrestrict` token lines. They're noise for the LLM, and they change every prompt on every run. Strip them from the schema in payloads.

- **Depends on:** 20260925-4 (index payload), 20260922-37 (rewrite payload).
- **Came from:** Review of the 20260922-65 prompt pack.
- **README:** 3b, 5a-5, 6a.
- **Status:** done

### 20260926-41. Step 9: support expression unique indexes instead of refusing.

After 20260926-37, a unique index on an expression anywhere in the fixture tables' closure (for example `CREATE UNIQUE INDEX ON users (lower(email))`, which is common in Rails apps) makes step 9 refuse the whole query as `expression_unique_index`. That fails safe, but it refuses many realistic schemas. Support it: evaluate the expression for candidate values (through Postgres, as `ValuePools.probe` does) and keep the evaluated keys distinct. Or, since fixture text values are already distinct, give every column the expression touches a distinct value, and verify the expression values differ.

Also from the review:
- Values set explicitly on identity columns don't advance the sequence. If ParentRows and a scenario path that leaves the identity column out ever write to the same table, they could collide. Call `setval` after loading, or confirm the two never mix.
- No test covers INCLUDE columns or partial unique indexes directly.
- `UNIQUE NULLS NOT DISTINCT` isn't handled.

- **Depends on:** 20260926-37.
- **Came from:** 20260926-37 build and review.
- **README:** Step 9.
- **Status:** done

### 20260924-13. Leak-test helper loose ends.

Findings from the reviews of 20260922-9:
- **A Tempfile slips past the IO refusal.** Tempfile is a Delegator, so `is_a?(IO)` is false, and a Tempfile holding a sentinel returns no findings. Refuse Tempfile too. A File nested inside an object is also neither scanned nor refused.
- **The positive control doesn't plant in Array elements, Hash keys and values, Struct or Data members, or a StringIO's `#string`,** though its comment says it does. The unit specs catch those breaks. Add the plants, or reword the comment.
- **Surviving mutants:**
  - `MAX_DEPTH` 24 → 10
  - case-insensitive `extra:` needles
  - scanning only the first backtrace line
  - `MIN_EXTRA` 9 → 4
  - the `seen` set, which only affects speed
- **`pg` isn't a runtime dependency of quaacks,** so `LeakCheck::Quaacks` can't run subcommands that connect to Postgres. The first task with such a step (20260922-16) must add `pg` to the quaacks gemspec and to `ENCLAVE_ALLOWED_GEMS`.
- **The harness schema has no JSON column,** so the fixture can't plant the JSON sentinel in stored rows.

- **Depends on:** 20260922-9.
- **Came from:** Both reviews of 20260922-9.
- **README:** Trust boundary.
- **Status:** done
- **Note:** The `pg` item is resolved. 20260922-16 made pg a runtime dependency of quaacks.

### 20260924-14. LLM client loose ends.

Findings from the builds and reviews of 20260922-6:
- **Streaming.** Non-streaming requests are capped at the gem's limit: 21,333 max_tokens for the default model, and lower for some models. Add streaming if a step ever needs bigger outputs.
- **Lazy-load `anthropic`.** Requiring it adds about 0.5s to every driver CLI start, even for commands that never call the LLM.
- **A driver config file** for the model and similar settings. Today config comes only from code and the environment.
- **Surviving mutants in `driver/lib/quaack/driver/llm/client.rb`:**
  - `limit = MODEL_NONSTREAMING_TOKENS[...]` → `nil`. The per-model limit is never tested. Try `model: "claude-opus-4-0"` with `max_tokens: 8193`.
  - `ENV[ALLOW_REAL_ENV] == "1"` → truthy. Nothing tests `QUAACK_ALLOW_REAL_LLM=yes` against the client guard. The root suite and child processes rely on that guard alone.
  - `ENV[SPECS_ENV] == "1"` → truthy. Nothing tests `QUAACK_SPECS=0`.
  - `e.message` passed through with extra text. Messages are matched by prefix only.
- **The `NoNetwork` prepend is only in the driver suite.** The root suite and child processes get only the client-level guard. Consider sharing it.
- **The workload-identity token exchange bypasses `PooledNetRequester`.** It calls `Net::HTTP` directly when a client is built with no key and federation credentials exist. Our client always passes a key, so only a spec that builds `Anthropic::Client` directly could reach it.
- **`calculate_nonstreaming_timeout` isn't in the gem's `rbi/` or `sig/`,** so a 1.x update could rename it. The specs would go red, but note this when bumping the gem.

- **Depends on:** 20260922-6.
- **Came from:** The builds and both reviews of 20260922-6.
- **README:** Where QUAACK runs, 15b.
- **Status:** done

### 20260924-17. Teardown loose ends.

Findings from the reviews of 20260922-66:
- **The rule is wrong when the recheck fails.** If the recheck `lstat` inside `Store.teardown`'s `rescue Error` raises a `SystemCallError`, such as EACCES after the base's mode changes mid-call, the raw Errno escapes as `internal_error`, where it should be `bad_store_base` or `teardown_failed`.
- **The rule is wrong after a race.** If the run path is swapped for a non-directory between `open`'s check and the delete, the path is left alone, as it should be, but the rule is `teardown_failed`, not `bad_run`.
- **A doc comment describes unbuilt behavior.** The top of `steps/teardown.rb` says the driver runs teardown at the end of every run. That's future work (20260922-65).
- **A redundant check.** `return :already_gone unless PrivateFiles.lstat(path)` is an equivalent mutant, because the recheck already covers it. Keep it as a fast path with a comment, or drop it.

- **Depends on:** 20260922-66.
- **Came from:** The reviews of 20260922-66.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260924-20. Driver transport loose ends.

Findings from the reviews of 20260922-5:
- **A timeout doesn't stop the remote `quaacks`.** It kills only the local ssh process. With `-T`, the remote side gets no SIGHUP, and it can keep running queries on the jump server until it next writes. Options: run the remote side under `timeout`, or have the enclave CLI exit when stdin or stdout closes.
- **Over ssh, a remote quaacks killed by a signal shows up as ssh exit 255,** so `killed?` is false. The error line still decides the rule.
- **Lexical is skipped when a line starts with whitespace,** so json 2.9.1 and 3.0.2 read ` {"type":"error",/*c*/"rule":"zz"}` differently. Check `line.lstrip`, or run Lexical on every line.
- **A child that closes stdout and then reads the rest of stdin hangs until the timeout,** because Pump stops writing on stdout EOF.
- **A grandchild holding stdout makes a call wait out the whole timeout** (3,600s by default) and then report success.
- **MAX_ARGV_BYTES doesn't bound the escaped ssh remote command.** Shellwords turns a newline into 3 bytes, so a value that passes can exceed Linux's 128 KiB per-argument limit and show up as `incomplete`. Cap the escaped length for Ssh.
- **Three Pump mutants are caught only by hanging the suite.** Add a per-example timeout to the driver specs.
- **The timeout test expects under 3s against a 1s timeout,** which could flake on a loaded machine.

- **Depends on:** 20260922-5.
- **Came from:** The reviews of 20260922-5.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260924-15. 3h clock anchoring loose ends.

Findings from the builds and reviews of 20260922-24 and 20260924-12:
- **Restore LLM candidates by anchored form, not by position.** `restore` finds added names by slot number. That's sound for queries with the same structure, but a restructured rewrite candidate (README step 15) usually gives `restore_mismatch`. Rarely, it could strip a name the author wrote that happens to match. A candidate that swaps the anchors gets mislabeled, and `quaack.clock_anchor()::date` without pg_catalog raises. This is needed if the report shows candidate SQL.
- **`'now'`, `'today'`, `'yesterday'`, and `'tomorrow'` literals also read the clock,** as in `created_at > 'today'::date - 7`. That needs a README change, or a decision from the user.
- **Three-part names:** `db.pg_catalog.now()`.
- **Refusing pg_temp and `$user` before pg_catalog is stricter than Postgres.**
- **ImplicitName differs from Postgres for some scalar subqueries.** It reads the raw parse, and Postgres reads the analyzed target list. For example, `(SELECT * FROM (SELECT 1 AS z) q)` is `z` in Postgres but `?column?` here, `(SELECT t.* FROM ...)` is `z` but `t` here, and `(VALUES (1))` is `column1` but `?column?` here. Anchoring stays correct, because inner slots keep their own names. Fix the code, or narrow the doc comment's claim.
- **Surviving mutants:**
  - `figure_sub_link`: removing `return NONE unless target` survives. Add `(VALUES (1))` to the oracle list.
  - `figure_sub_link`: the weak-name path `target.name.empty? ? figure(target.val) : strong(target.name)` survives. `(SELECT 1)::text` kills it.
  - `clock_anchoring.rb` `split_path`: dropping `cause: nil` from the `bad_search_path` raise survives.

- **Depends on:** 20260924-12.
- **Came from:** The reviews of 20260922-24 and 20260924-12.
- **README:** 3h.
- **Status:** done

### 20260924-18. Governed store loose ends, part two.

Minor findings from the second review of 20260923-34:
- **Nothing tests that create makes nothing through a linked `~/.quaack`.** In `Store.create`, replacing the first `in_base(...) { PrivateFiles.make_directories(base) }` with a plain call survives: the second check still raises BadBase, but `target/runs` gets created. Add a store case where the parent is linked and the target has no `runs`, and assert the target stays empty.
- **The pre-open lstat's condition isn't pinned.** `unless File.lstat(file).file?` → `if File.lstat(file).directory?` survives. Stub `File.lstat` to return a FIFO's stat for a real regular-file entry, and expect a refusal. Also fix the `PrivateFiles.read` comment, which says no test can tell the lstat is there.
- **`Store::BaseChecks` is a public constant.** Its methods are private, but it could be `private_constant`.
- **A base directly under macOS `/tmp` is refused,** because `/tmp` is a symlink. Only a custom test base can hit this. `standalone_require_spec` falls back to `/tmp` when `TMPDIR` is unset.

- **Depends on:** 20260923-34.
- **Came from:** Second review of 20260923-34.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260924-19. 3a relations loose ends.

Findings from the reviews of 20260922-17:
- **A function in FROM can hide a view or foreign table.** With `CREATE FUNCTION public.f() RETURNS SETOF public.order_view LANGUAGE sql STABLE AS 'SELECT * FROM public.order_view'`, `SELECT * FROM f()` passes with relations `[]`, while EXPLAIN shows the base table scanned. Non-inlined functions have the same gap. README 3a says to list relations with pg_query, so this matches the letter of the README. But 3b and 3c may need the relations the plan actually scans. Decide whether to refuse set-returning functions in FROM, or to read relations from the plan.
- **A relation named only in an unused CTE is still checked,** so it can over-refuse, for example `WITH c AS (SELECT id FROM p1) SELECT id FROM ONLY p1`.
- **`Relations.check` always reads search_path,** where `RelationQualifier.qualify` reads it only when a name has no schema. It doesn't matter in practice.
- **3b and 3c may need inheritance descendants,** because the scan reads them. `relations` lists only the tables the query names.
- **A leaf partition named directly is relkind `r`, so it passes.** **Decided:** Allow it and treat it as the table it is.

- **Depends on:** 20260922-17.
- **Came from:** The reviews of 20260922-17.
- **README:** 3a.
- **Status:** done

### 20260924-22. 3b schema dump loose ends.

Findings from the build and reviews of 20260922-18:
- **The subset DDL can't restore into an empty arena on its own.** `pg_dump --table` emits no `CREATE SCHEMA`, types, domains, enums, functions used in defaults or CHECKs, or extensions. That matters for 4b and step 10.
- **A query table that's a partition needs its parent.** Its dump carries `ALTER TABLE ONLY <parent> ATTACH PARTITION`.
- **The full dump covers only the query's namespaces plus public,** so a cross-schema FK ancestor is in the subset but not in the full dump. That follows the README, but it's worth knowing.
- **Add `--no-password` (`-w`),** so pg_dump never prompts.
- **A SQL_ASCII database with non-ASCII names crashes as `internal_error`.** It fails closed. Refuse SQL_ASCII by name, and list it as unsupported in v1.
- **In EUC_JP or WIN1252 databases, tables aren't in UTF-8 byte order.** Sort in Ruby after transcoding.
- **Near-miss secret keys aren't refused,** such as `"password "`, `PASSWORD`, or keys holding `=`. Require keys to match `/\A[a-z_]+\z/`.
- **Untested paths:** the subset dump's lock-wait timeout, a signal-killed pg_dump beyond the message, and an empty conninfo.
- **A password can hide in a dbname URI.**
- **Both dumps are held in memory.**

- **Depends on:** 20260922-18.
- **Came from:** The build and reviews of 20260922-18.
- **README:** 3b.
- **Status:** done

### 20260924-23. Deparse loose ends.

Findings from the build and reviews of 20260924-4:
- **`'t'::boolean` and `'f'::boolean` are still refused.** The deparser prints them as `true` and `false`, which parse to a different tree.
- **Shapes turn `EXISTS (SELECT WHERE x)` into `EXISTS (x)`,** because `deparse_expr` strips every `SELECT WHERE `.
- **Very deep queries raise RuntimeError instead of deparse_mismatch.** The wrappers can push a tree past pg_query's encode limit of 1,000, for example `(e OR b) IS TRUE` nested 150 times. It fails closed as `internal_error`, but callers that rescue only `Deparse::Error` (generator two, index SQL, relations, and the rewrite candidate check) abort instead of skipping. Rescue the encode error in `faithful_parse`, and raise `Error`.
- **Stale comments:** `predicate_atoms.rb` lines 82–89, `index_candidate.rb` lines 52–55, and `deparse.rb` lines 15–21, which don't mention Parentheses.
- **Four mutants refuse rare SQL without a test noticing:** the `b_expr` edits at `parentheses.rb` line 156 (three variants), and `operator_level(..., subquery: true)` at line 300. Pin them if it's cheap.
- **The deparse_spec matrix adds about 20s** to the enclave suite.

- **Depends on:** 20260924-4.
- **Came from:** The build and reviews of 20260924-4.
- **README:** Step 1.
- **Status:** done

### 20260926-46. Driver crashes on the first counterexample round.

`Pipeline::CounterexampleStage.compare` (`driver/lib/quaack/driver/pipeline.rb:151`) passes `round:` as an Integer. `Transport::Base#option` accepts only Strings, so it raises `ArgumentError: --round needs a String value` before the enclave runs. Any real run whose rewrite passes step 9 crashes. The specs miss it because `pipeline_spec.rb:304` uses a fake transport that doesn't validate args. Fix it with `round.to_s`, and add a spec that goes through the real `Transport::Base#argv`. Then check for other Integer option values the same way, and remove the prompt pack's `PromptPack::Transport` workaround.

- **Depends on:** 20260926-14.
- **Came from:** Prompt pack regeneration.
- **README:** Step 10.
- **Status:** done

### 20260926-47. Refuse user-defined set-returning functions in FROM.

A set-returning function in FROM can hide a view or foreign table from 3a's relation checks (`SELECT * FROM f()` where `f` reads a view).
- **Decided:** Allow built-in (pg_catalog) set-returning functions such as `generate_series` and `unnest`. Refuse user-defined functions in FROM, and list that as unsupported in v1.

- **Depends on:** 20260924-19.
- **Came from:** Build of 20260924-19.
- **README:** 3a, step 1.
- **Status:** done

### 20260926-48. Anchor clock-reading date literals.

`'now'`, `'today'`, `'yesterday'` and `'tomorrow'` as date or timestamp literals read the clock, just as `now()` does, but 3h doesn't anchor them.
- **Decided:** Anchor them. Rewrite them to the `clock_anchor()` equivalent, as 3h does for `now()` and `current_date`, so runs are reproducible.

- **Depends on:** 20260924-15.
- **Came from:** Build of 20260924-15.
- **README:** 3h.
- **Status:** done

### 20260926-51. Hangup watcher kills steps when stdout is a file or tty.

`Hangup.during` watches stdout with `IO.select` for the reader going away. A regular file is readable at once, so `quaacks probe > out.json` sends HUP immediately and every step fails. A read-write tty becomes readable on a keypress. Start the watcher only when `out.stat.pipe? || out.stat.socket?`, and test both cases.

- **Depends on:** 20260926-45.
- **Came from:** Review of the -45 hangup item.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260926-52. Anchor the clock in rewrite candidates too.

The original is anchored (3h: `now()`, `current_date`, and since 20260926-48 the `'now'`/`'today'`/`'yesterday'`/`'tomorrow'` literals), but LLM and operator rewrite candidates bind the raw placeholder values and call the real clock functions. For a query whose `'now'` literal is compared against a timestamp column, steps 9, 13, 14 and 14c can then see spurious differences between the anchored original and a candidate. The other words differ only across a day boundary or with a pinned anchor. Apply the same anchoring (functions and clock-literal placeholders) to every candidate before it's tested or measured, and test a `'now'` query end to end through a candidate.

Also from the review of -48:
- `restored_node` now accepts any type_cast, which weakens restore's mismatch detection. Add a restore spec with an unrelated `$n::date` next to an anchored one.
- Clock words typed another way (a function argument, an expression on a column, a domain over a domain) aren't anchored, and are listed as unsupported in v1.

- **Depends on:** 20260926-48, 20260922-24.
- **Came from:** 20260926-48 build and review.
- **README:** 3h, steps 9-14.
- **Status:** done

### 20260923-6. Test the runtime check's environment scrubbing.

Removing `GEM_PATH` or `RUBYLIB` from the isolated environment in `spec/support/isolated_install.rb` stays green. Without `GEM_PATH`, RubyGems can see the user and Homebrew gem directories. Also consider `RUBYGEMS_GEMDEPS` and `HOME` (for `~/.gemrc`). Plant a leak for each and prove the check goes red. Also check that closure gems like `quaack-protocol` load from the installed copy, not the repo.

- **Depends on:** 20260923-4.
- **Came from:** Second review of 20260922-1, finding 4.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-8. Unit-test the RepoGems helper.

`spec/support/repo_gems.rb` finds each repo gem's gemspec for the boundary and runtime specs, but its lookups have no direct tests:
- **The one-gemspec guard is untested.** Loosening `paths.size == 1` to `>= 1` in `RepoGems.gemspec` keeps every spec green. Only `enclave/` has its own "exactly one gemspec" test. If `driver/` or `protocol/` gained a second gemspec, `paths.first` could quietly pick the wrong one. Test the guard with two gemspecs planted in a temp directory.
- **One test repeats another.** `spec/repo_gems_spec.rb` checks that the enclave gemspec is named `quaacks`, which `enclave/spec/gemspec_spec.rb` already checks. Replace it with direct tests of `RepoGems.gemspec` and `gemspec_path_of`.
- **Noisy failures.** `enclave/spec/gemspec_spec.rb` loads its gemspec with `Gem::Specification.load` instead of `RepoGems.load`. A broken gemspec makes most of its examples fail with a `NoMethodError` on nil instead of one clear message.

- **Depends on:** 20260923-3.
- **Came from:** Second review of 20260923-3, minor findings 1 through 3.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-9. Close the test gaps in the spec task guards.

Task 20260923-5 made `rake spec` find the suites itself, run them all, and fail if the root suite didn't run. The second review found that the guards work today, but some mutants of them still pass every test:
- **The root guard is only tested by changing SPEC_SUITES.** The test in `spec/rakefile_spec.rb` swaps `SPEC_SUITES` for `%w[foo]`. So a guard that checks `SPEC_SUITES` instead of what actually ran also passes. Combined with a later `drop(1)` in the loop, full `rake` goes green with no root suite. Add a test where `SPEC_SUITES` still includes `"."` but the loop skips it.
- **Nothing tests a suite that can't start.** When `sh` can't start the command, `ok` is nil. Changing `unless ok` to `if ok == false` keeps every test green, and then a missing interpreter makes `rake spec` pass with zero examples run. Also, `ran` records a suite as run even when it never started. Test both.
- **Output is hard to use.** The echoed command has no shell quoting, so you can't paste it to rerun one suite. A suite that can't start is reported only as `Spec suites failed: x/spec`, with no reason or exit status.
- **The Rakefile comment oversells the guard.** It says the guard catches "a loop that skips a suite", but that holds only for the root suite.

- **Depends on:** 20260923-5.
- **Came from:** Second review of 20260923-5, findings 1, 2, 4, 5, and 6.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-10. Stop local RSpec options from filtering out boundary specs.

RSpec reads `.rspec-local`, `~/.rspec`, and `SPEC_OPTS`. None of them are in the repo, and `.rspec-local` isn't gitignored. A `.rspec-local` with `--exclude-pattern "**/boundary*_spec.rb"` made full `rake` pass with a planted enclave dependency on `quaack-driver`. The root suite ran 20 examples instead of 61. Local `rake` is the only check, so a personal options file can quietly turn off the trust-boundary checks. Make the spec task ignore local and personal RSpec options, or check that the boundary specs actually ran, and test it with a planted exclusion.

- **Depends on:** 20260923-5.
- **Came from:** Second review of 20260923-5, finding 3.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260923-16. Harness loose ends.

Minor findings from the second review of 20260922-2:
- **Untested branches.**
  - `rescue Errno::EPERM` in the owner-pid check could return false and nothing would notice.
  - "Never build the image" survives on a machine that already has it.
- **Child specs load the root spec_helper.** Harness child processes run from the repo root, so `.rspec` loads the root `spec_helper` and `TestPostgres.configure` runs twice. The children don't prove the documented setup works on its own.
- **Slow timeout test.** The readiness-timeout test takes about 4 s. A 1 s timeout would halve that.
- **Repeated backtrace.** A memoized launch failure repeats the first example's backtrace in every later failure.
- **Old images pile up.** Each Dockerfile edit leaves an old `quaack-test-postgres:<hash>` image of about 660 MB.
- **The admin connection outlives a fork elsewhere.** Only a drop resets a dead admin connection. If a spec forks in an example with no databases of its own, every later example fails with an empty `PG::ConnectionBad`. Reset the admin connection when it's dead, or check it before reuse.
- **`WITH (FORCE)` is untested.** Removing it keeps every test green, but a spec that holds a `connect` session open would then fail with `PG::ObjectInUse`.
- **Only the first drop error is reported.** If an example leaves `admin` inside `BEGIN`, every later example fails. The admin connection is reset only for `ConnectionBad`.
- **`ConnectionLost` always blames forking,** even when the container died or the backend was terminated.
- **Faster child specs.** The `IS_TEMPLATE` and `ConnectionLost` tests could run in-process with `pg_terminate_backend` and save about 3.5 s.
- **Arena template.** Arena's template comes from `template1`, not `template0` with locale settings matching production. The real arena setup in 20260922-27 should handle this, so check it there.

- **Depends on:** 20260923-15.
- **Came from:** Both reviews of 20260922-2, and the second review of 20260923-15.
- **README:** Steps 4 and 4b.
- **Status:** done

### 20260923-18. Runtime checker test loose ends.

Findings from both reviews of 20260923-13, all outside its diff:
- **Dead plants in three older tests.** In `spec/runtime_boundary_checker_spec.rb`, three tests stay green with their planted `require` deleted: "flags the driver as forbidden even when the allowlist admits it", "flags an LLM SDK by what it loads as", and "flags any file from the installed driver gem". Each adds a dependency on a gem built from source, so the every-file run flags that gem's files anyway. They aren't vacuous, since each goes red when its named rule breaks, but the plant proves nothing. Restrict each assertion to the `--version` run, or assert the planted path.
- **Failing for the right reason.** The two bare-dependency tests fail with a `KeyError` from `gem_dirs.fetch` when their dependency is removed, not on their assertion. Assert that the gem is installed first.
- **Isolation code no test watches.** In `spec/support/isolated_install.rb`, nothing tests `"GEM_PATH" => @home`, `"RUBYOPT" => nil`, `Bundler.with_unbundled_env` in `run_ruby`, or `File.realpath` in `stdlib_dirs`. Test them, or say why they're belt and braces. This overlaps with 20260923-6.

- **Depends on:** 20260923-13.
- **Came from:** Both reviews of 20260923-13.
- **README:** None. This is test infrastructure.
- **Status:** done

### 20260923-25. Static checker loose ends.

Minor findings from the second review of 20260923-7:
- `::Bundler.require` isn't flagged, because `bundler_require?` needs a `ConstantReadNode` receiver, and `::Bundler` parses as a `ConstantPathNode`.
- In names-only mode, the driver misses `require_relative "../../../../enclave/lib/quaack/enclave"`, and doesn't check its shebang. That's by design per the task, but say so in the header.
- The header and the `require_violations` comment say names-only mode checks only forbidden names, but parse failures are still flagged. Fix the wording.
- Nothing pins `names_only: true` for the real driver in `spec/boundary_spec.rb`. Dropping it stays green. The fixture tests do pin the mode itself.

- **Depends on:** 20260923-7.
- **Came from:** Second review of 20260923-7.
- **README:** Where QUAACK runs.
- **Status:** done

### 20260926-40. Keyset pagination loose ends.

- Step 9 pools keysets only on the leading column. Scenarios never build the tie case, so a candidate that changes only the tie-breaker value (`(qty, id) < (7, 901)` instead of `(7, 900)`) can pass step 9. Seed tie rows on the leading column, or list it as a v1 limitation. (Steps 10 and 14c may still catch it.)
- Row comparisons with `=` or `<>`, or with an expression in the column row, get no pool, so 9c may mark them untested.
- 3e picks no worst-case or typical values for tuple placeholders.
- No candidate-specific tests for row comparisons in rewrites.
- The relation-qualifier keyset test sits under a misleading `describe`.

- **Depends on:** 20260924-31.
- **Came from:** 20260924-31 build and review.
- **README:** 3e, step 9.
- **Status:** done

### 20260926-44. Expression-unique loose ends.

- `RowSet`'s `expression?` guard is untested: inverting it stays green. Add a unit test with a crafted key like `a), (b`, asserting the group is dropped without running the key.
- There's no perturb-and-retry for colliding expression keys, so the group is dropped.
- A column an expression reads that the row leaves out (a generated column) counts as NULL when the key is worked out.

- **Depends on:** 20260926-41.
- **Came from:** 20260926-41 build and review.
- **README:** Step 9.
- **Status:** done

### 20260926-50. FROM functions: non-FuncCall items crash.

`FromFunctions.calls` assumes every FROM function item is a FuncCall, so `SELECT * FROM current_user` or `SELECT * FROM coalesce(1,2)` may raise NoMethodError instead of a clean refusal (unless an earlier stage refuses them). Refuse any non-FuncCall item cleanly, and test it. Overloads aren't told apart either: a user function sitting earlier in the path with a pg_catalog name is refused (documented as unsupported in v1).

- **Depends on:** 20260926-47.
- **Came from:** 20260926-47 review.
- **README:** 3a.
- **Status:** done

### 20260923-23. Dedupe repeated ORDER BY columns in 5a-1.

Split out of 20260923-20. Postgres reads a column that ORDER BY repeats only at its first position, whatever the repeat's direction or position. An index on `(a, created_at)` serves both `ORDER BY a, a DESC, created_at` and `ORDER BY a, created_at, a DESC` with no Sort. Generator one no longer drops repeats. So today `WHERE a IN (1, 2) ORDER BY a, a, created_at` gives only `(a)`, and `ORDER BY created_at, created_at DESC` can propose a key with `created_at` twice. Re-add the dedupe, keeping the first occurrence. Test it with a non-adjacent repeat such as `ORDER BY a, created_at, a DESC`, so an adjacent-only dedupe goes red.

- **Depends on:** 20260923-20.
- **Came from:** The tests-only round of 20260923-20, where the old test stayed vacuous against an adjacent-only dedupe.
- **README:** 5a-1.
- **Status:** done

### 20260923-26. Egress loose ends.

Minor findings from the second review of 20260922-7:
- **A String subclass as a Hash key isn't tested.** Changing `[String, Symbol].include?(key.class)` in `plain_hash` to `is_a?` checks stays green, and it's a real leak: `rule: { Class.new(String) { def to_s = "SENTINEL" }.new("a") => 1 }` then sends the sentinel. Add it to the table of values that must raise.
- **A Hash-like message isn't tested.** Changing `message.is_a?(Hash)` to `message.respond_to?(:each_key)` stays green. Add an object with `each_key` and `[]`, or `ENV`, to the "sends nothing" table.
- **Deep nesting and cycles raise `SystemStackError`.** Fixed by 20260923-32 through the shared `PlainData.check`. Drop this item. A 100,000-deep Array or a self-containing Array recurses in `plain` before JSON's nesting limit applies. Nothing leaks, but the contract says `Egress::Error`, and `SystemStackError` isn't a `StandardError`. Add a depth cap in `plain`.
- **Error filtering (20260922-8) must catch `Egress::Error`, and must never print the cause chain of the errors it filters.**

- **Depends on:** 20260922-7.
- **Came from:** Both reviews of 20260922-7.
- **README:** Trust boundary.
- **Status:** done

### 20260923-27. Qualify relations loose ends.

Findings from both reviews and the builder of 20260922-14:
- **Other names depend on search_path too.** Unqualified functions, types in casts and column definitions, operators, collations, and text search configurations all resolve through `search_path`. So do relation names in string literals, such as `'t'::regclass`, `nextval('seq')`, and `to_regclass('t')`. None of them are rewritten. This matters for 3d, which looks functions up in `pg_catalog`, and for replaying the query on the racetrack.
- **`SELECT ... INTO new_table` aborts** because its target resolves nowhere. That's a safe abort, but intake (20260922-13) or the inbound check should reject it with a clear rule.
- **A multi-statement input is accepted,** and every statement gets qualified. Intake (20260922-13) should accept exactly one statement.
- **The role used to resolve names.** `"$user"` and the USAGE check use the role QUAACK connects as. If the operator's plan session ran as a different role, resolution could differ. Document this in the operator docs, or take the role as an input.
- **An empty search_path written by hand** as `""` or all whitespace aborts with "has an empty entry", but Postgres treats it as an empty path. EXPLAIN never writes that form.
- **The abort message** joins schemas with ", ", so a schema named `weird, schema` looks like two schemas.
- **Deparse drops formatting.** The output is pg_query's deparse even when nothing changed, so comments and layout are lost.

- **Depends on:** 20260922-14.
- **Came from:** Both reviews of 20260922-14, and its builder's notes.
- **README:** Step 1.
- **Status:** done
- **Note (from the review of 20260922-17):** RelationQualifier ignores the implicit `pg_temp` at the front of the search path. So a temp view named `orders` in the plan's session would resolve to `public.orders`. The enclave session has no temp relations, so this only matters if the plan's own session had one shadowing a real relation.

### 20260923-28. Canonical plan loose ends.

Minor findings from the second review of 20260922-15:
- **`Integer()` reads a leading zero as octal.** A real index named `"<09>fake"` raises `ArgumentError`, and `"<010>fake"` is read as oid 8. Use `Integer(..., 10)`.
- **A real index whose name starts with `<digits>` is treated as hypothetical.** Without a map, a real `"<123>orders_pkey"` compares equal to `orders_pkey`. It's unlikely, so document it.
- **Surviving mutants:**
  - An empty map treated like no map. `hypothetical_indexes: {}` with a `<oid>` index should make the plan not comparable.
  - The `\A` anchor dropped from `HYPOTHETICAL_INDEX`.
  - An Array of pairs accepted as the map.
- **The "two sessions" Postgres spec never gets two oids,** because `hypopg_reset()` runs after the extra index is made. Fix the setup or the comment.
- **The digest covers a partial predicate's literal.** A short literal could be guessed from the hash. It stays in the enclave today, but any step that sends a canonical form out must know this.
- **Merge `PlanExpression`'s parse helper with `CanonicalPlan`'s own parse step.**

- **Depends on:** 20260922-15.
- **Came from:** Second review of 20260922-15, and its builder's notes.
- **README:** Step 1.
- **Status:** done

### 20260923-35. Volatility check loose ends.

Findings from the reviews of 20260922-20:
- **Domain CHECK constraints aren't checked.** A domain whose CHECK calls a volatile function passes. That's realistic, because a validator function is VOLATILE unless someone marks it otherwise.
- **Attribute notation isn't checked.** `t.f` is a plain ColumnRef, so it's still missed. The review of 20260922-10 confirmed it: with `bumpo(public.orders)` VOLATILE, `SELECT o.bumpo FROM orders o` is accepted. The allowlist refuses `(t).f`.
- **One volatile cast to a common type poisons every cast to it.** For example, `CREATE CAST (x AS int)` with a volatile function makes every `::int` abort. None of the catalogs checked have one.
- **TABLESAMPLE is moot now.** The allowlist (20260923-33) refuses it before the volatility check runs.
- **Mislabeled STABLE functions get through.** The check trusts `provolatile`, so a function declared STABLE whose body calls `nextval` is accepted, and the sequence advance survives ROLLBACK. That's a labeling error in the production schema, but it breaks what the arena runner relies on. Record it as a known limitation, or look into checking the bodies of SQL functions.
- **STABLE functions that read other tables are accepted.** Examples are `table_to_xml` and a STABLE SQL function reading an unrelated table. The review of 20260922-10 judged this fine for version 1, since the rows stay in the enclave. Note it in the module doc.
- **Surviving mutants:**
  - Three `quote_ident` columns aren't pinned: `OPERATOR_SQL` `f.proname`, and `CAST_SQL` `named.nspname` and `fn.nspname`.
  - `count == 1 ?` can become `>= 1` without any test failing. Under that change, `a.pair(1, 2)` would falsely abort.
- **The hypothetical-set test** should assert its fixture is non-variadic (`provariadic = 0`, `pronargs = 2`) so it can't go vacuous without anyone noticing.
- **The parse can't see things Postgres adds on its own:** implicit casts, the source type's output function in I/O casts, the default-opclass operators behind DISTINCT, GROUP BY, and ORDER BY, and column defaults. The reviewer judged these exotic.
- **Index DDL too (from the first review of 20260922-11):** `IndexDdlCheck` reuses this check, so the attribute-notation and domain CHECK gaps reach index DDL. With `evil3(public.orders)` a VOLATILE SQL function, `CREATE INDEX ON public.orders ((orders.evil3))` is accepted, and HypoPG and a real CREATE INDEX both build it, because Postgres inlines the SQL body before its IMMUTABLE check. Postgres still refuses a body with side effects, or a non-SQL function. Fix these gaps here, and list them in the "what it doesn't catch" part of `IndexDdlCheck`'s header.

- **Depends on:** 20260922-20.
- **Came from:** Both reviews of 20260922-20, and the tests-only review.
- **README:** 3d.
- **Status:** done

### 20260923-38. Error filtering loose ends.

Findings from both reviews of 20260922-8:
- **A signal that arrives while `guard` is already reporting an error gets swallowed.** The `rescue Exception` clauses in `write`, `ask`, and `to_egress` catch an asynchronous SignalException, so `guard` returns 70 and a caller's loop carries on. Re-raise SignalException in those clauses too.
- **Nothing tests that `write` flushes.** Deleting `out.flush` stays green.
- **No spec combines `silence_stderr!` with a re-raised signal.**
- **Most enclave error classes have no `rule` method,** so they go out as `internal_error`. Add rules to `RelationQualifier::Error` and `Store::Error`, and to the ArgumentErrors that stand in for a rule, such as those in PredicateAtoms and IndexCandidate.
- **Decided:** No. Keep the identifier pattern for rule names, not a closed list. (The original question was whether rule names should be a closed list in the protocol gem, so every new rule is a reviewed change like the whitelist? Today any identifier-shaped word passes, so an error class that copied a one-word value into `rule` would send it.
- **Operators get no detail beyond the rule.** A rule-to-text table on the driver side would give them a readable message without changing the whitelist.

- **Depends on:** 20260922-8.
- **Came from:** Both reviews of 20260922-8.
- **README:** Trust boundary.
- **Status:** done

### 20260925-19. Schema-dump loose ends.

Minor findings from the first review of 20260925-9:
- **A failure after the writes.** The connection stays idle in transaction through both pg_dump runs. If production's `idle_in_transaction_session_timeout` ends the session, the ROLLBACK in `Inventory::Production.read_only` raises `production_read_failed` after `schema_dump` and `schema_subset` are already stored. Reproduce it with `ALTER ROLE ... SET idle_in_transaction_session_timeout = '1s'` and a fake pg_dump that sleeps 2 seconds. Fix: do the catalog reads, commit, then run pg_dump and write; or delete both entries on a later error.
- **The transaction test only proves that some transaction is open, not that it's read-only.** Note this, or find a way to check `transaction_read_only`.

- **Depends on:** 20260925-9.
- **Came from:** The first review of 20260925-9.
- **README:** 3b.
- **Status:** done

### 20260925-23. Anchor step loose ends.

- **`clock_replacements` can't go straight back into `restore`.** It's stored as string-keyed hashes, but `ClockAnchoring.restore` calls `.anchored` and `.original` on objects. Add a loader (`ClockAnchoring.load_replacements(store)` or similar) that rebuilds them, with a test that round-trips the stored form through `restore`. Step 15 needs this.
- **The step spec doesn't cover `now() - interval $n`.** Add a case.

- **Depends on:** 20260925-15.
- **Came from:** The first review of 20260925-15.
- **README:** 3h.
- **Status:** done

### 20260925-1. Index DDL check loose ends.

Findings from the second review of 20260922-11:
- **The unparsable sentinel test doesn't exercise the leak path.** In `enclave/spec/index_ddl_check_spec.rb`, the `"unparsable"` case in "a sentinel in the DDL" ends in a trailing AND. So pg_query's message is "syntax error at end of input", which never quotes the sentinel. Plant the syntax error on a sentinel token, such as `... WHERE status = '<sentinel>' '<sentinel>'`. The exact-message test still catches a leak today.
- **The README doesn't list the index DDL rules.** README "What goes into the enclave" says only "exactly one `CREATE INDEX` statement on a table the query uses". Add the refusals (CONCURRENTLY, UNIQUE, NULLS NOT DISTINCT, TABLESPACE, ON ONLY, an unqualified table, volatile functions, parameters, subqueries, and aggregates). Also say that the index name is dropped and that STABLE is left to Postgres.

- **Depends on:** 20260922-11.
- **Came from:** The second review of 20260922-11.
- **README:** What goes into the enclave.
- **Status:** done

### 20260925-3. Plan gate loose ends.

Minor findings from the first review of 20260922-28:
- **The `Redaction.binding` call in `plan_gate.rb` is untested.** Deleting it stays green. Add a test that SQL which doesn't bind to the stored map (an extra `$n`, or unredacted SQL) raises `Redaction::Error`.
- **The guards in `CanonicalPlan#unqualify_type` are untested.** Removing the anchor-only guard or the `names.size > 1` guard stays green. Test them, or drop the guards if stripping `pg_catalog` from every cast is fine.

- **Depends on:** 20260922-28.
- **Came from:** The first review of 20260922-28.
- **README:** Step 5.
- **Status:** done

### 20260925-24. Index-search loose ends.

- `Dedupe.restore` doesn't check that `considered` matches the lists, so a corrupt entry restores silently.
- `index_search.rb` finds proposals with `==`, which relies on `IndexCandidate#==` ignoring sources. If SingleCandidateTest ever normalizes a candidate, the lookup gives nil and crashes.

- **Depends on:** 20260925-6.
- **Came from:** The reviews of 20260925-6.
- **README:** 5a-3, 5a-4.
- **Status:** done

### 20260926-57. Update the e2e corpus for keyset support, and check for other drift.

The e2e corpus (merged from the user's branch) was written against an older README. Case `070-row-comparison-refused` expects keyset pagination `(created_at, id) < (...)` to be refused, but 20260924-31 made it supported. Turn 070 into an `index` case (for example an index on `(created_at DESC, id DESC)`), add a new refused case for a construct that is still refused (SIMILAR TO, TABLESAMPLE, or CTE CYCLE), and regenerate with `ruby e2e/verify.rb <case> --write`. Then run `quaacks intake` (or `SupportedSql`) over all 100 slow queries to catch any other case whose supported/refused expectation has drifted. Note in `e2e/README.md` that the full verify takes about 25 minutes and isn't part of `rake`.

- **Depends on:** 20260924-31.
- **Came from:** Review of the e2e corpus branch.
- **README:** Step 1.
- **Status:** done

### 20260926-43. Payload fidelity loose ends.

- Nothing tests the fallback when PREPARE fails (empty `parameter_types`, so the payload falls back to the 3g type class).
- The rewrite payload spec only checks that it agrees with the index payload, not that the types are correct.

- **Depends on:** 20260926-39.
- **Came from:** 20260926-39 build and review.
- **README:** 5a-5, 6a.
- **Status:** done

### 20260926-59. Keyset tie rows are dropped on realistic schemas.

On the prompt-pack `shop.orders` schema, step 9 doesn't catch a keyset candidate that changes only the tie-breaker value (`id < 900` becomes `id < 901`). The candidate passes with `dropped: 3`: the tie rows are left out, probably because they collide on a unique key, an FK, or the `GENERATED ALWAYS` identity id. The same test catches it on the simple `fx` schema. Find out why the tie rows are dropped, and make them load: give their other unique columns distinct values, keep them within FK parents, and handle identity keys as 20260926-37 did. Add the tie-breaker test to `step_nine_realistic_schema_postgres_spec.rb`.

- **Depends on:** 20260926-40, -55.
- **Came from:** Build of 20260926-55.
- **README:** Step 9.
- **Status:** done

### 20260926-58. End-to-end runner over the e2e corpus (20260922-65, part two).

Build a runner (a script or rake task outside the default `rake` check, like `e2e/verify.rb`) that runs the real `quaacks` + `quaack run` pipeline end to end over each `e2e/cases/*`:
- a throwaway harness Postgres standing in for production, loaded from the case's `schema.sql`
- a run server and racetrack from the same data
- the driver's `Pipeline`
- a fake LLM that returns empty answers for now, and replays `spec/fixtures/llm_corpus` replies once they exist

Per case it checks the case's claim:
- a `refused` case fails intake with the expected rule
- `index` cases produce a report whose top-ranked fix meets the case's block bound in `results.md`/`case.json`
- `rewrite`, `both` and `trap` cases are recorded as expected to need the LLM
- no case crashes

It writes a summary table and fails clearly on crashes. Any real QUAACK bug it finds becomes its own backlog task, not a fix inside this one.

- **Depends on:** 20260926-33, 20260926-57, the e2e corpus.
- **Came from:** User direction, 2026-09-26.
- **README:** All.
- **Status:** done

### 20260927-1. Set operations crash generator one (5a-1).

e2e cases 029, 058, 068, 097, 098 and 100 stop at `index-search` with `internal_error`. `generator_one.rb:157` raises `ArgumentError` on UNION, INTERSECT or EXCEPT, which intake accepts. Handle set operations in 5a-1: generate candidates per branch, or skip set-operation queries with a clean result. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1.
- **Status:** done

### 20260927-7. e2e corpus fixes: 075 and 010.

- 075's table has an inheritance child, which README 3c refuses as `inheritance_parent`. Make the case expect that refusal, or drop the child.
- 010's GIN index comes from the LLM, but its `features` don't say 5a-5. Add it.

- **Depends on:** the e2e corpus.
- **Came from:** The e2e runner.
- **README:** none.
- **Status:** done

### 20260927-6. Weak or unstable top picks.

- e2e 066 never finds the two-index combination it needs.
- 025 generated the right shape, but its top fix measured 4984 blocks against a bound of 2618.
- 055's matching candidate was declined as unused.
- Most urgent: the top fix isn't stable between runs on the same data. 024 measured 52 then 8 blocks, and 096 measured 2511, 11, then 2511. 070 (5 vs 4) and 086 (1013 vs 1007) miss narrowly on every run.

Find out why ranking or measurement varies between runs; it could be ANALYZE sampling, hint-bit or visibility-map state, or ties in ranking. Until then, the index verdicts can't gate anything. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-7, 12-14.
- **Landed (2026-09-27):** the instability was in the e2e harness, not in QUAACK. With `synchronous_commit=off`, VACUUM raced the WAL writer, so `relallvisible` came out 0 or full at random, and that flipped index-only pricing. The fix is a CHECKPOINT before VACUUM in `e2e/run.rb`. 024, 070 and 096 now pass every run. What's left moved to 20260927-9 to -12.
- **Status:** done

### 20260927-12. e2e 086 misses its bound by 6 blocks.

Now that runs are stable, 086 measures 1013 blocks against a bound of 1007, every run. Find out whether it's a real small miss in QUAACK or a bound that's too tight in the corpus.

- **Depends on:** 20260927-6.
- **Came from:** The 20260927-6 investigation.
- **README:** none.
- **Status:** done

### 20260927-2. 5a-4 and the plan gate prepare with untyped parameters.

`SingleCandidateTest#explain` (`single_candidate_test.rb:419`) prepares the query without parameter types, so Postgres guesses wrong:
- e2e 020, 048, 099 fail with `prepare_failed` 42883: `now()::date - $1` resolves as date minus date.
- 031 fails with `explain_failed` 22P02: `4242.0` won't bind to an inferred bigint.
- 091 is probably a plan-gate mismatch on `substring(... FROM $1 FOR $2)`.

Use the original literal's type for each placeholder (from the placeholder map, or cast the placeholder the way the original literal was written). Check every other PREPARE site (the plan gate, index search) for the same bug. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-4, step 5 plan gate.
- **Status:** done

### 20260927-3. 5a-1 puts grouping and ordering columns in INCLUDE instead of the key.

e2e 013 gets `(tenant_id) INCLUDE (status)` and 073 gets `(account_id) INCLUDE (started_at)`. The cases need those columns as key columns for GROUP BY or ORDER BY to use the index order. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1.
- **Status:** done

### 20260927-4. 5a-1 gives no atoms for correlated subqueries.

e2e 027 (LATERAL top-N) and 089 (`ARRAY(SELECT ...)`) get no index on the correlated column. Generate candidates from correlation predicates inside LATERAL and scalar/array subqueries. Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1.
- **Status:** done

### 20260927-5. 5a-1 gives no candidates in some common shapes.

These shapes get no candidates:
- A column compared with a non-constant expression (e2e 076, 078, 093, 094).
- OR across two columns (015, which could use a BitmapOr of two indexes).
- `COLLATE "C"` (090).

Details are in `e2e/RUN.md`.

- **Depends on:** 20260926-58.
- **Came from:** The e2e runner.
- **README:** 5a-1, 5a-2.
- **Status:** done

### 20260927-8. e2e 097: top fix far above bound; CTEs and subqueries get no candidates.

- e2e 097 (a set operation) no longer crashes, but its top fix measures 384 blocks against a bound of 118. Diagnose why.
- Generator one gives no candidates for a CTE body or a subquery in FROM, including set operations inside one. Add a spec pinning that a CTE referenced from a set-operation branch is neither refused nor qualified as a table. Consider descending into CTE bodies and FROM subqueries for candidates.

- **Depends on:** 20260927-1.
- **Came from:** 20260927-1 build and review.
- **README:** 5a-1.
- **Status:** done

### 20260927-14. Typed-prepare loose ends, and e2e 020 and 099.

- **e2e 020:** `started_at >= current_date - 1 GROUP BY user_id`. Its one candidate is declined as unused (bound 94). Diagnose it: clock anchoring's effect on the predicate, or 5a-1's choice.
- **e2e 099:** the top fix touches 13 blocks against a bound of 12. Is it a ranking issue or the bound?
- **Weak sentinel test:** the "failed typed prepare error free of the literal" test can't catch a regression, because the sentinel never reaches PREPARE.
- **Type names:** `Redaction.prepare` and `Binding#prepare_sql` interpolate type names unchecked. They're safe only because the set is fixed. Add an allowlist.
- **SELECT only:** `Redaction.one_statement?` doesn't require a SELECT.

- **Depends on:** 20260927-2.
- **Came from:** 20260927-2 build and review.
- **README:** 5a-4.
- **Status:** done

### 20260927-13. 5a-1 adds a non-covering INCLUDE and no bare-key variant.

Diagnosed from e2e 086 (20260927-12). QUAACK built `catalog (price_cents) INCLUDE (id, sku, name)`, which measured 1013 blocks against 1007 for the plain `(price_cents)` index. The plan is a BitmapOr feeding a heap scan, which never uses INCLUDE columns, and the heap filter needs `category`, which isn't in the INCLUDE. So the INCLUDE only widens the leaf entries.
- `btree(key)` (generator_one.rb ~792) always adds `include: covered - key`.
- `covered_columns` (~584) takes only target-list and GROUP BY columns, and leaves out WHERE-only filter columns.
- No bare-key variant is proposed, so ranking can't compare the two (`considered: 1`).

Fix: add the INCLUDE only when it makes the index truly covering for that table (every column the query reads from it, filter columns included), and/or always also propose the bare-key variant. Related to 20260927-11 (INCLUDE vs deduplication).

- **Depends on:** 20260927-12.
- **Came from:** The 20260927-12 investigation.
- **README:** 5a-1.
- **Status:** done

### 20260927-15. 5a-1 generation loose ends.

These are minor findings from the review of 20260927-3 to -8:
- A volatile value (`col = random()`) counts as a value and yields a false candidate. Refuse volatile calls in `value?`.
- A schema-qualified outer reference (`public.orders.id`) isn't treated as an outer column.
- Inside a subquery, an unqualified outer column that shares a name with an inner column resolves to the inner table.
- The first collation wins when a column gets different COLLATEs.
- Long OR chains build one set of uses per arm. Consider a cap.

- **Depends on:** 20260927-5.
- **Came from:** Review of 20260927-3 to -8.
- **README:** 5a-1.
- **Status:** done

### 20260927-16. one_statement? lets data-modifying CTEs and SELECT INTO through.

`Redaction.one_statement?` accepts `WITH d AS (DELETE ... RETURNING 1) SELECT ...` and `SELECT ... INTO t2`, because both parse as a SelectStmt. SingleCandidateTest rolls back, so writes should be undone. Check whether its transaction is READ ONLY, and consider refusing non-SELECT CTEs and `into_clause` (intake's allowlist probably already refuses these in the original query; check). e2e 020 now passes after 20260927-5, and 099 passes after 20260927-2.

- **Depends on:** 20260927-14.
- **Came from:** Review of 20260927-14.
- **README:** 5a-4.
- **Status:** done

### 20260926-60. A fixture load failure in the vacuity guard crashes step 9.

A genuine fixture load failure inside `VacuityGuard.exercised_atoms` (vacuity_guard.rb:91, from step_nine.rb:41) raises `ArenaRunner::Error` out of `StepNine.run` instead of producing a clean per-candidate outcome. Decide how 9c should treat a scenario that won't load: skip it and mark its atoms untested, or refuse the candidate with a rule. Then handle it, with a test.
- **Decided (2026-09-27):** scenarios must never crash QUAACK. Skip a scenario that won't load and mark the atoms it would have tested as untested.

- **Depends on:** 20260922-48, 20260926-59.
- **Came from:** Build of 20260926-59.
- **README:** Step 9.
- **Status:** done

### 20260927-10. Capture and restore relallvisible.

The planner prices index-only scans from `pg_class.relallvisible`. The enclave captures only `reltuples` and `relpages`, so index-only pricing on the racetrack depends on whether it has been vacuumed, not on production. Capture `relallvisible` in the statistics step. **Decided (2026-09-27):** neither, for v1. Assume production is vacuumed normally and the racetrack is fully analyzed and vacuumed after restore. Document these assumptions in the README (3c, 4a).

- **Depends on:** 20260922-17.
- **Came from:** The 20260927-6 investigation.
- **README:** 3c, 4a.
- **Status:** done

### 20260927-9. 5a-7 ranking and combining are stricter than the README.

e2e 025 and 066 fail because of how `IndexRanking` reads the worst-case rule:
- A candidate the planner doesn't use for the worst-case literal gets a worst-case reduction of 0, so a marginal index that helps every set by about 5% outranks one that cuts the slow set by 4x (025).
- `combine` adds a second index only if the worst case improves, so a needed pair is never built (066).

README 5a-7 says to keep adding indexes "as long as each addition lowers the cost further".
- **Decided (2026-09-27):** follow README 5a-7: keep adding while cost drops without making any set worse, and break worst-case ties on the next-worst set. (The original question was whether to combine while an addition lowers cost without making any set worse, and when worst-case reductions tie, compare the next-worst set before falling back to size? That changes how the worst-case rule is read.

- **Depends on:** 20260922-35.
- **Came from:** The 20260927-6 investigation.
- **README:** 5a-7.
- **Status:** done

### 20260927-11. HypoPG size ignores B-tree deduplication.

In e2e 055, the real key-only index `orders (status, total_cents)` is 5.6 MB and used, but HypoPG estimates 17.4 MB. 5a-1 proposes the INCLUDE shape, which isn't deduplicated, so the real planner wouldn't use it either. **Needs a decision:**
- make 5a-1 prefer key columns over INCLUDE when the leading key has few distinct values
- correct the size estimate for low-cardinality key-only indexes
- or list this case as unsupported in v1
- **Decided (2026-09-27):** HypoPG's estimate can't be corrected from outside, but 12a already builds every index for real. So when 5a-4 declines a key-only B-tree index on a low-cardinality leading column as unused, set it aside for 12a the way GIN and GiST candidates are, instead of dropping it. 12a builds it for real, and steps 13 and 14 measure it.

- **Depends on:** 20260922-30, -32.
- **Came from:** The 20260927-6 investigation.
- **README:** 5a-1, 5a-4.
- **Status:** done

### 20260927-20. Regenerate the prompt pack: JSON-only instruction and a subtly wrong fake rewrite.

The user's first 18 replies (`correlated_exists/10a-1`, `10a-2`) showed two problems:
- **Code fences and prose:** some models wrap JSON in code fences or add prose. Add an explicit "reply with only the JSON object, no code fences or commentary" line to every LLM prompt the driver sends (5a-5, 5a-6, 6a, step 7, 10a). The API's structured output already enforces the schema, but this helps other providers. Make the replay tolerant of fences too.
- **Empty answers:** the pack's fake 6a rewrite is exactly equivalent (a MATERIALIZED CTE wrapper), so 10a has no real counterexample and models return nothing. Give each query's fake rewrite a small, plausible bug (a changed boundary, a dropped condition) that still survives step 9 often enough to reach 10a, or add one buggy rewrite alongside the equivalent one.

Regenerate the pack. Move the existing 18 replies to an `archive/` subfolder for the equivalent-rewrite prompt, so they're kept but not mixed with the new prompts. The user will redo the replies (decided 2026-09-27).

- **Depends on:** 20260922-65 part one.
- **Came from:** The user's first replies.
- **README:** 5a-5, 6a, step 7, 10a.
- **Status:** done

### 20260927-21. LLM reply parsing: pick the right object, and check the schema.

These are minor findings from the review of 20260927-20:
- `embedded_json` always starts at the first `{`, so prose like `Using {"a":1} as shown: {"indexes":[]}` yields `{"a":1}`. Try every start, and prefer the object that matches the schema. Or refuse when more than one top-level object parses.
- `Client#ask` doesn't check a parsed reply against the schema. Check at least the required keys, so a wrong object is refused as `llm_bad_response` instead of reaching callers. (Claude's structured output makes this moot today; it matters for other providers and for replay.)

- **Depends on:** 20260927-20.
- **Came from:** Review of 20260927-20.
- **README:** LLM client.
- **Status:** done

### 20260922-65. Full pipeline.

Wire every step together in the driver, from intake through the report and teardown. Run it end to end against the test harness.
- **Decided:** The end-to-end test uses a scripted fake LLM, so it runs free in rake. The scripts must be realistic, drawn from a large corpus of responses. **Before building, ask the user questions:** they'll collect responses from several different LLMs to seed the corpus.
- **Landed (part one):** The prompt pack generator, `script/prompt_pack/run.rb`, and a partial pack in `spec/fixtures/llm_corpus/`. Rerun it after 20260926-37 and keyset support land, to capture the 10a and step 11 prompts.
- **Note (2026-09-26):** The user is having another LLM build a large end-to-end query corpus: for each test, the schema, the inserts, the slow query, and the changes that make it fast. Build -65's end-to-end tests on that corpus when it arrives. Don't spend cycles writing our own fixture queries beyond the small prompt pack.
- **Decided (corpus):** Split into two parts. First, a builder generates a prompt pack: it runs the pipeline on harness fixtures and captures every real LLM prompt (5a-5, 5a-6, 6a, step 7, 10a) to files. The user pastes each prompt into 3 LLMs, 3 replies each, and saves the replies next to the prompts. The fake LLM then replays them. Queries to cover: an ORM-style join (equality plus range, ORDER BY, LIMIT), aggregates with GROUP BY/HAVING, a correlated EXISTS or IN subquery, and keyset pagination (row comparisons are unsupported in v1, so that one tests the refusal path unless it's written without a row comparison).

- **Decided (replay, 2026-09-27):** A rake spec runs the four prompt-pack queries through the full pipeline, with the fake LLM replaying the corpus. It replays every saved reply separately, not just one per LLM. A prompt with no saved replies yet falls back to the e2e runner's valid empty answer, and the output notes that.

- **Depends on:** 20260922-36, 20260922-39, 20260922-42, 20260922-49, 20260922-52, 20260922-64, 20260926-1, 20260926-2, 20260927-23.
- **README:** All.
- **Status:** done
- **Landed (part three, 2026-09-27):** `spec/pipeline_replay_spec.rb` replays the corpus through the full pipeline in rake. 20260927-23 then added driver teardown, which covers the rest. Leftovers are in 20260927-24.
- **Note:** `e2e/cases/` holds 100 cases for this test to run QUAACK against, each with its schema and data, slow query, and expected outcome (new index, rewrite, both, negative result, trap to disprove, or refusal). `ruby e2e/verify.rb` proves each case against Postgres 18. See `e2e/README.md`.
- **Note (from 20260922-66):** The enclave's `quaacks teardown --run <id>` exists. The driver has to:
  - Call it at the end of every run: on success, on abort, on exception, and on signals where possible.
  - Require the `teardown` line followed by the done line.
  - Treat `store: "already_gone"` as success.
  - On `bad_run`, `bad_store_base`, or `teardown_failed`, tell the operator to check or remove `~/.quaack/runs/<id>` by hand. The enclave never sends the path.
  - Turn `next_step: "destroy_run_server"` into a plain operator message. Nothing destroys the run server automatically.
  - Add `--keep` to the run command. It skips teardown and prints the run ID and the exact teardown command for later.

### 20260927-23. Driver calls run teardown (20260922-65, part four).

The enclave's `quaacks teardown --run <id>` exists (20260922-66), but nothing in `driver/lib` calls it. Do the driver work listed in the -66 note under 20260922-65:
- Call teardown at the end of every run: on success, on abort, on exception, and on signals where possible.
- Require the `teardown` line, followed by the done line.
- Treat `store: "already_gone"` as success.
- On `bad_run`, `bad_store_base`, or `teardown_failed`, tell the operator to check or remove `~/.quaack/runs/<id>` by hand.
- Turn `next_step: "destroy_run_server"` into a plain operator message.
- Add `--keep` to the run command. It skips teardown and prints the run ID and the exact teardown command.
Then make `spec/pipeline_replay_spec.rb` assert that each run calls teardown.

- **Depends on:** 20260922-66.
- **Came from:** Build of 20260922-65, part three.
- **README:** Teardown.
- **Status:** done

### 20260927-24. Corpus replay loose ends.

These are findings from the build and reviews of 20260922-65, part three:
- Ask numbering shifts after a disproof. The counterexample loop stops at the first round that finds a mismatch, so later 10a asks get lower numbers than the prompt pack gave them, and their replies go to the wrong asks. Key replies by rewrite and round, not by a per-step count.
- orm_join's wrong rewrite (`u.name IS NOT NULL`) can't be disproved. `users.id` is `GENERATED ALWAYS`, and 10a refuses `OVERRIDING`. Either let 10a inserts set identity keys, or change orm_join's planted bug in the generator and the corpus README.
  - **Decided (2026-09-27):** Let 10a inserts use `OVERRIDING SYSTEM VALUE`, so they can set identity keys. They only load into the throwaway arena, and step 9 fixtures already use it. Update README step 10 and the insert check.
- The drift check compares only the system prompt, and it reads `prompt.md` only from the corpus, not the planted root.
- `PipelineReplay.wrong` finds `"sql"` strings with a regex, not a JSON parse. Assert that `wrong` isn't empty wherever a variant has a wrong rewrite.

- **Depends on:** 20260922-65 part three.
- **Came from:** Build and reviews of 20260922-65, part three.
- **README:** All.
- **Status:** done

### 20260927-26. Chat-friendly versions of multi-turn prompt-pack prompts.

Multi-turn prompts in `spec/fixtures/llm_corpus` (5a-5-2, 5a-6, later 10a rounds) hold `# User`, `# Assistant`, `# User` sections. Pasted into a chat window, the model can't tell the `# Assistant` section is its own earlier turn. Make `script/prompt_pack/run.rb` also write a `chat.md` next to each multi-turn `prompt.md`: one message that quotes the earlier turn plainly ("Earlier you replied with this: ...") and then gives the follow-up. Update the corpus README to say to paste `chat.md` when it exists, and to explain that the assistant turn is a planted reply. For example, 5a-5-2's planted reply holds an unqualified index so that the replacement ask happens.

- **Depends on:** 20260922-65.
- **Came from:** User, 2026-09-27, while collecting corpus replies.
- **README:** none.
- **Status:** done

### 20260923-1. Postgres 17 parser under Postgres 18.

The newest pg_query (6.2.3) ships the Postgres 17 parser, and no Postgres 18 version exists yet. The user accepted the Postgres 17 grammar for now. When pg_query fails to parse something, abort with a message that names the parser's Postgres version, so a Postgres 18-only construct is easy to spot. When pg_query ships Postgres 18 support, upgrade it and drop the special message.

- **Depends on:** 20260922-1.
- **Came from:** First review of 20260922-1.
- **README:** Anywhere pg_query parses SQL, including 3a, 5a-1, step 9, and the inbound checks.
- **Status:** done
- **Decided:** Step 3b doesn't parse the schema dump. It finds the subset tables and their FK parents from `pg_catalog`, and gets the subset from `pg_dump --table` for each one (see 20260922-18). So pg_query only parses queries and inbound SQL, and Postgres 18-only syntax in a dump doesn't matter.

### 20260923-2. Enclave deploys by gem install only.

The repo has one Gemfile and one lockfile for all three gems. So `bundle install` from a checkout on the jump server would install the driver gem, its LLM SDK once 20260922-6 adds it, and the dev tools. The enclave has to deploy by building and installing the `quaacks` gem on its own. Document that, and make the wrong way hard or impossible, for example by having the enclave executable refuse to run under a bundle that includes the driver.

- **Depends on:** 20260922-1.
- **Came from:** First review of 20260922-1.
- **README:** Where QUAACK runs.
- **Status:** done
- **Note (from 20260922-5):** The driver runs a bare `quaacks` over non-interactive ssh (`ssh -T -o BatchMode=yes -- host 'quaacks ...'`), so `quaacks` must be on PATH for a non-interactive session. The remote login shell must also be POSIX-compatible (bash, sh, or zsh). fish and csh break the Shellwords quoting.
- **Decided:** The driver builds the `quaacks` and `quaack-protocol` gems locally, copies them to the jump server over ssh, and installs them into a user gem directory there. It checks the installed version before each run. There's no gem server.
- **Decided (2026-09-27):** A separate `quaack deploy` command does the install. `quaack run` checks the installed version and refuses on a mismatch, pointing to `quaack deploy`. Install into a user-specific gem directory, never an OS-wide one. The jump servers have gcc and make, so gems with native extensions (pg_query) install from source there.

### 20260923-17. Index shape loose ends.

Minor findings from the second review of 20260923-14:
- **Untested requires.** The three `require_relative` lines added to `enclave/lib/quaack/enclave.rb` have no test. Deleting them keeps every suite green. Add a `"quaack/enclave"` use to `standalone_require_spec.rb` that reaches `IndexCandidate`.
- **Shadowed built-in names.** The built-in aggregate and window name check refuses an unqualified call to a user function that shares a built-in's name, such as `public.lead(int)`. Postgres accepts it, and `pg_get_indexdef` prints it unqualified. So `from_ddl` returns nil for such an existing index. It's rare and harmless, since the index just can't be represented. Document it. Also add a test that a column named like a built-in, such as `lag > 0`, is accepted.
- **Proportion.** The aggregate and window check guards input the mechanical generators can't produce, because a valid query's WHERE clause can't hold those calls. It also misses set-returning functions, `DEFAULT`, and `merge_action()`. Decide whether to keep it, trim it, or finish it when 5a-5 extends the shape.
- **Redundant check.** The `!sql.strip.empty?` check in `index_candidate.rb` duplicates the parse error.

- **Depends on:** 20260923-14.
- **Came from:** Second review of 20260923-14.
- **README:** 5a.
- **Status:** done

### 20260928-3. LLM provider seam, configuration, and Anthropic auth without a key.

The driver only talks to Anthropic, through `LLM::Client`, and it requires `ANTHROPIC_API_KEY`. Many operators have an OpenAI, Google, or Groq key instead. This task makes the provider pluggable and gives it configuration. 20260928-4 adds the second provider.

- Split `LLM::Client` into a provider-neutral front and a provider adapter. The front keeps today's interface and behavior: `ask(step:, messages:, max_tokens:, system:, schema:, json:)` returns text or parsed JSON, and it owns the burndown count per attempt (15b), `ReplyJSON`, the `JSON_ONLY` instruction, the error rules (`llm_auth`, `llm_rate_limited`, `llm_unavailable`, `llm_bad_request`, `llm_bad_response`), and the guard against real clients in specs. The Anthropic adapter holds everything Anthropic-specific: request shape, structured output, stop reasons, the gem's retries, and mapping its errors to the rules.
- Configuration lives in an `llm` block in `~/.quaack/driver.json`: `provider` (`anthropic` or `openai_compatible`), `model`, `base_url`, and `api_key_env`, the name of the environment variable that holds the key. Keys never go in the file. `QUAACK_MODEL` still overrides the model, and `QUAACK_LLM_PROVIDER` and `QUAACK_LLM_BASE_URL` override the others. With no `llm` block, the driver behaves as today: Anthropic, `claude-opus-5-5`. A bad block fails with a usage error that names the key, never a value.
- Anthropic auth: stop requiring `ANTHROPIC_API_KEY`. Let the anthropic gem resolve credentials in its usual order (API key, `ANTHROPIC_AUTH_TOKEN`, then an `ant auth login` profile), and map an authentication failure to `llm_auth`. `api_key_env`, when set, still wins.
- Update README.md (requirements, configuration, and the `llm_auth` row) and DESIGN.md's "Where QUAACK runs".

- **Depends on:** none.
- **Came from:** The user, 2026-09-28. Answers already given: two adapters (Anthropic, plus one OpenAI-compatible adapter that covers OpenAI, Groq, Gemini's compatible endpoint, OpenRouter, and Ollama); configuration in driver.json with env overrides; fold in keyless Anthropic auth.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `claude/quaack-readme-graphic-8iwhvt`. The full `bundle exec rake` couldn't run in the cloud session (no HypoPG image), so run it before merging to `main`. RuboCop, the driver suite, and the boundary specs passed.

### 20260928-4. OpenAI-compatible LLM adapter.

Add the second adapter from 20260928-3: the OpenAI-compatible Chat Completions API, through the official `openai` gem, with the base URL from configuration. One adapter serves OpenAI, Groq (`https://api.groq.com/openai/v1`), Google Gemini's OpenAI-compatible endpoint, OpenRouter, and local servers such as Ollama.

- Map `system` and `messages` to chat messages, and a finish reason other than `stop` to `llm_bad_response`, as the Anthropic adapter does for stop reasons.
- With `schema`, ask for `response_format` of type `json_schema` when the provider takes it. Some providers and models don't enforce schemas. For those, rely on the `JSON_ONLY` instruction and `ReplyJSON`'s validation, and if the reply doesn't validate, re-ask once with the validation error attached, then fail with `llm_bad_response`. Each attempt counts in the burndown. Decide at build time how the adapter learns whether schema mode is supported (configuration, or falling back when the API rejects it), and say which in README.md.
- Map the gem's errors to the same rules as the Anthropic adapter. Keep retries at the gem's level, counted per attempt.
- Add a fake at this adapter's HTTP edge, like `FakeLLM`, and run the existing driver LLM specs against both adapters where the behavior is shared. No spec may reach the network. An opt-in live smoke test (with `QUAACK_ALLOW_REAL_LLM=1` and a real key) may exist, but outside `rake`.
- Add `openai` to the driver gem's dependencies. It's already on `LLM_SDK_REQUIRES`, so the enclave stays barred from it. Check that the boundary specs still pass.
- Verify, before building, what structured-output support OpenAI, Groq, and Gemini's compatible endpoint offer today. Don't rely on memory.
- Where the re-ask lives: after 20260928-3, the front runs `ReplyJSON.parse` after the adapter's `reply` returns, so a "validate, then re-ask once" loop has no home in the adapter contract. Either give the front a re-ask for adapters that don't enforce schemas, or let the adapter call `ReplyJSON` itself. Say which, and keep the burndown counting every attempt.
- Document per-provider setup in README.md, including a Groq example.

- **Depends on:** 20260928-3.
- **Came from:** The user, 2026-09-28. Answer already given: prompt, validate, and retry once when the provider can't enforce a schema.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `claude/quaack-readme-graphic-8iwhvt` after two reviews and a fix round (a 200 with no `choices` crashed the adapter). The provider docs couldn't be reached, so the structured-output check in this entry is unverified; see 20260929-1. The full `bundle exec rake` couldn't run in the cloud session (no HypoPG image), so run it before merging to `main`. RuboCop, the driver suite, and the boundary and guard specs passed.

### 20260929-3. `quaack deploy`: show progress, and diagnose PATH.

`quaack deploy` is silent until it finishes, and when `quaacks` isn't on the jump server's non-interactive PATH, it only points at DESIGN.md. The user's first real deploy ended exactly that way. Make it say what it's doing and work out the fix.

- **Progress.** Print one line on stdout as each step starts: building each gem, copying each one to the host, `gem install` on the host (saying it builds pg_query from source and can take a few minutes), and checking `quaacks` over ssh. The final "installed quaacks X on host" line stays last. Errors stay on stderr.
- **PATH diagnosis.** When the check after install can't run `quaacks`, run read-only probes on the jump server over non-interactive ssh, the same way the driver reaches it. Probes are POSIX sh, because the remote login shell runs them. Find out:
  - what `ruby -e 'puts Gem.user_dir'` prints, or that `ruby` itself isn't on the non-interactive PATH;
  - whether `<user_dir>/bin/quaacks` exists;
  - whether `<user_dir>/bin` is on the non-interactive PATH;
  - the user's login shell.

  Then print the specific fix:
  - The exact line to add, such as `export PATH="<user_dir>/bin:$PATH"`, and the file to put it in: `~/.bashrc` for bash, above any line that returns early for non-interactive shells; `~/.zshenv` for zsh; for other POSIX shells, say which file to check.
  - For a shell QUAACK doesn't support (fish or csh), say that.
  - For a `quaacks` that's on PATH but isn't what was just installed, such as a different Ruby, say that instead.
  - End with the command to check the fix: `ssh <host> quaacks --version`.
- **Never change the jump server's shell config.** Only advise; the user makes the edit.
- **Messages.** Keep them to what the probes found. They're about the jump server's setup, not production data, but print only what's needed.
- Update DESIGN.md's "Deploying the enclave" and README.md's deploy step.

- **Depends on:** 20260923-2.
- **Came from:** The user, 2026-09-29, after a first real deploy. Answers already given: diagnose and advise only (the driver keeps running a bare `quaacks`, so PATH still matters), never edit the user's shell config, and progress goes to stdout with the result.
- **Design:** Where QUAACK runs, "Deploying the enclave".
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `claude/quaack-readme-graphic-8iwhvt` after two reviews and a fix round (the gem install and check progress lines could print after their step with no test failing). New `DeployDiagnosis` probes the jump server read-only over `sh -s`. The minor findings went to 20260929-6. The full `bundle exec rake` couldn't run in the cloud session (no HypoPG image, and `deploy_spec.rb:73` expects aarch64 gems), so run it before merging to `main`. RuboCop and the driver suite otherwise passed.

### 20260929-7. Say which clients `run_server_other_clients` saw.

`quaacks run-server` fails with `run_server_other_clients` when `pg_stat_activity` shows another client backend, but the operator can't tell which one. Have the error line list them, so the operator can find and stop them.

- The error line gains a `clients` field, only for `run_server_other_clients`: an Array of `{ "pid", "backend_start" }`, one per other client backend, oldest first. `pid` is a positive Integer. `backend_start` is the UTC time the backend started, as `YYYY-MM-DDTHH:MM:SSZ`. At most 20 entries, so a crowded server can't make the line huge.
- Nothing else about a client goes out: not `usename`, `application_name`, `client_addr`, `datname`, `state`, or `query`. Those are production configuration or free text. A pid and a start time are neither.
- `clients` joins the `error` entry in `Protocol::WHITELIST`. The enclave's ErrorFilter sends it only for that rule, and only if every entry has exactly that shape. Otherwise it leaves the field out, as it does for `function`.
- The driver's reply parser accepts `clients` with the same shape check, and the driver's error message names the pids and start times.
- DESIGN.md step 4 says the error names the other clients' pids and start times, and nothing else about them.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after a real `run_server_other_clients` failure.
- **Design:** Trust boundary, step 4.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after two reviews and one fix round. Round one found two tests that stayed green with the code broken: nothing checked the oldest-first order, and nothing checked the start anchor of the start-time pattern. Round one's minor findings went to 20260929-11, round two's to 20260929-12. The full check still fails on this Mac with the two failures filed as 20260929-9 and 20260929-10. They fail the same way on unchanged main. The task's own specs, RuboCop, protocol, and the boundary specs pass.

### 20260929-9. The full check fails on a Mac whose pg_dump is older than 18.

`spec/pipeline_replay_spec.rb` runs the installed `quaacks schema-dump`, which uses whichever pg_dump is first on PATH. The test server is Postgres 18. On a development Mac whose PATH has Homebrew's `postgresql@14`, every replay fails with `pg_dump_too_old`, 198 failures on 2026-09-29 on unchanged main (a762d73).

Answers from the user, 2026-09-29:

- The test harness finds a pg_dump whose major version matches the test server's. It checks the `QUAACK_TEST_PG_BIN` directory first, if that's set, then Homebrew's libpq keg (`/opt/homebrew/opt/libpq/bin`). It puts that directory first on PATH only for the `quaacks` children it starts. The operator's own shell PATH is untouched.
- If it finds none, the specs that need one fail early, once, with a clear message naming what to install or set. They never fail 198 times with `pg_dump_too_old`.
- CLAUDE.md's Development section says the full check needs a pg_dump of the test server's major version, and how the harness finds it.
- This Mac's libpq keg was upgraded to 18.6 for this.

- **Depends on:** nothing open.
- **Came from:** The full check run for 20260929-7.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after two reviews and one fix round. Round one found two problems. First, `with_env` in the prompt pack and e2e scripts took its ENV snapshot after calling the finder, so a missing pg_dump showed up as a TypeError. Second, the test that the major version comes from the image stayed green with a hardcoded 18. The minor findings went to 20260929-14 and 20260929-15. With pg_dump 14 first on PATH, the full replay spec passes: 204 examples in about 25 minutes. The root suite is slower than before, because every replay now runs its whole pipeline. 20260929-13 aims to speed that up.

### 20260929-8. `run_server_other_clients` may count QUAACK's own session.

`RunServerCheck` tells its own sessions apart from other clients by libpq's `backend_pid`. That's the pid the server sent at connect time. Behind a pooler or proxy, such as PgBouncer, it can be a pid the pooler made up, not the server backend running QUAACK's queries. Then QUAACK's own session counts as another client, and step 4 fails with `run_server_other_clients` on a quiet server.

- Get each own pid from the server with `SELECT pg_backend_pid()` on that connection, not from libpq.
- Confirmed 2026-09-29 with 20260929-7's output. The run server on port 5431 is PgBouncer in session mode. `run_server_other_clients` named pid 58297, which was QUAACK's own session. The server log shows the check excluded `$1 = '{1235762793}'`, the pid PgBouncer made up and libpq reported. The session came from 127.0.0.1, through PgBouncer.

Answers from the user, 2026-09-29:

- Support PgBouncer in session mode in front of the run server. Each client keeps one server backend for its session, so later steps that rely on one session still work.
- Transaction and statement pooling are unsupported in v1. DESIGN.md step 4 says so. Detecting them is not required.
- Build this alongside 20260929-13, as an exception to the one-task-at-a-time rule. 13 only touches the test harness.

- **Depends on:** 20260929-7.
- **Came from:** The user, 2026-09-29, who doubted the run server really had other clients.
- **Design:** Step 4.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings, so there was no fix round. `RunServerCheck` now reads each own pid with `SELECT pg_backend_pid()`. The test image runs PgBouncer 1.26 in session mode, on demand, and the spec failed with the real error through it before the fix. DESIGN.md step 4 covers poolers. The minor findings went to 20260929-16. The builder's full check passed apart from 20260929-10.

### 20260929-13. Build the prompt-pack database once per spec process.

`PromptPack.databases` builds each replay's production database from scratch: it creates it from template0, loads `script/prompt_pack/schema.sql` and `data.sql`, and runs ANALYZE. The data script generates about 420,000 rows, which takes about 3 seconds, and the pipeline replay spec does that for each of its 39 runs. The data is the same for every query. Copying a database with `CREATE DATABASE ... TEMPLATE` takes about 0.07 seconds.

- Build the loaded, analyzed database once per spec process, on the first run that needs it, and create each run's production database as a copy of it. The racetrack database is already a copy of production, so it stays as it is.
- Every copy must hold the same schema, data, extensions, and statistics as a fresh build. A spec should prove a copy matches.
- The template database must have no connections left open when it's copied, and no replay run may change it.
- `script/prompt_pack/run.rb` uses the same helper, so it gets the same speedup.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after timing the full check.
- **Design:** none. This is test harness speed only.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings, so there was no fix round. The template is built as `pack_template_building` and renamed to `pack_template` once it's complete, and it refuses connections. ANALYZE samples randomly, so two fresh builds give different `pg_stats` for orders and line_items. So the spec checks each copy against the template exactly, and against a fresh build wherever a fresh build is deterministic. The root suite went from about 26m34s to 24m27s. The minor findings went to 20260929-17 and 20260929-18.

### 20260929-19. Schema dump selects `pg_catalog` when an extension lives there.

`SchemaDump.full_dump` adds each extension's schema to the full dump's `--schema` list. `plperl` and `plperlu` live in `pg_catalog`, so on the Canvas test database of 2026-09-29 the dump got `--schema=pg_catalog`. pg_dump then tried to dump the system catalog. It warned "typtype of data type ... appears to be invalid" for every pseudo-type, and it emitted DDL for pg_catalog's own objects, which 4a would then try to load into arena.

Answers from the user, 2026-09-29:

- Never dump a system schema: not `pg_catalog`, not `information_schema`, and not any other `pg_*` schema. `--extension=<name>` alone still gets each `CREATE EXTENSION`.

To do:

- Check that arena's load, 4a, still gets every extension it needs, including one in `pg_catalog` such as plperl.
- Add a Postgres spec with an extension in `pg_catalog`, whichever is simplest to install in the test image. Show that the dump has no `--schema=pg_catalog`, and that it loads into arena.
- Confirmed as the cause of that run's `pg_dump_failed`. The user's production role isn't a superuser. With `--schema=pg_catalog`, pg_dump fails right away with `ERROR:  permission denied for table pg_authid`. A red test should reproduce that with a non-superuser role.

- **Depends on:** nothing open.
- **Came from:** The user's first real run, 2026-09-29.
- **Design:** 3b, 4a.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. `SchemaDump.system_schema?` drops `information_schema` and every `pg_*` schema from the full dump's namespaces, while `--extension` is still passed, so plperl reaches arena. The test image now installs plperl, and a read-only-role spec reproduces the user's `permission denied for table pg_authid` before the fix. The minor findings went to 20260929-22 and 20260929-23.

### 20260929-10. The leak check sees BUNDLER_VERSION in a script's environment.

`enclave/spec/leak_check_spec.rb:374` ("runs a script the same way, with no Bundler in its environment") fails on unchanged main (a762d73) on 2026-09-29. It expected no Bundler variables and got `BUNDLER_VERSION`. A likely cause is Ruby 3.4's bundled bundler re-execing into the lockfile's bundler 4.0.15, which sets `BUNDLER_VERSION`. Find the cause, and scrub the variable, or fix the check, so a script runs with no Bundler in its environment.

- **Depends on:** nothing open.
- **Came from:** The full check run for 20260929-7.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. The cause: under `bundle exec`, Ruby 3.4's bundler 2.7.2 re-execs into the lockfile's 4.0.15 with `BUNDLER_VERSION` set. That lands in `Bundler.original_env`, which `with_unbundled_env` restores, since `unbundle_env` removes only `BUNDLE_*` keys. `IsolatedInstall#isolated_env` now unsets it. The full check passed with 0 failures. The minor findings went to 20260929-24.

### 20260923-40. Allowlist loose ends.

Still open from the reviews of 20260923-33:
- EXTRACT's field match uses Unicode `downcase`, in both `predicate_atoms.rb` and `redaction/query.rb`, so `'weeK'` with a Kelvin sign is kept. Use `downcase(:ascii)`, and print the field lowercased.
- No test pins `EXTRACT_FIELDS`.

- **Depends on:** 20260923-33.
- **Came from:** The reviews of 20260923-33.
- **Design:** Step 1.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. Both EXTRACT field matches use `downcase(:ascii)`, and a kept field goes out lowercased, only on the tree copy. A Kelvin-sign `'weeK'` is redacted, and both `EXTRACT_FIELDS` sets are pinned to Postgres 18's 22 fields, checked on a real server. The minor finding went to 20260929-25.

### 20260928-6. LLM provider seam loose ends, part two.

These are minor findings from the second review of 20260928-3:
- The spec for the CLI's default client builder (`cli_run_spec.rb`, "builds the client from the block's settings") only checks `api_key_env`. A builder that drops the block's model or base_url stays green. Move the builder into a small method that takes a transport, so a spec can pass FakeLLM and assert the model and URL in `fake.asks`.
- The same spec sets `QUAACK_ALLOW_REAL_LLM=1`, which turns off the `NoNetwork` guard. Its only remaining guard is `ANTHROPIC_BASE_URL=http://127.0.0.1:9`, so a future explicit base URL could send its sentinel key to the real API from `rake`. Keep a refusal at the gem's requester in that example.
- `AnthropicAdapter` claims a given `api_key:` wins over `api_key_env`, but no spec checks it. Add one, or drop the claim.
- `quaack run` now reads driver.json. A file that exists but can't be read (EACCES) raises `Errno::EACCES` out of `DriverConfig.read`, uncaught, so the run dies with a stack trace. Rescue `SystemCallError` there as `Bad`, or as a "can't read" usage error. `start` has the same gap.

- **Depends on:** 20260928-3.
- **Came from:** Second review of 20260928-3.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. Changes: `CLI.build_client(settings, transport:)`, with a FakeLLM spec on model and URL; `NoNetwork.always_refuse`, which refuses even with `QUAACK_ALLOW_REAL_LLM=1`; a spec that a given `api_key:` wins; and an unreadable driver.json, now a clean usage error for `run` and `bad_driver_config` for `start`. The minor findings went to 20260929-27.

### 20260929-21. The full schema dump misses schemas that FK parent tables live in.

`SchemaDump.full_dump` dumps the schemas the query's tables live in, plus public. The subset follows foreign keys to parent tables in other schemas, but the full dump doesn't add their schemas. So a query on `sales.items` gets `public` and `sales`, while `sales.skus` has an FK to `audit.vendors`. Loading that full dump into arena then fails with `schema "audit" does not exist` (`arena_dump_load_failed`). The 20260929-19 builder hit this with the existing sample fixture.

This is likely to bite the user's Canvas database, where shard schemas such as `cluster44_shard_7236` may have foreign keys into other schemas.

- Add each FK ancestor's schema to the full dump's namespaces, as `ancestors` already finds them, still leaving out system schemas (20260929-19).
- Red test: the cross-schema FK fixture above, loaded into arena.

- **Depends on:** 20260929-19.
- **Came from:** The build of 20260929-19.
- **Design:** 3b, 4a.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no findings to fix. `SchemaDump.run` passes the FK ancestors, not just the query relations, to `full_dump`, so every ancestor's schema is dumped, at any depth, still without system schemas. A spec loads a two-level cross-schema chain into arena. The reviewer noted that a widely referenced parent schema, such as `auth`, is now dumped whole, and its tables must be lockable by the read-only role. Before the fix, that dump failed to load anyway. The builder's related findings went to 20260929-26.

### 20260923-22. MCV statistics loose ends.

Still open from the second review of 20260923-19:
- An invalid-UTF-8 literal on a t/f column raises `Encoding::CompatibilityError` from `strip`. It fails closed and doesn't leak.
- Optional: a real-Postgres test that pins `= false` on a nullable boolean to `freq(f)`.

- **Depends on:** 20260923-19.
- **Came from:** Second review of 20260923-19.
- **Design:** 3c.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no findings to fix. `ColumnStatistics#boolean_text` leaves an invalid-UTF-8 literal unchanged, so it misses the t/f MCVs and gets the non-MCV estimate instead of raising. The guard is defensive, since pg_query already refuses invalid UTF-8. A real-Postgres spec pins `= false` on a nullable boolean to freq(f).

### 20260923-37. Arena runner loose ends.

Still open from the second review of 20260922-46:
- `ArenaRunner` reports every 57014 as `statement_timeout`, including a self-cancel or an operator cancel. Name it `statement_canceled`, or document it. 20260926-5 fixed this for run discipline only.
- A non-StandardError from the block, followed by a failed rollback, loses the primary error. Changing `rescue Exception` to `rescue StandardError` in `in_transaction` stays green. Add a test that uses an Interrupt.
- Moving `check_fixture` after `refuse_unless_idle` stays green. It only changes which error wins when bad rows meet a busy connection.

- **Depends on:** 20260922-46.
- **Came from:** Second review of 20260922-46.
- **Design:** Step 9.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. A 57014 is `statement_timeout` only once `statement_timeout_ms` has passed since the connection call started, as in run discipline. Anything sooner is the new rule `statement_canceled`, in `arena_runner/cancel.rb`. New specs cover a self-cancel, an operator cancel, an Interrupt surviving a failed rollback, and the fixture check coming before the idle check. The minor findings went to 20260929-28 and 20260929-29.

### 20260924-1. 5a-4 loose ends.

Still open from the second review of 20260923-56:
- Changing `guarded(:cleanup_failed) { deallocate }` to another rule stays green.
- The exact-cost assertions use single-node plans only. Add one on a join.
- `CanonicalPlan` treats any `"<N>…"` index name as hypothetical, so a real index named that way is canonicalized wrong.

- **Depends on:** 20260923-56.
- **Came from:** Second review of 20260923-56.
- **Design:** 5a-4.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Note (landed 2026-09-29):** Landed on `main` after one review with no blocking findings. New specs pin `cleanup_failed` on a failed DEALLOCATE and a join's exact root cost. CanonicalPlan now treats an index name as hypothetical only when its `<oid>` is in the map SingleCandidateTest builds from HypoPG's `indexrelid`, so a real index named `"<1>..."` no longer breaks the plan gate. An oid the map leaves out now counts as a real index instead of making the plan not comparable, which is a deliberate trade-off. The minor finding went to 20260929-30.

### 20260927-25. Teardown loose ends.

These are minor findings from the review of 20260927-23:
- A second Ctrl-C, or any other signal, during teardown in the `ensure` replaces the run's original exception. No test covers this.
- `Teardown#call` rescues only `EnclaveError`. Today the transport wraps every failure in one, but any other exception raised during teardown after a failed run would mask the run's error. Broaden the rescue, or comment why it's safe.

- **Depends on:** 20260927-23.
- **Came from:** Review of 20260927-23.
- **Design:** Teardown.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. `Teardown#call` rescues any StandardError. A non-EnclaveError becomes `driver_error`, with the `quaacks teardown` hint. A signal during teardown prints the run's original error, then re-raises. The reviewer checked that printing `Class: message` for a non-EnclaveError can't carry unapproved enclave output, since the transport turns every bad reply into an EnclaveError with no cause. The minor findings went to 20260930-1.

### 20260929-17. Test the prompt-pack template's recovery from a failed build.

`PromptPack.template` in `script/prompt_pack/run.rb` builds under `pack_template_building`, renames it once the build is complete, and first drops any leftover `pack_template_building`. No test needs that. Building straight into `pack_template`, or skipping the drop, leaves the spec green. Then a data.sql or ANALYZE failure in one replay would leave a half-built template for the next replay to copy. The reviewer confirmed by hand that the real code recovers. Add a spec that plants a one-time build failure and checks that the retry produces a complete copy. Also rewrap the odd header comment at run.rb:9-10.

- **Depends on:** 20260929-13.
- **Came from:** Review of 20260929-13, round one.
- **Design:** none. Test harness only.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings to fix. A new example in spec/prompt_pack_databases_spec.rb wraps `PG.connect` so the first build's ANALYZE fails once. It checks that no `pack_template` is left, then that the retry builds a complete copy. Both mutations named here go red, and it doesn't disturb the replay specs. The header comment in run.rb is rewrapped.

### 20260929-25. Pin the guard on EXTRACT field lowercasing in the query redaction.

In `Redaction::Query#lowercase_field` (enclave/lib/quaack/enclave/redaction/query.rb), dropping `&& extract_field?(constant)` leaves every spec green. Every SQL-syntax EXTRACT's first argument would then be lowercased, recognized or not, so a redacted `'Years'` would be stored as `years`. Nothing leaks, since the value is redacted either way. Make the Kelvin test in redaction_query_spec use an uppercase ASCII letter, such as `'WEEK'` with the Kelvin sign, and expect the placeholder map to keep the original case.

- **Depends on:** 20260923-40.
- **Came from:** Review of 20260923-40, round one.
- **Design:** 3g.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. The Kelvin example in redaction_query_spec now uses `'WEEK'` with the Kelvin sign, and expects the placeholder value to keep its case. Dropping the `extract_field?` guard, or reintroducing the Unicode downcase from 20260923-40, turns it red. The full rake on the branch passed with 0 failures.

### 20260929-23. Pin the underscore in `SchemaDump.system_schema?`.

Changing `start_with?("pg_")` to `start_with?("pg")` leaves every spec green. That version would silently drop a user schema like `pgbouncer` (common for PgBouncer's auth_query) or `pgaudit_log`, and the query's tables would be missing from the dump and arena. Add an example with such a schema holding a query table, and assert it stays in the namespaces and the DDL.

- **Depends on:** 20260929-19.
- **Came from:** Review of 20260929-19, round one.
- **Design:** 3b.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. A Postgres example keeps `pgbouncer` and `pgaudit_log` query tables in the dump. A new unit spec pins `system_schema?` on system and look-alike names, which were checked on a real server: Postgres reserves only a lowercase `pg_` prefix. The minor finding went to 20260930-2.

### 20260928-5. LLM provider seam loose ends.

These are minor findings from the build and review of 20260928-3:
- A set-but-empty `ANTHROPIC_API_KEY` hides other credentials. The anthropic gem treats `""` as a set key, so it skips `ANTHROPIC_AUTH_TOKEN` and profile discovery, then sends no credential header. With `ANTHROPIC_AUTH_TOKEN` also set, the run fails `llm_auth` after one counted attempt. With a valid `ant auth login` profile, it fails with "no Anthropic credentials". Refuse up front with "ANTHROPIC_API_KEY is set but empty", or pass the token or discovered credentials explicitly. Also fix the comment on `AnthropicAdapter#credentials?`, which says an empty key is sent as no header.
- `Start`'s `rescue DriverConfig::Bad` has no spec. A driver.json of `not json`, `[1]`, or `null` gives `bad_driver_config` today, but deleting the rescue keeps every spec green. Add those cases to `start_spec.rb`.
- The anthropic gem prints precedence warnings on stderr, such as "ANTHROPIC_API_KEY is set and takes precedence over ... auto-discovery", even when `api_key_env` supplied the key. They leak no values, but they mislead. Silence them or explain them.

- **Depends on:** 20260928-3.
- **Came from:** The build report and round-one review of 20260928-3.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. With no key passed, the first of `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` that's set must be non-empty. Otherwise the run fails with `llm_auth: <VAR> is set but empty` before any attempt. When QUAACK passes the key, a `GivenKeyClient` subclass skips the gem's misleading precedence warning. start_spec covers `not json`, `[1]`, and `null`. The builder worked while the safety classifier was down. The reviewer confirmed the diff touches only the five files the task calls for. The minor findings went to 20260930-3.

### 20260929-15. `TestPgDump.server_major`'s regex is under-tested.

The test "reads the major version from the image's FROM line" in `spec/test_pg_dump_spec.rb` uses a fixture Dockerfile with no digits before `FROM`. So weakening the regex to `/(\d+)/` keeps it green. Put a line with a number before `FROM` in the fixture, such as `ARG PG_MAJOR=16` or a comment naming a version, and check that the test still reads the `FROM` line's major.

- **Depends on:** 20260929-9.
- **Came from:** Review of 20260929-9, round two.
- **Design:** none. Test harness only.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings to fix. The fixture now has a comment naming `FROM postgres:16` and an `ARG PG_MAJOR=16` before `FROM postgres:17`, so an unanchored or digit-anywhere regex reads 16 and goes red. Dropping the `\b` isn't caught. That's harmless for the real Dockerfile, which pins a plain major.

### 20260929-28. Arena runner cancel tests: pin the start time, and bound the wait.

Minor findings from the review of 20260923-37:

- No test pins that `ArenaRunner` records a statement's start time per connection call. Recording one start for the runner's whole life leaves every spec green. StepNine reuses one runner across scenarios, so after the timeout's worth of total time, an operator's cancel would read as `statement_timeout`. Add a test with a short timeout: two `pg_sleep` calls, each under it, then a self-cancel. Expect `statement_canceled`.
- In `arena_runner_postgres_spec.rb`, the operator-cancel test's canceler thread polls for the `PgSleep` wait event with no deadline. If a regression stops the INSERT from running, `canceler.join` blocks forever and the suite hangs. Give the loop a deadline.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** Step 9.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. A new test with a 2000 ms timeout runs two `pg_sleep(1.3)` calls, then a self-cancel, and expects `statement_canceled`. It goes red if the runner keeps one start time for its whole life. The operator-cancel test's poll loop now gives up after 10 s instead of hanging. It passed 10 times under heavy load with no flakes. The minor findings went to 20260930-5.

### 20260929-12. `clients` shape checks: round-two test gaps.

Minor findings from the second review of 20260929-7. The code is correct, and none of these can leak today, because the enclave builds the start time with a fixed-format `to_char`.

- Changing `\A` to `^` in the start-time pattern survives the specs, in both the enclave's ErrorFilter and the driver's reply parser. So does changing the driver's `\z` to `$`. Add cases with the start time after or before a newline to both suites.
- The driver never tests keeping exactly 20 clients. With the driver's limit at 19, a real 20-client error line would lose its `clients` field and the specs stay green.
- Whether the UTC test in `enclave/spec/run_server_check_postgres_spec.rb` catches a 12-hour clock (`HH12`) depends on the time of day the suite runs. Pin it to an afternoon hour.
- The enclave never tests its exact-class checks on an Array or Hash subclass, only on a String subclass. Loosening them to `respond_to?` survives. Egress's own plain-data check backs them up.

- **Depends on:** 20260929-7.
- **Came from:** Review of 20260929-7, round two.
- **Design:** Trust boundary, step 4.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. New tests cover four gaps. Newline cases pin the start-time anchors in ErrorFilter and the driver. The driver keeps exactly 20 clients. Array and Hash subclasses are dropped by ErrorFilter's own exact-class check. The start-time `to_char` is now the constant `BACKEND_START_SQL`, tested on a fixed afternoon timestamp, so HH12 is caught at any time of day. The minor findings went to 20260930-6.

### 20260930-4. An assertion in index_candidate_expression_spec passes a value as its failure message.

The enclave suite prints "WARNING: ignoring the provided expectation message argument(5) since it is not a string or a proc", and the same for `(:lower)`, from enclave/spec/index_candidate_expression_spec.rb:50. The line is `expect { key_column.new(expression: bad) }.to raise_error(ArgumentError, /expression/), bad`, inside a loop over bad inputs. `bad` is only meant to label which input failed, and RSpec ignores it for the non-string inputs `5` and `:lower`. The assertion still runs for every input, so nothing is untested. Pass `bad.inspect` so the label works and the warning goes away.

- **Depends on:** nothing open.
- **Came from:** The build of 20260929-15.
- **Design:** 5a-3.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. The label is now `bad.inspect`, so the warning is gone and a failure names its input. No other spec file had the warning.

### 20260930-2. Pin that `system_schema?` matches `pg_` only as a prefix.

Changing `start_with?("pg_")` to `include?("pg_")` in `SchemaDump.system_schema?` leaves every spec green. That version would drop a user schema such as `app_pg_stats`, and its query tables would be missing from the dump and arena. Add a name like `app_pg_x` to the "leaves every other schema to the user" list in enclave/spec/schema_dump_spec.rb.

- **Depends on:** 20260929-23.
- **Came from:** Review of 20260929-23, round one.
- **Design:** 3b.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. `app_pg_x` in the user-schema list turns `include?("pg_")` and `match?(/pg_/)` red.

### 20260930-3. Anthropic credential checks: minor findings.

Minor findings from the review of 20260928-5:

- `GivenKeyClient#warn_env_shadow(**)` accepts only keyword arguments. If the anthropic gem starts passing positional arguments, building the client raises ArgumentError. Use `(*, **)`. A rename is already caught, because llm_client_spec's warning example goes red.
- README.md and DESIGN.md read as if any empty Anthropic variable fails the run. Only the first of `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` that's set is checked. Tighten the wording.
- When `api_key_env` names a variable that's set but empty, the message is "`<VAR>` isn't set", while the new check says "is set but empty". Make them agree.

- **Depends on:** 20260928-5.
- **Came from:** Review of 20260928-5, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. An `api_key_env` variable that's set but empty now says "is set but empty", while an unset one still says "isn't set". `GivenKeyClient#warn_env_shadow` takes `(*, **)`, pinned by a spec that calls it with positional arguments. README.md and DESIGN.md say which empty variable fails a run. The minor findings went to 20260930-8.

### 20260929-11. `run_server_other_clients` clients list: minor test gaps.

Minor findings from the first review of 20260929-7. Each is untested, but none is visible outside the enclave on a realistic setup.

- `RunServerCheck` returns nil rather than `[]` when every other client leaves between the count query and the list query. Changing that to `[]` survives the specs. ErrorFilter drops an empty Array, so nothing changes on the wire. Pin it, or drop the special case.
- In ErrorFilter's client shape check, dropping the key-order check survives the specs. A Hash with its keys reversed then goes out, and the driver drops it, because its key check cares about order. Add a reversed-key-order case, or make both sides agree on whether order matters.
- `ORDER BY pid` passes the specs as well as `ORDER BY backend_start, pid`. They differ only across pid wraparound.

- **Depends on:** 20260929-7.
- **Came from:** Review of 20260929-7, round one.
- **Design:** Step 4.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. `RunServerCheck` now returns `[]` rather than nil when no client is left to name, and ErrorFilter already drops an empty list. Reversed-key-order rows on both sides pin that key order matters. Two new Postgres tests shadow `pg_stat_activity` with a temp view: one where the list comes back empty after a non-zero count, and one where the older client has the higher pid. The review found that the check's unqualified catalog names can be shadowed through search_path. That went to 20260930-9.

### 20260930-7. The OpenAI-compatible adapter says "isn't set" for an empty key variable.

In driver/lib/quaack/driver/llm/openai_compatible_adapter.rb (about line 113), the key variable named by `api_key_env`, or `OPENAI_API_KEY`, is reported as "`<VAR>` isn't set" when it's set but empty. Since 20260930-3, the Anthropic adapter tells the two apart: "isn't set" versus "is set but empty". Make the OpenAI-compatible adapter match, and test both messages.

- **Depends on:** 20260930-3.
- **Came from:** The build of 20260930-3.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings. `named_key` says "isn't set" for an unset variable and "is set but empty" for an empty one, as the Anthropic adapter does. Specs cover both the `api_key_env` variable and `OPENAI_API_KEY`, and check that no attempt is made or counted.

### 20260929-24. Scrub every Bundler variable, not a named list.

Minor findings from the review of 20260929-10:

- `IsolatedInstall#isolated_env` unsets Bundler variables by name. Another `BUNDLER_*` in a developer's shell, such as a leftover `BUNDLER_ORIG_*`, still reaches the child. The leak check then fails loudly, so nothing slips through. Unset every key matching `/\ABUNDLE/` in `ENV` and `Bundler.original_env` instead.
- `Deploy::UNBUNDLED` (driver/lib/quaack/driver/deploy.rb) and deploy_spec's `clean` env don't unset `BUNDLER_VERSION`. It's harmless today, since `gem build` ignores it and ssh doesn't forward it. Add it for consistency with deploy_diagnosis_spec.

- **Depends on:** 20260929-10.
- **Came from:** Review of 20260929-10, round one.
- **Design:** none. Test harness and deploy only.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. `isolated_env` unsets every `/\ABUNDLE/` key in `ENV`, and it's always computed inside `Bundler.with_unbundled_env`, where `ENV` is what the child inherits. So a separate `Bundler.original_env` scan isn't needed. `Deploy::UNBUNDLED` also drops `BUNDLER_VERSION`, and a deploy_spec example pins what `gem build` sees. The minor finding went to 20260930-10.

### 20260930-1. Teardown: capture the run's error exactly.

Minor findings from the review of 20260927-25:

- `Teardown.around` takes the run's in-flight error from `$ERROR_INFO` in its `ensure`. That's exact today, but if `around` is ever called from inside a rescue body, a successful run that gets a signal during teardown would report the outer error as the run's. Capture it explicitly, with `rescue Exception => e; run_error = e; raise`, or add a comment.
- A signal that arrives while the `rescue StandardError` clause is printing, or in `around` after `call` returns, still loses the run's error. So does a non-StandardError from the transport, such as a LoadError. Both need a tiny window or an unusual setup.

- **Depends on:** 20260927-25.
- **Came from:** Review of 20260927-25, round one.
- **Design:** Teardown.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no findings to act on. `Teardown.around` captures the run's error with a `rescue Exception` instead of reading `$ERROR_INFO`. `call` handles signals first, then treats any other exception, such as a LoadError, as `driver_error`, which never masks the run's error. The instant-long signal windows are documented in the class comment, not closed. The reviewer noted that an `exit` from a transport during teardown now reports `driver_error`. Its status is kept when the run succeeded, and it gives way to the run's error otherwise. No transport calls `exit` today.

### 20260930-8. Anthropic credential docs and one spec line: tidy.

Minor findings from the review of 20260930-3:

- README.md:190 is one long sentence ("So does an empty `ANTHROPIC_API_KEY`, or an empty `ANTHROPIC_AUTH_TOKEN` when ..., since ..."). DESIGN.md:139's parenthetical is dense too. Both are accurate. Split them into short sentences, in the house style.
- In driver/spec/llm_client_spec.rb:415, the second assertion of the positional-arguments example checks only that `warn_env_shadow` returns nil. An override that prints and returns nil would pass it. Add `not_to output.to_stderr`, as the first assertion has.
- The class comment at anthropic_adapter.rb:16-18 has uneven line lengths after the reflow.

- **Depends on:** 20260930-3.
- **Came from:** Review of 20260930-3, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. The README and DESIGN credential text is now in short sentences, checked against the code. The positional-arguments spec also checks stderr on the keyword call, which catches an override that warns and returns nil. The adapter comment is rewrapped. The minor findings went to 20260930-12.

### 20260930-9. Qualify the catalog names the run server check reads.

`RunServerCheck`'s `CLIENTS_SQL` and `OTHER_CLIENTS_SQL` read `pg_stat_activity`, and `PLANNER_SQL` reads `pg_settings`, without `pg_catalog.`. Those unqualified names can be shadowed. In the review of 20260929-11, the reviewer set `search_path = public, pg_catalog` on the run server's database and created an empty `public.pg_stat_activity` table. The quiet check then passed with another client connected. If such a table had `pid` and `backend_start` columns, its values would go out as "clients", still in the pid and timestamp shape. The setup is unusual, but the fix is cheap.

- Qualify every catalog relation and function the run server check reads with `pg_catalog.`, and check the rest of step 4, such as `Inventory::Production`'s settings SQL, for the same gap. 20260924-24 already notes `current_setting` and `json_array_elements_text` there.
- Red test: shadow `pg_stat_activity` through the database's search_path, with another client connected, and expect `run_server_other_clients`.
- Qualifying the name breaks the temp-view technique of two tests from 20260929-11: "names no client, and still fails, when none is left to name" and "names the oldest other client first, even when its pid is the higher one". Replace it, for example by running the check's SQL constants against a stand-in source.
- Comment nits from the same review: run_server_check.rb:48's "none if none is left to name" should say "an empty list". error_filter.rb:37-39 should say the two keys must come in that order.

- **Depends on:** 20260929-11.
- **Came from:** Review of 20260929-11, round one.
- **Design:** Step 4.
- **Status:** done
- **Note (landed 2026-09-30):** Landed on `main` after one review with no blocking findings. Every catalog relation and function in `RunServerCheck` and `Inventory::Production` is `pg_catalog.`-qualified, including `count(*)`, `to_char`, and the `text` cast. The one exception is `$1::json`, since `json` is a keyword. Shadow tests plant look-alikes in `public` under `search_path = public, pg_catalog` and show both still read the real catalog. The two temp-view tests now swap only the FROM clause of the real constants. The follow-ups went to 20260930-13 and 20260930-14.

### 20261001-1. `quaack run` prints the LLM error's detail.

When an LLM call fails, `quaack run` prints only the rule, such as `quaack run failed: llm_bad_request`, so the operator can't tell why the API refused. The detail is already on `LLM::Error#message` (the provider's own error text; for `llm_auth` it's just the status). Print the whole message for `LLM::Error`, such as `quaack run failed: llm_bad_request: <provider's message>`. Keep printing only the rule for enclave errors. The detail comes from the LLM provider and is printed on the laptop, so it doesn't cross the trust boundary. Update the comment above `run_command` and DESIGN.md wherever it says a run failure prints only its rule.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, blocked on an unexplained `llm_bad_request` during an end-to-end test.
- **Design:** The `quaack run` command.
- **Status:** done

### 20261001-2. A failed LLM call says which step it was and how big the request was.

A run against Groq failed with "Please reduce the length of the messages or completion", and nothing said which step overflowed or what filled the request. When an LLM call fails, add to the `LLM::Error` message: the step (such as `5a-5`), `max_tokens`, the system prompt's size in characters, and each message's role and size. When a message holds a JSON payload (the ```json block the steps send), also give each top-level key's size in characters, largest first. Report only sizes, roles, step names, and key names, never content. Do this once, in `LLM::Client`, so every step and adapter gets it.

- **Depends on:** 20261001-1.
- **Came from:** The user, 2026-10-01, blocked on a context-length 400 from Groq during an end-to-end test.
- **Design:** The `quaack run` command; LLM client.
- **Status:** done

### 20261001-3. Trim the LLM payloads to fit a 131k-token window.

A run against Groq (`openai/gpt-oss-120b`, 131k tokens) overflowed at 5a-5. The size report from 20261001-2 showed 550k characters: mechanical_results 322k, schema 154k, stats 52k, and plan 14k. The user settled the cut on 2026-10-01:

- **mechanical_results:** Every candidate keeps its DDL, its sources, whether the planner used it, its total cost per literal, its size, and any refusal. Only the baseline and the single best candidate keep full plans. The best candidate is one the planner used, with the lowest total cost summed over the literals.
- **Schema:** Send only the query's own tables (the run's `relations`), not their FK parents, plus the indexes and constraints on them. Strip pg_dump's noise: SET and set_config lines, comments, COMMENT ON, ownership, grants, and sequence statements. Keep types, enums, and domains. Use pg_query to split and classify the statements. The stored `schema_subset` stays whole, since fixtures and arena need the FK parents.
- **Stats:** Send only the columns of the query's own tables, to match the schema.

Apply the same trimming to the 6a payload (`rewrite_payload`) wherever it sends the same sections. Update DESIGN.md (the 5a-5 and 6a payloads) to say what's sent.

- **Depends on:** 20261001-2.
- **Came from:** The user, 2026-10-01.
- **Design:** 3b, 5a-5, 6a.
- **Status:** done

### 20261001-8. `quaack run` shows its progress.

`quaack run` is silent until it finishes or fails, so the operator can't tell what it's doing or how much is left. Print a progress line to stderr as each step starts, naming the step and where it falls in the run, such as `quaack: [5/18] 5a-5 generator three (LLM)`. Also print a line when a step is skipped because a resumed run already has its output, such as `quaack: [3/18] index-search: already done, skipping`, and when an LLM ask starts and each time it's retried. Lines carry only step names, counts, and timings, never data from the enclave. Stdout stays as it is today. Match the style of `quaack deploy`'s progress lines (20260929-3). Open question to settle before building: should a step that takes a long time also print how long it has been running, or is the start line enough?

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, during an end-to-end test.
- **Design:** The `quaack run` command.
- **Status:** done

### 20261001-9. The full schema dump always includes the `dba` schema.

Arena failed to load 3b's full dump with `arena_dump_load_failed`: the dump holds functions that reference the `dba` schema, which the dump didn't include. To unblock the end-to-end test, `quaacks schema-dump` always adds `dba` to the namespaces it passes to `pg_dump --schema`, like `public`, but only when production has a schema of that name, so a database without one still works. The subset that reaches the LLM doesn't change. Update DESIGN.md 3b. 20261001-10 replaces this with a general fix.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, blocked on arena_dump_load_failed during an end-to-end test.
- **Design:** 3b.
- **Status:** done

### 20261001-12. `quaack run`'s progress lines say in plain English what each step does, and 12a shows each index it builds.

The progress lines from 20261001-8 work, but they use DESIGN.md's step IDs (`5a-5 generator three`, `4b arena-setup`), which mean nothing to someone who hasn't read DESIGN.md. Rewrite each step's line in plain English, keeping the ID in parentheses at the end, such as `quaack: [2/17] Asking the LLM for index ideas the mechanical search missed (5a-5)`. Do the same for the lines for each rewrite and for the LLM ask lines. A second ask in the same step, such as 5a-5's replacement round, should say what it is (`asking again for replacements`) and not repeat the first line.

12a (`index-build`) can take a long time. Have it report each index as it starts, such as `quaack: [10/17] building index 1/23: CREATE INDEX quaack_505c… ON cluster44_shard_7236.submissions USING btree (id, assignment_id)`. The DDL shown must be the redacted form the enclave already lets out (CandidateDdlRedaction: `?` in place of any constant that isn't a low-cardinality MCV), never the stored DDL with its literals. That needs the enclave to send a progress message for each index while it works, and the driver to print it as it arrives, not after the step exits. Today the transport reads the whole reply after the process ends, so this means the transport has to stream. Any message that arrives early must be one of a small, fixed set of progress types, and it carries only what's listed here.

- **Depends on:** 20261001-8.
- **Came from:** The user, 2026-10-01, during an end-to-end test.
- **Design:** The `quaack run` command, 12a, the transport.
- **Status:** done

### 20260929-27. LLM seam: minor findings.

Minor findings from the review of 20260928-6:

- No spec checks that `NoNetwork.always_refuse` resets its flag after an exception inside the block. A reset only on normal exit stays green. That fails safe (the guard stays stricter), but add one example that raises inside the block, then checks that a request reaches the closed port with the opt-in set.
- `DriverConfig.read` treats an unreadable `~/.quaack` directory (mode 000) as a missing driver.json, since `File.file?` returns false. `run` then silently uses the default Anthropic settings, and `start` says `no_driver_config`. Refuse an existing but unreadable `~/.quaack` like an unreadable file. 20260929-4 touches the same code.

- **Depends on:** 20260928-6.
- **Came from:** Review of 20260928-6, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-10-01):** Landed on `main` after one review with no blocking findings. `DriverConfig.read` now stats driver.json: a missing path (ENOENT, ENOTDIR) still counts as no config, but any other error, or something that isn't a regular file, is refused with "can't read ~/.quaack/driver.json". A spec pins that `NoNetwork.always_refuse` resets after a block that raises. The follow-ups went to 20261001-14 and 20261001-15.

### 20260930-11. A `bedrock` LLM provider: Anthropic models on AWS Bedrock.

The driver's `llm` block accepts only `anthropic` and `openai_compatible`, so QUAACK can't call Anthropic models on AWS Bedrock with AWS credentials. The anthropic gem already ships `Anthropic::BedrockClient`, which signs requests with SigV4 using the standard AWS credential chain. It needs the `aws-sdk-bedrockruntime` gem.

Answers from the user, 2026-09-30:

- Add a third provider, `"provider": "bedrock"`, backed by `Anthropic::BedrockClient` through a new adapter behind the provider-neutral client, like the other two.
- Credentials come from the standard AWS chain: environment variables, `~/.aws` profiles, and SSO. A Bedrock API key in `AWS_BEARER_TOKEN_BEDROCK` also works, since the client reads it itself. QUAACK stores no credentials.
- The llm block takes optional `aws_region` and `aws_profile`, plus the usual `model` and `base_url`. `model` is required, since Bedrock model IDs vary by region and inference profile, so there's no default. Check the new keys the way the block's existing keys are checked. A bad value is a usage error naming the key, never the value.
- Map the client's errors onto the existing rules: `llm_auth`, `llm_rate_limited`, `llm_unavailable`, `llm_bad_request`, `llm_bad_response`. That includes AWS credential errors raised before a request is sent, so no SDK exception escapes.
- Add `aws-sdk-bedrockruntime` as a driver dependency only. The enclave must never depend on it: add its require name to `LLM_SDK_REQUIRES` in spec/support/boundary.rb, and keep the boundary specs green.
- No spec may reach AWS. Keep the `NoNetwork` guard working for the new client's requests, and fake at the transport edge as the other adapters' specs do.
- Document it in README.md's LLM setup section and DESIGN.md's LLM client section.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-30.
- **Design:** Where QUAACK runs, LLM client.
- **Status:** done
- **Note (landed 2026-10-01):** Landed on `main` after one review with no blocking findings. `BedrockAdapter` resolves AWS credentials through the standard chain, or takes `AWS_BEARER_TOKEN_BEDROCK`, and maps credential and request failures onto the existing rules without a cause. The llm block takes `aws_region` and `aws_profile`. `aws-sdk-bedrockruntime` is a driver dependency only. The follow-ups went to 20261001-16.

### 20261001-21. Mechanical rewrite rules.

**Needs a design. The user, 2026-10-01: settle this before the report work (20261001-17 to -20). It's a critical part they expected to exist already.** QUAACK has no mechanical rewrite rules, and DESIGN.md never had any. The two mechanical generators (5a-1, 5a-2) propose indexes only. Rewrites come from the LLM (6a) and the operator (step 7) and nowhere else, so a weak model means few rewrites, or none. In run 20261001T210856Z-3b7041a3 the LLM gave one, and step 8 found it planned exactly like the original. The README's opening ("QUAACK has mechanical rules to generate candidates that should help") reads as if rewrites were covered. Fix it either way.

The idea: a generator of sound, catalog-checked transformations that runs in the enclave before 6a, as 5a-1 and 5a-2 run before 5a-5. Each rewrite it makes carries its rule's name and its assumptions in 6b's vocabulary, and goes through steps 8 to 14 like any other. The report then says which rule proposed what.

What rules could do for that run's query: `assignments.id` is the primary key, so `a.id IN (SELECT a2.id FROM assignments a2 JOIN ... WHERE P)` names the same row twice. A rule can drop the inner `assignments`, move its predicates to the outer one, and leave `EXISTS (... WHERE s2.assignment_id = a.id ...)`. That's most of the rewrite the user wrote by hand. The hand rewrite goes one step further and folds the subquery's own join to `submissions` into the outer one, which is right only if a content participation always belongs to its submission's own user. No constraint says so, so no sound rule can assume it, and step 9 or 10 would likely disprove it if the operator submitted it. Whether an operator should be able to assert an invariant the schema doesn't state is a separate question.

- **Depends on:** None.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** Step 6. Needs a new section.
- **Open questions:** Which rules are in version 1. Whether rules chain. Whether the LLM is told what the rules already made. Whether operators can assert invariants.
- **Status:** done
- **Note (2026-10-01):** The user approved the five starting rules, chaining, and running rule-made rewrites through steps 9 and 10, and asked that adding rules stay easy. The design is DESIGN.md 6c. The work is 20261001-22 to -28. Operator-asserted invariants are left for later.

### 20261001-22. 6c: the rule generator, and `key_in_self_join`.

Build DESIGN.md 6c's generator in the enclave gem, with its first rule.

- A rule is one object: a name, a description, and a method from a pg_query parse tree and catalog facts to zero or more rewritten trees, each with its assumptions in 6b's vocabulary. The generator holds a list of rules and knows nothing about any one of them. Adding a rule is one file and one line.
- The generator chains: breadth first, list order, at most two rules deep, duplicates by deparsed SQL dropped, at most five kept.
- `key_in_self_join`, as 6c's table says, including the `UNION ALL` arms.
- `quaacks rewrite-rules --run <run ID>`: runs the generator on the redacted query, puts each result through `rewrite-check`'s checks (inbound, 6b, structural), stores survivors as `rewrite_<n>` with `"source" => "rule"` and `"rules" => [names]`, writes `rewrite_rules_applied`, adds it to `status`, and sends one `rewrite_outcome` each. 6a's and step 7's entries get `"source"` too (`llm`, `operator`).
- Test on real Postgres that each rule's output returns the same rows as its input, on data that would expose a wrong one, and that the rule doesn't fire when the key isn't unique or is nullable.

- **Depends on:** None open.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after two reviews with no blocking findings. `RewriteRules.generate` chains a list of rules; a rule has `name`, `description`, and `rewrites(parse, catalog)`. `key_in_self_join` fires only on a top-level AND condition and refuses anything not clearly safe. `quaacks rewrite-rules` shares `RewriteCheck.check` with `rewrite-check`, and every stored rewrite now has a `source`. The builder changed 6c: a rule may run on its own output, and the marker holds the duplicate and over-cap counts. Adding a rule is one file and two lines. The follow-ups went to 20261002-1.

### 20261001-23. 6c: run the rules from `quaack run`, and count them.

The driver calls `rewrite-rules` before 6a unless `rewrite_rules_applied` is stored. A rerun stores its rewrites again, so the marker is the only guard; the marker has no per-rule counts, which 15b's row needs. Record the 6c burndown stage (add `6c` to the protocol's stages). `report-payload` sends each rewrite's source and rule names, and flags a rule-made rewrite that steps 9, 10, or 14c disproved as a QUAACK bug. Extend the replay spec to cover a rule-made rewrite end to end. Reword the README's opening and step list to say rules propose rewrites too.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c, 15b.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. `quaack run` calls `rewrite-rules` before 6a, with no LLM call. A rerun of the step changes nothing. The 6c burndown record counts results by their last rule. `report-payload` sends each rewrite's `source` and `rules`, and `rule_bugs`: rule-made rewrites that step 9, step 10, or a real 14c mismatch disproved. A 14c timeout or `unsupported_order` isn't one. The replay spec runs a rule-made rewrite end to end. The follow-ups went to 20261002-2.

### 20261002-13. Two bedrock driver specs fail on `main`.

Two driver specs fail on `main`, every run, whatever the environment:

- `driver/spec/bedrock_adapter_spec.rb:179` expects `e.message` to be `"llm_auth: AWS refused the credentials (403)"`, but it's `"... (403) [step 5a-5, max_tokens 1000, system 0 chars, messages: user 31]"`.
- `driver/spec/cli_run_spec.rb:548` expects stderr `"quaack run failed: llm_auth\n"`, but it's `"quaack run failed: llm_auth: no AWS credentials: set AWS_ACCESS_KEY_ID ..."`.

The bedrock provider (20260930-11, commit e23b414) was written before 20261001-1 (`quaack run` prints the LLM error's detail, merged 85e4332) and 20261001-2 (a failed LLM ask says its step and request sizes, merged 6f22fae) landed. Those two changed the messages on purpose, and the bedrock specs weren't updated. Check what DESIGN.md and those two tasks say the messages should be. If the code is right, fix the specs, and make sure the fixed assertions are still specific: they must still prove the adapter doesn't quote AWS's own message and doesn't retry. If the code is wrong, fix the code with a failing test first. Check the other bedrock and provider specs for the same staleness.

- **Depends on:** 20260930-11, 20261001-1, 20261001-2.
- **Came from:** The baseline full check before 20261002-11, 2026-10-02. (First filed as 20261002-12, which another session had already taken for the `copilot_cli` provider.)
- **Design:** The driver's LLM client.
- **Status:** done
- **Note (landed 2026-10-02):** The code was right, and only the specs were stale. The two specs now expect the request-size suffix and the printed LLM detail. They still assert that AWS's message (a sentinel) never appears and that there's exactly one call. Mutation checks confirmed both go red. The first review was clean. The sandbox's block on `~/.config/anthropic` went to 20261002-14. Another machine fixed the same two specs on its own (73678d1), with an exact `eq` on the whole message, which is stricter. Merging origin/main kept that version.

### 20261002-11. 6c keeps up to ten rewrites.

With a dozen rules, a cap of five crowds out useful results. Raise `RewriteRules::MAX` to 10, keep `DEPTH` at 2, and update DESIGN.md 6c ("Keep at most five rewrites") and any spec that pins five.

- **Depends on:** 20261001-22.
- **Came from:** The user, 2026-10-02.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, a second review, and a round that fixed only the tests, checked by a third reviewer. `MAX` is 10 and `DEPTH` stays 2. DESIGN.md 6c and README's burndown text say ten. The cap specs, the unit spec and the `rewrite-rules` step spec, use eleven unique rule rewrites plus two duplicates. They assert that rule1 to rule10 are kept, that rule11 is over the cap, and the exact `over_cap` and `duplicate` counts. The mutations `last(MAX)`, MAX=9, MAX=11, counting duplicates as over the cap, and disabling duplicate detection all go red. The full check passed after merging the other machine's three rules.

### 20260929-4. Say why driver.json is bad.

`quaack start` answers `bad_driver_config` for four different problems and doesn't say which, so the user can't tell what to fix. It happened on the user's first real `quaack start`, right after adding an `llm` block. Name the file and the problem, without quoting its contents:
- not valid JSON, with the line and column from the parser, never the parser's message, since it can quote the file;
- valid JSON but not an object;
- no `jump_command`;
- `jump_command` isn't one non-blank line.

Keep the rule `bad_driver_config` in each message, so scripts still match it. `quaack run` reads the same file for its `llm` block (`DriverConfig`), so give its errors the same detail. Show a complete driver.json example, with both `jump_command` and `llm`, in README.md. 20260928-6 already covers an unreadable file (EACCES). Do it here too if it fits naturally.

- **Depends on:** 20260928-3.
- **Came from:** The user's first real `quaack start`, 2026-09-29.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, a second review, and a round the user allowed that fixed only the specs, checked by a third reviewer. Messages read `bad_driver_config: <path>: <problem>`. The problems are: not valid JSON (line and column only, never the parser's message); not an object; can't be read (permission denied); not a file; no `jump_command`; and `jump_command` isn't one non-blank line. `DriverConfig.read` validates `jump_command` whenever driver.json exists, so `quaack start` and `quaack run` share the checks. A missing driver.json still works for `quaack run`. Sentinel specs show that the file's contents never appear. README shows a complete driver.json. The answers: the message shape is rule, then path, then problem; the EACCES cause is included.

### 20261001-25. 6c rule: `not_in_to_not_exists`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. The rule fires only on a top-level ANDed `x NOT IN (SELECT y ...)` or `NOT (x IN ...)`, with x and y plain qualified columns the catalog proves not null, neither on the nullable side of an outer join. The correlation is `x = y`. A subquery table that shadows the outer one gets a fresh alias. It refuses `<> ALL`, row-valued NOT IN, and set-operation or grouped subqueries. Three helpers moved into `Tree`. The follow-ups went to 20261002-3.

### 20261001-26. 6c rule: `distinct_join_to_exists`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. `SELECT DISTINCT` of one table's plain columns or its `*` over inner or cross joins becomes that table with one `EXISTS` holding every condition that reads the others, without the DISTINCT. It fires only when the select list holds a single-column key the catalog proves unique and not null; LIMIT or OFFSET only when the ORDER BY names that key. `Catalog#columns` lists a table's columns; `Tree.tables?` moved from `key_in_self_join`. The follow-ups went to 20261002-4.

### 20261001-24. 6c rule: `or_to_union`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** 6c.
- **Status:** done
- **Note (landed 2026-10-02):** Landed on `main` after two reviews with no blocking findings. A top-level OR whose arms read different tables or subqueries becomes a UNION of one arm each, every arm selecting the columns the query uses plus a unique not-null key of each FROM table; the select list, aggregates, DISTINCT, ORDER BY, LIMIT and OFFSET read that UNION as a derived table, so duplicate join rows survive and `count(*)` stays right. It refuses GROUP BY, outer joins, composite keys, same-table ORs, and columns UNION can't compare. At landing its `Catalog#columns` merged with 20261001-26's (now `columns` and `column_names`) and the shared helper is `Tree.tables?`. The follow-ups went to 20261002-5.

### 20261001-17. Report payload: send what a legible report needs.

The first report from a real query (run 20261001T210856Z-3b7041a3, nothing beat the original) showed no query at all, and its lists couldn't be read. Most of what's missing never leaves the enclave. `quaacks report-payload` sends SQL, measurements, verdicts, and index lists only for the `top` labels, so a negative result gets none. Send, as shape-class data:

- **The original query, always.** The redacted query with the clock put back, as `original_sql` gives it today for an index-only winner.
- **Every stored rewrite,** not only the ranked ones: its SQL, its source (the LLM in 6a, or the operator in step 7, from `inferred`), and one fate. The fates: step 8 found its plans the same as the original's; step 9 disproved it, with the scenario and rule; step 10 disproved it, with the round; 14c found different results on production data; it was measured and wasn't better; it was ranked.
- **A step 8 prune is not a step 9 disproof.** `rewrite-test` stores a pruned rewrite as `passed` false with rule `discarded`, and NegativeResult sends that as a step 9 disproof. The report then says "rewrite_1: disproved in step 9 by scenario  (rule discarded)" for a rewrite that was never tested for correctness. Send the step 8 fate instead.
- **Every measured label,** not only `top`: its measurements, its per-literal verdicts, and the indexes it ran with (their built names), so the report can say what `original:top:1` was and how many blocks it read against the original.
- **Existing index sizes.** For `covered_by` and `makes_redundant`, send each existing index's `size_bytes` from the planner statistics with its name.
- **No repeats in 15a's lists.** In the real run the same DDL was listed twice under one search (`user_id, cached_due_date`), a partial index appeared once with `'deleted'::text` and once with `'deleted'`, and the rewrite's search repeated nearly all of the original's lines. Send each declined or existing index once, with the searches it came up in.

Trust boundary: SQL is the redacted query or a stored rewrite's SQL, DDL goes through CandidateDdlRedaction, and the rest is counts, names from the schema, and names from QUAACK's own constants. Test with sentinel literals, and update the whitelist in the protocol gem.

Rewrites the enclave refused on arrival aren't stored, so this task sends nothing for them. 20261001-19 counts them by reason.

- **Depends on:** 20260922-62, -63.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** Step 15, 15a.
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after one review with no blocking findings. The report message now carries `original_sql` always, `original_measurements`, `labels` (one entry per measured label: its search, built index names, measurements, and verdicts), and `rewrites` (every stored rewrite: SQL, source, rules, one fate with its scenario, rule, round, or `after`, and its plan, untested atoms, and evidence). `candidates`, `verdicts`, `measurements`, `negative.disproved`, and `negative.knocked_out` are gone. **Decided (the user, 2026-10-03):** states outside the task's six fates get their own, so there are fourteen (`RewriteFate`), all from closed lists; a step 8 prune is `same_plans`. `covered_by` and `makes_redundant` send `{ name, size_bytes }`. 15a's `declined` and `existing` list each index once with its `searches`, counting two as one when they differ only by casts (`CastlessIndex`). `counterexample-round` stores each round's rule. The driver renders what it did before and nothing new; 20261001-18 renders the rest. The follow-ups went to 20261003-3.

### 20261001-18. Report: readable HTML.

The driver's half of the same complaint. Render the report so someone who has never read DESIGN.md can follow it:

- **Queries.** Show the original query first, then every rewrite, each pretty-printed. pg_query 6.2 does this (`PgQuery.deparse(tree, opts: PgQuery::DeparseOpts.new(pretty_print: true, ...))`), and it's already a driver dependency.
- **No internal labels or rule names.** `original:top:1: not_better` becomes words: the original query with the index on `submissions (assignment_id, user_id, cached_due_date)` read so many blocks on the slow values against so many for the original, which isn't more than 5% fewer. The same goes for `footprint_tie`, `same_plans`, `never_used`, and the rest.
- **Sizes.** Use the unit that fits (kB, MB, GB) with thousands separators, right-aligned, so indexes compare at a glance. Show the existing indexes' sizes in the last two columns of the index table.
- **Who proposed what.** Say where each idea came from and what became of it, by source: the LLM's rewrites, the operator's rewrites, the two mechanical index generators, and the LLM's index proposals. **Decided (the user, 2026-10-01):** a table with one row per source and one column per outcome. One table for rewrites (proposed, refused on arrival, same plan as the original, wrong results, not better, ranked) and one for indexes (proposed, already existed, planner ignored, built and measured, not better, ranked).
- **Burndown and LLM calls in English.** "Index suggestions for the original query: 2 calls", not "LLM calls, 5a-5: 2". Stage names too.
- **A negative result's index table isn't "Proposed indexes".** Nothing is being proposed. Call it what it is: indexes QUAACK built and measured.
- **Layout.** A summary of the verdict at the top, then readable typography, tables with aligned numbers, and SQL in code blocks. Plain CSS in the file, no scripts, no animation, and nothing loaded from the network.
- Update the README's "Reading the report" to match.

- **Depends on:** 20261001-17. The accountability counts for rewrites refused on arrival, and the burndown rows, need 20261001-19 and -20.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** Step 15, 15a, 15b.
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after a review, a fix round, and a second review with no blocking findings. **Not run on the branch:** the enclave suite and the Docker-backed root specs, `spec/pipeline_replay_spec.rb` with its three reworded assertions among them; Docker was denied to the agents, and the user chose to land without them (2026-10-03). RuboCop, the driver and protocol suites, and the boundary specs passed. The report is `driver/lib/quaack/driver/report/` with an `.erb` template the gem ships: the verdict first, the original query and every rewrite pretty-printed with its source and fate in words, candidates named by their indexes, sizes in kB, MB, or GB, the two who-proposed-what tables, and the burndown and LLM calls in English. **Decided (the user, 2026-10-03):** it says "not recorded" where the payload has no count, and the task stayed in the driver. The builder's choices, not yet confirmed by the user: a seventh rewrites column, "Stopped for another reason", for rewrites that failed, timed out, tied, fell below the top three, or didn't finish; and 6c rule names still shown, as DESIGN.md 15 asks. An index counts as not better only if every label that ran with it was. 20261001-19 and -20 fill most "not recorded" cells; 20261003-5 has the rest. The follow-ups went to 20261003-4.

### 20261002-12. A `copilot_cli` LLM provider: a local `copilot` command.

The driver can call Anthropic, an OpenAI-compatible API, or Bedrock. Add a fourth provider, `"provider": "copilot_cli"`, that runs a local command, such as GitHub's `copilot` CLI, once per ask, through a new adapter behind the provider-neutral client, like the other three. The prompts can be hundreds of thousands of characters, too big for a command line. So the adapter writes each prompt to a file, runs a command that points the model at the file, and reads the reply from stdout. For example: `copilot --model claude-opus-5.5 -p 'Please follow my prompt in <file>'`.

The user settled these on 2026-10-02:

- **The command is a template in the llm block.** The operator gives it with placeholders for the prompt file and the model. Store it as an argv array, not a shell string, and run it without a shell, so a path or model never needs quoting. Give it a default that runs `copilot` from PATH with `--model` and `-p`. Check against `copilot --help` which flags make it non-interactive and print only the reply. A bad template, such as one missing the prompt-file placeholder, is a usage error naming the key.
- **Copilot gets read-only access.** It may read the prompt file and nothing else: no shell, no file writes, no network tools. Find the flags that enforce that (`--deny-tool`, `--available-tools`, or whatever the CLI offers) and put them in the default template. Run the command from an empty private temp directory, so no repo instructions (AGENTS.md, CLAUDE.md, `.github/...`) load. The CLI also loads the operator's global instructions on every run, wherever it runs: `~/.copilot/copilot-instructions.md`, `~/.copilot/instructions/**`, and any directories in `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. These must not reach QUAACK's prompts, since they can push the reply away from bare JSON. Before building, find the flag (or setting) that turns custom instructions off, using `copilot --help` and GitHub's Copilot CLI docs, and put it in the default template. Also unset `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` in the child's environment. If no such flag exists, stop and report back rather than work around it. Pointing copilot's config dir at an empty folder may also hide its login, so the user decides.
- **The prompt file is deleted after each ask.** Write it with mode 0600 in a private temp directory (`Dir.mktmpdir`), and remove the directory after the ask, whether or not the ask succeeded.
- **The default model is `claude-opus-5.5`.** Note that it's spelled with a dot, unlike the Anthropic default `claude-opus-5-5`.
- **Each ask has a timeout.** It's an optional `timeout_seconds` (a positive number) in the block, with a sensible default. A command that runs too long is killed, along with its process group, and the ask is `llm_unavailable`.

Other details:

- **Schemas.** The CLI can't enforce a JSON schema, so the adapter says it doesn't. The client's existing check and its one re-ask cover the rest. Every command run counts in the burndown.
- **The prompt file.** It holds the system prompt, the JSON-only instruction, and the schema, followed by the whole conversation as a plainly labeled transcript, so the multi-turn exchanges (5a-5's replacement round, 10a's rounds, the re-ask) still work.
- **Errors.** A command that isn't found is `llm_unavailable` with a clear message, or a usage error when the client is built if it's checked then. Decide which and document it. A non-zero exit is `llm_unavailable`, with the exit status and a short tail of stderr as the detail. Empty stdout is `llm_bad_response`. Strip whatever framing the CLI adds around the reply, if any. Spot `copilot`'s not-logged-in message, if it's distinctive, and map it to `llm_auth`.
- **Config.** `QUAACK_LLM_PROVIDER` takes `copilot_cli`. `base_url`, `api_key_env`, `aws_region`, and `aws_profile` don't apply to it, and giving any of them is a usage error naming the key. The new keys, the command template and `timeout_seconds`, apply to no other provider.
- **Trust boundary.** The adapter runs on the laptop, in the driver, like every LLM call. The enclave never runs or depends on it. No new gem should be needed, since `Open3` or `Process.spawn` is in the standard library. Keep the boundary specs green.
- **Tests.** Fake the CLI at the edge with a stub script on PATH or in the template. It should record its argv, its cwd, and the prompt file's contents and mode, and print a canned reply, exit non-zero, or hang. Assert that the file is gone afterward and that a hang is killed at the timeout. Don't call the real `copilot` in specs. A manual check through `script/llm_smoke.rb` is fine.
- **Docs.** Add the provider to DESIGN.md's LLM client section and the llm block paragraph, and to README.md's provider table.

- **Depends on:** 20260930-11.
- **Came from:** The user, 2026-10-02.
- **Design:** LLM client, driver.json.
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after three reviews. The user granted an extra fix round after the second. `CopilotCliAdapter` writes the prompt (system prompt, JSON-only instruction, schema, labeled transcript) to a 0600 file in a private temp dir. That dir is also the cwd. It runs the argv template without a shell and with `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` unset. It reads stdout and stderr against a deadline, so a detached grandchild holding a pipe can't hang it. On timeout it kills the process group (`llm_unavailable`). It removes the dir after every ask. The default template passes `--no-custom-instructions --disable-builtin-mcps --no-ask-user --available-tools=view --allow-tool=read({prompt_dir}) --disallow-temp-dir`, denies shell, write, and url, and uses `-s -p`. The docs don't say whether `--no-custom-instructions` covers `~/.copilot`'s user-level instructions. README.md warns about that, as the user chose. Settings are checked after the env overrides, so `QUAACK_LLM_BASE_URL` is refused for `copilot_cli`. The follow-up went to 20261003-1.

### 20260929-5. Say why intake can't read the query or plan.

`quaack start --query ~/q/query.sql ...` failed with only `query_unreadable`. The laptop's shell had expanded `~` to the laptop's home (`/Users/...`), but `--query` and `--plan` are paths on the jump server, so the file wasn't there. Both sides should help:

- **The driver, before any ssh.** If `--query` or `--plan` is an absolute path under the laptop's own home directory (`Dir.home`), refuse with a usage error: that looks like a path on this laptop, and these are paths on the jump server, so give one relative to your home there, such as `q/query.sql`, or an absolute path there. Decide whether a literal leading `~/` (quoted, so the laptop's shell leaves it) should be expanded on the jump server. If it is, do it in `quaacks`, never with a remote shell.
- **The enclave.** `query_unreadable` and `plan_unreadable` have several causes that look the same today: missing, a symlink as the last part (refused by `NOFOLLOW`), not a regular file, and no permission. Keep the rule, and add which cause it was, such as `query_unreadable: no such file on the jump server`. Never include the path or the OS's own message, which quotes it. Check the whitelist and the egress rules for what an error line may carry.
- Update README.md's `quaack start` section and DESIGN.md step 1 to say plainly that the paths are on the jump server, relative to your home there.

- **Depends on:** none.
- **Came from:** The user's first real `quaack start`, 2026-09-29.
- **Design:** Step 1, Where QUAACK runs.
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after two review rounds. The user's answer: a quoted leading `~/` works, and `quaacks` expands it, and a bare `~`, with the jump server's `Dir.home`, in Ruby. `~otheruser` is taken literally. The driver refuses an absolute `--query` or `--plan` under the laptop's home with a usage error (exit 64) before any ssh. The enclave keeps the rules and adds a whitelisted `reason`: `missing`, `symlink`, `not_regular_file`, or `permission_denied`. Neither the path nor the OS's message goes out, and sentinel specs check that. The driver gives each reason a fixed message, and specs pin all four for both rules. The fix round added those specs. Minor findings went to 20261003-7.

### 20261003-2. Take the recorded replay runs out of the per-commit check.

The full check takes about 54 minutes. The root `spec/` suite takes 38½ of them, the enclave suite 13, and the driver suite 2 (measured while landing 20261002-12). Most of the root suite is probably `spec/pipeline_replay_spec.rb`. It runs the whole driver pipeline on real Postgres once per replay variant: 4 queries × 3 models × 3 recorded runs (36), plus 3 planted runs and the `key_in_self_join` rule run. First, time it to confirm. RSpec's `--profile` works, or time the suite with that file left out. Also note where the enclave's 13 minutes go, as a separate finding.

The user settled on 2026-10-03:

- Plain `bundle exec rake`, the per-commit check, keeps the planted runs, the rule run, and one recorded run per query.
- A separate command runs every recorded variant, such as `rake replay` or `rake full`, or an env switch on `rake`. Pick one and document it.
- The full replay must run every time a version is bumped. Settle with the user which versions count (the gems' `version.rb` files, the enclave version, or all of them) and whether a spec or the Rakefile should enforce it, for example by refusing to pass when a version changed without the full replay recorded.
- Update CLAUDE.md's development section, which today says one command is the whole check, and the "Land" step if it changes.

Keep the Rakefile's guarantees: every suite runs, an empty suite fails, and the root suite must run.

- **Note (2026-10-03, answers):** The command is `rake full`. A bump of any gem's `VERSION` (protocol, driver, or enclave) needs the full replay. Enforce it with a stamp: `rake full` writes a committed stamp file of the versions it passed at, and a per-commit spec fails when the current versions don't match the stamp. Landing must run `rake full` only when the task bumps a version.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-03, after the 20261002-12 landing check took 54 minutes.
- **Design:** none (development tooling).
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after two review rounds.
  - **Timings:** the replay spec took about 90% of the root suite (1932s of 35:54). Plain `rake` now takes about 17 minutes. `rake full` takes about 38.
  - **What plain `rake` runs:** the planted runs, the rule run, and the `claude-1` recorded variant of each query, the first in sorted order. It fails rather than run zero recorded variants.
  - **`rake full`:** sets `QUAACK_FULL_REPLAY` (`rakelib/full_replay.rb`), runs every variant, and writes `spec/fixtures/full_replay_versions.json` only after RuboCop and every suite pass.
  - **The stamp:** `spec/full_replay_stamp_spec.rb` fails, telling you to run `rake full`, when the gems' versions don't match it.
  - **CLAUDE.md:** updated.
  - **The fix round:** it added dry-run selection specs that go red if the env var doesn't reach the replay spec.
  - **Follow-ups:** minor findings and the enclave timing notes went to 20261003-8.

### 20261002-17. 6c rule: `implied_predicate_removal`.

- **Note:** First filed as 20261002-5. Renumbered when merging another machine's work, which had already used -5.

The same query also had `enrollments.workflow_state <> 'deleted' AND enrollments.workflow_state = 'active'` and `enrollments.type IN ('StudentEnrollment', 'TeacherEnrollment', ...) AND enrollments.type = 'TeacherEnrollment'`. Rails scopes stack predicates like this. Postgres doesn't remove the implied ones. It multiplies their selectivities, so it underestimates rows, and that can pick a bad plan.

The rule: in a top-level `AND` (and in each `AND` of a subquery's `WHERE`), when one conjunct is `col = c`, drop any other conjunct on the same column that `col = c` implies. Treat the conjuncts of every inner join's `ON` at that level as part of the same `AND`, since for inner joins they filter the same rows. When the same conjunct is in both `ON` and `WHERE`, as in `JOIN assignments ON ... AND assignments.type = 'Assignment' ... WHERE assignments.type = 'Assignment'`, drop the one in `WHERE`. Never move a conjunct into or out of an outer join's `ON`, and never use one as proof. The conjuncts it drops:

- `col <> d` with `c` and `d` different.
- `col IN (..., c, ...)`.
- `col NOT IN (d1, d2, ...)` with `c` in none of them.
- A range such as `col > d`, `col >= d`, or `col BETWEEN d1 AND d2` that `c` satisfies.
- An exact duplicate of another conjunct, such as `score IS NOT NULL` written twice. This one doesn't need `col = c`.

NULLs are safe: `col = c` already drops the rows where `col` is NULL. It needs no catalog facts, so it states no assumptions. Refuse when the column has a nondeterministic collation, or when comparing the constants needs anything but the column type's default operators. Compare the constants in Postgres, in the enclave, with the column's type and collation, not in Ruby. Dropping a conjunct can leave a `WHERE` with one item, so deparse it without an empty `AND`.

Add it to 6c's table in DESIGN.md, as something the planner doesn't do. Put it first in the rules list, so later rules see the simpler query.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-02, answers):** Rules never see literal values. This task adds a `Literals` object, the first rule to need one, passed to rules beside `Catalog`, that answers with booleans only: `same?(a, b)` (two placeholders have the same literal text and shape, a safe under-approximation of equal values) and `holds?(expr)` (evaluates a boolean expression over placeholders on the racetrack connection, with the real values bound as parameters, never spliced). Rule code never reads `placeholder_map`, and nothing a rule outputs carries a value. A merged copy keeps the first copy's placeholder.
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after three reviews and one fix round.
  - **Shipped:** `RewriteRules::Literals` (`same?`, `holds?`; values bound as parameters on the racetrack) and the rule, first in `RULES`.
  - **What the rule covers:** top-level `WHERE` plus inner-join `ON`, all five drop kinds, the refusal on a nondeterministic collation, and the outer-join exclusion.
  - **First review:** found the oracle had no mutation coverage.
  - **Second review:** found that two equal-valued equalities with different text proved each other, and both were dropped. The fix stops a dropped conjunct from proving anything. That review also asked for a positive `NOT IN` test.
  - **Third review:** clean.
  - **Split out to 20261003-6:**
    - subquery `WHERE`s and UNION arms, which this landing doesn't reach;
    - refusing casts on literals;
    - refusing volatile duplicates;
    - the remaining test gaps and `Literals#inspect`.

### 20260929-6. `quaack deploy` diagnosis: close test gaps and fix wording.

The round-one review of 20260929-3 left these minor findings. The code is in `driver/lib/quaack/driver/deploy_diagnosis.rb`.

- **The shell-name filter is untested.** `SHELL_NAME` can become `/.*/`, and its guard can be dropped, with every spec still green. Without the filter, a passwd shell field holding an escape sequence goes into the advice as-is. Add a test where getent answers a shell with an escape sequence, a space, or uppercase, and assert no shell-specific advice.
- **Only the PATH side of the physical-path comparison is tested.** The probe's `pwd -P` on the bin dir can become `pwd`. Add a test where HOME is a symlink and PATH holds the physical bin dir. Without `-P`, that case wrongly advises "another quaacks comes first".
- **Parts of the decision order are untested.** Swapping unsupported-shell with missing-ruby, or other-quaacks with other-ruby, stays green. Add a fish-without-ruby example, and one with another quaacks on PATH and `installed=no`. Decide the right message for the second: today it tells the user to put a bin dir that has no quaacks on PATH. **Decided (the user, 2026-10-03):** say quaacks isn't installed for this Ruby, tell the user to run `quaack deploy`, and mention the other quaacks on PATH.
- **The advice for other shells overclaims.** It says POSIX sh reads no startup file because `$ENV` is only for interactive shells, but ksh88 reads `$ENV` non-interactively. Soften it to "it may read none; see its manual", and keep "bash or zsh may be easier". The comment claiming sshd sets `$SHELL` from passwd is unsourced; cite a source or soften it.
- **DESIGN.md's decision order leaves out the last case.** That case is quaacks on PATH that didn't answer. Mention it there. Its message says "didn't answer" even when quaacks answered with the wrong version; word it as "didn't answer with version X".
- **The installed check is weakly tested.** The probe's `[ -x "$d/bin/quaacks" ]` can become `[ -d "$d/bin" ]` with every spec green, because the "other Ruby" example never creates the bin dir. In that example, create `bin` holding some other executable (not quaacks) and keep the "other Ruby" message expected. (From round two.)
- **Optional tests.** The `\A` anchor on `LINE` and the `run.limit.nil?` guard both survive removal. The guard is effectively redundant.
- **Also consider:**
  - a `gem` and `ruby` mismatch on the jump server (the install went into one Ruby's user dir, and the probe asks another);
  - a user gem dir with a space in its path, which falls back to the general advice today.

- **Depends on:** 20260929-3.
- **Came from:** Reviews of 20260929-3, rounds one and two.
- **Design:** Deploying the enclave.
- **Status:** done
- **Note (landed 2026-10-03):** Landed on `main` after one clean review.
  - **Required items:** all done, with a test per gap. Each named mutation goes red.
  - **The user's answer:** another quaacks on PATH with `installed=no` gets "quaacks isn't installed for this Ruby; run `quaack deploy`", and names the other quaacks.
  - **Wording:** the wrong-version message says "didn't answer with version X". Other shells "may read none". The sshd comment cites OpenSSH's `session.c`.
  - **"Also consider":** both items are done. The probe reports where `gem` and `ruby` are, and names both when they differ. User gem dirs with spaces get the export line.
  - **Refactor:** the probe moved to `deploy_probe.rb`.
  - **Skipped:** the optional `run.limit.nil?` test, which would be a racy test of a redundant guard.
  - **Follow-ups:** minor findings went to 20261003-9.

### 20260930-10. Drop or explain the `BUNDLE_SOMETHING` plant in isolated_install_spec.

`Bundler.with_unbundled_env` already strips every `BUNDLE_*` key before `IsolatedInstall#isolated_env` scans `ENV`. So the `BUNDLE_SOMETHING` plant in spec/isolated_install_spec.rb proves nothing, and narrowing the scan to `/\ABUNDLER_/` leaves every spec green. It's an equivalent mutant, and no variable can get through. Cut the plant, or say in the comment that it's belt and braces. **Decided (the user, 2026-10-03):** keep it, with a belt-and-braces comment.

- **Depends on:** 20260929-24.
- **Came from:** Review of 20260929-24, round one.
- **Design:** none. Test harness only.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20260930-10.
  - **Change:** the plant stays. Its comment now says it's belt and braces, and that it would only matter if `isolated_env` ran outside `with_unbundled_env`.
  - **Verified:** narrowing the scan to `/\ABUNDLER_/` still leaves the spec green, so the plant can't fail today.
  - **Review:** one round, clean.

### 20260930-5. Clean up the operator-cancel test's canceler thread.

Minor findings from the review of 20260929-28, in enclave/spec/arena_runner_postgres_spec.rb's operator-cancel test:

- If the example fails before `canceler.join`, for example because no INSERT runs and `run_error` raises first, nothing kills the canceler thread. It polls until the after hook's `DROP DATABASE ... WITH (FORCE)` ends its connection, then dies with a `PG::ConnectionBad` trace on stderr. There's no hang and no stuck backend, just noise. Kill and join it in an `ensure`.
- The deadline's clearer message, "the INSERT never reached pg_sleep", shows up only when the test reaches `join`. Surface it when `run_error` fails first too, if that's cheap.

- **Depends on:** 20260929-28.
- **Came from:** Review of 20260929-28, round one.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20260930-5.
  - **Change:** the new helper `cancel_once_sleeping` handles the canceler thread.
    - It opens the thread's connection on the main thread, then kills the thread, joins it, and closes the connection in an `ensure`.
    - The thread's own error report is turned off, but any error it raises still comes out through the join.
    - If the INSERT fails before the cancel goes out, the test fails with "the INSERT never reached pg_sleep", with the original error kept as the cause.
  - **Review:** one round, clean.
    - The reviewer broke the production cancel handling, and the test went red.
    - A run with an INSERT that skips `pg_sleep` printed the thread's error trace on main. On the branch it gave the clear message in about 2.6s.
  - **Follow-ups:** minor findings went to 20261003-10.

### 20261002-7. 6c rule: `transitive_predicate_copy`.

The query behind 20261002-6 has `enrollments.course_id = assessor_asset.course_id` in an inner join's `ON`, and `assessor_asset.course_id IN (2883, ...)` in `WHERE`. Together they imply `enrollments.course_id IN (2883, ...)`, so a rule can add that predicate. Postgres carries a constant equality across an equi-join (equivalence classes), but not an `IN` list, a range, `BETWEEN`, or `IS NOT NULL`, so it can't use that implied filter to narrow `enrollments` early.

The rule: for each equality `a.x = b.y` in a top-level `AND` of `WHERE` or of an inner join's `ON`, and each conjunct on `a.x` alone that's an `IN` list of constants, a comparison with a constant (`<`, `<=`, `>`, `>=`), or `BETWEEN` two constants, add the same conjunct on `b.y`, unless one is already there. Keep the original. Refuse when:

- `x` and `y` have different types, or the equality isn't the type's default btree equality.
- Either column has a nondeterministic collation.
- Either side is on the nullable side of an outer join.

It's sound with no catalog facts: any row that passes has `a.x = b.y`, so `b.y` passes whatever `a.x` passes. It states no assumptions. Apply it to a fixed point within one rule call, so chains such as `a.x = b.y = c.z` carry across in one step.

20261002-15 also copies a predicate, but its proof comes from the data. This rule's proof comes from the query, so it stays a sound rule. Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-03, answers):** Don't copy `IS NOT NULL`. Put the copy in the same place as the source conjunct: the top-level `WHERE`, or that inner join's `ON`. The copy reuses the source's placeholders, and the "already there" check uses `Literals#same?`.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261002-7.
  - **Change:** the new rule `rewrite_rules/transitive_predicate_copy.rb` runs after `implied_predicate_removal`.
    - It copies IN lists, ranges and BETWEEN across equalities to a fixed point, including inside subqueries.
    - It refuses when:
      - the filter has casts, COLLATE, function calls, IS NOT NULL, NOT IN, `<>` or `=`;
      - the two columns differ in type or collation, or a collation is nondeterministic;
      - the type's comparisons aren't its default btree operators;
      - a column is on an outer join's nullable side.
    - `Catalog#default_btree?` is new. DESIGN.md's 6c table has the rule.
  - **Tests:** 22 examples on real Postgres, with mutation checks on every branch.
  - **Review:** one round, clean. The reviewer ran 20 Rails-style queries on data with NULLs and duplicates, and every rewrite returned the same rows.
  - **Follow-ups:** minor findings and the build's out-of-scope gaps went to 20261003-11. Nested SELECTs for `implied_predicate_removal` are already in 20261003-6.

### 20260929-30. Step 8 pruning doesn't test its reliance on HypoPG oid maps.

Since 20260924-1, CanonicalPlan tells hypothetical indexes apart only through the oid map SingleCandidateTest builds. Step 8's cross-session plan match (ThreeConfigurationPruning), and 5a-7's IndexRanking, depend on it. Passing an empty or nil map from SCT fails SCT's own specs, but no pruning or ranking spec. Add a pruning test that would break if the same index got a different oid in each session and the map were missing.

- **Depends on:** 20260924-1.
- **Came from:** Review of 20260924-1, round one.
- **Design:** 5a-7, step 8.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20260929-30. Tests only.
  - **Why the old specs missed it:** HypoPG reuses the same fake oids after each reset, so they stayed green with an empty map.
  - **Change:** the new pruning test and the new ranking test both set `hypopg.use_real_oids`, so each session gives its indexes new oids, and both first check that the oids really differ.
    - **Pruning:** a rewrite whose plans match the original's must still be discarded.
    - **Ranking:** the canonical plans must match the same indexes planned in a later session.
  - **Mutations:** an empty map from SingleCandidateTest turns both tests red, and so does CanonicalPlan ignoring the map.
  - **Review:** one round, clean.
    - The `SET` is per session, and each example gets its own database, so the setting can't leak into other examples.
    - Both tests passed across several seeds.
    - Nothing reads `Entry#canonical_plans` yet, so the ranking test pins it for later users.

### 20261003-10. Operator-cancel test: don't blame pg_sleep for other failures.

Minor findings from the review of 20260930-5, in enclave/spec/arena_runner_postgres_spec.rb's `cancel_once_sleeping` (around line 245):

- **The clear message can mislabel a failure.** "The INSERT never reached pg_sleep" depends only on `canceler[:canceled]`, which the thread sets just after `pg_cancel_backend` returns.
  - If the test's call fails between the cancel and the flag being set, the message wrongly blames pg_sleep. The reviewer couldn't make this race happen.
  - If the thread dies for another reason, such as a PG error while polling, `stop` swallows that error, and the message still blames pg_sleep.
  - The original error stays attached as the cause in both cases. Surface the thread's own error, and set the flag before the cancel, or make it clear the flag can be late.
- **A dropped `stop` would go unnoticed.** The thread's own error report is off, so a later change that dropped the `stop` call would let the thread die silently when the database is dropped. Consider a comment, or a check that the thread is gone after each example.

- **Depends on:** 20260930-5.
- **Came from:** The review of 20260930-5, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-10. Spec only.
  - **Change:**
    - If the canceler thread died, the test raises the thread's own error first, with the block's error as its cause.
    - The flag is now `:cancel_sent`, set just before `pg_cancel_backend`.
    - The thread is named `operator-canceler`, and a group `after` hook fails if it's still alive. That hook runs before the database drop.
  - **Review:** one round, clean.
    - Plants for a polling error, a dropped `stop`, and a failed `pg_cancel_backend` each gave the right error.
    - Breaking ArenaRunner's 57014 handling still turns the happy path red.
  - **Not filed:** the reviewer's one minor note. The hook catches a dropped `stop` only because it runs within about 50ms, before the closed connection kills the thread. It caught it 3 of 3 times. The comment also says the thread dies when the database is dropped, when really it dies when `other` is closed. Too small for a task.

### 20261003-8. `rake full`: harden the stamp and close test gaps.

Minor findings from the first review of 20261003-2:

- **`rake spec full` writes the stamp without the full replay.** So does `rake default full`. Rake runs a task only once per invocation, so `full`'s invoke of `:spec` does nothing after `spec` has already run. Make `full` run its suites itself, or refuse when `spec` already ran.
- **The stamp spec doesn't read the real version constants.** `full_replay_stamp_spec.rb:15` parses the version files with a regex, using a copy of the Rakefile's path map. If the regex stops matching, the Rakefile stamps `null` and the spec compares nil with nil, so it passes. Compare against the loaded `Quaack::*::VERSION` constants, and refuse to stamp a nil.
- **Exporting `QUAACK_FULL_REPLAY=1` makes plain `rake` skip the stamp check** (`full_replay_stamp_spec.rb:19`).
- **No test covers RuboCop failing during `rake full`** (`Rakefile:79`). The stamp is skipped today, but nothing pins that.
- **The `reject { it == EMPTY }` in `spec/support/pipeline_replay.rb` is untested.** Without it, a query with no replies at all would run the all-empty variant instead of failing.
- **CLAUDE.md wording.** The Docker and pg_dump bullets still say "the full check", which now reads as `rake full`, though both apply to plain `rake` too.
- **Where the enclave suite's time goes.** The builder's profile: about 9½ minutes, led by `standalone_require_spec` (39s), then `candidate_runs_step_postgres_spec` (26s), then the baseline, schema-dump, and step specs. Trim these if they're worth it.

- **Depends on:** 20261003-2.
- **Came from:** The first review of 20261003-2, 2026-10-03.
- **Design:** none (development tooling).
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-8.
  - **Refusal:** `full` refuses, writing no stamp, when `spec` or `default` already ran in the same command. Re-running the suites would cost about 17 more minutes without saying so.
  - **The variable:** `QUAACK_FULL_REPLAY` reaches the suites only while `rake full` runs. Otherwise the `spec` task removes it, so an exported value can't make plain `rake` skip the stamp check.
  - **The stamp:** the Rakefile refuses to stamp a nil version and names the file. The stamp spec compares against the loaded `Quaack::*::VERSION` constants.
  - **New tests:** one for RuboCop failing during `rake full`, and one for the `reject { it == EMPTY }` case.
  - **CLAUDE.md:** the Docker and pg_dump bullets now cover both commands.
  - **Suite time:** `standalone_require_spec` runs its child processes in parallel, cutting it from 31s to about 6s. The other slow specs were left alone.
  - **Review:** one round, clean.
    - Under plain `rake` the variable doesn't reach the child suites. Under `rake full` it does.
    - Every mutation went red.
    - The parallel spec passed four runs, three of them at the same time.
  - **Follow-ups:** minor findings went to 20261003-12.

### 20261003-9. `quaack deploy` diagnosis: minor findings, round two.

Minor findings from the review of 20260929-6:

- **The escape filter on gem and ruby paths is untested.** `deploy_diagnosis.rb:110`'s `which_gem` filters those paths with `PLAIN_PATH`, but removing that check leaves every spec green. It's the only thing keeping a PATH entry that holds an escape sequence out of the advice. Add a test with a `gem` dir holding `$` or ESC, and expect the general sentence.
- **The `pwd -P` on the gem/ruby comparison is untested** (`deploy_probe.rb:33`). Changing it to `pwd` stays green.
- **The trailing `(?<! )` on `PLAIN_PATH` is untested,** and it seems unneeded, since `bin` always ends in `/bin`. Test it or drop it.
- **The not-installed advice may not help.** It tells the user to run `quaack deploy` again, but deploy's `gem install` may well install to the same place again. The probe already reports `gem_dir`. Use it to say where the gem went and why this Ruby doesn't see it.

- **Depends on:** 20260929-6.
- **Came from:** The review of 20260929-6, 2026-10-03.
- **Design:** Deploy.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-9.
  - **Escape filter:** it moved into a shared helper, `other_gem`. Tests now put `$` or ESC in the gem dir.
  - **`pwd -P` was a real bug.** A plain `cd` resolves `link/..` as text, so the check compared the wrong directory.
    - Both comparisons now use `cd -P "$x" && pwd`.
    - Two `link/..` tests cover it.
    - The reviewer confirmed this under dash, busybox ash, `bash --posix` and macOS `sh`.
  - **`(?<! )`:** dropped as unreachable.
  - **Not-installed advice:** when `gem` isn't beside `ruby`, the advice names both paths. It explains that quaacks went into the other Ruby's user gem directory, and says to put Ruby 3.4's bin first. Each path it prints is filtered first. DESIGN.md's Deploy paragraph is updated.
  - **Review:** one round, clean.
  - **Follow-ups:** minor findings went to 20261003-13.

### 20261002-8. 6c rule: `cte_hoist_dedupe`.

A hand-tuned Canvas user search got much faster by hoisting a CTE. The original is a `UNION` of five arms in a subquery in `FROM`. Each arm, and the outer `WHERE`, has `users.id IN (WITH users_in_account AS MATERIALIZED (SELECT user_id FROM user_account_associations WHERE account_id = 1) SELECT user_id FROM users_in_account)`. Postgres builds each of those six identical CTEs separately. The tuned version defines it once in a top-level `WITH`, and each `IN` reads from that.

The rule: find every CTE, at any depth, whose body deparses to the same SQL as another's, and that has the same materialization option (`MATERIALIZED`, `NOT MATERIALIZED`, or none). Define one copy in the top-level `WITH`, and point every reference at it, renaming it if its name clashes there. Refuse a CTE that:

- Is correlated, reading a column from outside its own body.
- Is recursive or modifies data.
- Calls a volatile function.
- Would be hidden by a nearer CTE of the same name at some reference after hoisting. **(As built, the rule renames the merged CTE to a fresh `quaack_cte_<n>` instead of refusing. See the landing note.)**

It's sound with no catalog facts, since every copy reads the same snapshot and gives the same rows, and it states no assumptions. Hoisting a single copy changes nothing, so fire only when at least two copies merge.

Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-02, answers):** Match CTE bodies with 20261002-17's `Literals#same?` for their placeholders, never by reading values.
- **Note (2026-10-03, answers):** Merge CTEs with any materialization option, as long as every copy has the same one, and keep it. Merged plain CTEs may become materialized, and steps 8 onward decide whether that helps. A hoisted CTE whose name clashes at the top level is renamed `quaack_cte_<n>`.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261002-8.
  - **Change:** the new rule `rewrite_rules/cte_hoist_dedupe.rb` (with `scopes.rb`) is last in RULES.
    - CTEs at any depth with the same body, materialization option and column names merge into one CTE at the front of the top-level WITH.
    - Placeholders are matched only with `Literals#same?`.
    - A clash, or a nearer CTE that would hide the merged one, renames it to a fresh `quaack_cte_<n>`, and renamed references keep the old name as an alias.
    - It refuses correlated, volatile, recursive and data-modifying CTEs, and copies that read an outside CTE.
    - The new Catalog checks are `self_contained?` (PREPARE and DEALLOCATE of placeholder-only SQL, inside a savepoint) and `calls_volatile?`.
    - DESIGN.md's 6c table has the rule.
  - **Departure:** renaming instead of refusing when a CTE would be hidden. The reviewer found it sound, since the fresh name is used nowhere else in the query.
  - **Tests:** 27 rule examples, plus catalog specs. The builder ran 36 mutations and the reviewer 16; every one went red except removing the catalog cache, which only saves repeated queries.
  - **Review:** one round, clean.
    - 21 realistic queries all returned the original's rows. They covered LATERAL, EXISTS, UNION arms, column-alias lists and scalar subqueries.
    - FOR UPDATE is refused upstream by SupportedSql.
  - **Known trade-off (accepted):** merging can make a plain CTE materialized. A body expression that can error, such as `1/x`, could then raise on rows the outer filter used to exclude. Result comparison catches that.
  - **Follow-ups:** the build's out-of-scope findings went to 20261003-14.

### 20260928-1. `quaack setup`: one command for steps 2 through 4.

`quaack start` runs only intake (step 1), and `quaack run` starts at step 5. Nothing in the driver runs the steps between them, so today the operator types eleven `quaacks` commands on the jump server by hand: `inventory`, `run-server`, `qualify`, `schema-dump`, `statistics`, `volatility`, `classify`, `redact`, `literals`, `anchor`, and `racetrack-setup`, in that order. `e2e/run.rb` runs the same list itself, which is why the e2e run never noticed. DESIGN.md sections 2 through 4 already say "the driver runs" each of these.

Add `quaack setup --run <ID> [--host <h> --port <p> --racetrack-db <name> --arena-db <name>]`. It runs those steps over ssh in order, passing any run-server flags through to `quaacks run-server` (which falls back to `run_server_command` for missing ones). It resumes like `quaack run`: a step whose output the store already holds is skipped, which may mean adding the setup entries to the enclave's `Status::ENTRIES`. A failure stops it and prints only the step's rule, as `start` and `run` do.

- **Depends on:** None.
- **Came from:** Writing the user-facing README (2026-09-28).
- **Design:** Steps 2 through 4, "Where QUAACK runs."
- **Open questions:** Should `quaack run` call setup itself when the run hasn't had it, so `start` then `run` is all an operator types? Should `quaack start` take the run-server flags and do setup too?
- **Note (2026-10-03, answers):** Yes, `quaack run` runs setup first when the run hasn't had it, so it accepts the same run-server flags as `quaack setup` and passes them through. No, `quaack start` stays as it is and does no setup.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20260928-1.
  - **Change:**
    - `quaack setup --run <ID>` runs the eleven steps over ssh in order, with progress lines, and skips any step whose last entry is already in the store.
    - `quaacks status` reports one entry per setup step, holding only entry names and true/false.
    - The run-server flags go only to `run-server`, and only the ones given.
    - `quaack run` takes the same flags and runs setup first when any step is missing. Setup then counts in the progress total, such as [1/29] through [11/29].
    - `quaack start` is unchanged.
    - `e2e/run.rb` and the prompt pack use the shared setup code.
    - README and DESIGN.md say who runs these steps.
  - **Tests:**
    - driver unit specs for the step order, the flags, skipping, failures and the run total;
    - a guard that `start` doesn't run setup;
    - a real-Postgres spec of a full setup, a rerun with no calls, and a resume after a partial failure.
  - **Review:** one round, clean.
    - The reviewer checked that each step's marker is the last thing it writes, and that writes are atomic.
    - Eight mutations, and each one went red.
  - **Follow-ups:** minor findings went to 20261003-22.

### 20261003-17. Step 9: break foreign-key cycles through nullable columns.

A user's `quaack run` failed at steps 9-10 with `fk_cycle`. Step 9 loads fixtures for the query's tables and their foreign-key closure (`ArenaSchema.load_closure`), parents first. `Scenarios::Topology#load_order` raises `:fk_cycle` when no order exists. Real schemas often have cycles, such as Canvas's `accounts.course_template_id → courses` alongside `courses.account_id → accounts`, so on such a schema step 9 can't test any rewrite.

Most cycles have an edge whose child columns are nullable. The rule: when ordering the load, ignore a foreign key if all its child columns are nullable and no predicate atom reads any of them. Fixture rows set those columns to NULL rather than the type's typical value, and those columns join no key class. If a cycle remains with no such edge, still refuse with `fk_cycle`. A self-referencing foreign key is already ignored and stays that way.

Also check the other users of `Topology`: `Counterexamples` orders the LLM's rows with it (`counterexamples.rb:110`). An LLM row that gives a value for an ignored column would break the load order. Set the column to NULL there too, or refuse the row with a rule, and say which in DESIGN.md.

Update DESIGN.md's "Unsupported in v1" note for step 9. Test it against real Postgres with a two-table cycle (one nullable edge) and a three-table cycle, and check that a cycle with no nullable edge still refuses. A cycle through a column the query filters on must also still refuse.

- **Depends on:** none.
- **Came from:** A failed `quaack run` the user hit, 2026-10-03.
- **Design:** Step 9.
- **Note (2026-10-03, answers):** When an LLM row from 10a-10c sets a value in an ignored foreign-key column, load the row with NULL there, then set the column to the LLM's value with an UPDATE once every table is loaded. That keeps the row as the LLM wrote it.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-17.
  - **Change:**
    - `Topology` cuts a nullable foreign key only if it's inside a cycle (a strongly connected component) and no predicate atom reads its columns.
    - Step 9's fixture rows set cut columns to NULL, and those columns join no key class.
    - A cycle with no such edge still refuses with `fk_cycle`.
    - In 10a-10c, every nullable foreign key in a cycle is cut. An LLM row that sets a cut column is inserted with NULL there. Once every insert has loaded, an UPDATE keyed on the row's `tableoid` and `ctid` (from `RETURNING`) sets the LLM's value. This happens in both load orders.
    - A row that can't be found for its UPDATE fails the load with `insert_failed`.
    - DESIGN.md's step 9, 9d and 10a text says so.
  - **Tests:** cycles of two and three tables; still refusing with no nullable edge, with a NOT NULL column in a composite key, and when the query reads the column; acyclic schemas unchanged; LLM values present after forward and reverse loads; partitioned-table row targeting; a sentinel check on `DeferredInsert#inspect`.
  - **Review:** one round, clean.
    - All 15 tests went red against main's code.
    - 11 mutations, and all but one went red. The survivor is a missing test, filed in 20261003-25.
    - A wrong rewrite that joins the cut column is disproved.
  - **Follow-ups:**
    - 20261003-23: joining on the nullable edge still refuses, and a cut column's value isn't tested in step 9.
    - 20261003-24: an older value leak in ParentRows.
    - 20261003-25: loose ends.

### 20261002-9. 6c rule: `union_outer_filter_removal`.

The query behind 20261002-8 filters the `UNION`'s result with `WHERE users.id IN (SELECT user_id FROM users_in_account) AND users.workflow_state <> 'deleted'`, when every arm already applies both conjuncts, in its own `WHERE`, to the column it outputs. The outer copy can't drop a row, but Postgres still runs it: here, as a semi-join over the union's result.

The rule: for a query whose `FROM` is one subquery that's a `UNION` or `UNION ALL` (or such a subquery under inner joins), drop a top-level `WHERE` conjunct on that subquery's output columns when every arm has the same conjunct in its top-level `WHERE`, applied to the expression each arm outputs in those columns. Map output columns by position, expanding `t.*` from the catalog. Compare by deparsed form, with the column references replaced by placeholders. A conjunct with a subquery matches only when the subqueries deparse the same and read the same CTE (after 20261002-8, the same top-level one). Refuse when:

- A conjunct calls a volatile function.
- An arm outputs the column as an aggregate.
- An arm has the conjunct only in `HAVING`.
- The set operation is `INTERSECT` or `EXCEPT`.

It's sound with no catalog facts: every row an arm outputs passed that arm's `WHERE`, and `GROUP BY` doesn't change a grouped row's value for a column it groups by or one that depends on it. It states no assumptions.

Add it to 6c's table in DESIGN.md. List it after `cte_hoist_dedupe`, so it sees one shared CTE.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Note (2026-10-02, answers):** Match conjuncts with 20261002-17's `Literals#same?` for their placeholders, never by reading values.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261002-9.
  - **Change:** the new rule `rewrite_rules/union_outer_filter_removal.rb` (with `union.rb` and `conjuncts.rb`) comes after `cte_hoist_dedupe` in RULES. DESIGN.md's 6c table has its row.
    - It drops an outer top-level `WHERE` conjunct that reads only one `UNION` or `UNION ALL` subquery's output columns, when every arm's top-level `WHERE` has the same conjunct on what that arm outputs at the same positions.
    - Placeholders are compared only with `Literals#same?`.
    - It also refuses:
      - `LATERAL`, and column aliases;
      - a union on an outer join's nullable side;
      - `INTERSECT` or `EXCEPT` anywhere, and grouping sets;
      - arm columns read from CTEs or subqueries, unqualified columns, and stars it can't expand;
      - arm column types or collations that differ;
      - a subquery whose CTE a nearer `WITH` hides.
  - **Tests:** 25 examples on real Postgres.
    - They check the exact SQL, and that rows match on data with NULLs and duplicates, for both `UNION` and `UNION ALL`.
    - The Canvas five-arm query runs through `cte_hoist_dedupe` first.
    - Each refusal test has a twin that fires.
    - The builder ran 34 mutations and the reviewer 14; every one went red.
  - **Review:** one round, clean. Probes covered `NOT IN` with NULLs, swapped columns, a varchar arm against a text one, and a Rails `users.*` query. The one minor, an untested name guard, can't be reached, since Postgres rejects an ambiguous name first.
  - **Follow-ups:** the builder's widenings, and duplicate candidates reached by different rule orders, went to 20261003-26.

### 20261002-6. 6c rule: `shared_scan_cte`.

A hand-tuned Canvas query got much faster by reading `submissions` once instead of twice. The original joins `submissions` and `submissions AS assessor_asset`, and each copy filters on the same `course_id IN (2883, 4906, ...)`. The tuned version moves the filtered table into a `WITH ... AS MATERIALIZED` CTE and reads it twice. The scan happens once, and the CTE stops the planner from choosing its bad join order.

The hand-tuned version also moved `submissions.workflow_state <> 'deleted'` into the CTE, so it applied to `assessor_asset` as well, which the original never did. That isn't equivalent. The rule must move only the conjuncts every copy shares.

The rule: when a table is read two or more times in one `FROM` tree, and the copies' top-level `WHERE` conjuncts (or inner-join `ON` conjuncts) share one or more items that each read only that copy, build `WITH <name> AS MATERIALIZED (SELECT * FROM t WHERE <shared conjuncts>)`. Point every copy at it under its old alias, and leave each copy's other conjuncts where they were. Compare conjuncts by their deparsed form, with the copy's alias replaced by a placeholder. Refuse when:

- A copy is on the nullable side of an outer join.
- A shared conjunct calls a volatile function.
- The query already has a CTE of that name.
- A copy is in a subquery or CTE rather than the top-level `FROM`.

It needs no catalog facts, since every copy reads the same snapshot, so it states no assumptions. It isn't always faster: a join against a materialized CTE can't use the table's indexes. Steps 8 onward decide, as for any rewrite. Make sure step 8's index search and 12a treat the CTE correctly, by indexing the base table that the CTE's own scan reads.

Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c, 8.
- **Note (2026-10-02, answers):** Match shared conjuncts with 20261002-17's `Literals#same?`, never by reading values.
- **Note (2026-10-03, answers):** Name the CTE `quaack_scan_of_<table>`.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261002-6.
  - **Change:** the new rule `rewrite_rules/shared_scan_cte.rb` (with `shared_scan_cte/copies.rb`) comes right after `transitive_predicate_copy` in RULES, since that rule can create the shared conjuncts. DESIGN.md's 6c table has its row.
    - Conjuncts are compared with each alias replaced by a placeholder, and literals only through `Literals#same?`. An `ON` left empty becomes `ON true`.
    - Beyond the listed refusals, it also refuses whole-row references other than `copy.*`, unnamed FROM items such as aliased joins, tables that aren't plain, copies that rename columns, and anything Postgres can't prepare, such as a GROUP BY relying on the primary key.
  - **Tests:** 25 examples on real Postgres check the exact SQL and that rows match on data with NULLs and duplicates. Every refusal has a twin that fires. A step-8 test shows candidates land on the base table, never on the copies.
    - The builder ran 19 mutations and the reviewer 15; every one went red.
  - **Review:** one round, clean. The reviewer ran 21 Rails-style self-join queries (DISTINCT ON, aggregates, windows, LIMIT/OFFSET, `USING`, `SELECT *`, an inherited table) and every rewrite returned the same rows.
  - **Follow-ups:** the builder's widenings went to 20261003-28.

### 20261002-10. 6c rule: `existence_in_flip`.

A hand-tuned Canvas existence check got much faster by turning it inside out. The original:

```sql
SELECT 1 AS one FROM enrollments JOIN courses ON ... JOIN assignments ON ...
WHERE enrollments.user_id = 6504 AND ...
  AND assignments.id IN (SELECT assignment_id FROM assignment_configuration_tool_lookups WHERE tool_product_code = 'turnitin-lti' AND ...)
LIMIT 1;
```

The tuned version reads `assignment_configuration_tool_lookups` with its filters, and checks the rest with `EXISTS (SELECT 1 FROM enrollments JOIN courses ... JOIN assignments ... WHERE <the original's other conjuncts> AND assignments.id = assignment_configuration_tool_lookups.assignment_id)`, still under `LIMIT 1`. Postgres could choose that plan for the semi-join itself, but with `LIMIT 1` it bets on a fast-start plan from the other side and loses.

The rule: when a query is an existence check, rewrite it so the `IN` subquery's table drives. An existence check here means:

- Every select-list item is a constant.
- It has `LIMIT 1`.
- It has no `DISTINCT`, `GROUP BY`, aggregate, window function, `HAVING`, `OFFSET`, or locking clause.

The query must also have a top-level `WHERE` conjunct `x IN (SELECT y FROM S WHERE P)` whose subquery is uncorrelated and has no `LIMIT`, `OFFSET`, aggregate, set operation, or volatile function. The rewrite is `SELECT <the same constants> FROM S WHERE P AND EXISTS (SELECT 1 FROM <the original FROM> WHERE <the original's other conjuncts> AND x = y) LIMIT 1`. Keep the original's CTEs at the top. Rename `S`'s aliases if they clash with the original's.

It's sound with no catalog facts. Both return one row exactly when some combination of rows passes every predicate with `x = y`. The `IN` and the `=` use the same operator, so NULLs behave the same. It states no assumptions. It needs `LIMIT 1`: with a higher limit, or none, the two can return different numbers of rows.

Leave these for later: the same flip inside an `EXISTS (...)` body, and `x = ANY (SELECT ...)`.

When several `IN` conjuncts qualify, emit one candidate per conjunct, within the cap of ten (the user, 2026-10-03).

Add it to 6c's table in DESIGN.md.

- **Depends on:** 20261001-22.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261002-10.
  - **Change:** the new rule `rewrite_rules/existence_in_flip.rb` comes right after `not_in_to_not_exists` in RULES, and after `key_in_self_join`, so when both match the same IN the self-join removal comes first under the cap of ten. DESIGN.md's 6c table has its row.
    - It fires only on an existence check (constant select list, `LIMIT 1` read through the literal oracle, no DISTINCT, GROUP BY, HAVING, WINDOW, ORDER BY or OFFSET, no volatile function) with a top-level `x IN (SELECT y FROM S WHERE P)`.
    - The original FROM goes whole into the EXISTS, outer joins included; the original's CTEs stay on top. A bare y is qualified, and S's table is renamed when its name clashes. A correlated subquery is refused, since Postgres can't prepare the rewrite.
  - **Tests:** 16 examples on real Postgres with NULLs and duplicates; every refusal has a twin that fires. The builder ran 25 mutations and the reviewer 23; the one survivor in each is equivalent.
  - **Review:** one round, clean. The reviewer compared 26 Rails-style existence checks on real Postgres. One minor, a whole-row reference captured by a column of S, went to 20261003-29.
  - **Follow-ups:** the builder's widenings went to 20261003-29.

### 20261003-27. Step 9: `unsupported_type` should say which type, and cover more types.

A user's `quaack run` failed at steps 9-10 with `unsupported_type`, and nothing says which column caused it. `Scenarios::Values` (`scenarios/values.rb`) picks a value for each fixture column by trying a short list of strings and keeping the first one Postgres can cast to the column's type. When none of them casts, it raises `unsupported_type`. Types that likely miss today:

- **Range types** (category `R`): none of the strings reads. `'empty'` would.
- **Geometric types** (category `G`): `'(0,0)'`, and its nth forms.
- **`bit(n)`**: `'0'` only fits `bit(1)`. Pad to the length in the typmod.
- **Arrays when a distinct value is needed** (`nth`, for keys and unique columns): `'{}'` covers only the typical value. Use `'{<nth of the element type>}'`. **Seen in the user's run:** Canvas's `users.root_account_ids bigint[]` is in a unique index, so it's treated as unique and needs `nth`.
- **A multi-column unique index needs only one column to vary.** Today every column of a unique index gets an `nth` value. Instead, vary one column that can take distinct values, such as an integer or text one, and give the others their typical value. That sidesteps types with no `nth` at all.
- **Small numeric types when a distinct value is needed.** `key_value` adds 100,000 to the key for a split group, which overflows `smallint` and narrow `numeric(p,s)`. Wrap the number within the type's range, or pick a smaller offset when the type is narrow.
- **A domain whose CHECK rejects every candidate.** That's a real refusal, but say so.

The rule:

- Add candidates for each type above, with real-Postgres tests that build a fixture holding a column of each type, both as a plain column and as a unique one.
- Make the error name the type and column, such as `unsupported_type: courses.tags (int4range)`, as 20261003-19 does for `fk_cycle`. Type, table and column names are schema, not data. Add a sentinel test showing no row value appears in the error.
- DESIGN.md lists the types that still refuse.

Until then, the user can find the column with a catalog query over the query's tables and their foreign-key closure, listing columns whose type category isn't N, S, B, D, T or E, or that are domains.

- **Depends on:** none. Fits with 20261003-18, which stops this refusal from ending the run, and 20261003-19, which names tables in `fk_cycle`.
- **Came from:** A failed `quaack run` the user hit, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-27.
  - **Error detail:** `unsupported_type` and the new `domain_check` carry a `column` field, `{table, column, type}`, such as `unsupported_type: public.courses.tags (int4range)`. It holds schema names only. The enclave's error filter, the protocol whitelist, and the driver each check its exact shape and drop the whole field if any part fails. `quaack run` prints it.
  - **Values:** new candidates for ranges (`'empty'`, `[v,v]`), geometric types, `bit(n)` padded to its length, arrays (`{<element's distinct value>}`), and narrow numerics, which wrap negative instead of overflowing on the +100,000 offset. A domain whose CHECK rejects every candidate refuses as `domain_check`.
  - **Unique keys:** `Constraints#varying` varies one column per unique key, narrower keys first, so a wider key reuses a column already varied. It picks the best-ranked column, never a join key, and types with no readable distinct value rank last. A single-column unique key still varies. Expression unique indexes still vary every column they read. ParentRows follows the same rule.
  - **Tests:** `scenario_types_postgres_spec.rb` on real Postgres, including the Canvas case (a `bigint[]` in a multi-column unique key), plus sentinel tests on both sides of the boundary.
  - **Review:** three rounds. Round 1: the varying logic's `needed?` and sort order were untested; fixed, along with the rank of unreadable types. Round 2: the join-key exclusion and the FEW tier were untested; the builder's tests-only round added them. Round 3 checked those two tests, and both went red under two mutations each.
  - **Follow-ups:** 20261003-33.

### 20261003-33. Step 9 values: loose ends from 20261003-27.

Minor findings from building and reviewing 20261003-27. Do the false-collision and load-failure items first.

- **`readable?` tests a value with an explicit CAST, which is laxer than inserting it.** CAST quietly truncates `varchar(n)` and `char(n)`, so distinct values can collide after truncation or fail on insert. Check readability with an assignment coercion, as an INSERT does, rather than an explicit CAST.
- **ParentRows gives a nullable self-FK the value 0.** For example, `accounts.root_account_id`; the parent row then fails to load. This reproduces on main.
- **The varying pick ignores CHECKs.** With `kind int CHECK (kind IN (1,2))` and `UNIQUE (kind, login)`, it varies `kind`, so the third row fails to load. Prefer a column with no CHECK.
- **A split group's key takes the type of the slot's first column** (`scenarios.rb`, around lines 251-253). A smallint FK and an integer parent in the same slot can still overflow on the smallint side.
- **`bit varying` with no length gets only 2 distinct values**, since `Literals.bits` falls back to length 1. `bit(n)` also repeats values when it needs more than 2^n.
- **A nullable column of an unsupported type could take NULL** instead of refusing, when the query doesn't read it.
- **Expression unique indexes still vary every column they read.**
- **ValuePools' boundary regex may match array types** such as `bigint[]`.
- **Arrays over a domain over a domain** may not find their element type.
- **No test checks that FEW ranks below the middle tier** in `Values#rank`.

- **Depends on:** 20261003-27.
- **Came from:** The build and reviews of 20261003-27, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-33.
  - **Change, by item:**
    1. `readable?` uses `pg_input_is_valid`, which checks a value as an INSERT does. DESIGN.md requires Postgres 17 or later.
    2. ParentRows sets a nullable self-FK to NULL, and points a NOT NULL one at the row itself.
    3. `Checks#checked?` breaks ties toward unchecked columns, in FreeValues and ParentRows.
    4. `Values#shared_nth` picks a split slot's value that every column in the slot accepts.
    5. `bit varying` with no length gets unlimited distinct values.
    6. `Scenarios::Reads`: a nullable column of an unsupported type that the query doesn't read becomes NULL instead of refusing.
    7. `ExpressionUnique#key_columns` lets an expression index vary one column.
    8. The boundary regex skips array types.
    9. Arrays over nested domains get a regression test.
    10. The FEW tier gets a rank test.
  - **Not done:** `bit(n)` past 2^n values, which is an inherent limit already in DESIGN.md.
  - **Tests:** each fix went red first. The builder's and reviewer's mutations all went red.
  - **Review:** one round, clean. Its minor findings went to 20261003-34.

### 20261002-16. `distinct_join_to_exists`: handle what Rails sends.

- **Note:** First filed as 20261002-4. Renumbered when merging another machine's work, which had already used -4.
- **Note (2026-10-02):** Set aside by the user until 20261001-26 lands. It has since landed (merged from origin/main), with `t.*` support. Its minor findings went to 20261002-4, and they overlap with this task's select-list expressions.
- **Note (2026-10-03):** Back in the rule queue, after 20261002-15 (the user).

A hand-tuned Canvas query got much faster by removing a `DISTINCT` over a join:

```sql
SELECT DISTINCT users.*, sortable_name COLLATE public."und-u-kn-true"
FROM users JOIN enrollments ON users.id = enrollments.user_id
WHERE enrollments.course_id = 341535 AND ...
ORDER BY sortable_name COLLATE public."und-u-kn-true" ASC, users.id ASC
LIMIT 20 OFFSET 0;
```

This is `distinct_join_to_exists`'s case, but the rule must handle three things 20261001-26's entry doesn't mention. Check what 20261001-26 landed, and add whichever of these it lacks:

- `t.*` in the select list. It holds the kept table's key.
- Select-list expressions that read only the kept table's columns, such as `col COLLATE ...`, a cast, or a function call. A volatile function stays refused.
- `ORDER BY`, `LIMIT`, and `OFFSET`, carried over unchanged. Their expressions read only the kept table, as `DISTINCT` already requires them to appear in the select list.

Test it with this query's shape. Also test that the rule refuses when the select list reads a column of a table it would remove.

- **Depends on:** 20261001-26.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6c.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261002-16.
  - **Change:** `distinct_join_to_exists` now matches the shapes Rails sends: qualified select-list columns, ORDER BY and LIMIT in the forms Rails generates, and calls the catalog resolves by name (`catalog/calls.rb`). The select-list column checks moved to `distinct_join_to_exists/columns.rb`. The DESIGN.md 6c row was updated.
  - **Tests:** real-Postgres specs in `enclave/spec/distinct_join_to_exists_postgres_spec.rb` went red first. Mutations went red.
  - **Review:** one round, clean. Follow-ups went to 20261003-35. The pre-landing rake had one timing flake in `driver/spec/copilot_cli_adapter_spec.rb:204`, which -16 doesn't touch. It passed when rerun alone and went to 20261003-36.

### 20261003-34. Step 9 values: loose ends from 20261003-33.

These are minor findings from building and reviewing 20261003-33. Do the first two first.

- **`Reads` misses `USING` and `NATURAL` joins** (`scenarios/reads.rb`). It only collects `ColumnRef`s, so a column read only through `JOIN ... USING (lsn)` looks unread and gets NULL.
  - Every scenario then returns 0 rows, and a wrong rewrite passes step 9. 9c does list `USING (lsn)` as untested, so this isn't silent.
  - Fix: count `using_clause` names as reads, and treat `is_natural` as reading every column.
- **A NOT NULL CHECK or NOT NULL domain now fails the load instead of refusing.** Examples: `lsn pg_lsn CHECK (lsn IS NOT NULL)`, or a domain `AS pg_lsn NOT NULL`.
  - `null?` in `free_values.rb` should check `@checks.allows?(table, col, nil)` and the domain's not-null flag before choosing NULL, as main's clean `unsupported_type` did.
- **The NULL is chosen from the original query only.** A rewrite that adds `AND lsn IS NULL` passes. That's the same weakness every unmentioned column's constant has, so give it one line in DESIGN.md.
- **`bit(n)` still repeats values past 2^n.**
- **ParentRows still refuses a nullable column of an unsupported type.** Use `Reads` there too.
- **`Reads` matches columns by name only**, so it sometimes refuses a column the query doesn't really read.
- **`null?` ignores a domain's NOT NULL.** Overlaps with the second bullet.
- **A NOT NULL self-FK whose referenced columns the row doesn't set** still gets a new parent row.
- **`Literals.bits` dropped its `match&.` guard**, so a custom base type of category `V` would crash instead of refusing.

- **Depends on:** 20261003-33.
- **Came from:** The build and review of 20261003-33, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-34.
  - **Change:**
    - `Reads` counts `USING` and `NATURAL` join columns as reads. It also tracks join aliases and pins a qualifier to its table.
    - The new `scenarios/nulls.rb` picks NULL only when CHECK constraints and the domain's NOT NULL (nested domains included) allow it. Otherwise it refuses cleanly.
    - ParentRows uses `Reads` over the original query and the candidate, so it NULLs an unread nullable column of an unsupported type.
    - A NOT NULL self-FK whose referenced columns the row doesn't set points at the row itself.
    - `Literals.bits` got its `match&.` guard back.
    - DESIGN.md says the NULL is chosen from the original query only.
  - **Not done:** `bit(n)` past 2^n values, an inherent limit already in DESIGN.md.
  - **Tests:** each fix went red first. The reviewer ran 14 mutations of the diff and 13 went red. The survivor is minor finding 2 below.
  - **Review:** one round, clean. Its minor findings went to 20261003-37:
    - a base table aliased with a column list;
    - the self-FK fix depends on foreign-key order.

### 20261003-24. ParentRows can leak a value in a Postgres error.

Found while building 20261003-17. This predates that task. In 10a-10c, `Counterexamples::ParentRows` runs `SELECT (value)::text` on an LLM row's values (`counterexamples/parent_rows.rb`). If Postgres raises there, such as on a bad cast, the error can escape `prepare` with the value in its message. Errors from the enclave must carry only a rule.

Reproduce it with a sentinel value that makes the cast fail, and check that the sentinel shows up today. Then wrap the error in a rule (with `cause: nil`, as elsewhere), and check that the sentinel never shows up in any output.

- **Depends on:** none.
- **Came from:** The build of 20261003-17, 2026-10-03.
- **Design:** 10a, trust boundary.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-24.
  - **Change:**
    - The new `Counterexamples::Evaluated` evaluates each value of an accepted insert in the arena once. It catches Postgres errors.
    - A bad value refuses only its own insert, recorded as `{index, rule: "bad_value"}`, with no cause. The round carries on, since a driver-ending error was too harsh for an ordinary LLM mistake.
    - `ParentRows` and `Deferral` read the evaluated results and no longer query Postgres with LLM values. `Deferral.text`, used for cut columns, had the same leak.
    - DESIGN.md 10a describes `bad_value`.
  - **Tests:** sentinel tests for a bad FK value, a plain value, a cut column and a full step run went red on main. A meta-test proves the leak check catches a planted sentinel. The reviewer tried enum, date, jsonb, out-of-range, division by zero and multi-row cases, and nothing leaked. Mutations went red.
  - **Review:** one round, clean. Its minor findings went to 20261003-38.

### 20261003-31. Step 9: two false passes on ordinary joins.

The second review of 20261003-23 found two cases where step 9 passes a wrong rewrite. Both are on main and both are realistic, so this goes ahead of widenings.

- **Self-referencing anti-join.** `SELECT a.id FROM accounts a LEFT JOIN accounts r ON r.id = a.root_account_id WHERE r.id IS NULL` is treated as equal to its JOIN form. The scenarios never hold an account whose `root_account_id` points at nothing, or is NULL. It happens on an acyclic schema too.
- **EXISTS vs JOIN.** Duplicate children are never generated, so a JOIN that returns a parent once per child passes as equal to `EXISTS`. Some group must hold a parent with two matching children.
- **A nullable FK always points at the group's own parent.** On the Canvas `accounts.course_template_id` cycle, "courses that are some account's template" passes as equal to "courses whose account has a template", on main too (review of 20261003-30, case C6). Some group must hold a row whose nullable FK points at a parent from another group. Note: on a cycle this interacts with 20261003-23/-30, which are set aside. Do the acyclic form here, and leave the cyclic form for them.

Test both on real Postgres, with the wrong rewrite disproved and the right one passing.

- **Depends on:** none.
- **Came from:** The second review of 20261003-23, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-31.
  - **Change:**
    - An atom no stored value can satisfy, such as `r.id IS NULL` on a NOT NULL key, no longer drops every group. That fixes the self-referencing anti-join false pass.
    - A copy row gets its own value for a key its table holds unique (`topology.rb` `own_key?`/`own_slots`). Before, it collided with the original and was dropped, so a parent never had two children. That fixes EXISTS vs JOIN.
    - S3 adds rows whose foreign key points at another group's parent. This is the acyclic form only; cycle-cutting is untouched.
    - DESIGN.md step 9 notes.
  - **Tests:** `enclave/spec/step_nine_joins_postgres_spec.rb`, on real Postgres. Each wrong rewrite was red on main and is now disproved, and each correct twin passes. In the fix round, tests were added that pin `own_key?` and the outward guard in `own_slots`; each goes red under its mutation.
  - **Review:** two rounds. The first found `own_key?` and the outward guard untested (blocking), and the fix round added tests for both. The second review was clean, with 26 Rails-style cases: no new load failures, no new false passes, and two more wrong rewrites now disproved. Minor findings went to 20261003-39 and 20261003-40.
  - **Not done:** the cyclic form (Canvas `accounts.course_template_id` ↔ `courses`), which belongs to 20261003-23 and -30.

### 20261003-18. A scenario refusal shouldn't end the run.

When step 9 can't build scenarios for a query, because of `fk_cycle`, `complex_check`, `expression_unique_index` or `unsupported_type`, the `Scenarios::Error` escapes `StepNine.run` (from `VacuityGuard`) and `quaack run` fails with just the rule. The index work done so far is lost, even though the index search doesn't need step 9.

The rule: a scenario refusal marks every rewrite untested, with the refusal's rule. Untested rewrites are never recommended. The run carries on through the index steps (12a, 13, 13a) and writes the report. The report says rewrites were skipped and why, by rule. A resumed run must not retry the refused step forever, so record the refusal in the run's store like any other step result.

Test it end to end against real Postgres with a schema that refuses (a complex `CHECK` is the easiest). The run should finish, the report should name the rule, and no rewrite should be recommended.

- **Depends on:** none.
- **Came from:** A failed `quaack run` the user hit, 2026-10-03.
- **Design:** Steps 9-10, step 15.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-18.
  - **Change:**
    - `StepNine.run` catches `Scenarios::Error` and gives every rewrite "not passed", carrying only the rule. It stores `"refused" => true` and `survived = false`, so steps 10 and 11 and ranking skip the rewrite.
    - A new fate, `step9_untested`. Its rule must be on `REFUSALS`, or it goes out as nil. A refused rewrite isn't counted as a rule bug.
    - The report says per rule that QUAACK couldn't make up test data, so it never tested the rewrite and won't recommend it.
    - The index steps and the report still run. A resumed run skips the refused step.
    - DESIGN.md: steps 9 and 10, the fate table, and step 15.
  - **Tests:**
    - `spec/pipeline_scenario_refusal_spec.rb` runs end to end on real Postgres, with a complex CHECK, and covers resume.
    - A sentinel `domain_check` spec checks that column and domain names never leave the enclave.
    - All six `REFUSALS` rules are pinned.
    - Each test went red before the fix, and every mutation went red.
  - **Review:** two rounds. The first found no leak test for the refusal message (blocking); the fix round added it. The second was clean. Its minor finding went to 20261003-41.

### 20261003-6. `implied_predicate_removal`: refuse casts and volatile duplicates, reach subqueries, close test gaps.

Minor findings from the second review of 20261002-17:

- **Casts on a literal.** `columns.rb`'s `value()` strips the cast before comparing. So `grade = 2.7::int AND grade < 2.8` on a numeric column, or `created_at = '2020-01-01 10:00'::date AND created_at > '2020-01-01 05:00'`, drops a predicate the equality doesn't imply. Refuse when the literal has a cast, unless it's the column's own type.
- **Volatile exact duplicates.** `random() < 0.5 AND random() < 0.5` loses a copy, which changes the results. Never drop a duplicate that calls a volatile function.
- **Subquery WHEREs and UNION arms are never reached.** `Tree.find` stops at the first `SelectStmt`, but the task asked for each `AND` of a subquery's `WHERE`. Reach them, or say in DESIGN.md that v1 only does the top level.
- **Mutations that survive:**
  - dropping the column's `COLLATE` in `typed`;
  - dropping the shape half of `Literals#same?`. The test's title claims to cover it. Pin it or remove it.
- **Missing tests:**
  - an inner join's ON equality dropping a WHERE `<>` or range predicate;
  - a positive `NOT IN` case;
  - an ON clause that dropping empties.
- **`Literals` has no redacting `inspect`,** unlike `Binding`. Inspecting one would print the placeholder map, values included.

- **Depends on:** 20261002-17.
- **Came from:** The second review of 20261002-17, 2026-10-03.
- **Design:** 6c.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-6.
  - **Change:**
    - A new `Catalog#type_name` (`catalog/types.rb`) resolves a cast's type, typmod included. pg_query checks the type text first, so no literal value is ever sent to Postgres.
    - A cast on a literal blocks the drop, unless it's to the column's own type.
    - An exact duplicate that might call a volatile function is kept (`Catalog#calls_volatile?`; anything it can't check counts as volatile).
    - Each SELECT is simplified on its own: the top level, subqueries, CTEs and set-operation arms. An equality only proves predicates in its own SELECT.
    - COLLATE is pinned.
    - The shape half of `Literals#same?` was removed as dead; the reviewer confirmed it.
    - `Literals` redacts in `inspect`, `to_s` and `pretty_print`.
    - New tests: an inner-join ON equality, and an emptied ON becoming CROSS JOIN.
    - The DESIGN.md 6c row was updated.
  - **Tests:** seven tests went red first for the right reason. 15 reviewer mutations and the builder's own mutations all went red.
  - **Review:** one round, clean, with no findings. The reviewer checked 45 realistic queries against real Postgres, covering casts, SELECT levels, volatile duplicates and Rails duplicates.
  - **Not done (builder's notes, not filed):**
    - An unusual type that doesn't deparse as `NULL::<type>` is refused, which is conservative.
    - Outer equalities are never used inside a correlated subquery, by design.

### 20261003-40. Step 9: a dropped group leaves rows pointing at missing parents.

Found while fixing 20261003-31. It happens on main too. It fails safe, but it rejects correct rewrites of an ordinary query shape.

- **An equality filter on a unique parent column, joined to a child,** fails to load at S6. Example: `posts JOIN taggings JOIN tags tg … WHERE tg.name = 'ruby'`. The S6 "many" group collides with the hit on the unique `name`, so the whole group is dropped. The group's single-table copies stay, though, and the taggings copy points at a post and tag that were never loaded, so the load fails with `fixture_load_failed`.
- **The S3 cross rows assume the hit group is never dropped.** If it were, they'd point at a missing parent in the same way.
- Fix: when a group is dropped, also drop every row that points at its rows, and the rows built only for it. Or pick the colliding group's unique values so they can't collide. Check whether this also clears 20261003-32's "a group that skips leaves orphaned copies".

Test with the taggings query: the correct rewrite must pass, and a wrong twin must still be disproved.

- **Depends on:** 20261003-31.
- **Came from:** The fix round of 20261003-31, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-40.
  - **Change:**
    - The scenario builder retries a colliding group with later values from the pool (a new `Retries` class).
    - Cross rows go first and are trimmed.
    - A unique column that an ignored atom reads now gets varied values.
    - A row whose parent isn't loaded counts as a collision, and a group that collides partway rolls back its earlier rows.
    - A group that doesn't fit beside the hit goes into a further fixture of the same scenario, with copies of its parent rows (`RowSet#parents_of`). If it fits nowhere, it tries its near-miss version.
    - Step 9 loads and compares every further fixture, in both load orders.
    - `Ties.allowed?` was pulled out of the scenario code. DESIGN.md's step 9 notes are updated.
  - **Tests:** a new `step_nine_unique_filter_postgres_spec.rb` covers has_one, LEFT JOIN, DISTINCT has_many, a three-level chain, tags with `=` and `IN`, and sender/recipient. The RowSet tests cover a three-level chain, a partly-NULL composite FK, a parent in the same group, and `parents_of`.
  - **Review:**
    - Round 1 was blocking. The first version pruned orphaned rows, which turned safe refusals into false passes (for example, dropping a has_one join under a unique email filter).
    - The fix round replaced the prune with further fixtures.
    - Round 2 was clean. Every round-1 reproducer and 7 more realistic queries came out right: correct rewrites pass and wrong ones are disproved. All 11 mutations went red.
  - **Follow-ups:** filed as 20261003-42.

### 20261003-19. Name the tables in an `fk_cycle` refusal.

`fk_cycle` says only that a cycle exists, so the user has to find it with their own catalog query. The error should name the tables in one cycle, in order, such as `fk_cycle: accounts -> courses -> accounts`. Table names are schema, not data, and the relations step already lets them out. Constraint names and column names may go too. Check DESIGN.md's trust-boundary rules for errors, which today say they "name only a rule", and update that sentence for this case.

Add a sentinel test: plant a row value in the cycle's tables, and check that it never shows up in the error. Check too that the cycle shown is real, in the order the foreign keys point.

- **Depends on:** none. If 20261003-17 lands first, the cycle shown must be one that's left after nullable edges are ignored.
- **Came from:** A failed `quaack run` the user hit, 2026-10-03.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-19.
  - **Change:**
    - Topology records the cycle that blocks the load order: the tables in foreign-key order, with the first table repeated at the end. Nullable FKs that get cut are left out, and so are tables that only reference the cycle.
    - Step 9 stores the cycle along with the `fk_cycle` refusal.
    - The report payload (`CycleTables`) and step 10's re-raised error only name tables that exactly match a `schema_subset` string, and they send that string, not the stored value.
    - The enclave's ErrorFilter passes `cycle` only for `fk_cycle`, and only when the cycle is closed and well formed.
    - The protocol whitelist allows the field. The driver checks the rule and the name shape again, then names the tables in the report sentence.
    - `Scenarios::LoadOrder` was pulled out of Topology to stay within RuboCop's limits after merging -40. DESIGN.md's step 9 and step 15 text is updated.
  - **Review:**
    - Round 1 found one blocking problem: a vacuous closure test, whose name SENTINEL.c failed the shape check anyway. It also found one minor: the empty-cycle guard was untested.
    - The fix round corrected both, and each was confirmed to go red when its check is removed.
    - Round 2 was clean. 13 of round 1's 15 mutations had already gone red, and the two survivors are the ones the fix round covered.
  - **Follow-ups:** filed as 20261003-43.

### 20261003-29. `existence_in_flip`: a captured whole-row reference, and widenings.

From the build and review of 20261002-10.

- **A whole-row reference can be captured (correctness, rare).** When a moved condition names a table bare, as a whole row, and `S` has a column of that name, Postgres resolves the name to `S`'s column inside the `EXISTS`. Reproducer: `holders(id, posts)` with rows `(1, NULL), (2, 5)`, and `SELECT 1 AS one FROM posts WHERE posts.id IN (SELECT holders.id FROM holders) AND posts IS NULL LIMIT 1`. The original returns no rows; the rewrite returns one. Fix: refuse a bare one-field column reference in the moved conditions or in `x` that names an original FROM item, and list it in DESIGN.md as unsupported in v1. Do this one first.
- **Widenings:**
  - The prepare check treats every placeholder as unknown, so it refuses ambiguous calls such as `generate_series($2, $3)`.
  - ORDER BY with a constant select list, a cast constant in the select list, a bare y when S has several tables, y as an expression, and renaming when S has subqueries are all refused today.
  - Deferred by the task: the flip inside an `EXISTS` body, and `x = ANY (SELECT ...)`.

- **Depends on:** 20261002-10.
- **Came from:** The build and review of 20261002-10, 2026-10-03.
- **Design:** 6c.
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-29.
  - **Change:**
    - **The capture fix:** the rule refuses a bare one-field name in the moved conditions, or in x, when it names a FROM item on its own side. Qualified `t.*` still flips. DESIGN.md lists the bare form as unsupported in v1.
    - **Widenings:**
      - (A) The prepare check gives each placeholder its literal's type, through `Literals#prepares?`, which returns only true or false. So `generate_series($2,$3)` flips.
      - (B) An ORDER BY whose keys are all safe becomes `ORDER BY 1`. A safe key is an output position, or a qualified column of a plain table whose type can be compared, with no USING.
      - (C) A cast constant in the select list.
      - (D) A bare y when S has several tables, qualified by the one plain table that has that column.
      - (E) y as an expression. Its columns are qualified and renamed. A SubLink and a bare top-level constant are refused.
      - (F) Renaming when S has subqueries, allowed when nothing else in S introduces that name.
  - **Review:** one round, clean. The reviewer compared about 55 realistic queries in real Postgres, and 29 of 31 mutations went red.
  - **Follow-ups:** filed as 20261003-44.

### 20261003-36. Flaky driver spec: copilot_cli adapter grandchild-stdout test.

`driver/spec/copilot_cli_adapter_spec.rb:204` ("does not hang after a successful command leaks stdout from a detached grandchild") wraps the call in `Timeout.timeout(1.0)`. It failed once in a full rake while other agents were running Docker-heavy suites. It passed when rerun alone. Give it enough slack to stay green on a loaded machine, without letting it pass when the adapter really hangs. For example, make the fake grandchild sleep much longer than the new limit.

- **Depends on:** none.
- **Came from:** The pre-landing rake of 20261002-16, 2026-10-03.
- **Design:** none (test only).
- **Status:** done
- **Landed:** 2026-10-03, as a merge of task/20261003-36.
  - **Change:** only `driver/spec/copilot_cli_adapter_spec.rb` changed.
    - The grandchild-stdout test's outer limit went from 1s to 10s (`hang_limit`). The fake grandchild still sleeps 60s.
    - The two sibling timeout and process-group tests had the same problem. They get a 3s adapter timeout (`slow_start_timeout`) and a 10s outer limit or poll.
  - **Review:** one round, clean. Three deliberate breaks each turned the matching test red: the success path reading stdout to EOF, the timeout path reading to EOF, and killing only the child. The two timeout tests now take about 3s each.

### 20261003-15. `quaack run`: say what each step did when it finishes.

Today every finished step in `quaack run` prints the same line, such as `quaack: [1/18] Done in 15s (index-search)`. That says how long the step took but not what it found. A step that found 12 indexes looks just like one that found none. Instead, the closing line should give a short count of the step's output, such as:

```
quaack: [1/18] Checking the query plan and searching for indexes (index-search)
quaack: [1/18] Found 12 possible index definitions mechanically in 15s (index-search)
```

The rule: `Progress#step` (`driver/lib/quaack/driver/progress.rb`) lets a step give a summary for its closing line, built from its result. When it gives one, the line says `<summary> in <duration>`. When it doesn't, or when the step was skipped or failed, the line stays as it is now. Give every step in `Pipeline::SAY` a summary that says what it produced, for example:

- index-search: how many index definitions were found mechanically.
- 5a-5 and 5a-6: how many index ideas the LLM gave, and how many were new.
- 5a-7 and index-rank: how many ideas were kept, out of how many.
- 6c: which rules fired, or "No rule applied".
- 6a: how many rewrites the LLM gave.
- rewrite-prune: whether the rewrite was kept or dropped.
- steps 9-10 and 14b-14d: how many rewrites or choices are left.
- 12a: how many indexes were built.
- 13, 13a and 14: how many measurements were taken.
- 15: where the report was written.

Summaries carry only counts, step names, and rule names, which the progress lines already allow. They never carry data, SQL, or literal values from the enclave. A test plants a sentinel in a step's result and checks that it never shows up in the progress output.

- **Depends on:** none.
- **Came from:** The user, 2026-10-03.
- **Design:** Progress lines for `quaack run`.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-15.
  - **Change:**
    - `Progress#step` takes a `summary:`, so the closing line reads `<summary> in <duration> (<step>)`. Steps with no summary still end with `Done`. Skipped, failed and sub-step closing lines are unchanged.
    - The summaries live in `driver/step_summary.rb`. Examples: `Got 4 index ideas from the LLM, 1 of them new and tested, 1 set aside untested`, `Got 3 rewrites from the LLM, 2 kept`, `Tested 2 rewrites, 1 passed`, `Built 2 indexes`, `No rule applied`.
    - On a resumed run, steps 8 and 11 count only the rewrites they did work for, as in `for 1 rewrite, 2 already done`.
    - DESIGN.md is updated.
  - **Not built:** some steps can't give counts, and 6c can't name the rules that fired, because the enclave sends neither. Those steps get plain wording. This is filed as 20261004-1.
  - **Review:**
    - Round 1 was blocking: on resumed runs, steps 8 and 11 counted rewrites that had already been done. The fix round corrected it and four minors.
    - Round 2 was clean, with 12 of 12 mutations caught.
  - **Minor, not filed:** steps 9–10 don't say how many rewrites were already done, unlike steps 8 and 11. 20261003-16 and -21 will rework these lines.

### 20261003-38. `bad_value`: loose ends from 20261003-24.

These are minor findings from the review of 20261003-24:

- **`Counterexamples::Evaluated` catches every `PG::Error`** (`evaluated.rb:23`). A dropped connection or a statement timeout gets reported as `bad_value`. No value leaks, and the next query still fails loudly, but the refusal reason is misleading. Catch only data errors (SQLSTATE class 22, and 23 if it applies). Let connection and timeout errors go up as the usual rule-only error.
- **Wrapped test description** (`counterexample_steps_postgres_spec.rb:192`). The description wraps onto a second line, so `rspec file:192` runs a different test. Put it on one line.

- **Depends on:** 20261003-24.
- **Came from:** The review of 20261003-24, 2026-10-03.
- **Design:** 10a.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-38.
  - **Change:** `counterexamples/evaluated.rb` reports `bad_value` only for SQLSTATE classes 22, 23 and 42. Any other PG error is re-raised as `internal_error`, carrying only the sqlstate.
  - **Review:** one round, clean. The minors went to 20261004-3.

### 20261004-2. Step 9 re-probes CHECK constraints thousands of times.

On a real Canvas run, rewrite-test spent over 10 minutes on one rewrite. It sent the same query again and again: `SELECT $1::text = ANY(ARRAY['complete'::varchar::text, 'processing'::varchar::text, …])`, a CHECK on a `workflow_state`-like column.

The cause is in `scenarios/checks.rb`:
- `Checks#satisfying` eagerly runs `ValuePools.sorted` for every CHECK on the column, about 35 probe queries, on every call. It does this even when the first preferred value passes.
- `allows?` calls each probe twice per value.
- Nothing is cached, and `FreeValues#plain_value` calls `satisfying` for every free column of every row, in every group, retry, further fixture, scenario and rewrite.

The fix:
- Cache the probe results per CHECK node and value, and the sorted values per node, within a run's `Checks`. A CHECK's answer for a value never changes during a run.
- Compute a CHECK's own satisfying values lazily, only when no preferred value passes.
- Call each probe once per value.
- Look for other hot paths with the same pattern, such as `ValuePools.sorted` for atom pools and `Values#readable?`, and cache them too if they repeat.

Test on real Postgres with a Canvas-like table that has a `workflow_state` CHECK IN list of 8 values and several such columns. Count the queries the connection sends during scenario building, using a thin counting wrapper around the real connection. Assert that a second scenario build sends no new probe queries for the same column and value, and that the total stays below a small bound. The results, the fixtures and the step 9 outcomes must not change.

- **Depends on:** none.
- **Came from:** The user's Canvas run, 2026-10-04.
- **Design:** Step 9.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261004-2.
  - **Change:** a new `ValuePools::CachedProbe` asks each CHECK and atom probe once per value. Columns of the same type with the same CHECK share one cache. A CHECK's own values are sorted only when no preferred value passes. The value pools and the Picker share their atom probes.
  - **Effect:** on a Canvas-like join, one step 9 run went from 60,968 queries to 274, and from 39–171s to 0.75s. Fixtures are byte-identical to before.
  - **Tests:** `enclave/spec/scenarios_query_count_postgres_spec.rb` counts the queries through a thin wrapper around the real connection.
  - **Review:** one round, clean. The minor went to 20261004-6, and the builder's candidates went to 20261004-4 and -5.

### 20261002-15. 6c rule: `polymorphic_key_copy`, checked against the data.

- **Note:** First filed as 20261002-3. Renumbered when merging another machine's work, which had already used -3.

A hand-tuned Canvas query got much faster by repeating a predicate across a join. The original read:

```sql
FROM submissions JOIN assignments ON assignments.id = submissions.assignment_id ...
WHERE assignments.context_type = 'Course' AND assignments.context_id = 2588916 AND submissions.user_id = 2418270 ...
```

The tuned version keeps every predicate and adds `submissions.course_id = 2588916`, which lets Postgres narrow `submissions` before the join. The planner doesn't do this itself, because the query never states `submissions.course_id = assignments.context_id`.

The rule: when a query joins `s.<x>_id = a.id` and filters `a.<p>_type = '<Klass>'` and `a.<p>_id = <const>` (Rails's polymorphic convention), and `s` has a column named Rails's way for `<Klass>` (`Course` becomes `course_id`, and `Foo::Bar` becomes `foo_bar_id`), add `s.<klass>_id = <const>` and keep the original predicates. If a foreign key from that column exists, it must point at `<Klass>`'s table, and the rule doesn't fire otherwise.

The rewrite only adds a predicate, so it can drop rows but never add them. It's sound only if every joined row has `s.<klass>_id = a.<p>_id` when `a.<p>_type = '<Klass>'`. The catalog can't prove that from naming alone, so this rule is a heuristic, unlike the sound rules 6c describes. It's checked against the data instead:

- The rule states a new assumption kind, such as `denormalized_equal` (child column, parent column, type column, and type value).
- 6b checks it with one query on the real database, in the enclave: `EXISTS` a joined row where `a.<p>_type = '<Klass>'` and `s.<klass>_id IS DISTINCT FROM a.<p>_id`. Only the boolean leaves the jump server. If any such row exists, the assumption is unmet and the rewrite is dropped.
- The report marks the rewrite as resting on an empirical assumption, one the data holds today but the schema doesn't enforce, and names the columns.
- Steps 9 and 10 test it like any other rewrite. If they disprove it, the report doesn't call that a rule bug, since the assumption was empirical.

Open questions to settle before building: the cost of the `EXISTS` check on large tables (a statement timeout, and treat a timeout as unmet?), what to do when two candidate columns could match, and which Rails inflections to support (STI, namespaced classes, irregular plurals for the table check).

DESIGN.md 6c says every rule is sound by design. Update it to allow heuristic rules whose assumptions are checked against the data, and list the new assumption kind in 6b.

- **Depends on:** 20261001-22, 20261001-23.
- **Came from:** A hand-tuned query the user shared, 2026-10-02.
- **Design:** 6b, 6c, 15.
- **Note (2026-10-02, answers):** The data check runs on the racetrack with a 300000 ms statement timeout, and a timeout or error is unmet. Refuse when two columns could match. Naming: CamelCase to snake_case, `::` to `_`. If an FK exists, its target table must be the snake name plus `s` or `es`, or the rule doesn't fire. The rule never reads the type literal: it turns each candidate `<x>_id` column into its class name and asks `Literals#holds?` whether the placeholder equals it.
- **Note (2026-10-03, set aside for a question):** Built on `task/20261002-15` (worktree kept). The first review found two blocking issues.
  - **Trust boundary:** `rewrite-check` accepts `denormalized_equal` from any source, so an LLM or operator rewrite can probe production data. Fix: accept it only from `rule`.
  - **Step 9:** the rule's rewrite never passes step 9 on the Canvas shape. S1's hit row gives `course_id` a value other than the parent's `context_id`, so the rewrite is disproved and never ranked.
  - **Waiting on the user:** should step 9/10 fixtures honour `denormalized_equal`, or should a step 9/10 disproof of such a rewrite count as untested, leaving 14c's check on real data to decide?
- **Note (2026-10-04, answers):** Honour it. Step 9 and 10 fixtures for a rewrite that rests on `denormalized_equal` generate rows that keep the child column equal to the parent column wherever the type column holds the class. Also make the trust fix: accept `denormalized_equal` only from `rule`.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261002-15.
  - **6c rule `polymorphic_key_copy`:** it adds `child.<x>_id = $n`, reusing the placeholder, when the query filters `parent.<p>_type = $m AND parent.<p>_id = $n`. The class name comes only from `Literals#holds?`. The rule refuses when two columns match or an FK points to the wrong table.
  - **6b `denormalized_equal`:** an assumption checked against the data on the racetrack, read-only and within the time limit. Only a rule may state it; a rewrite from the LLM or an operator gets `bad_assumption`, with no probe.
  - **Steps 9 and 10:** fixtures honour a rule's own assumption, through `DenormalizedFixture`, inside the rolled-back transaction.
  - **Report:** each rewrite gets an `empirical` field, plus a driver sentence.
  - **Review:** round 1 had two blocking findings, the source trust check and the fixture honouring. The fix round fixed both, and round 2 was clean. The minors went to 20261004-9.

### 20261003-23. Step 9: break a cycle when the query joins on its nullable edge.

20261003-17 breaks a foreign-key cycle by cutting a nullable edge, but only when no predicate atom reads the edge's columns. A query that joins on that very edge, such as `JOIN courses c ON c.id = a.course_template_id` in Canvas, still refuses with `fk_cycle`. That's a common shape, so many real queries still can't be tested.

Find a sound way to break such a cycle. Two options:

- Cut a different edge in the cycle, one the query doesn't read, when there is one.
- Load the rows with the read column as NULL, then UPDATE it to its parent's key once every table is loaded. The deferred UPDATE from 20261003-17's counterexample path already does this, keyed by `tableoid` and `ctid`. The column then joins its key class as usual.

The second covers more cycles. It also fixes the minor finding from 20261003-17's review: a cut column is always NULL in step 9's fixtures, so a rewrite that depends on its value, such as adding `AND a.course_template_id IS NULL` or dropping a sort key on it, passes step 9 when it would fail on the same schema without the cycle.

Test it on real Postgres with a Canvas-like `accounts`/`courses` cycle and a query that joins on the nullable edge. Also test that the two rewrites above are disproved.

- **Depends on:** 20261003-17.
- **Came from:** The build and review of 20261003-17, 2026-10-03.
- **Design:** Step 9.
- **Note (2026-10-03, answers):** The user chose this as the next side task. Prefer the second option, loading NULL and then UPDATEing to the parent's key, since it covers more cycles and also tests the cut column's value.
- **Note (2026-10-03, not landed):** Built on `task/20261003-23` (kept, with its worktree). The first review's blocker (S6 empty on a cycle) was fixed. The second review found a regression that works on main: on a Canvas-like schema with a third table under `accounts`, `SELECT a.id FROM accounts a LEFT JOIN courses c ON c.account_id = a.id WHERE c.id IS NULL` fails every candidate with `fixture_load_failed`. It fails safe, but it can't land. The rest moved to 20261003-30, which finishes this on the same branch.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-23, together with 20261003-30.
  - **Change:** step 9 handles FK cycles the query joins through, by cutting the nullable edge, as in Canvas `accounts.course_template_id` → `courses` → `accounts`.
    - Cut columns are deferred: rows load first, and the cut column is set by UPDATE afterwards. The INSERT and UPDATE counts are checked, and a load error carries no value.
    - Copies and crosses keep their parent on a cut FK. The empty group's is NULL.
    - Work is in `scenarios/topology.rb`, `arena_runner/deferred.rb` and `spec/fk_cycle_postgres_spec.rb`.
  - **Review:** round 1 had one blocking finding: a dropped sort key on the cut column still passed under LIMIT, because copies NULLed the cut column. The fix round fixed it, and round 2 was clean. The minors went to 20261004-8.

### 20261003-30. Finish 20261003-23: a skipped group's cut-column key class.

20261003-23 is built on `task/20261003-23` (worktree `.claude/worktrees/20261003-23`) and passed one review. Its second review found a regression that main doesn't have. Fix it on that branch, then land 20261003-23 and this task together.

- **The regression.** The schema is Canvas-like: `accounts` has self-references `root_account_id` and `parent_account_id`, plus a nullable `course_template_id` that points at `courses`. `courses` has `account_id` and `root_account_id` (NOT NULL) and `enrollment_term_id`. `enrollment_terms` has `root_account_id` (NOT NULL). On this schema, `SELECT a.id FROM accounts a LEFT JOIN courses c ON c.account_id = a.id WHERE c.id IS NULL ORDER BY a.id` fails every candidate with `fixture_load_failed` at S3, and at S6 too. On main, the correct NOT EXISTS rewrite passes and the wrong ones are disproved.
- **Why.** `fk_edges` in `topology.rb` follows every foreign key, so the cut column `accounts.course_template_id` joins `courses.id`'s key class. The pool for `c.id IS NULL` is empty, because `courses.id` is a NOT NULL primary key, so the slot becomes `:skip`. That drops the hit's `accounts` row and the copy groups' `accounts` rows. But the `enrollment_terms` copy is still built with `root_account_id=1`, which now points at nothing.
- **Fix, either way:**
  - Keep a cut column out of a key class whose atom pool is empty.
  - When a group skips, also drop the copy and "many" rows that depend on it.
- **Test** with a third table under `accounts`. Reviewer reproducer, in the review scratch dir: `canvas_spec.rb`, case 7.
- **Also:** in `arena_runner/deferred.rb` (`load_rows`/`update_rows`), a row that RETURNING doesn't give back raises a bare `ArgumentError`. That happens, for example, with a BEFORE INSERT trigger that returns NULL. Raise `fixture_load_failed` instead, as DESIGN.md says.
- **Also (from 20261003-31's build, still open on main):** these are cases in the Canvas reproducer.
  - **Case 4:** `ORDER BY … NULLS FIRST` on a column that was cut to break a cycle still passes a wrong rewrite.
  - **Case 7:** the correct candidate's fixture fails to load at S6 because of the cycle.
  - **The cyclic form of 20261003-31's C6** isn't covered: a nullable FK in a cycle always points at its own group's parent. 20261003-31 fixed only the acyclic form.

- **Depends on:** 20261003-23 (its branch).
- **Came from:** The second review of 20261003-23, 2026-10-03.
- **Design:** Step 9.
- **Note (2026-10-03, set aside for a question):** Two review rounds ran on `task/20261003-23` (worktree kept).
  - **Round 1:** NULLing the cut column in every scenario let Rails's `where.missing(:course_template)` pass a wrong rewrite.
  - **Fix round:** the cut column is now NULL only where the group has no parent row.
  - **Round 2:** still blocking. Each group holds one account and one course, so "has a template" always means "has a course", and "the template" always means "the account's own course". The results:
    - For the anti-join `accounts LEFT JOIN courses ON account_id … c.id IS NULL`, the wrong rewrite `WHERE a.course_template_id IS NULL` passes, which main disproves.
    - In two cases main refuses with `fk_cycle`, and the branch passes a wrong rewrite: `where.missing(:course_template)` against "no courses", and a template lookup by `account_id`.
  - **A real fix** needs more varied scenarios: an account with courses and a NULL template, and a template pointing at another account's course.
  - **Question for the user:** keep pushing on that, or drop 20261003-23 and keep main's `fk_cycle` refusal for a query that joins on the cycle's nullable edge? Dropping it would make 20261003-18 (a refusal doesn't end the run) the way to keep such runs going.
- **Note (2026-10-04, answers):** Keep pushing. Build scenarios varied enough to break these cycles soundly, such as an account that has courses and a NULL template, and a template that points at another account's course.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-23, together with 20261003-30.
  - **Change:** step 9 handles FK cycles the query joins through, by cutting the nullable edge, as in Canvas `accounts.course_template_id` → `courses` → `accounts`.
    - Cut columns are deferred: rows load first, and the cut column is set by UPDATE afterwards. The INSERT and UPDATE counts are checked, and a load error carries no value.
    - Copies and crosses keep their parent on a cut FK. The empty group's is NULL.
    - Work is in `scenarios/topology.rb`, `arena_runner/deferred.rb` and `spec/fk_cycle_postgres_spec.rb`.
  - **Review:** round 1 had one blocking finding: a dropped sort key on the cut column still passed under LIMIT, because copies NULLed the cut column. The fix round fixed it, and round 2 was clean. The minors went to 20261004-8.

### 20261003-16. `quaack run`: a live clock instead of "Still working" lines.

Today a long step in `quaack run` prints a new line every 30 seconds:

```
quaack: [6/18] Asking the LLM for rewrites of the query (6a)
quaack: [6/18] Asking the LLM (6a)
quaack: [6/18] Still working, 30s so far (6a)
quaack: [6/18] Still working, 1m00s so far (6a)
quaack: [6/18] Done in 1m10s (6a)
```

Instead, the line the step is on should carry a clock that counts up in place, and no "Still working" lines should print. The run above would end up as:

```
quaack: [6/18] Asking the LLM for rewrites of the query (6a)
quaack: [6/18] Asking the LLM (6a) 1m10s
quaack: [6/18] Done in 1m10s (6a)
```

The rule:

- The clock goes on the last line printed, whether that's the step's own line or a note under it. It updates about once a second by redrawing that line with `\r` and clearing to the end of the line.
- When a new line prints, the previous line keeps its final clock reading and stops updating.
- The heartbeat thread and `say` already share a lock. Redraws must take it too, so a note never prints in the middle of a redraw.
- When stderr isn't a terminal, such as when it's piped to a log file, nothing gets redrawn and no "Still working" lines print. Only the closing line gives the time the step took.
- The clock carries only a duration, so nothing new crosses the trust boundary.

Specs use a fake clock and a fake terminal `io`. They check the exact bytes in both cases.

20261003-15 changes the closing line. Whichever lands second fits in with the other.

- **Depends on:** none.
- **Came from:** The user, 2026-10-03.
- **Design:** Progress lines for `quaack run`.
- **Note (2026-10-03, answers):** The clock goes on the latest line printed, including notes. When the output isn't a terminal, there are no live updates and no "Still working" lines. The closing line gives the final time.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-16.
  - **Change:** in `driver/lib/quaack/driver/progress.rb`, the "Still working" lines are gone.
    - **On a terminal:** the open line carries a live clock, redrawn about once a second under the shared lock. The line plus its clock is cut to fit `IO#winsize`, and a cut line is reprinted whole before its newline. The timer thread is joined before the closing line.
    - **On a pipe:** no thread and no redraws.
  - **Review:** round 1 had one blocking finding: long lines wrapped on narrow terminals and stacked up copies. The fix round fixed it, and round 2 was clean. The minors went to 20261004-7 and -13.

### 20261001-29. Renumber step 6 in running order, and give the rules table examples.

DESIGN.md says mechanical rules (6c) run before candidate generation (6a) and the assumption check (6b). Number them in the order they run: 6c becomes 6a, 6a becomes 6b, and 6b becomes 6c.

- Rename everywhere, not only in DESIGN.md: README, BACKLOG.md's open tasks, code comments, error and report text, and names that carry the number, such as the protocol's burndown stages and LLM steps (`6a`, `6b`) and the driver's `STEP`. Rename in BACKLOG-COMPLETE.md too (the user, 2026-10-01), so every file uses one numbering.
- A store written before the rename holds burndown records under the old stage names. Say what a resumed run does with them: refuse, or read them under the new names.
- The before and after SQL examples for each rule moved to 20261004-14 (the user, 2026-10-04).

Do this after 20261001-22 to -28 land, or between two of them, never while one is in flight: it touches the same lines.

- **Depends on:** 20261001-22.
- **Came from:** The user, 2026-10-01.
- **Design:** Step 6.
- **Decided (the user, 2026-10-04):** Dropped, superseded by 20261003-21, which renames every step to a slug and numbers steps in run order. -21 keeps the ordering this task asked for: the mechanical rules (old 6c) run first, candidate generation (old 6a) next, and the assumption check (old 6b) last of the three. The question about stored burndown stage names moved into -21.
- **Status:** dropped

### 20261003-21. Give the design's steps descriptive names, and number them in order.

The design's steps have IDs like `5a-6`, `6c`, `steps 9-10` and `14b`. They show up in `quaack run`'s output, such as `quaack: [5/18] Applying QUAACK's own rewrite rules to the query (6c)`, and also in the code, the run store's keys, the report and the specs. They say nothing about what a step does. Some are lettered sub-steps of a number, and their order doesn't match the order the pipeline runs them in (6c runs before 6a).

The rule:

- Give every step a short descriptive slug, in lowercase words joined by hyphens, such as `index-search`, `llm-index-ideas`, `llm-index-refine`, `rewrite-rules`, `llm-rewrites`, `counterexamples`. Some steps have slugs already (`index-search`, `index-rank`, `rewrite-prune`, `rewrite-test`); keep those unless they're unclear.
- Use the slug everywhere the old ID was used:
  - DESIGN.md's headings and cross-references;
  - the code, including `Pipeline::SAY`, the progress lines, and the protocol's step names;
  - the run store's keys;
  - the report payload and the readable report;
  - specs and fixtures, including the recorded replay runs, which may need re-recording.
  
  Progress lines keep the slug in parentheses at the end, as now.
- In DESIGN.md, also number the steps in the order the pipeline runs them. The numbers say order only, and the slug stays the name. The numbering has to show the pipeline's loops. Number a loop's body as sub-steps of the loop, such as `7. For each rewrite:` then `7.1 rewrite-index-search`, `7.2 rewrite-prune`. Say plainly where a loop repeats, such as the counterexample rounds: "repeat 9.2–9.4 until …". Put one ordered outline of the whole pipeline near the top of DESIGN.md, which is the only place the numbers appear. Code and output use slugs only, so renumbering never touches code.
- Add a table to DESIGN.md mapping each old ID to its new slug. BACKLOG-COMPLETE.md is history and keeps the old IDs, and the table keeps those entries readable. Update BACKLOG.md's open entries to the new slugs.
- Changing the store keys means a run started by an older version can't be resumed. That's fine with a version bump. Make sure `quaack run` refuses such a run with a clear message, rather than misreading it.

This touches nearly every file, so build it when no other task is in flight, or merge carefully with whatever is. It may be worth splitting into DESIGN.md first (outline, slugs, mapping table), then code and store keys. If so, the builder should propose the split before starting.

- **Depends on:** none. Best built after 20261003-15, -16 and -20, which change the same progress lines.
- **Came from:** The user, 2026-10-03.
- **Design:** All of it.
- **Note (2026-10-03, answers):** Rename every step to a descriptive slug across DESIGN.md, the code, the store keys and the report, and keep the slug in the progress lines. DESIGN.md also numbers the steps in run order, with a numbering that shows the pipeline's loops.
- **Note (2026-10-04, answers):** Build it all in one task: DESIGN.md, code, store keys, and the version bump. Number sections 1–4 (input, inventory, schema, run server) as steps in the outline too. The main session approves the slugs. This task absorbs the dropped 20261001-29: the outline must put the mechanical rules (old 6c) before candidate generation (old 6a), and the assumption check (old 6b) last of the three. It also says what a resumed run does with burndown records stored under the old stage names, which is to refuse the run like any other run from an older version.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-21, with every gem at 0.1.3 and `rake full` passed.
  - **Change:** steps, stages, store keys, LLM step names and report fates use slugs. DESIGN.md has a run-order outline (the only numbered place) and an old ID → slug table, and its prose now matches the code: setup order, arena placement, the vacuity guard before the scenarios, and `rewrite-check` after `rewrite-rules`, `llm-rewrites` and `operator-rewrites`.
  - **Older runs:** new stores carry `store_format` `{"format": 2}`. `quaacks` refuses an older run as `run_from_older_version` (except `teardown`), and `quaack run` and `quaack setup` explain what to do.
  - **LLM step split:** `rewrite-index-ideas`'s asks are counted under `rewrite-llm-index-ideas` and `rewrite-llm-index-refine`.
  - **Review:** one round, with no blocking findings. The minors went to 20261004-15.

### 20261003-20. Give each rewrite a whimsical name.

Rewrites are called "Rewrite 1", "Rewrite 2" and so on, in the progress lines (`pipeline.rb`'s `progress.within("Rewrite #{number}")`) and in the report (`report/words.rb` and `report/candidates.rb`). Numbers are easy to mix up across runs. Give each rewrite a name instead, such as "Rewrite Silver Fox" or "Rewrite Blue Lagoon".

The rule:

- Add two hand-written word lists to the driver: 200 adjectives and 200 nouns, each of one or two syllables. Keep them family-friendly, with no duplicates, and each word in only one list. Record each word's syllable count next to it, so nothing has to count syllables at run time.
- A name is "Adjective Noun", title case, with three syllables in total: a one-syllable adjective with a two-syllable noun, or the other way round.
- The names in one run are all different, and the same run always gives the same names, so a resumed run (or a report rebuilt later) agrees with the first. Pick them with a random generator seeded from the run ID, in rewrite order.
- The name is only a label. The store keys, protocol messages and the enclave keep the rewrite's number (`rewrite_3`), and the driver maps the number to the name wherever a person reads it: progress lines, the readable report, `candidates.rb`'s descriptions, and the LLM prompts that talk about a rewrite. The report payload carries both.
- Names come from the driver's own lists, never from enclave data, so nothing new crosses the trust boundary.

Tests check that both lists have 200 words, no duplicates, and the syllable counts given, and that every name has three syllables. They check that one run ID always gives the same names, that names don't repeat in a run, and that the progress lines and report use the names. Spot-check the syllable counts by hand at review.

- **Depends on:** none. 20261003-15 and -16 also change the progress lines. Whichever lands later fits in with the others.
- **Came from:** The user, 2026-10-03.
- **Design:** Progress lines for `quaack run`, report.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261003-20.
  - **Change:** `driver/lib/quaack/driver/rewrite_names.rb` holds 200 adjectives and 200 nouns, half of one syllable and half of two. That gives 20,000 three-syllable names. The name for rewrite N is the Nth pair of a shuffle seeded by SHA-256 of the run ID and the draw's position, so it's stable across processes and resumes. Past the last name, the label falls back to "Rewrite <n>".
  - **Where names show:** progress lines and the readable report use names. The payload carries `name` next to the number. Anchors, the store, the protocol and the enclave keep the number. No LLM prompt named a rewrite by number, so none changed.
  - **Review:** one round, with no blocking findings. The minors went to 20261004-16.

### 20261004-16. Rewrite names: drop word pairs that read badly.

From the review of 20261003-20. Each word in `driver/lib/quaack/driver/rewrite_names.rb` is family-friendly alone, but some pairs aren't: "Pink Beaver" is crude slang, and "Brown Monkey" or "Tan Monkey" can read as racial. `report_spec.rb` even shows "Pink Monkey". Drop `beaver` and `monkey`, and replace them with harmless two-syllable nouns so each list keeps 100 one-syllable and 100 two-syllable words. Re-check every color adjective against animal nouns for a similar reading. Update any spec that names a dropped word.

Also minor: `RewriteNames.name` replays every draw up to n on each call. That's negligible at real sizes. Memoize per run only if it's simple.

- **Depends on:** 20261003-20.
- **Came from:** The review of 20261003-20.
- **Design:** Progress lines for `quaack run`, report.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261004-16.
  - **Change:** 21 words were swapped for others with the same syllable count, among them `beaver`, `monkey`, `pink`, `rocket`, `crystal` and `waffle`. A spec pins the dropped words, and checks that none of the bad pairs can be drawn. No memoization: the replay costs next to nothing.
  - **Review:** round 1 blocked on "Blue Waffle", the fix round swapped `waffle` for `parsnip`, and round 2 was clean. The minors went to 20261004-20.

### 20261004-18. `quaack start --port`: production's port.

`quaack start` takes only `--server`, so every production connection passes only the host: inventory, qualify, statistics, volatility, and schema-dump's `pg_dump`. libpq then takes the port from `PGPORT`, or falls back to 5432. The user's production servers don't listen on 5432, and `PGPORT` applies to every server, so a run can't name its own port (the user, 2026-10-04).

- `quaack start` takes an optional `--port <n>`, passed to `quaacks intake --port`. Check it the way `run-server` checks its `--port`.
- Intake stores it with the run's `server`, in a way that leaves runs without it working as now. Without `--port`, nothing changes: libpq's setup decides.
- Every production connection uses it: each `PG.connect`, and `pg_dump --port`. Find them all, ideally through one helper, so a new step can't forget it.
- It must not change the run server's connections, which already have their own port.
- A real-Postgres spec runs production on a port other than 5432, with `PGPORT` unset or wrong, and checks that each production step connects.
- Update README's `quaack start` section and DESIGN.md's intake, inventory and schema-dump. The port is the operator's own input, not production data, so it doesn't cross the trust boundary. Say so.
- If the store format changes, follow `store_format`. A gem version bump comes with it.

- **Depends on:** none. 20261004-17's note should mention `--port` once this lands.
- **Came from:** The user, 2026-10-04.
- **Design:** intake, inventory, schema-dump, Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-04, as a merge of task/20261004-18, with every gem at 0.1.4 and `rake full` passed.
  - **Change:** `quaack start --port <n>` goes to `quaacks intake --port`, which stores a `production_port` entry only when given. Inventory, qualify, volatility, statistics and schema-dump connect through `Inventory::Production.params(store)`. pg_dump gets the port in its `--dbname` conninfo. A shared `Protocol::Port.valid?` also checks run-server's port. No `store_format` bump: a store without the entry means libpq decides, as before.
  - **Review:** one round, with no blocking findings. The minors went to 20261004-22.

### 20261004-20. Rewrite names: ambiguous words and borderline pairs.

Minor findings from both reviews of 20261004-16, in `driver/lib/quaack/driver/rewrite_names.rb`:

- **Ambiguous syllable counts:** `owl` is often said "ow-ul", and `sparkly` "spar-kuh-lee". Swap each for an unambiguous word with the same count.
- **Borderline pairs:** "Fuzzy Clam", "Woolly Clam" and "Fluffy Clam" ("clam" is crude slang), "Fuzzy Duck" (a crude spoonerism), "Fuzzy Plum", and "Golden Dawn" (a Greek neo-Nazi party). Dropping `clam`, `fuzzy` and `dawn`, or similar, fixes them. Add them to the spec's bad-pair list.
- **Dead test entry:** "Eager Beaver" in the spec's bad-pair list can never be drawn, since both words have two syllables. Replace it with a drawable pair, or drop it.

Each list keeps 100 one-syllable and 100 two-syllable words. Update the names pinned in specs that move.

- **Depends on:** 20261004-16.
- **Came from:** Both reviews of 20261004-16.
- **Design:** Progress lines for `quaack run`, report.
- **Status:** done
- **Landed:** merge bd543c4. Swapped owl, sparkly, clam, dawn and fuzzy for kelp, gleaming, lute, sled and fearless; dropped "Eager Beaver". The review was clean. Its minors were accepted as is: the syllable spec checks a fixed list, and "fearless" has an accent-dependent syllable count like "deer".

### 20261004-19. `quaack run` on a terminal: drop lines the live clock makes redundant.

Since the live clock (20261003-16) landed, a terminal shows some steps' time twice (the user, 2026-10-04):

```
quaack: [13/29] Asking the LLM for index ideas the mechanical search missed (llm-index-ideas) 2s
quaack: [13/29] Asking the LLM for index ideas (llm-index-ideas) 32s
```

Other steps add real information in the lines after the first, and that must stay:

```
quaack: [17/29] Asking the LLM for rewrites of the query (llm-rewrites)
quaack: [17/29] Asking the LLM (llm-rewrites) 51s
quaack: [17/29] Got 3 rewrites from the LLM, 3 kept in 51s (llm-rewrites)
```

The rule, on a terminal only:

- **Closing lines with no summary:** a step that would close with the bare `Done in <time>` prints no closing line. The open line's frozen clock already gives the time, so make sure it does: the last open line ends at the step's final reading, even under one second.
- **Closing lines with a summary,** such as "Got 3 rewrites from the LLM, 3 kept in 51s", still print. So does `Failed after <time>`.
- **Notes that only repeat the step:** an LLM ask's note (`LLM::Client::ASKING`, or a `purpose` that says no more than the step's own line, as "Asking the LLM for index ideas" does under llm-index-ideas) adds nothing when it's the step's only ask. Leave it out, and let the step's own line keep the clock.
  - Notes that add something stay: a second ask, a re-ask, "again for replacements", a sub-step under `within`, or a count.
  - Check the real output for each LLM step to see which notes these are. Example 1 may be such a note rather than a closing line.
- **Not a terminal** (a pipe or a log file): nothing changes. Every line prints as now, since there's no clock there.

Specs use the fake clock and the fake terminal `io` that progress_spec.rb already has. Pin the exact bytes in both modes, for a step with a summary, one without, a failed one, and one with a single LLM ask. Update README's and DESIGN.md's progress examples to match.

- **Depends on:** none.
- **Came from:** The user, 2026-10-04.
- **Design:** Progress lines for `quaack run`.
- **Status:** done
- **Landed:** merge 08cfe07. On a terminal, steps with no summary print no `Done in` line, and an LLM ask line that repeats its step (first line after the step, same ID, words a prefix of the description) is dropped. Summaries and `Failed after` still print. The review had no blocking findings; its minors are 20261004-25.

### 20261004-21. Make `incomplete` failures diagnosable.

A real `quaack run` failed 3 minutes into Shiny Boat's counterexamples, after a 19m39s rewrite-test on the same rewrite, with nothing but `quaack run failed: incomplete` (the user, 2026-10-04). The operator can't tell which `quaacks` call died or how.

- **Say what died.** For `incomplete`, `rule_with_note` adds the subcommand and how it ended: the exit status, or the signal. `EnclaveError` already has these, and they're the driver's own data, not the enclave's. Say that exit 255 means the ssh session ended or failed to connect, or the remote process was killed, and point at the jump server's kernel log (OOM killer) and sshd log.
- **ssh keepalive and connect timeout.** Add `ServerAliveInterval`, `ServerAliveCountMax` and `ConnectTimeout` to `Transport::Ssh::DEFAULT_OPTIONS`.
  - The keepalive stops an idle firewall or NAT dropping a quiet, long call, and notices a dead link rather than hanging until the transport's timeout.
  - The connect timeout makes a failed connect fail in seconds, not the ~3 minutes TCP takes.
  - Document it in README's ssh section, including the risk of a stale `ControlMaster` socket after a long, quiet call.
- **Retrying a failed connect.** In the user's run, the call after a 19m39s `rewrite-test` (`counterexample-payload`) never reached the jump server: `quaacks` never ran. Consider retrying a call once when ssh exits 255 with no stdout at all. Only do it if that can be told apart from a remote process killed before it printed anything, or if every subcommand it would retry is safe to run twice. Say which.
- **Give enclave calls their own progress line.** The counterexamples step's line, "Asking the LLM for rows that could break the rewrite", prints before `quaacks counterexample-payload` runs, and each round's `counterexample-round` prints nothing either. So the clock under an LLM line covered enclave calls, which made the failure look like the LLM's, when an LLM failure is always an `llm_*` rule. Give the enclave calls their own notes, and check the other steps for enclave calls hidden under an LLM line the same way.
- **Find the cause** once the user reports what the jump server's logs show. If the OOM killer or a slow fixture load in rewrite-test or counterexample-compare is at fault, open a task for it.
- **Name ssh failures.** The user's failure was most likely their ssh authentication expiring mid-run, which `BatchMode=yes` turns into exit 255 with no output. When a call ends that way, the driver should run a probe, `ssh <options> -- <host> true`, which runs no `quaacks` and so carries no enclave data. If the probe fails too, report a rule of its own, such as `ssh_failed`, with a note: "couldn't ssh to the jump server; check your ssh login or network, then resume with `quaack run --run <ID>`." Keep `incomplete` for a remote process that died.

- **Depends on:** none.
- **Came from:** The user, 2026-10-04.
- **Design:** Where QUAACK runs, Transport.
- **Status:** done
- **Landed:** merge b402978, plus a follow-up refactor that moves the terminal-width read into Fit to keep Progress under RuboCop ClassLength. `incomplete` names the subcommand and exit status or signal; exit 255 with no stdout probes `ssh … true`, and a failed probe gives `ssh_failed` with a resume hint for each command; ssh keepalive and ConnectTimeout defaults; progress notes for enclave calls under LLM lines; deploy fails cleanly on ssh_failed at its version check. No retry, no version bump. Round 1 found one blocking issue (deploy crash), now fixed; round 2 was clean. Minors are 20261004-26.

### 20261004-23. rewrite-test spends ~20 minutes of Ruby CPU per rewrite.

In the user's real run (2026-10-04), each `quaacks rewrite-test --search rewrite_<n>` took 20–21 minutes (21m11s, 21m05s, 19m47s, 21m11s), whatever the rewrite. The process pegs one core while the arena sits idle: its last query is a `ROLLBACK` minutes old. rbspy can't attach to Ubuntu's packaged `ruby3.4` ("Couldn't find Ruby VM address").

1. **Profiler.** When `QUAACKS_PROFILE=<path>` is set, `quaacks` starts a thread that samples `Thread.main.backtrace_locations` every 10 ms. At exit it writes a count of each `path:lineno` (self and total) to `<path>` on the jump server.
   - Use only the standard library, with no new gem; `Boundary::ENCLAVE_ALLOWED_GEMS` stays as it is.
   - It records code locations only, never values, and never goes to stdout, so nothing crosses the trust boundary. A spec plants a sentinel in the data and checks it's absent from the profile.
   - Document it in README's troubleshooting.
2. **Reproduce.** Build a realistic, larger fixture, such as a Rails-style schema with 10–20 tables, several unique indexes and foreign keys, CHECK constraints, and a few-table join query. Time `rewrite-test` on it, and profile it with (1).
3. **Fix the hotspots** the profile shows, keeping every outcome the same.
   - Code reading suggests `Scenarios::RowSet` is the first suspect: `parents_of` uses `Array#include?`, `parent` runs a linear `find` per foreign key per row, and `clash?` scans the table's rows per unique constraint per new row. Hash indexes would fix all three.
   - The user's gdb samples (2026-10-04) back this up. All five native stacks sit in structural equality and hashing:
     - `rb_equal` → `rb_funcallv` → `rb_equal`, nested.
     - `rb_st_lookup` → `rb_eql`, wrapping `rb_hash_aset` and `rb_hash_delete_entry`. That's Ruby's recursion guard for comparing or hashing nested objects.
     - All of it sits under `rb_hash_foreach` and many nested `rb_yield` frames.
     That matches whole `ArenaFixture::FixtureRow` values (a `Data` holding arrays and a nested `DeferredInsert`) being compared and hashed over and over:
     - `@rows[t].include?(r)` and `.delete` in `add?`.
     - `tried.include?(rows)` in `add_any?`.
     - `found.include?` and `rows.include?` in `parents_of`.
     - `.uniq` in `Parts#spill?`.
     - The `@evaluated` cache keyed on `[row, index]`, which `clash?` hits for every existing row.
     Key on cheap identities instead, such as `object_id`, a per-row integer, or precomputed key tuples per constraint.
   - Each rewrite runs in a new process and rebuilds the original query's scenarios and probe caches. Consider storing what's reusable in the run store, as 20261004-5 does within one process.
   - Add a timing guard spec on the large fixture with a generous bound, so a regression shows up.
4. **Ask the user** to rerun with `QUAACKS_PROFILE` set, and confirm.

- **Depends on:** none. Related to 20261004-5.
- **Came from:** The user, 2026-10-04.
- **Design:** rewrite-test, Where QUAACK runs.
- **Status:** done
- **Landed:** merge e57a7fe. The profile showed `Topology#members` comparing `[TableName, name]` pairs, which matches the gdb stacks; fixed with `Slots`. Also memoized result-comparison Shapes and their queries (cleared at 64), each build's rows in `Parts#spill?`, and shared expression-index keys (484 queries become 5). CPU on a 19-table Rails-style fixture went from about 25 s to about 3 s, with byte-identical outputs. Added `QUAACKS_PROFILE`, a stdlib sampling profiler, and a 12 s timing guard. The review had no blocking findings. Confirming on the user's schema, RowSet scans and the minors are 20261004-27.

### 20261004-24. Flaky ProductionComparison timeout spec under load.

`enclave/spec/production_comparison_postgres_spec.rb:116` ("LIMIT without ORDER BY is partial when the full original times out and the count matches") failed once. It hit a `PG::QueryCanceled` raised from `ProductionComparison.take`, through `Run#digest` and `#read`, instead of returning `partial subset_timed_out`. That run had several spec suites sharing Docker; the spec passed 3 of 3 times on its own.

Under load, a 1 s statement timeout can fire during the LIMIT run itself, not only the full run, and that path raises instead of giving a verdict.

1. Find out whether a production run can hit the same path. If a slow server can make the LIMIT run time out, `take` should give a verdict (`timed_out`, or whatever DESIGN.md's result-comparison says), not raise. Fix that with a test first.
2. Make the spec robust to load, for example with a larger gap between the LIMIT run's cost and the timeout.

- **Depends on:** none.
- **Came from:** The per-commit check on main after landing 20261004-19, 2026-10-04.
- **Design:** result-comparison.
- **Status:** done
- **Landed:** merge baeaab0. The cause was `Run#stream` judging a cancel against the enclave's own clock with no margin. `Run` now reads the server's `clock_timestamp()` before each query and sets a savepoint; after a cancel it rolls back to the savepoint and compares server clock readings. The subset specs sleep only on rows past the LIMIT. The review had no blocking findings. Its minors went to 20261004-28. Accepted as is: a backwards server clock step still raises.

### 20261004-26. ssh_failed and incomplete: resume advice after teardown, and the ControlMaster note.

Minor findings from the first review of 20261004-21:

1. **Resume advice without `--keep`.** README's `incomplete` row (`README.md`, the errors table) says "then resume the run". But `quaack run` without `--keep` tears down on failure (`cli.rb`, `Teardown.around`). When the probe succeeded, ssh works, so teardown has likely deleted the store and there's nothing to resume.
   - For `ssh_failed`, the teardown that follows fails too. The operator then gets both "Run this on the jump server: quaacks teardown" and "resume with `quaack run --run`", which contradict each other.
   - Each failed teardown also probes again, adding up to 30 s.
   - Make the advice match what's left: say "resume" only when the store was kept (or teardown failed), and skip the probe or teardown once ssh is known down.
2. **ControlMaster note.** README's note says "If calls start failing with `ssh_failed` while plain `ssh <host>` works". But plain `ssh <host>` goes through the same `ControlPath` socket and fails the same way, and the `-o ServerAlive*` options don't reach an existing master. Rewrite it: suggest `ssh -O exit <host>`, or `ssh -o ControlMaster=no -o ControlPath=none <host>` to test.

- **Depends on:** 20261004-21.
- **Came from:** The first review of 20261004-21.
- **Design:** Transport, Where QUAACK runs.
- **Status:** done
- **Landed:** merge d383d93. `quaack run` says resume only while the store is left (`--keep`, a failed teardown, or no teardown), and otherwise says to start a new run. After `ssh_failed`, teardown is skipped and its command is printed for later. `incomplete` ends with a command-specific "To go on". The ControlMaster note is rewritten. The review had no blocking findings; its minors are 20261004-29.

### 20261004-29. Docs and wording after ssh_failed skips teardown.

Minor findings from the review of 20261004-26. After `ssh_failed`, `quaack run` now skips teardown, so the run's files, which hold copies of production data, stay on the jump server, and the run server isn't destroyed:

1. README's `--keep` paragraph says that without `--keep`, QUAACK deletes the run's files "whether it succeeded or failed" and destroys the run server. Step 5 says to tear down only "If you used `--keep`". Mention the `ssh_failed` exception in both.
2. DESIGN.md says a failing setup step in `quaack run` "is torn down unless `--keep`, as for any step". Add the `ssh_failed` exception.
3. README's `ssh_failed` row says only "keeps the run". Say that the run server, and the production data on it, stays up until you run the printed teardown command.
4. `teardown.rb`'s `interrupted` message still says "Run this on the jump server:". Reword it to "To tear it down later, run this on the jump server:", like the other teardown hints.
5. When a run succeeds but teardown then fails, the message still says to resume with `quaack run --run`, which redoes the run's last steps. Teardown alone would do: say that.

- **Depends on:** 20261004-26.
- **Came from:** The review of 20261004-26.
- **Design:** Where QUAACK runs, Transport.
- **Status:** done
- **Landed:** merge 767713d. A run that succeeds and then fails teardown now advises running the teardown command instead of resuming. The interrupted-teardown hint is reworded. README and DESIGN.md say that ssh_failed leaves the run's files and the run server until teardown. The review had no blocking findings; its minors are 20261004-31.

### 20261004-31. A run that finished but couldn't tear down: show the report, and tidy the advice.

Minor findings from the review of 20261004-29:

1. **Report path not shown.** When a run succeeds and then teardown fails, `drive` never prints the report path, because teardown raises first, even though the report file was written. The failure message says "the run itself finished", so print the report's path too. Test first.
2. **Teardown command printed twice.** The same case prints it once in the "couldn't tear down" line and again in "quaack run failed". Print it once.
3. **README step 5** says "QUAACK printed this command for it". That isn't true when teardown fails with `bad_run`, `bad_store_base` or `teardown_failed`, where QUAACK says to check or remove `~/.quaack/runs/<ID>` by hand. Reword it.
4. **Wording:** README and DESIGN.md say the run's files and the run server "stay up". Say the files "remain".

- **Depends on:** 20261004-29.
- **Came from:** The review of 20261004-29.
- **Design:** Where QUAACK runs, report.
- **Status:** done
- **Landed:** Landed in 30f839a. Review minors went to 20261004-32.

### 20261004-30. Flaky run-server-check spec: a young client listed before an old one.

`enclave/spec/run_server_check_postgres_spec.rb`, "names the oldest other client first, whatever order pg_stat_activity lists them in", failed once during the build of 20261004-28. Its helper `connect_listed_before` opens and closes up to 1000 connections, hoping one lands in an earlier `pg_stat_activity` slot than `old`. That never happened, and the file passed when run alone.

Make it deterministic. For example, free an earlier slot on purpose first: open a connection before `old`, close it, then connect. Or test the ordering on a stubbed list of `pg_stat_activity` rows, while still covering the real query's ORDER BY.

- **Depends on:** none.
- **Came from:** The builder of 20261004-28.
- **Design:** run-server checks.
- **Status:** done
- **Landed:** Landed in 67b5f61. Review minors went to 20261004-33.

### 20261004-28. Timeout checks on the enclave's clock: RunDiscipline and ArenaRunner.

20261004-24 found that `ProductionComparison::Run#stream` decided whether a `QueryCanceled` was a statement timeout by checking the enclave's own clock against `timeout_ms`, with no margin. Postgres fires `statement_timeout` by the server's clock. Measured at 1 s, the enclave saw the cancel after as little as 1001.3 ms, so a slightly fast clock, from load or NTP drift between the jump server and the run server, turns a timeout into an uncaught error. `RunDiscipline.timed` and `ArenaRunner::Cancel` use the same zero-margin check.

Fix them the way 20261004-24 fixed `Run`, or with a shared helper. Write a test first that simulates a slow enclave clock.

Also, from the review of 20261004-24:
- Update DESIGN.md's run-discipline wording to match the fix.
- The operator-cancel spec in `enclave/spec/production_comparison_postgres_spec.rb` cancels after a fixed `sleep 0.3`. Under load the cancel can land while the backend is idle and get dropped. Wait for `pg_stat_activity` to show `pg_sleep` before cancelling.

- **Depends on:** 20261004-24.
- **Came from:** The builder of 20261004-24.
- **Design:** result-comparison, rewrite-test, minimax.
- **Status:** done
- **Landed:** Landed in b3b745d. Review minors went to 20261004-34 and 20261004-36.

### 20261004-17. Explain `production_connection_failed`.

`quaack setup` failing with a bare `production_connection_failed` (the user, 2026-10-04) leaves the operator guessing. The enclave connects to production with `PG.connect(host:)`, where the host is the `server` that `quaack start` recorded. The port, user, database and password come only from libpq's own setup on the jump server, in the non-interactive ssh session QUAACK runs in. The setup's own `--host` and `--port` are for the run server, and don't apply.

Add a fixed note to `EnclaveError#rule_with_note` for this rule, the way `run_from_older_version` has one. It should say:

- which host was tried (the driver knows the run's `server`, so it doesn't have to come from the enclave);
- that the port, user, database and password come from `PG*` variables, `~/.pg_service.conf` with `PGSERVICE`, and `~/.pgpass` on the jump server, and that a non-interactive ssh session may not load the shell rc file that sets them;
- how to test it: `ssh <jump> 'psql -h <server> -c "select 1"'`.

It must never carry libpq's message, which can name the user or the database. Do the same for the run server's connection failure, if it has its own rule. Check README's setup section says this too.

- **Depends on:** none. Mention `quaack start --port` (20261004-18, landed) in the note.
- **Came from:** The user, 2026-10-04.
- **Design:** inventory, Where QUAACK runs.
- **Status:** done
- **Landed:** Landed in 257615e. Review minors went to 20261004-37.

### 20261004-37. Connection-failure notes: follow-ups.

These are review minors from 20261004-17.

1. README says "the message says which server it tried" for both connection failures, but the `run_server_connection_failed` note names no host. Fix README.
2. Remove the inline `Metrics/AbcSize` disable on `run_command` in `driver/lib/quaack/driver/cli.rb`. It's the only one in any gem's `lib`. Split the method instead, for example by moving the run lookup and transport setup into a helper.
3. Record `quaack start --port` in the run record too, so the note's psql test command can include `-p <n>` exactly instead of "adding -p <n> if you gave…".
4. In the note, "It gives libpq only that host" doesn't say who "It" is. Say "QUAACK gives libpq…".

- **Depends on:** 20261004-17.
- **Came from:** The review of 20261004-17.
- **Design:** inventory, Where QUAACK runs.
- **Status:** done
- **Landed:** Landed in 460dbd0. Review minors went to 20261004-40.

### 20261004-36. ArenaRunner: no statements after a cancel's rollback.

This is a review minor from 20261004-28. `ArenaRunner::Cancel.rule` now rolls back the whole arena transaction after a cancel, where main left it aborted. If a fixture block caught the error and ran another query, that query would run outside any transaction and without `statement_timeout`. The reviewer reproduced it: a `WITH d AS (INSERT …) SELECT …` caught by the select-only check wrote a row that stayed in the arena. Main fails such a query with 25P02. No caller catches errors inside a fixture block today.

Refuse to send a statement when the connection isn't inside the runner's transaction. Checking `transaction_status` before each send is one way; closing the handle after a cancel is another. Write a test first. Also leave pipeline mode on a dead connection, or document that it stays in it.

- **Depends on:** 20261004-28.
- **Came from:** The second review of 20261004-28.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** Landed in d1d9420. Review minors went to 20261004-41.

### 20261004-35. Order-dependent Deparse cache spec.

`spec/result_comparison_spec.rb:172` (the `Deparse.faithfully` call-count spec from 20261004-23) failed once under `rake` with seed 34956: it expected 4 calls and got 8. It passes alone. It's probably sharing the cache with an earlier example. Reproduce with that seed, then isolate the cache per example or reset it.

- **Depends on:** 20261004-23.
- **Came from:** The builder of 20261004-28.
- **Design:** none (tests only).
- **Status:** done
- **Landed:** Landed in fcd2b7a. Review minors went to 20261004-42.

### 20261004-40. Connection note: port wording.

These are review minors from 20261004-37.

1. README (around line 442) says the message "names the production server and port it tried". It names a port only when `quaack start --port` gave one. Change it to "and its port, if you gave `quaack start --port`".
2. A hand-edited run record with a valid port but an invalid server gives `psql -h <server> -p 6543`, which is half filled in. Leave out `-p` when the server is the placeholder, or accept it as is and say so.

- **Depends on:** 20261004-37.
- **Came from:** The review of 20261004-37.
- **Design:** inventory.
- **Status:** done
- **Landed:** Landed in da1cf3e. One review minor, the README wording for runs with no recorded server, went to 20261004-44. The other minor questioned this task's own choice to drop -p when the server is unknown, which only affects hand-edited records, so it wasn't filed.

### 20261004-39. ArenaRunner pipeline: a timeout before the Sync leaves the connection stuck.

The builder of 20261004-36 found this. A denormalized-fixture spec with a 1 ms `statement_timeout` fails under CPU load, on main too. The timeout can fire after a statement but before the pipeline's final Sync is processed. Then `Pipeline.finish` raises `Broken` and the connection stays in pipeline mode with the Sync unread, so every later run on it reports `connection_unusable` instead of the timeout. Rare with real timeouts, but it's a real race in the 20261004-28 pipeline.

When a cancel or timeout arrives while the pipeline is finishing, drain to the Sync, leave pipeline mode, and classify it as a timeout or cancel as usual. Find a deterministic reproduction, for example by injecting at `Pipeline.finish`, and write the test first.

- **Depends on:** 20261004-28.
- **Came from:** The builder of 20261004-36.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** Landed in 8915e32. Review minors were added to 20261004-41.

### 20261004-42. Shape cache: tidy the specs.

These are review minors from 20261004-35.

1. The specs reset the cache with `instance_variable_get(:@kept).clear`. Add a small public `Shape.forget` and use it.
2. The comment near `spec/result_comparison_spec.rb:165`, "Shapes are kept across examples, so each example's SQL names a table of its own", is half stale now that the cache is reset. Update it.
3. The cache key holds the caller's own unfrozen SQL string. Freeze a copy as the key.

- **Depends on:** 20261004-35.
- **Came from:** The review of 20261004-35.
- **Design:** result-comparison.
- **Status:** done
- **Landed:** Landed in 39dfed7. A review minor went to 20261004-46.

### 20261004-33. Tidy the oldest-client-first spec helper.

These are review minors from 20261004-30, in `enclave/spec/run_server_check_postgres_spec.rb`.

1. `listed_before?` runs a separate `pg_stat_activity` query for each pid. Take one snapshot instead.
2. If `production.connect` raises inside `connect_listed_before`, for example with "too many clients", the connections in `opened` are never closed. Close them in an `ensure`.

- **Depends on:** 20261004-30.
- **Came from:** The review of 20261004-30.
- **Design:** none (tests only).
- **Status:** done
- **Landed:** Landed in 6609562. One unlikely review minor wasn't filed: an error from close_and_wait inside the ensure would replace the original error.

### 20261004-38. Invalid UTF-8 in driver arguments crashes with a backtrace.

The builder and reviewer of 20261004-22 found these crashes:
- `quaack setup` and `quaack run` crash on invalid UTF-8 in `--host`, `--port` or the database flags. The ssh transport raises an uncaught `ArgumentError` in `Transport::Base#refuse`.
- `quaack start` crashes on invalid UTF-8 in `--server` (in `Transport::Base#refuse`) or `--query` (in a Pathname regex).

In each case the operator gets a backtrace instead of a usage error. Check every driver argument's encoding up front, and give a usage error (exit 64) that doesn't echo the value. Write a test first for each command.

- **Depends on:** 20261004-22.
- **Came from:** The builder and review of 20261004-22.
- **Design:** intake.
- **Status:** done
- **Landed:** Landed in 10dfd89. Review minors went to 20261004-47.

### 20261004-44. README: the connection note when no server is recorded.

This is a review minor from 20261004-40. README says the `production_connection_failed` message "names the production server it tried". For runs with no recorded server (started before 20261004-17), it says "the production server you gave quaack start" instead. Make README say so.

- **Depends on:** 20261004-40.
- **Came from:** The review of 20261004-40.
- **Design:** inventory.
- **Status:** done
- **Landed:** Landed in 02fd140. Review minors went to 20261004-48.

### 20261004-41. ArenaRunner post-cancel guard: follow-ups.

These are review minors from 20261004-36.

1. The cancel spec can't tell where the refusal happened. Main already raised `transaction_ended`, only after the write ran, and a read-only query sent in autocommit wouldn't be caught at all. Count sends (for example `pipeline_sync`) and expect none after the cancel.
2. DESIGN.md says the runner "sends nothing more until the next transaction begins", but `finish` still sends `ROLLBACK`. Reword it.
3. The comment above `PQTRANS_*` in `arena_runner.rb` still says the status is checked only after each statement. Say it's checked before too, and that INERROR is allowed then.
4. When a caller catches an error after the connection died, the next statement now gets `transaction_ended` ("a statement ended the arena transaction early"). It used to get `query_failed`. Consider reporting `connection_unusable` instead. Also consider whether a cancel fits `transaction_closed` better.

5. (From the review of 20261004-39.) In `Pipeline.finish`, if nothing was sent and an error arrives at the Sync, `results[-1] = last` raises `IndexError`, which hides the original error. It's only possible on a dead connection. Replace the result only when there is one, or raise `Broken`.
6. (From the review of 20261004-39.) If the last statement fails on its own and a cancel then arrives at the Sync, the cancel replaces the statement's own error. Add a comment saying it's harmless, since the transaction is aborted either way, or keep the first error.

- **Depends on:** 20261004-36.
- **Came from:** The review of 20261004-36.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** Landed in 46a8e57. Review minors went to 20261004-49.

### 20261004-46. Shape: drop the dead copy in `initialize`.

This is a review minor from 20261004-42. In `Shape#initialize` (`enclave/lib/quaack/enclave/result_comparison.rb`), `sql.frozen? ? sql : sql.dup.freeze` can no longer copy anything, because `new` is only called from `parse`, which always passes a frozen string. Make `new` private and assign `@sql = sql`.

- **Depends on:** 20261004-42.
- **Came from:** The review of 20261004-42.
- **Design:** result-comparison.
- **Status:** done
- **Landed:** Landed in 5c77de2. One review minor wasn't filed, because the reviewer said it needs no follow-up: nothing asserts the stored SQL is frozen.

### 20261004-47. Driver UTF-8 argument check: follow-ups.

These are review minors from 20261004-38.

1. No test pins two parts of `Arguments.not_utf8`. Dropping the `(?= <)` lookahead would blame `--keep` in `run --run ID --keep <bad>`. Dropping `force_encoding` would stop the check firing under `LC_ALL=C`. Add an example for each.
2. The flag can be misattributed. `start --server --port <bad>` blames `--port`, which there is `--server`'s value. `start … --arena-db <bad>` names a flag that `start` doesn't take, because the flag list comes from the whole usage text. Use the subcommand's own usage, and pair flags with values left to right.
3. README: "The last names the flag the argument goes with" isn't always true. Say "names the flag the argument goes with, if any, never the argument."

- **Depends on:** 20261004-38.
- **Came from:** The review of 20261004-38.
- **Design:** intake.
- **Status:** done
- **Landed:** Landed in 399d20b.

### 20261004-45. Flaky transport spec: a run that outlasts its timeout.

`driver/spec/transport_spec.rb:257`, "kills a run that takes longer than its timeout", failed once under `rake` during 20261004-33's build. It failed reading a pid file that didn't exist yet. The same seed passed on a rerun. It's probably a race between the child writing its pid file and the spec reading it under load. Make the spec wait for the file, or the code expose the pid, without weakening what it asserts.

- **Depends on:** none.
- **Came from:** The builder of 20261004-33.
- **Design:** none (tests only).
- **Status:** done
- **Landed:** Landed in fe6272c.

### 20261004-15. Step slugs: minor findings.

Minor findings from the review of 20261003-21:

- **Untested exemptions.** No test pins which subcommands the `run_from_older_version` check covers. Exempting `Steps::Status` in `enclave/lib/quaack/enclave/cli.rb` `dispatch` keeps every spec green. Add a test that walks the real `CLI::STEPS` table.
- **Garbled text from the rename:**
  - The header comment of `enclave/lib/quaack/enclave/burndown.rb` became a run-on line with stray `#` marks.
  - Doubled words in `protocol/lib/quaack/protocol/burndown.rb` and `whitelist.rb` ("burndown burndown", "report report", "the redact redacted").
  - Doubled words in BACKLOG.md: 20260924-25, -26 and -28's titles, and "vacuity-guard's vacuity guard" in 20261003-25.
- **Stale comment.** `enclave/lib/quaack/enclave/error_filter.rb:28-29` says step names start with a digit.
- **BACKLOG.md references:**
  - `StepNine` and `step_nine.rb` (now `ScenarioTests` in `scenario_tests.rb`) appear in four open entries.
  - Old "steps 2 through 4" became "inventory through run-server", which skips the schema steps.
  - Old "steps 9 and 14" became "rewrite-test and candidate-runs", where 14 likely meant `result-comparison`.
- **DESIGN.md:** seven outline slugs have no heading to link to: `rewrite-correctness` (also the mapping table's target for old 9 and 10), `rewrite-index-search`, `rewrite-index-rank`, `rewrite-index-rerank`, `rewrite-prune`, `rewrite-llm-index-ideas` and `rewrite-llm-index-refine`. Give them headings or anchors.

- **Depends on:** 20261003-21.
- **Came from:** The review of 20261003-21.
- **Design:** The outline, `burndown`.
- **Status:** done
- **Landed:** Landed in ecfe202. The main session fixed the BACKLOG.md items: the three titles, the vacuity-guard wording, the four StepNine references, result-comparison, and racetrack-setup.

### 20261004-43. ArenaRunner: ROLLBACK and a pending cancel under a short timeout.

The builder of 20261004-39 found these. Both are rare with real timeouts.
1. The runner's `ROLLBACK` itself runs under the arena `statement_timeout`. In about 1 in 4,000 tries at 1 ms, it was canceled. Then `Cancel.rule` reports `statement_canceled` and `finish` reports `rollback_failed`. Turn the timeout off with `SET LOCAL statement_timeout = 0`, or send the ROLLBACK in a way that's immune, before rolling back.
2. A pending cancel can surface on a later command as "canceling statement due to user request". Find where, and make sure it's classified correctly or drained.

Find deterministic reproductions, for example by injection, and write the tests first.

Seen again in the review of 20261004-38: `enclave/spec/denormalized_fixture_postgres_spec.rb:80` got `statement_canceled` instead of `statement_timeout` under parallel load. It passes alone.

- **Depends on:** 20261004-39.
- **Came from:** The builder of 20261004-39.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** Landed in 824a10b. Root cause: the clock read ran under the transaction's statement_timeout and was itself canceled, so Cancel.rule had no start time. Each statement now arms and disarms its own timeout in the same pipeline.

### 20261004-57. Rename artifacts left in comments, and a dangling colon in DESIGN.md.

Minor findings from the review of 20261004-15. These are all comment or prose fixes.

- "for each literals literal set" appears in `measurement.rb:11`, `steps/baseline.rb:12`, `steps/index_search.rb:34`, `steps/index_test.rb:30` and `steps/result_comparison.rb:14`.
- "Until literals literal sets … and redact redaction" appears in `single_candidate_test.rb:32`.
- "the volatility VolatilityCheck" appears in `index_ddl_check.rb:64`, `insert_check.rb:66` and `rewrite_candidate_check.rb:58`.
- DESIGN.md's rewrite-index-ideas intro ends with "…that plan-pruning started:" but prose follows now, not a list.
- "the first first" appears in `scenarios/parts.rb:40`. This one predates the rename.

- **Depends on:** none.
- **Came from:** The review of 20261004-15, 2026-10-05.
- **Design:** none.
- **Status:** done
- **Landed:** Landed in 1a5fd3d.

### 20261004-50. Report: collapse the query list and the "Measured, and not ranked" section.

Two parts of the readable report are too long to scan.

1. **The queries section at the top.** Keep its content, but put each query's text behind a collapsed `<details>`, so the reader sees the list of rewrites and how they fared without scrolling past every query.
2. **"Measured, and not ranked."**
   - Collapse it by default, behind a summary like "Things QUAACK tried that didn't pan out".
   - Render its content as a table instead of a wall of sentences. Use one row per rewrite or index, with columns for what it was, who proposed it, and why it didn't make the cut.

The report must still read correctly with JavaScript off: use `<details>`/`<summary>`, not scripts.

- **Depends on:** none.
- **Came from:** The user, 2026-10-05, reading a run's report.
- **Design:** report.
- **Status:** done
- **Landed:** Landed in cb12d14.

### 20261004-56. Pid-file races in two more timeout specs, and the group check's start-up gap.

From the second review of 20261004-45.

- `driver/spec/start_spec.rb:213` and `enclave/spec/inventory_memory_spec.rb:79` start `sleep 30 & echo $! > pid_file; wait` under a 0.5 s timeout. The shell can be killed before it writes the pid file, the same race 20261004-45 fixed in the transport spec. Take the pid from the spawn, or otherwise close the race.
- The transport spec's process-group check stays green without testing anything when Ruby takes longer than the 1 s timeout to start its grandchild. Make the spec notice that case, for example by having the child signal readiness first or by asserting the grandchild started.

- **Depends on:** none.
- **Came from:** The second review of 20261004-45, 2026-10-05.
- **Design:** none (test infrastructure).
- **Status:** done
- **Landed:** Landed in 28cbe8a.

### 20261004-49. ArenaRunner transaction-status check: untested branches.

These are review minors from 20261004-41.

1. In `enclave/lib/quaack/enclave/arena_runner/transaction_status.rb`, `PQTRANS_INTRANS` and `PQTRANS_INERROR` in the `settled` list are never tested. Narrowing the list to `[PQTRANS_IDLE]` leaves every test green, and neither status can realistically reach that line. Reduce the check to `status == PQTRANS_IDLE`, or test them.
2. The `connection_unusable` message ("the arena connection can't be used") now covers both the start-time refusal and a connection that dies mid-transaction. It's accurate for both, but less specific at start. Consider separate wording.

- **Depends on:** 20261004-41.
- **Came from:** The review of 20261004-41.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** Landed in 026aa05.

### 20261004-32. Teardown-failure docs and the path-without-done case.

These are review minors from 20261004-31.

1. README step 5 says to "destroy the run server yourself too" after `teardown_failed`. But when `destroy_command` is set, the enclave runs it before deleting the store (see `destroyed?` in `enclave/lib/quaack/enclave/steps/teardown.rb`), so the server is usually gone already. Only `bad_run` and `bad_store_base` skip the destroy. Fix the wording.
2. DESIGN.md and the `TEARDOWN_LEFT` comment in `driver/lib/quaack/driver/teardown.rb` say the failure line points to teardown's message for "a store teardown wouldn't or couldn't delete". For `bad_run`, `bad_store_base` and `teardown_failed`, `rule_with_note` adds no next step. Make the docs match, or add the pointer.
3. README's "It prints the report's path, then `<run ID> done`" doesn't mention that the path can print without `done`, with exit 1, when only teardown failed. The error table mentions this only in the `ssh_failed` and `incomplete` rows. Document it for the other teardown rules too, and check stdout in the `--keep` spec.

- **Depends on:** 20261004-31.
- **Came from:** The review of 20261004-31.
- **Design:** teardown.
- **Status:** done
- **Landed:** Landed in 76c5932.

### 20261004-51. Report: explain the untested-conditions note under a rewrite, and render its conditions readably.

Under some rewrites the report says: "The made-up test data never exercised these conditions, so a change to one of them wasn't really checked. The LLM-written test data exercised them afterwards." A bullet list follows, sometimes ending in a bullet that's a lone number. The user couldn't tell what it meant.

- Reword the note so a reader who doesn't know rewrite-test or counterexamples understands it. It should say:
  - the rewrite's conditions (WHERE and JOIN predicates) that QUAACK's generated rows never made both true and false;
  - why that matters: a rewrite that changed one of them could still have passed;
  - whether a later test covered them.
- Render each condition as a readable predicate, such as `t.col = $1`, styled as SQL (see 20261004-53). Today `Rewrites#atoms` joins a Hash's values with spaces.
- Find out where the lone-number bullet comes from, such as a value or position field joined in by `atoms`, and fix it.
- When the later test did cover them, consider collapsing the list, since nothing is left to worry about.

- **Depends on:** none.
- **Came from:** The user, 2026-10-05, reading a run's report.
- **Design:** report.
- **Status:** done
- **Landed:** Landed in 73a0586. The lone numbers were vacuity-guard atom positions: the payload read untested_atoms instead of untested. Counterexample rounds now record covered conditions.

### 20261004-7. Harden the live clock's timer thread.

The review of 20261003-16 found three minor issues in `driver/lib/quaack/driver/progress.rb`:
- No spec pins `timer&.join`, so removing it keeps every spec green. An old timer that wakes as a step closes could draw a stale time on the next step's line. Test this with a redraw held mid-draw by a slow io.
- A Ctrl-C during `timer.join` skips the rest of the cleanup, so `@start` stays set.
- A write error such as EPIPE inside the timer thread is raised again from `join` and replaces the step's own result.

- **Depends on:** 20261003-16.
- **Came from:** The review of 20261003-16.
- **Design:** Progress lines for `quaack run`.
- **Status:** done
- **Landed:** Landed in 888cc17.

### 20261004-48. README: polish the connection-note wording.

These are review minors from 20261004-44.

1. "For a run started before QUAACK recorded the server" doesn't say where it was recorded. Say "started by a driver before 0.1.6, which didn't record the server in `~/.quaack/runs/`", or similar.
2. The `production_connection_failed` cell in the error table is long, and the new parenthetical in the middle makes it hard to follow. Move it to the end, or shorten it.

- **Depends on:** 20261004-44.
- **Came from:** The review of 20261004-44.
- **Design:** none (docs only).
- **Status:** done
- **Landed:** Landed in 7f97f53.

### 20261004-58. ArenaRunner per-statement timeout: untested guards, and a nonzero session default.

These come from the build and review of 20261004-43.

- **`clocked` keeps the statement's own error, but nothing tests it.** Changing the guard to `failed?(reset) ? reset : outcome` leaves the suite green. Now that the reset is last, a late cancel on the Sync replaces the reset's result, not the statement's. Test it: a late cancel on the Sync after `SELECT 1/0` must give `[:query_failed, "22012"]`, not `[:statement_canceled, "57014"]`.
- **The disarm in `load` is only pinned by the phase-count test.** Add a test with a nonzero session `statement_timeout`, such as 100 ms. An empty fixture's slow ROLLBACK must still succeed; with `DISARM_SQL` removed from `load`, it fails.
- **A nonzero server default.** After a cancel, `Cancel.rule` runs a clock read once the rollback has put the setting back to the session's value. A nonzero server or role default would apply to that read. Decide whether the arena connection should set `statement_timeout` to 0 at connect, and test it.

- **Depends on:** 20261004-43.
- **Came from:** The build and review of 20261004-43, 2026-10-05.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** Landed: Cancel.rule reads the clock in its own short transaction with statement_timeout 0; clocked guard and load disarm pinned.

### 20261004-52. Report: show the original query in the ranking table, and numbers instead of "better"/"no worse".

1. **The ranking table.** Add a row for the user's query as it is, with the same measurements as the ranked candidates, so the relative improvement is visible at a glance. Mark the row clearly as the baseline, and don't give it a rank.
2. **The "Against your query" column** in each ranked candidate's performance table. Replace "better" and "no worse" with numbers:
   - the change in blocks read against the user's query on the same values, such as "−52%" or "1,668 vs 3,454";
   - keep a short word only where no number exists.

- **Depends on:** none.
- **Came from:** The user, 2026-10-05, reading a run's report.
- **Design:** report.
- **Status:** done
- **Landed:** Landed: baseline row in the ranking table; Against your query shows numbers.

### 20261004-13. Two live-clock edge cases.

The second review of 20261003-16 found these minors in `driver/lib/quaack/driver/progress.rb`:
- At line 156, nothing tests that `draw` sets `@cut`. If the window widens within the last second before a line ends, after a redraw cut it, the line must still be reprinted whole. Reproduce it at 36 columns, with the clock at 1.2s, then widen to 80 before the step ends.
- At line 144, when a finished line plus its clock is exactly as wide as the terminal, the trailing `\e[K` runs while the cursor waits to wrap, and on xterm it erases the last character, so `1m02s` shows as `1m02`. Print `\e[K` before the text instead.

- **Depends on:** 20261003-16.
- **Came from:** The second review of 20261003-16.
- **Design:** Progress lines for `quaack run`.
- **Status:** done
- **Landed:** Landed: @cut pinned by a test; \e[K printed before the text so a full-width line keeps its last character.

### 20261004-60. Teardown failure: edge cases from 20261004-32.

These are review minors from 20261004-32.

1. **`teardown_failed` without the destroy.** README says that after `teardown_failed`, `destroy_command` has already destroyed the run server. But `destroyed?` reads `store.read("server")` inside `call`'s `rescue Store::Error`. If that read fails, the rule is `teardown_failed` and the destroy never ran, so the run server may still be up. Give that case its own rule, or hedge the README's wording.
2. **`Teardown.failure` assumes an `EnclaveError`.** It calls `error.to_go_on?` unguarded. That's safe today, but if teardown could raise another rescued class it would raise `NoMethodError`. Add an `is_a?(EnclaveError)` guard, with a test.
3. **A driver error from teardown after a good run.** DESIGN.md says the pointer follows "every rule teardown fails with". A non-`EnclaveError` failure (`driver_error`) isn't rescued by `run_command`, so it escapes with no pointer and no path note. Handle it, or narrow DESIGN.md's claim. This predates 20261004-32.

- **Depends on:** 20261004-32.
- **Came from:** The review of 20261004-32, 2026-10-05.
- **Design:** teardown.
- **Status:** done
- **Landed:** Landed: destroy_command_not_run rule, EnclaveError guard in Teardown.failure, Teardown::DriverError handled by run_command.

### 20261004-34. ServerClock follow-ups.

These are review minors from 20261004-28.

1. The `cancel_when_sleeping` helper in `enclave/spec/support/server_clock.rb` can hide a spec's real failure. Make it report the failure of the code under test, not its own timeout.
2. A failed clock read is handled differently in two places: RunDiscipline raises the read's error, while ArenaRunner reports `statement_canceled`. Pick one behavior, document it, and test it.

- **Depends on:** 20261004-28.
- **Came from:** The review of 20261004-28.
- **Design:** run discipline, rewrite-test.
- **Status:** done
- **Landed:** Landed: cancel_when_sleeping reports the block's failure; a failed clock read after a cancel raises the cancel everywhere.

### 20261004-53. Report: style inline SQL so it stands out from the prose.

The report puts raw SQL inside sentences, such as "Rewrite Blithe Mango with a new index on cluster44_shard_7236.assignments (context_id) INCLUDE (id, type, muted) WHERE context_type::text = 'Course'::text AND workflow_state::text <> 'deleted'::text read 1,668 blocks…". Wrap every piece of SQL the report embeds in an element such as `<code class="sql">`: index definitions, predicates, table and column names, and query text. Style it in the template's CSS with a monospace font and a subtle background, so it reads as distinct from the text around it. Long index DDL should wrap without overflowing the page.

- **Depends on:** none.
- **Came from:** The user, 2026-10-05, reading a run's report.
- **Design:** report.
- **Status:** done
- **Landed:** Landed: every embedded SQL piece is in <code class="sql">, styled and wrapping.

### 20261004-63. `production_connection_failed` for a run without a recorded port: check the port source it names.

From the review of 20261004-48. When a run's record has no `port`, as for runs started by a driver before 0.1.6, the message says the port comes from the libpq setup, even if the operator gave `quaack start --port`. Check what the enclave actually connects with for such a run, since the jump server's run state may hold the port. Make the message say the truth, with a test.

- **Depends on:** 20261004-17, -37.
- **Came from:** The review of 20261004-48, 2026-10-05.
- **Design:** inventory.
- **Status:** done
- **Landed:** Landed: a run recorded with neither server nor port names both port sources.

### 20261001-19. Record the rewrite stages in the burndown.

In a real run the rewrite burndown has one row, plan-pruning, and it's wrong. `Burndown.record` has two production callers, both plan-pruning: `StructuralDiscard.record` under the search `rewrites` and `rewrite-prune` under `pruning`. The report sums the two, so one rewrite that came in and was pruned reads as "In 2, Out 1". Nothing records llm-rewrites, assumption-check, operator-rewrites, rewrite-test, counterexamples, rewrite-index-ideas, or measurement.

- Record every stage in DESIGN.md's burndown's rewrite table. llm-rewrites and operator-rewrites: the rewrites the LLM gave and the operator gave, counted separately, and those refused on arrival, by rule. assumption-check: unmet assumptions, and operator-rewrites' warnings. rewrite-test: disproved by scenario, untested atoms, vacuity-guard retries. counterexamples: disproved by round. measurement: by minimax and result-comparison reason.
- Make plan-pruning one record per rewrite that adds up across its two halves, so "in" is the rewrites that reached plan-pruning and "out" is those that went on.
- Record the work totals: indexes built, measurement runs, fixture loads.
- A step that's skipped on a resumed run mustn't be counted twice, and one that's rerun mustn't either.

- **Depends on:** 20260922-61, -64.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** burndown.
- **Status:** done
- **Landed:** Landed: every rewrite stage, plan-pruning once per rewrite, and the work totals are recorded; record_once guards resumes.

### 20261004-64. Arena timeout: minors from 20261004-58.

The review of 20261004-58 found these minors in `enclave/lib/quaack/enclave/arena_runner/cancel.rb`:
1. Nothing pins the `ensure ROLLBACK` on a failed clock read in `Cancel.rule`. If the `ensure` became an ordinary statement after the read, a raising read would leave the connection aborted (`INERROR`), and a block that caught the cancel would get 25P02 on its next statement instead of a `transaction_ended` refusal. Add a test that plants a raising second clock read and asserts the connection is idle afterwards.
2. `Cancel.rule`'s first `ROLLBACK` (in `"ROLLBACK; BEGIN; SET LOCAL statement_timeout = 0"`) still runs under the aborted transaction's `statement_timeout`. If the server takes longer than the timeout to reach it, the cancel there reads as `statement_canceled`. It's rare. Either run that ROLLBACK untimed or document the edge.

- **Depends on:** 20261004-58.
- **Came from:** The review of 20261004-58, 2026-10-05.
- **Design:** arena-runner.
- **Status:** done
- **Landed:** Landed: ensure ROLLBACK pinned; the first ROLLBACK runs under the session timeout after an abort, documented as unsupported in v1.

### 20261004-67. ServerClock: minors from 20261004-34.

The review of 20261004-34 found:
1. Two mutations to `cancel_when_sleeping`'s success path survive: dropping `canceller.join` after the block returns, and stopping the canceller unconditionally. Add a test that the canceller's own error still surfaces when the block succeeds.
2. `rescue StandardError` in `ServerClock.timed_out?` also swallows programming bugs (`NoMethodError`, `Float()`'s `ArgumentError`), which then read as an operator's cancel. ArenaRunner's rescue is just as broad. Consider narrowing both to `PG::Error` and the like.
3. DESIGN.md says the enclave "raises the cancel, not the read's error". When the connection died, the `ensure ROLLBACK`'s `PG::ConnectionBad` replaces the cancel. "Every caller already handles a cancel" is also generous, since Measurement lets it propagate. Tighten the wording.

- **Depends on:** 20261004-34.
- **Came from:** The review of 20261004-34, 2026-10-05.
- **Design:** run discipline.
- **Status:** done
- **Landed:** Landed: clock-read rescues narrowed to PG::Error; canceller success path pinned; DESIGN wording tightened.

### 20261004-54. Report: show "Why the winner reads fewer blocks" plans as a tree table.

That section shows each plan as a flat bullet list, which loses the plan's shape. Render each plan as a table in the style of explain.depesz.com:
- one row per node, indented by depth;
- columns for node type, relation and index, estimated vs actual rows, and blocks read, where the payload carries them;
- the nodes that differ between the winner and the user's query highlighted.

If the payload's plan nodes don't carry their depth or parent, add that, inside the trust boundary 20261003-5 sets: a node sends only its type, relation, index name, row counts, and now its depth.

- **Depends on:** none. Coordinate with 20261003-5, which also changes the plan payload.
- **Came from:** The user, 2026-10-05, reading a run's report.
- **Design:** report.
- **Status:** done
- **Landed:** Landed: plans render as a depesz-style tree table with depth from the enclave and differing steps marked; no blocks column, since nodes carry none.

### 20261004-66. Teardown: minors from 20261004-60.

The review of 20261004-60 found:
1. `teardown_failed` without the destroy can still happen through a race: `open_run` fails, then the open inside `Store.teardown` succeeds. Also, `entry?` can raise an unrescued `SystemCallError`, which is unlikely, since the run directory is checked to be 0700 first. Decide whether either needs handling.
2. The spec "keeps the message of the run's own non-EnclaveError" in the driver's teardown spec passed on main too, since the condition short-circuits before the guard, and `run_command` doesn't rescue `IOError` anyway. Make it cover a realistic path, or drop it.
3. README's rules table doesn't list `driver_error`, which DESIGN.md names as a rule the operator sees.

- **Depends on:** 20261004-60.
- **Came from:** The review of 20261004-60, 2026-10-05.
- **Design:** teardown.
- **Status:** done
- **Landed:** Landed: destroy_command runs inside Store.teardown's open; SystemCallError gives destroy_command_not_run; README lists driver_error.

### 20261004-74. Flaky `schema_dump_postgres_spec.rb:204`: pg_dump's `\restrict` token.

From the review of 20261004-66. The spec checks that the dump text doesn't include "dba", but pg_dump's random `\restrict` token sometimes contains that substring. Make the check ignore the `\restrict`/`\unrestrict` lines, or match "dba" as a word or identifier.

- **Depends on:** none.
- **Came from:** The review of 20261004-66, 2026-10-05.
- **Design:** schema-dump.
- **Status:** done
- **Landed:** Landed: the two dba checks match a whole word, so pg_dump's random \restrict token can't trip them.

### 20261004-70. Arena ROLLBACK after an abort runs under the session's timeout.

From the build and review of 20261004-64. Once a transaction aborts, Postgres drops its `set_config` settings, so the runner's closing `ROLLBACK` after any aborted transaction runs under the session's `statement_timeout`, not with no timeout. DESIGN.md's fixture-open paragraph still says "the closing `ROLLBACK` runs with no timeout" while also saying a nonzero session setting applies after an abort. Fix the wording, and decide whether a nonzero session timeout should be handled, for example by resetting it at connect where `Counterexamples::Evaluated` doesn't rely on it. Also:
- Rename the spec "takes longer than the runner's timeout to reach" (arena_runner_postgres_spec) and its comment to say it's a sanity check on the fixture's delay.
- "isn't canceled by the runner's timeout" only pins Postgres behaviour; say so in its comment.

- **Depends on:** 20261004-64.
- **Came from:** The build and review of 20261004-64, 2026-10-05.
- **Design:** arena-runner.
- **Status:** done
- **Landed:** Landed: DESIGN.md wording on the ROLLBACK after an abort, plus specs pinning already_in_transaction. Review minors became 20261004-75.

### 20261004-65. Ranking baseline: minors from 20261004-52.

The review of 20261004-52 found:
1. The verdict sentence (`View#compared`, via `Format.fewer`) rounds 12 vs 5,120 to "(100% fewer)", while the winner's table says "over 99% fewer blocks". Use one rule in both places.
2. Nothing tests a baseline timeout on a set other than the slow values. Making `baseline_sum` check only the first set survives. Add a test where the original times out on `worst_case`.
3. Nothing tests the "over 99%" threshold from below. Changing `percent == 100` to `percent >= 99` survives. Add a case that rounds to 99%.
4. README's "Against your query" bullet omits the "not recorded" fallback when there's no verdict, which DESIGN.md mentions.

- **Depends on:** 20261004-52.
- **Came from:** The review of 20261004-52, 2026-10-05.
- **Design:** report.
- **Status:** done
- **Landed:** Landed: the verdict sentence uses Format.apart's rounding, plus tests for a worst_case timeout and 99% rounding. The review's one minor (stale Format.fewer mentions in 20261003-4) was fixed in the backlog text.

### 20261004-73. Teardown: recheck the run directory after `destroy_command`.

From the review of 20261004-66. `Store.open` checks the run directory's owner and mode before `destroy_command` runs (timeout up to 3600s), but the delete afterwards only rechecks that the path is a directory and not a symlink. Before 20261004-66 the check ran right before the delete. Re-open or re-check the store after the block, with a test. Low risk: only the same user or root can change the run directory.

- **Depends on:** 20261004-66.
- **Came from:** The review of 20261004-66, 2026-10-05.
- **Design:** teardown.
- **Status:** done
- **Landed:** Landed: Store.teardown rechecks the run directory after destroy_command, just before the delete, and fails as bad_run if it went bad. The review's README/DESIGN minor was fixed while landing.

### 20261004-71. ServerClock: comments and wording from 20261004-67.

The review of 20261004-67 found:
1. A comment in `arena_runner.rb` (around line 26) still says pg "isn't an enclave dependency yet… never names a PG constant", and `pipeline.rb` repeats it. `server_clock.rb` now requires `pg`, so ArenaRunner loads it anyway. Update the comments, or drop the rule.
2. In DESIGN.md, "The arena runner does the same, reporting it as `statement_canceled`" follows the new dead-connection exception, so it reads as if the arena runner has that exception too. It doesn't: its own `ROLLBACK` failure is caught. Say so.
3. A bug escaping `Cancel.rule` carries the original `PG::QueryCanceled` as its cause, unlike `ArenaRunner::Error` (`cause: nil`). Egress ignores causes, so it isn't a leak, but consider raising with `cause: nil` for consistency.

- **Depends on:** 20261004-67.
- **Came from:** The review of 20261004-67, 2026-10-05.
- **Design:** run discipline, arena-runner.
- **Status:** done
- **Landed:** Landed: comments in arena_runner.rb and pipeline.rb and DESIGN.md wording fixed; Cancel.rule now runs outside the rescue so an escaping bug has no cause. The review's cosmetic minor went into 20261004-75.

### 20261001-20. Record the index stages in the burndown.

In a real run the "Index candidates for the original query" table is empty. `record_dedupe`, `record_single_candidate_test`, and `record_llm_round` exist and are tested, but no step calls them, and nothing records index-from-query, index-from-plan, or index-rank. Wire them in, for the original's search and for each rewrite's (plan-pruning and rewrite-index-ideas):

- `index-search`: index-from-query and index-from-plan (candidates per generator), index-dedupe, and index-test with its set-asides.
- `index-test`: llm-index-ideas and llm-index-refine, one record per round, saying whether the refinement round ran.
- `index-rank`: index-rank, combinations tested and what didn't make the cut.

This takes over the llm-index-ideas burndown bullet of 20260926-3 and the `set_aside:` wiring bullet of 20260927-19. Settle 20260924-8's `since` question on the way, since `index-test` runs in a different process from `index-search`.

- **Depends on:** 20260922-61, -64.
- **Came from:** The user, 2026-10-01, reading the report of run 20261001T210856Z-3b7041a3.
- **Design:** burndown.
- **Status:** done
- **Landed:** Landed: index-search, index-test's LLM rounds and index-rank record their burndown stages, with words in the report. Review minors became 20261004-77; the builder's index-test query finding became 20261004-76.

### 20260926-3. Generator three follow-ups.

- Record the llm-index-ideas burndown: LLM candidates, plus any replacements asked for dropped ones, with the index-dedupe and index-test reasons (DESIGN.md's burndown table).
- `CandidateDdlRedaction` masks `col = ANY (ARRAY[...])` completely, allowed MCVs included, because `operands` handles only `AEXPR_OP` and `AEXPR_IN`. Postgres prints IN lists this way, so partial-predicate values from plan filters get lost. Allow the same per-column MCV rule there.

- **Depends on:** 20260925-4.
- **Came from:** The build and second review of 20260925-4.
- **Design:** llm-index-ideas, burndown.
- **Landed (2026-09-26):** MCV handling for `= ANY` arrays in CandidateDdlRedaction. The llm-index-ideas burndown record landed with 20261001-20.
- **Status:** done
- **Landed:** Done: the CandidateDdlRedaction part landed 2026-09-26, and the llm-index-ideas burndown record landed with 20261001-20.

### 20261004-55. Report: draw the burndown as an SVG funnel.

Render each burndown, rewrites and indexes, as an inline SVG sales-funnel graphic, built by the driver with no external assets or scripts:
- one band per stage, narrowing as candidates drop out;
- each band labeled with the stage, the count in, and the count out, with the drop-off reason on hover (`<title>`) or beside it.

Keep the existing burndown table under it, for exact numbers and for readers without SVG. A stage whose counts read "not recorded" must show as unknown in the funnel, never as zero.

- **Depends on:** none, but the funnel is most useful after 20261001-19 and -20 record every stage.
- **Came from:** The user, 2026-10-05, reading a run's report.
- **Design:** report, burndown.
- **Status:** done
- **Landed:** Landed: report/funnel.rb draws each burndown as an inline SVG funnel above its table; unrecorded stages are hatched and never narrower than Funnel::UNKNOWN. Review minors became 20261004-78.

### 20261004-76. index-test tests a rewrite's LLM index ideas against the original query.

- **Status:** done
- **Depends on:** 20261001-20 (done)
- **Came from:** the build of 20261001-20.
- **Design:** index-test, llm-index-ideas.

index-test reads `anchored_query` for every search, so for a rewrite's search it asks the planner whether the original query, not the rewrite, would use each LLM index idea. index-rank uses the right query. Ideas that only help the rewrite may be dropped as `never_used`, and ideas that only help the original may be kept. Confirm with a test on a rewrite's search, then use the search's own query.
- **Landed:** Landed: index-test asks the planner about the search's own query (IndexSearch.query), in both LLM rounds. Clean review.

### 20261004-78. Burndown funnel loose ends from 20261004-55.

- **Status:** done
- **Depends on:** 20261004-55 (done)
- **Came from:** both reviews of 20261004-55.
- **Design:** report.

Each of these is code in `driver/lib/quaack/driver/report/funnel.rb` with no test that fails when it's broken:
1. Cutting long labels short.
2. Set-aside counts, beside the band and in its tooltip; the test data always has 0.
3. The scale's largest count taken from "went on" as well as "came in".
4. An all-zero funnel's width.
5. Where the hatch stripes sit on an unknown band, and the unknown band's tooltip text.
6. The negative-count guard.
7. The vertical layout: the viewBox height and the gap between bands.
8. Where the labels sit: their x, and the two lines' y.

Also:
9. A stage with a "came in" count but no "went on" is drawn fully unknown, while the table shows the "came in" number. Draw what's known.
10. Six funnel specs, run with the funnel taken out of the template, fail on `undefined method 'scan' for nil` rather than on an assertion. Make them fail on their assertion.
- **Landed:** Landed: tests pin items 1-8, funnel specs fail on a clear assertion when the SVG is missing, and a stage with only a came-in count is drawn as a hatched partial band with a solid top line. Review minors became 20261004-79.

### 20261004-75. Tighten the wording left over from 20261004-70.

- **Status:** done
- **Depends on:** 20261004-70 (done)
- **From:** the review of 20261004-70.

Three small accuracy fixes, all wording only:

1. DESIGN.md says that after an aborted ROLLBACK the next fixture is refused, "so the step fails". On the vacuity guard's last attempt, rewrite-test instead records `passed: false` with rule `already_in_transaction`. `RewriteFate` counts that as a runner failure, not a disproof, so it's still safe. Say so.
2. DESIGN.md says counterexamples' value evaluation "relies on" the arena session's timeout. That timeout is 0 by default, and the scenario builder's own queries run outside the runner too. Say "benefits from" and name when it applies.
3. The comment on the `expect_left_aborted` spec helper says it turns the 50ms session timeout off before counting. It doesn't: it runs ROLLBACK and counts from a fresh connection. Fix the comment.
4. From the review of 20261004-71: the comments at `arena_runner.rb:24` and `arena_runner/pipeline.rb:26` no longer give a reason for hard-coding the `PGRES_*` and `PG_DIAG_SQLSTATE` values, now that pg is loaded. Give the reason, or use the `PG::` constants.
- **Landed:** Landed: DESIGN.md wording on the aborted ROLLBACK and session timeout, the expect_left_aborted comment, and pg's own constants in the arena runner. The review's three wording minors were fixed while landing.

### 20261004-77. Index burndown loose ends from 20261001-20.

- **Status:** done
- **Depends on:** 20261001-20 (done)
- **Came from:** the build and review of 20261001-20.
- **Design:** burndown, report.

1. `report/words.rb` has no words for several reasons the checks can refuse an LLM index: `concurrently`, `unique`, `nulls_not_distinct`, `tablespace`, `on_only`, `storage_options` (from `index_ddl_check.rb`), and possibly the volatility, supported-SQL and deparse rules. They show as plain names such as "unique: 1".
2. The report's Indexes table adds up each source's Proposed, and the LLM's "already existed" and "planner ignored", over the original and every rewrite's search. But "All sources together" (apart from Proposed) comes from the original's negative result and the indexes built, so the LLM row can disagree with the total. README's Indexes table text doesn't say the counts cover the rewrites. Make them line up, or say what each covers.
3. index-rank's record can also drop `never_used` or `hypopg_refused` when it re-tests a candidate. DESIGN.md's index-rank burndown row doesn't list them.
4. The "second round didn't run" record could go stale if index-test ran again after index-rank. The driver never runs them in that order today; refuse or overwrite it if that changes.
5. Built, not better, and ranked per source still read "not recorded" in the Indexes table, because QUAACK doesn't record which source proposed each index it built. Record it, if it's cheap.
- **Landed:** Landed items 1-4: words for every LLM index refusal (checked by a cross-gem spec), All sources together from the burndown over every search, DESIGN's index-rank row, and the refinement round replacing index-rank's didn't-run record. Item 5 became 20261004-80; review minors became 20261004-81.

### 20261004-22. Port check: minor findings.

Minor findings from the review of 20261004-18:

- **Bad encodings raise. Done:** landed in 6e520d5. Invalid UTF-8 in the driver's other arguments went to 20261004-38. The original finding was: `Protocol::Port.valid?` (`protocol/lib/quaack/protocol/port.rb:17`) raises on invalid UTF-8 (`ArgumentError`) or UTF-16 input (`Encoding::CompatibilityError`) instead of returning false. So `--port $'\xff'` gives `internal_error` instead of `bad_port` or `bad_run_server_port`. The old run-server check tested `ascii_only?` first. Check `valid_encoding? && ascii_only?` first, with a spec for each case.
- **The operator's commands don't get the port.** `run_server_command`, `destroy_command` and `memory_command` get only `{server}`, not production's port. Add a `{port}` placeholder only if a script needs it, and ask the user first.

- **Depends on:** 20261004-18.
- **Came from:** The review of 20261004-18.
- **Design:** intake, run-server.
- **Status:** done
- **Landed:** Closed: the user decided not to add a {port} placeholder (2026-10-05); the encoding item had already landed.

### 20261004-69. Rewrite burndown: minors from 20261001-19.

The review of 20261001-19 found:
1. The store format wasn't bumped. A run started before 20261001-19 and resumed after it counts surviving rewrites twice in plan-pruning, and keeps a stale `pruning` record. Either bump the store format so such runs are refused on resume, or ignore the old record.
2. The report shows rewrite-test's "never tested" reasons as raw names ("complex check", "statement timeout", "failed"). Use the plain-English phrases `Words::REFUSALS` and `Words::FAILURES` already have.
3. When a rewrite fails to run in a counterexamples round, the burndown says "wrong in round k", while "Who proposed what" puts it under "Stopped for another reason", which README says means not shown to be wrong. Make the burndown say it failed to run.
4. "Refused on arrival" means only the arrival rules in the burndown, but anything not stored in "Who proposed what". Align the two, or name them differently.
5. If a step crashes between writing its burndown record and its done marker, a rerun with a different outcome keeps the first record. The window is tiny; consider writing the record and the marker together.

- **Depends on:** 20261001-19.
- **Came from:** The review of 20261001-19, 2026-10-05.
- **Design:** burndown.
- **Status:** done
- **Landed:** Landed: store format 3 (older runs refused on resume), plain-English never-tested reasons, failed_in_round_<k>, 'Not kept' column, and Burndown.record_latest. Review minors: the note wording was fixed while landing; the funnel label test went to 20261004-79.

### 20261004-72. Plan tree table: minors from 20261004-54.

The review of 20261004-54 found:
1. Nothing in the protocol checks which keys a plan node carries; only the enclave spec pins it. Consider a shape check on plan nodes (pre-existing gap).
2. The enclave spec checks the rewrite's plan with `include`, so the rewrite plan's depth isn't asserted.
3. The `share` cutoff at `< 0.0005` in `report/plans.rb` is untested: changing it to `0.005` stays green.
4. When the join order is swapped, the `Hash` node is marked "differs" though both plans have one, a side effect of matching in plan order. DESIGN.md allows it; consider a smarter match.
5. The table has no blocks column, since the payload carries no per-node blocks. If the user wants per-node blocks, extending 20261003-5's boundary to send them is a separate decision.

- **Depends on:** 20261004-54.
- **Came from:** The review of 20261004-54, 2026-10-05.
- **Design:** report.
- **Status:** done
- **Landed:** Items 1-3 landed: Protocol::PlanNodes allowlist (node, relation, index, est_rows, actual_rows, selectivity, depth) enforced at enclave egress (String or Symbol plan keys) and the driver's reply check; share cutoff and rewrite depth tests. Item 4 not done (marking matches DESIGN). Item 5 became 20261004-82. Minors became 20261004-83.

### 20261004-25. Progress lines: summaries that only repeat the step, and asks after notes.

Minor findings from the review of 20261004-19. That task drops, on a terminal, the bare `Done in` lines and an LLM ask line that repeats its step. Some lines still just repeat the step with its time:

1. **Fixed-text summaries.** Many pipeline steps' summaries carry no information, e.g. "Ranked the index ideas in 5s (index-rank)" after the frozen "Ranking the index ideas (index-rank) 5s". Others do ("Got 3 rewrites from the LLM, 3 kept"). **Ask the user** whether to drop fixed-text summaries on a terminal, and how to tell the two kinds apart (e.g. a summary flag on the step, set only when the text carries counts).
2. **Asks under per-rewrite sub-steps** still repeat, e.g. "Rewrite Silver Fox: Asking the LLM for rows that could break the rewrite (counterexamples)" followed by "Asking the LLM for rows that could break the rewrite (llm-counterexamples) 20s".
3. **After 20261004-21's notes**, the "repeats its step" rule fires only for llm-rewrites. A note such as "Reading the query's shape for the LLM" now comes between the step line and the ask, so the ask is no longer the first line. Decide with the user whether those asks still count as repeats.
4. A second, identical ask is also dropped, because a dropped note leaves the step as the latest line. No caller does this today, but no test pins it.
5. No test pins the word boundary in `Repeat`: mutating `start_with?("#{words} ")` to `start_with?(words)` survives.
6. DESIGN.md's progress paragraph says each step's closing line gives the final time, without saying that setup steps print no closing line on a terminal.

- **Depends on:** 20261004-19, 20261004-21.
- **Came from:** The review of 20261004-19.
- **Design:** Progress lines for `quaack run`.
- **Decided by the user (2026-10-05):** Item 1: drop fixed-text summaries on a terminal; steps flag which summaries carry counts, and those always stay. Item 3: an LLM ask line after a note under the same step still counts as a repeat, and is dropped on a terminal.
- **Status:** done
- **Landed:** Landed after a review with no blocking findings. On a terminal, steps without informative: true print no closing line (flagged: llm-index-ideas, llm-index-refine, rewrite-rules, llm-rewrites, operator-rewrites, plan-pruning, rewrite-correctness, rewrite-index-ideas, index-build, report); asks repeating their step or sub-step are dropped even after notes. Minor: the wait's clock on a note line became 20261004-84.

### 20261004-62. A closed stderr pipe ends `quaack run` with EPIPE.

The review of 20261004-7 found that when stderr is a real pipe whose reader has closed, the step's own progress lines raise `Errno::EPIPE`. That replaces the step's result and stops the run, on main as well as after 20261004-7. Nothing in `driver/lib` handles EPIPE. Decide what `quaack run` should do when its progress output goes away, such as `quaack run … 2>&1 | head`. It could stop writing progress and carry on, or exit cleanly with a clear rule. Then test it with a real `IO.pipe`.

- **Depends on:** 20261004-7.
- **Came from:** The review of 20261004-7, 2026-10-05.
- **Design:** Progress lines for `quaack run`.
- **Decided by the user (2026-10-05):** Stop writing progress and keep running.
- **Status:** done
- **Landed:** Landed after a review with no blocking findings. QuietStream wraps the progress stream and run_command's stderr: the first failed write is swallowed, later writes are skipped, and the run keeps its exit code. Minors and the stdout case became 20261004-85.

### 20261004-82. Plan tree table: a blocks column.

- **Status:** done
- **Depends on:** 20261004-72
- **Came from:** item 5 of 20261004-72. The user decided this on 2026-10-05.
- **Design:** report, egress (20261003-5's boundary).

Send per-node block counts from the enclave in the report payload's plan nodes, as numbers only (shared hit and read blocks, from EXPLAIN (ANALYZE, BUFFERS)), and show a blocks column in the "Why the winner reads fewer blocks" plan tree table. Extend `Protocol::PlanNodes`' shape check (from 20261004-72) to allow exactly the new keys, and update DESIGN.md's boundary text. Test with planted sentinels that nothing but the counts crosses.
- **Landed:** Landed after a review with no blocking findings. PlanNodes now requires shared_hit_blocks and shared_read_blocks (non-negative Integer or nil); the enclave sends Postgres's per-node counts; the plan tables show 'Blocks read, with the steps under it'. Rewrite plans are hypothetical, so their counts are nil: 20261004-86. Minors: 20261004-87.

### 20260925-18. Qualify loose ends.

Still open from the first review of 20260925-8:
- **Needs a decision:** wrap `Relations.check` in `Inventory::Production.read_only` in the qualify step, without a failing test first, since no test can observe it.
- Refuse a `$user` search_path entry that matches an existing schema other than the operator's own.

- **Depends on:** 20260925-8.
- **Came from:** The first review of 20260925-8.
- **Design:** input, qualify.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Wrap `Relations.check` in `Inventory::Production.read_only`, without a failing test first.
- **Status:** done
- **Landed:** Landed after a fix round and a clean second review. Relations.check runs inside Inventory::Production.read_only (a test can observe it after all). New ambiguous_user_schema refusal: the path has "$user" and another role's same-named schema holds a relation (with "$user" at or before where the name resolved), function or type the query names without a schema; the first review's false refusals on pganalyze, Datadog, Supabase and PgBouncer setups were fixed. Minors and the operator's-own-schema question: 20261004-88.

### 20261004-80. Indexes table: which source proposed each built index.

- **Decided by the user (2026-10-05):** Count it in every source's row, with a note that rows can overlap.
- **Status:** done
- **Depends on:** 20261004-77 (done)
- **Came from:** item 5 of 20261004-77, which its builder left undone because it isn't cheap.
- **Design:** report, burndown.

In the report's Indexes table, "Built", "not better" and "ranked" per source still read "not recorded", because QUAACK doesn't record which source proposed each index it built. Doing it needs:
- a new report-payload field carrying only QUAACK's own source names, from a fixed list;
- matching each built index back to its candidates across every search;
- changes to the per-source rows and the docs.

**Needs a decision:** one index can come from several sources. For example, an LLM idea that repeats a generator's adds the LLM to that candidate's sources. Should it count in every source's row (then the rows don't add up to the total), only under the first source, or in a separate "several sources" row?
- **Landed:** Landed after a review with no blocking findings. New payload field index_sources (built, not better, ranked for generator_one, generator_two and llm; Protocol::IndexSources checked at egress and in the reply check); each built index counts in every source that proposed it, with an overlap note. Minor and remaining 'not recorded' cells: 20261004-89.

### 20260926-45. Driver, LLM client and harness items left from 20260924-13, -14, -20.

- **Needs a decision:** lazy-loading `anthropic` would save about 0.5s per CLI start, but breaks `runtime_boundary_spec`, which expects every driver file to load the gem. Change that spec to build a client first, or keep the eager load.
- **Pump/Child rework:** cover a child that closes stdout and then reads stdin, and a grandchild that holds stdout open.
- **Per-example timeout for driver specs,** tuned so it doesn't cause flakes.
- **JSON harness column:** add a JSON column to the harness schema.

- **Depends on:** 20260924-13, -14, -20.
- **Came from:** The build of those tasks.
- **Design:** Where QUAACK runs, LLM client.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Load `anthropic` lazily, and change `runtime_boundary_spec` to build a client first.
- **Status:** done
- **Landed:** Items 1-3 landed after a review with no blocking findings: anthropic and openai load only when a client is built (quaack --version ~1.25s to ~0.25s), runtime_boundary_spec builds a client per SDK provider; Pump reads all of a closed-stdout child's stdin and returns when the child exits even if a grandchild holds stdout; driver examples fail after 120s (QUAACK_EXAMPLE_TIME_LIMIT). Item 4 exposed a jsonb MCV leak and moved to 20261004-90 with its patch. Doc minors fixed while landing; the drain-deadline minor is unrealistic (bounded by max_bytes) and was not filed.

### 20261004-90. Classify: low-cardinality json, jsonb and array columns send their MCV values.

Found by the builder of 20260926-45 (item 4, the JSON harness column). DESIGN.md's classify section says text[], json and jsonb values never go out. But classification marks a jsonb column with few repeating values as low-cardinality and sends its MCV values: with a nullable `customers.preferences jsonb` column added to the harness and a JSON sentinel planted there, `pii_classification_postgres_spec` found `{"note": "sentinel…-json"}` in the outbound statistics. This is a trust-boundary leak on main.

Fix: never mark json, jsonb or any array column (or a domain over one) as low-cardinality, so its MCV values never go out; its frequencies follow the existing rules. Expression-index and extended-statistics MCVs over such a column follow from their base columns. Land 20260926-45's item 4 with it: its patch, which adds the jsonb column and sentinel to the harness, is in the session's `files/build-20260926-45/item4-json-harness-column.patch`. Also check other places that send values (llm-index-ideas payload, report, dedupe) for the same types.

**Later, ask the user:** whether other structured types (hstore, xml, composite types, ranges) should be refused the same way. This task only does what DESIGN.md already says.

- **Depends on:** none.
- **Came from:** The build of 20260926-45.
- **Design:** classify, trust boundary.
- **Status:** done
- **Landed:** Landed after a review with no blocking findings, with 20260926-45's item 4 (customers.preferences jsonb and a json sentinel in the harness). The statistics step records each table's structured columns (json, jsonb, any array, domains over them at any depth); classify never marks them low-cardinality, so their MCV values never go out, and expression and extended-statistics MCVs follow. Minors and the other-types question: 20261004-91.

### 20260924-10. index-rank loose ends.

**Needs a decision,** from the reviews of 20260922-35:
- `rank` checks the literal-set names against the baseline, but not the values. Checking the values means the baseline must store the values it was measured with. Store them, or keep this a documented precondition.

- **Depends on:** 20260922-35.
- **Came from:** The reviews of 20260922-35.
- **Design:** index-rank.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Store the baseline's values and check them.
- **Status:** done
- **Landed:** Landed after a review with no blocking findings. The baseline is in memory (index-rank re-measures it each run), so no store change: Baseline and Result carry a frozen, hidden copy of their literal values, and rank checks values as well as names, raising its fixed-message ArgumentError on a mismatch. Minors and the by-name-only comparisons elsewhere: 20261004-92.

### 20260923-58. Enclave CLI loose ends.

Still open from the reviews of 20260922-4 and 20260923-53:
- **Needs a decision:** `JSON.parse` uses 50 to 135 times the input size on dense arrays. A 64 MB `[0,0,...]` peaked at 3.2 GB. Lower `Input::MAX_BYTES`, or cap the element count before parsing.

- **Depends on:** 20260923-53.
- **Came from:** The reviews of 20260922-4 and 20260923-53.
- **Design:** Where QUAACK runs.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Cap the element count before parsing.
- **Status:** done
- **Landed:** Landed: input and intake plans over 2,000,000 commas, colons and opening brackets outside strings are refused before parsing.

### 20260924-7. fixture-compare comparator loose ends.

**Needs a decision,** from the reviews of 20260922-47 and 20260923-54:
- A precise check for ties at a cut: the rows before the tied group must match exactly, and the rest must come from the group. That would recover top-N originals that are refused today.
- Comparing intervals by value in the comparator.

- **Depends on:** 20260922-47.
- **Came from:** The reviews of 20260922-47 and 20260923-54.
- **Design:** fixture-compare.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Build both: the precise tie check at a cut, and comparing intervals by value.
- **Status:** done
- **Landed:** Landed: precise tie check at a LIMIT/OFFSET cut via a bounded edge check, and intervals compared by value. Follow-ups: 20261004-93, 20261004-94.

### 20260925-2. Insert check loose ends.

Still open from the first review of 20260922-12:
- **Needs a decision:** values aren't pinned to be deterministic. TimeZone-dependent timestamptz literals and `'now'` or `'today'` are accepted. Fix the arena session's TimeZone, or refuse the special date and time inputs.
- Removing the `attisdropped` clause in COLUMNS_SQL stays green. Keep it or drop it.

- **Depends on:** 20260922-12.
- **Came from:** The first review of 20260922-12.
- **Design:** What goes into the enclave.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Pin the arena session's TimeZone to UTC, and refuse the special date/time inputs ('now', 'today' and the like).
- **Status:** done
- **Landed:** Landed: arena sessions pinned to UTC; new clock_literal refusal for now/today/tomorrow/yesterday; attisdropped covered by a test. Follow-ups: 20261004-95.

### 20261004-93. Result comparison: the candidate's own ties inside a LIMIT/OFFSET window.

From the second review of 20260924-7. Correctness, already on main before that task.
- The edge check looks only at the original's tie groups. A candidate whose own tie group sits in the middle of its window can pass when both its tiebreaker runs happen to return the original's rows.
- Example: products `(a,10),(b,10),(b,10),(c,10),(d,5)`. The original `SELECT category, price ... ORDER BY price DESC, category LIMIT 2 OFFSET 1` always returns `b,b`. A candidate that drops `category` from its `ORDER BY` could also return `a,b`, yet it passes fixture-compare and production comparison.
- A pure-Ruby fuzz of 12k cases found 42 such false passes, all on the row-for-row path. Each needed duplicate output rows, or a one-row window in the exact middle of a tie.
- Suggested fix: when the candidate has a LIMIT and an OFFSET, run its through-window query (LIMIT+OFFSET, no OFFSET) both ways too. If the two runs differ, send it to CutTies or refuse it.
- Probes: `files/review-20260924-7-r2/probe/` in the session scratchpad.

- **Depends on:** 20260924-7.
- **Came from:** The second review of 20260924-7 (B1).
- **Design:** fixture-compare, result comparison.
- **Status:** done
- **Landed:** Landed: a candidate with LIMIT and OFFSET that matches row for row now runs its through-window query both ways, and goes to CutTies if they differ.

### 20261004-84. Progress: the LLM wait's clock sits on a note's line.

From the review of 20261004-25. On a terminal, an LLM ask that repeats its step is dropped even after a note (the user's 2026-10-05 decision on -25 item 3). So during the wait, the live clock ticks on the note: "Reading the query's shape for the LLM (llm-index-ideas) 1m10s", which reads as if the enclave call took the minute. The first counterexamples ask does the same under "Rewrite X: Reading the rewrite's shape for the LLM". `progress_spec.rb` (~571) pins today's behavior.

**Ask the user** which they prefer: (a) keep it; (b) when the latest line is a note, freeze the note and print the ask after all (so the clock ticks on "Asking the LLM…"); or (c) print a short ask line such as "Waiting for the LLM" instead of the repeated wording.

- **Depends on:** 20261004-25.
- **Came from:** The review of 20261004-25.
- **Design:** Progress lines for `quaack run`.
- **Decided by the user (2026-10-06):** (c), print a short ask line such as "Waiting for the LLM", so the clock ticks on it.
- **Status:** done
- **Landed:** On a terminal, an LLM ask that repeats its step after a note now prints as "Waiting for the LLM (<ask ID>)", and the clock ticks on it. Follow-ups: 20261006-1.

### 20261004-91. Structured columns: test gaps, and other structured types.

From the builder and review of 20261004-90.
1. The "missing structured list is an error" guard is untested: changing `table.fetch("structured_columns")` to `fetch("structured_columns", [])` keeps every suite green. Add a test that a statistics entry without the list fails classify.
2. In `pii_classification_postgres_spec`'s trust-boundary test, the "exposure is real" block doesn't check `customers.preferences`, so if the fixture stops planting json only `leak_check_spec` notices. Add it.
3. **Ask the user:** should hstore, xml, tsvector, composite types and ranges be treated like json (never low-cardinality, values never go out)? tsvector has an equality operator, so ANALYZE can keep MCV values for it. DESIGN.md says v1 treats them like any other non-text type.

- **Depends on:** 20261004-90.
- **Came from:** The builder and review of 20261004-90.
- **Design:** classify, trust boundary.
- **Decided by the user (2026-10-06):** item 3, yes: treat hstore, xml, tsvector, composite types and ranges (and domains/arrays over them) like json: never low-cardinality, values never go out.
- **Status:** done
- **Landed:** Classify withholds hstore, xml, tsvector, tsquery, composite, range and multirange columns (and domains/arrays over them) like json; tests for the missing structured list and customers.preferences. Follow-ups: 20261006-2, 20261006-3.

### 20261004-88. ambiguous_user_schema: minors and the operator's own schema.

From the builder and two reviews of 20260925-18.
1. **Ask the user:** the operator's own schema is trusted. If the plan ran as an application role and the operator has a schema of their own name (say `bench.orders`), `"$user"` resolves `orders` to the operator's schema, which the application never saw. Refuse it too, or keep trusting it?
2. repmgr creates a `repmgr` role and schema with tables `events` and `nodes`, so with the default path `SELECT * FROM events` is refused. That's the rule as designed; add a README line naming this common case and the fix.
3. A role schema the name resolved to, or one listed before `"$user"`, can't change resolution, yet still triggers the refusal (path `"$user", myapp, public` refuses `widgets` found in `myapp`; path `myapp, "$user", public` refuses `slugify()`). Skip those.
4. Mutating the unqualified-name guard `if list.size == 1` to `if true` survives; add a test with a qualified name whose last part matches a role schema's function or type.
5. Unqualified operators and collations aren't checked.

- **Depends on:** 20260925-18.
- **Came from:** The builder and reviews of 20260925-18.
- **Design:** input, qualify.
- **Decided by the user (2026-10-06):** item 1, refuse the operator's own schema too, like any other role's schema. The refusal message should say why: the name could resolve to a schema the application never saw.
- **Status:** done
- **Landed:** The operator's own schema is refused like any role schema, with a message saying why; role schemas that can't change resolution are skipped (respecting schema USAGE); qualified names use their last part; unqualified operators (written and implicit) and collations are checked; README names repmgr. Follow-ups: 20261006-4.

### 20261004-95. Insert check: clock words, loose ends.

From the review of 20260925-2.
1. An insert that leaves out a column such as `created_at timestamptz DEFAULT now()`, or writes an explicit `DEFAULT`, loads wall-clock time, not the clock anchor. That time varies between runs and against anchored predicates like `= CURRENT_DATE`. Refuse it, or fill the column from the anchor, and say which in DESIGN.md.
2. Rare bypasses: a word built by a function (`textcat('to','day')::date`), and backslash escapes in array or range literals (`'{to\day}'`, `'[to\day,infinity)'`). Refuse them, or list them in DESIGN.md as unsupported in v1.
3. **Needs a decision:** the arena now always runs in UTC. Before, it effectively ran in production's timezone, so a rewrite that's equal only in UTC, such as `interval '1 day'` → `'24 hours'` on timestamptz across a DST change, can no longer be disproved there. Pinning to production's recorded TimeZone would be just as deterministic.
4. `bind` puts the query's real literals into `$n` before the check. A `clock_literal` refusal therefore reveals whether a placeholder holds a clock word (one bit, like `bad_value`), and `VALUES ($1)` is refused when `$1` is `'today'`. Binding the anchored value instead would avoid both.
5. False refusals: any function argument holding a clock word, such as `to_tsvector('english', 'Today only...')`, and a composite column whose text field holds "now".
6. The driver's counterexamples prompt doesn't tell the LLM to avoid `'now'` and `'today'`. Check its effect on the recorded replays.

- **Depends on:** 20260925-2.
- **Came from:** The review of 20260925-2.
- **Design:** What goes into the enclave; insert check.
- **Decided by the user (2026-10-06):** item 3, pin the arena session's TimeZone to production's recorded TimeZone instead of UTC. This reverses the UTC part of 20260925-2. Item 1, fill a column whose omitted or `DEFAULT` value reads the clock from the clock anchor, rather than refusing. Item 2, list the bypasses in DESIGN.md as unsupported in v1. Item 5, fix the false refusals: stop refusing a clock word that can't reach a date/time value.
- **Status:** done
- **Landed:** Items 1, 2, 3, 5 and 6: the arena's TimeZone is production's recorded TimeZone; clock-reading column and domain defaults are anchored; each clock word is judged by the type it reaches (array, range and composite literals parsed, escaped bypasses refused); `textcat`-built words listed as unsupported in v1; the counterexamples prompt asks for fixed dates. Item 4 (anchored placeholder binding) was built but backed out after the second review found it mis-anchors text-only arguments; split into 20261006-5. Follow-ups: 20261006-5, 20261006-6.

### 20261004-83. Report plans: the flat-layout fallback is unreachable.

From the review of 20261004-72. Reports reach `Report.write` only through `Reply.parse`, which now refuses any plan node without an Integer depth of zero or more. So `report/plans.rb`'s flat layout (`tree?` false, ~lines 8-11 and 40-43) can't happen in a real run, and only the direct-render specs (`report_spec.rb` ~875, 886) exercise it. DESIGN.md (~1186) says both that the driver refuses a report whose nodes lack a depth and that such a plan "is laid out flat". Remove the fallback and its specs, or keep it and say why, and make DESIGN.md say one thing.

While here (second review of 20261004-72): no test plants a Hash in place of a report's `rewrites`, so mutating `rewrites.is_a?(Array)` to `respond_to?(:all?)` survives in both `enclave/.../egress.rb` and `driver/.../reply.rb`. Add one.

- **Depends on:** 20261004-72.
- **Came from:** The review of 20261004-72.
- **Design:** The report's plan tables.
- **Status:** done
- **Landed:** Removed the unreachable flat plan layout and its specs (every report goes through Reply.parse); DESIGN.md says only that such a report is refused. Egress and the driver's reply check have tests for a Hash in place of `rewrites`.

### 20261006-3. Classify: bytea, geometric and other non-text types can still send MCV values.

From the builder of 20261004-91. `bytea`, geometric types (`point` and the like) and other non-text, non-structured types can still be classed low-cardinality, so their MCV values go out. A `bytea` column can hold text.

**Ask the user** which types, if any, to add to the structured (never-sent) list, or whether to flip the rule to an allowlist of types whose values may go out.

- **Depends on:** 20261004-91.
- **Came from:** The builder of 20261004-91.
- **Design:** classify, trust boundary.
- **Decided by the user (2026-10-06):** flip the rule to an allowlist: only types whose values are safe to send (such as numeric, boolean, date/time, uuid and enum types, and domains over them) may be classed low-cardinality and send values. Every other type is withheld like json.
- **Status:** done
- **Landed:** Statistics records `sendable_columns`: text-like types (text/PII path, unchanged) plus an allowlist of int2/4/8, numeric, float4/8, money, oid, bool, date/time types, interval, uuid, enum, and domains over them. Everything else (bytea, bit, geometric, inet/cidr/macaddr, "char", arrays, structured, unknown) is withheld. The column-type query uses OPERATOR(pg_catalog.=), covering 20261006-2 item 2. Store format bumped to 4 so runs classified by older code are refused. Follow-ups: 20261006-7.

### 20261004-10. Make the enclave call timeout configurable.

The driver kills any enclave call after `Transport::Base::DEFAULT_TIMEOUT` (3600s, `driver/lib/quaack/driver/transport/base.rb`). Nothing passes in a different value, though the comment says the driver's config does. On a real Canvas run, index-build failed after exactly 1h00m00s.

Add a driver config setting for this timeout, with a `quaack run` flag to override it, and pass it to every `Transport::Ssh.new` that runs pipeline steps. Validate it as a positive number. Say in the failure message which setting to raise when a call hits the limit, for example: "the enclave call timed out after 1h00m00s; raise `enclave_timeout_seconds`". Document it in the README.

- **Depends on:** none.
- **Came from:** The user's Canvas run, 2026-10-04.
- **Design:** Transport, config.
- **Status:** done
- **Landed:** `enclave_timeout_seconds` in driver.json (positive number, default 3600), overridden by `quaack run --enclave-timeout-seconds N`. `quaack run` (with its setup and teardown) and `quaack start` use it. A timed-out call names the setting to raise. README and DESIGN.md document it.

### 20261004-11. Build each candidate index in its own enclave call.

index-build builds every candidate index in a single `quaacks index-build` call, so the total build time has to fit in one call's timeout. On a large table, a few indexes are enough to pass an hour. Have the driver call index-build once per index instead, so each index gets its own timeout and the run can resume after the last index built. Keep the progress output: one line per index, plus the step summary's count.

Check how a resumed run treats indexes that already exist on the racetrack. They should be skipped, not built again, and not counted as failures.

- **Depends on:** 20261004-10.
- **Came from:** The user's Canvas run, 2026-10-04.
- **Design:** index-build.
- **Status:** done
- **Landed:** `quaacks index-build --run ID --index N` builds only the Nth index and sends its progress line. The driver calls `--index 1`, takes the total from its line, calls 2 through total, then makes the plain call, which skips built indexes, hides all, records burndown, and writes `index_build`. A resumed run skips indexes already on the racetrack. All three gems went to 0.1.6, with the `rake full` stamp.

### 20260928-2. `quaack start --captured-at`.

`quaacks intake` takes `--captured-at <time>` (DESIGN.md's input, clock-anchor), but `quaack start` accepts exactly `--server`, `--query`, and `--plan`, so an operator starting from the laptop can't pass it. The clock is then anchored at intake time, which is wrong for a plan captured earlier. Accept an optional `--captured-at` and pass it through.

- **Depends on:** None.
- **Came from:** Writing the user-facing README (2026-09-28).
- **Design:** input, clock-anchor.
- **Status:** done
- **Landed:** `quaack start` takes an optional `--captured-at <time>` and passes it unchanged to `quaacks intake --captured-at`, which validates it. A refused value reads `bad_captured_at` with fixed driver text giving the accepted format. README and DESIGN.md document it.

### 20261001-7. Send stats only for the columns the query references.

The llm-index-ideas payload's `stats` covers every column of each table the query uses. On wide tables that came to 52k characters for one query. Send stats only for the columns the query references anywhere (select list, WHERE, JOIN, GROUP BY, ORDER BY), found with pg_query from the qualified query. Keep the stored statistics whole. Update DESIGN.md (llm-index-ideas) to match. Settle against DESIGN.md first whether llm-rewrites or any other LLM step sends stats too.

- **Depends on:** 20261001-3.
- **Came from:** The user, 2026-10-01.
- **Design:** classify, llm-index-ideas.
- **Status:** done
- **Decided by the user (2026-10-06):** trim both llm-index-ideas and llm-rewrites; `*` and `t.*` keep every column of the tables they cover.
- **Landed:** `StatsPayload.subset` (enclave/lib/quaack/enclave/stats_payload.rb) cuts each table's outbound `columns` to those the SQL references, found with pg_query. index-payload uses the qualified query (plus the rewrite SQL for a `rewrite_<n>` search), and rewrite-payload uses the qualified query. Unresolvable columns are kept for every table with that name. Bare `*`, whole-row refs, NATURAL joins, and unparseable SQL keep whole tables. Stored statistics and classification stay whole. No other LLM step sends stats.

### 20261006-11. Run the spec suites in parallel.

The per-commit check takes about 19 minutes because the `Rakefile` runs the suites one after another: enclave about 10.5 minutes, root about 6.3 (mostly the eight kept pipeline replays), driver about 2, protocol under a second. They're separate processes, and each starts its own Postgres container with a Docker-assigned port, pid-named databases, and stale-container cleanup that removes only containers whose owner pid has exited. So they can run at once, and wall time drops to about the slowest suite.

Run every suite at the same time, in both `rake` and `rake full`. Keep every current rule: every suite runs even after one fails, and the run fails if any suite fails, if a suite runs no examples, or if the root `spec/` suite didn't run. Buffer each suite's output and print it whole, under a header naming the suite, when that suite finishes, so the output doesn't interleave. Keep RuboCop and the version-stamp checks as they are. Print each suite's wall time.

Check these before relying on it, and fix what you find:
- Concurrent builds of the test Postgres image from `spec/support/postgres/Dockerfile`, all with the same tag, at suite start.
- Specs that write a fixed path a parallel suite could also write, such as a real `~/.quaack`, a fixed temp file name, or `spec/fixtures/full_replay_versions.json` (written only after everything passes).
- Docker memory with four containers at once.

Update CLAUDE.md's description of the two commands if it changes.

- **Depends on:** None.
- **Came from:** The user, 2026-10-06, after profiling the per-commit check.
- **Design:** None (test infrastructure).
- **Status:** done
- **Landed:** The `Rakefile` runs every suite at once, one thread per suite, and holds each suite's output until it finishes, then prints it under a header naming the suite, whether it passed, and its wall time. Every failure rule is unchanged. `TestPostgres` builds the test image under a per-tag `flock`, so parallel suites build it once. No shared fixed paths were found, and peak Docker memory was about 853 MiB. The per-commit check went from about 19 minutes to about 10.

### 20261004-1. `quaack run` step summaries: counts and rule names from the enclave.

20261003-15 gives each finished step a summary, but some steps can only say what they did, not how much. The enclave sends the driver nothing but `done` for index-search, index-rank, arena-setup, baseline, index-baseline, candidate-runs, minimax, result-comparison and selection. And rewrite-rules doesn't say which rules fired. So the lines read "Searched for indexes", not "Found 12 possible index definitions mechanically", and rewrite-rules gives counts only.

The rule:

- Add an allowlisted counts message, sent by each of those steps when it finishes. It carries only small integers with fixed key names, such as `{"type":"step_counts","found":12}`. The protocol whitelist checks every key and that every value is a non-negative integer.
- rewrite-rules reports which rules fired, by name. The names must come from a constant list shared through the protocol gem, matching the enclave's RULES. The whitelist and the driver both refuse any name not on that list.
- The driver's summaries use these counts and names.
- Sentinel tests: a value planted in the data never reaches the counts or the names. A forged message carrying a string where a count belongs is refused.

- **Depends on:** 20261003-15.
- **Came from:** The build of 20261003-15. The user asked for it, 2026-10-04.
- **Design:** Progress lines for `quaack run`, the protocol whitelist.
- **Status:** done
- **Landed:** A new allowlisted `step_counts` message (`Protocol::StepCounts`: fixed count keys with Integer values from 0 to below 10^12, plus an optional `rules` list drawn from `RULE_NAMES`, which a spec ties to the enclave's RULES) goes out before `done` from index-search, index-rank, arena-setup, baseline, index-baseline, candidate-runs, minimax, result-comparison, and selection. rewrite-rules sends the names of the rules that fired. Egress and the driver both check it, and the driver falls back to the plain line on a bad or incomplete message. The summaries use the counts (`driver/lib/quaack/driver/counted_summary.rb`). All three gems went to 0.1.7, with the `rake full` stamp.

### 20261001-28. Tell the LLM what the rules already made.

llm-rewrites' payload carries the rule-made rewrites' SQL, and the prompt says not to repeat them, as llm-index-ideas does with `mechanical_results`.

- **Depends on:** 20261001-23.
- **Came from:** 20261001-21.
- **Design:** llm-rewrites, rewrite-rules.
- **Status:** done
- **Landed:** `quaacks rewrite-payload` sends `rule_rewrites`, `{sql, rules}` for each stored rule-sourced rewrite. Its SQL is built on the redacted query, and a guard sends one only if every constant in it is in the redacted query or is `1`/`true`. Transformations and assumptions are never sent. The whitelist allows the field, and the llm-rewrites system prompt says not to repeat them. The four corpus `llm-rewrites-1/prompt.md` system sections were updated. All three gems went to 0.1.8, with the `rake full` stamp.

### 20261006-9. A timed-out index build can race its resume.

From the review of 20261004-11. When a per-index `quaacks index-build --index N` call hits the enclave timeout, the driver kills ssh, but the backend `CREATE INDEX` may keep running on the racetrack. A quick resume then issues a second `CREATE INDEX` for the same `quaack_<hash>` name, which can wait on it and then fail on a duplicate name (`enclave/lib/quaack/enclave/steps/index_build.rb` ~73, `IndexBuild.create`). The single-call build had this too, but per-index timeouts make it likelier. Fix with `statement_timeout` on the build connection, or by waiting on or cancelling a running build of the same name before creating it.

- **Depends on:** 20261004-11.
- **Came from:** The review of 20261004-11.
- **Design:** index-build.
- **Status:** done
- **Landed:** `Enclave::BuildConnection` sets `client_connection_check_interval = '2s'` on the build connection (Postgres 14+), so the server ends an orphaned build soon after its client goes away. Before each build, `IndexBuild.create` cancels any other active backend still building the same `quaack_<hash>` name (`pg_cancel_backend`) and waits up to 30s, else refuses `index_build_orphan_running`. The chosen fix is to cancel, not wait. All three gems went to 0.1.9, with the `rake full` stamp.

### 20261006-8. Enclave timeout: minor findings from 20261004-10.

From the review of 20261004-10.
1. `quaack setup` keeps a fixed 3600s timeout, but a timed-out call there still says to raise `enclave_timeout_seconds`, which setup does not read (`driver/lib/quaack/driver/enclave_error.rb` `timed_out`, `setup_command.rb`). Have setup read the setting, or drop the hint when the timeout did not come from the config or flag. Deploy may have the same issue if its calls go through `Transport::Base`.
2. `--enclave-timeout-seconds` parses with `Float()`, so it accepts forms like `0x10` and `1_000` (`driver_config.rb`). Harmless, but looser than a plain number of seconds.
3. `EnclaveVersion.check!` reads any failed version call, including a timeout, as "quaacks is not installed".

- **Depends on:** 20261004-10.
- **Came from:** The builder and review of 20261004-10.
- **Design:** Transport, config.
- **Status:** done
- **Landed:** `quaack setup` reads `enclave_timeout_seconds`, defaulting to 3600, and refuses a bad driver.json before touching the jump server. `quaack deploy` keeps its fixed timeout, and its timeout message names no setting (`EnclaveError#rule_with_note(timeout_hint:)`). `--enclave-timeout-seconds` takes only plain decimals. A timed-out version check reports `timeout`, not "quaacks isn't installed". This was driver-only, with no version bump.

### 20261006-5. Bind a clock-word placeholder to the anchored value (20261004-95 item 4).

Split from 20261004-95. `bind` puts the query's real literals into `$n` before the insert check. A `clock_literal` refusal therefore tells the LLM one bit (whether a placeholder holds a clock word, like `bad_value`), and `VALUES ($1)` is refused when `$1` is `'today'`. Binding the anchored value instead avoids both. The user decided (2026-10-06) to bind the anchored value.

A first build (reverted commit 50b1c27 on `main`'s history, `counterexamples/clock_binding.rb`) failed the second review: it anchored placeholders whose word never reaches a date/time value. `INSERT INTO t (id, tags) VALUES (1, string_to_array($1, ','))` into `tags text[]` with `$1 = 'today'` loaded `{2024-01-01}` instead of `{today}`. The literal `'today'` form is also refused as `clock_literal` though no date/time is reachable (insert_clock_words.rb ~158-160, ~222-223). Restrict anchoring, and the malformed-literal fallback, to targets that can hold a date/time value. Start from the reverted commit and add regressions for both forms. Also cover a placeholder holding a clock word plus more, such as `'today 10:00'` (still refused today).

- **Depends on:** 20261004-95.
- **Came from:** 20261004-95 item 4, and its second review.
- **Design:** What goes into the enclave; insert check; clock anchoring.
- **Status:** done
- **Landed:** `bind` puts the anchored value into a `$n` whose whole literal is a clock word, but only where a real date/time type reads it (`counterexamples/clock_binding.rb`, `InsertClockWords.clock_params` with `reads_clock?(firm: true)`). A `$n` that only a polymorphic parameter reads is bound as written and refused as `clock_literal`. `Types#holds_clock?` limits reading a clock word, and the malformed-literal fallback, to types that can hold a date/time, so `string_to_array($1, ',')` and `string_to_array('today', ',')` into `text[]` load the word as written. `'today 10:00'` is still refused. All three gems went to 0.1.10, with the `rake full` stamp. It passed its second review after one fix round, for the polymorphic-parameter case.

### 20261001-27. rewrite-rules rule: `unused_join_removal`.

- **Depends on:** 20261001-22.
- **Came from:** 20261001-21.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** `RewriteRules::UnusedJoinRemoval` (`enclave/lib/quaack/enclave/rewrite_rules/unused_join_removal.rb`, with `candidates.rb` and `Catalog#strict_foreign_key?`) removes an inner JOIN, or a comma-FROM item and its join conjuncts, to a table read nowhere else. Every join conjunct must be a plain `=` matching a validated, non-deferrable FK's pairs exactly, on plain tables with no inheritance, no RLS on the joined table, enabled RI triggers, the key's own `=` operator, and deterministic collations. Joining columns must be catalog NOT NULL. It records `foreign_key` and `not_null` assumptions. In RULES and `RULE_NAMES`, it sits between `union_outer_filter_removal` and `polymorphic_key_copy`. DESIGN.md's rules table row lists every condition and what v1 doesn't support. All three gems went to 0.1.11, with the `rake full` stamp.

### 20261004-86. Plan tree table: measured plans, with blocks, for rewrites.

From 20261004-82's builder and review. Only the original plan carries per-node block counts, because it comes from the operator's `EXPLAIN (ANALYZE, BUFFERS)`. A rewrite's plan in the report is a hypothetical `EXPLAIN`, so in "Why the winner reads fewer blocks" the winner's blocks column is all "not recorded" and the report doesn't say why. Record a measured plan (ANALYZE, BUFFERS) for each ranked candidate from its measurement runs (today these keep plans only when a run is unstable), and send it in the payload within the same `PlanNodes` boundary. Until then, the report should say in words why the winner's column is empty.

- **Depends on:** 20261004-82.
- **Came from:** The builder and review of 20261004-82.
- **Design:** report, measure, egress.
- **Status:** done
- **Landed:** Each measured set stores `"plan"`, the redacted plan of its most-blocks run, the same run whose totals `MeasuredLabels.summary` reports. `report-payload` sends each label's slow-set plan through the original plan's `nodes()` extraction. Egress and the driver's reply check require `labels` to be an Array of Hashes, with each `plan` nil or valid under `PlanNodes`. "Why the winner reads fewer blocks" shows the winner's measured plan with its blocks. Without one, it says in words why the column is empty. There's no store-format bump, since older stores just lack `"plan"`. All three gems went to 0.1.12, with the `rake full` stamp.

### 20261004-4. The Picker breaks CHECK constraints when no value fits both the atom and the CHECK.

When no value in the pool satisfies both the atom and the column's CHECKs, the Picker falls back to the first value in the pool, even if that value breaks a CHECK. On Canvas-like schemas:
- `workflow_state <> 'deleted'` picks `'DELETED'`, which isn't in the CHECK's IN list.
- `role_state LIKE 'c%'` picks `'c%'`.

S1 then fails to load with `fixture_load_failed` (23514), so every candidate is disproved. This was there before 20261004-2. It will likely hit the next Canvas run.

The fix: add the CHECK's own values that satisfy the atom to the Picker's candidates. Test on real Postgres with a CHECK IN list and both atoms above.

- **Depends on:** 20261004-2.
- **Came from:** The build of 20261004-2.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** The Picker (`enclave/lib/quaack/enclave/scenarios/picker.rb`) now tries each CHECK's own values on the slot's columns (`Checks#values`) after the pool values. When no candidate satisfies every atom, it falls back to the first candidate that passes every CHECK, so a fixture never breaks a CHECK and fails as `fixture_load_failed`. An atom left unhit is still marked untested by vacuity-guard. The new tests run on real Postgres with `workflow_state <> 'deleted'`, `role_state LIKE 'c%'`, and an unsatisfiable `LIKE 'x%'`. All three gems went to 0.1.13, with the `rake full` stamp.

### 20261004-12. Build index-build's indexes in table order.

index-build builds the candidate indexes on the run server in whatever order they arrive. That can build one on a large table, then one on another large table, then go back to the first, so the first table's pages have already left the cache. Group the builds by table, so every index on one table is built before moving to the next, while that table is still in cache. Within a table, keep the current order.

Test that the build order is grouped by table, and that every index still gets built and reported. If 20261004-11 has landed by then, keep its one-call-per-index structure and order those calls by table.

- **Depends on:** none.
- **Came from:** The user, 2026-10-04.
- **Design:** index-build.
- **Status:** done
- **Landed:** `Enclave::BuildOrder.ddls` (`enclave/lib/quaack/enclave/build_order.rb`) takes index-build's distinct DDL and groups it by the parsed `[schemaname, relname]`. Tables appear in the order they first show up, and each table keeps its own order. The plain call and `--index N` both use it, so each table's indexes are built back to back. All three gems went to 0.1.14, with the `rake full` stamp.

### 20260929-20. `quaack deploy` removes old enclave versions.

Every `quaack deploy` installs the new `quaacks` and `quaack-protocol` gems next to the old ones in the jump server's user gem directory, so versions pile up. After a successful install and version check, have deploy remove every version of those two gems older than the last release. It keeps the version it just installed and the one before it, so the operator can still fall back one release.

- Remove only QUAACK's own gems (`quaacks` and `quaack-protocol`), only from the user gem directory, and only with `gem uninstall --user-install -v <version>`. Never touch shared dependencies such as pg or pg_query, and never use sudo.
- Do it only after the new version answers `quaacks --version` correctly. A failed deploy removes nothing.
- Print a line for each version removed, like the other deploy progress lines.
- Also clear the old gem files out of `~/.quaack/deploy`.
- Open question: "the last release" here means the version installed before this deploy. If the operator skipped a release, is that still right, or should deploy keep the highest version older than the new one? Settle this before building.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-09-29, after the bump to 0.1.1.
- **Design:** Where QUAACK runs, "Deploying the enclave".
- **Status:** done
- **Landed:** After `quaacks version` answers correctly, `quaack deploy` (with `driver/lib/quaack/driver/deploy_cleanup.rb`) keeps the version it just installed and the highest installed version older than that, for `quaacks` and then `quaack-protocol`. It uninstalls every other older version with `gem uninstall --user-install -v`, printing a line for each. Newer versions are left alone, with a line saying so. It also deletes old gem files from `~/.quaack/deploy`. Versions are compared as `Gem::Version`. It only touches those two gem names, never uses sudo, and removes nothing when the deploy fails. The user was asleep, so the main session decided (2026-10-07) to keep the highest version older than the new one, not the version installed before this deploy. This is driver-only, with no version bump.

### 20261006-12. Parallel suites: minor findings from 20261006-11.

From the review of 20261006-11.
1. A suite killed by a signal shows as "exit " with no number, since `exitstatus` is nil (`Rakefile` ~83). Name the signal instead. This predates 20261006-11.
2. The image-build lock file is in `Dir.tmpdir`, so two runs with different `TMPDIR` values don't share it and can still build the same tag at once (`spec/support/test_postgres.rb` ~237). Use a fixed per-user path.
3. If a suite thread raises an unexpected exception, `join` re-raises it in order, so later suites' output never prints and their child processes are orphaned (`Rakefile` ~76-93). The run still fails. Join every thread before raising, and print what each one held.

- **Depends on:** 20261006-11.
- **Came from:** The review of 20261006-11.
- **Design:** None (test infrastructure).
- **Status:** done
- **Landed:** A suite killed by a signal now shows `failed (killed by SIGKILL)` in its header and in the failure summary. The test image's build lock moved to `~/.cache/quaack/quaack-test-postgres-<hash>.lock`, so it no longer depends on TMPDIR. Each suite's thread now catches its own exceptions and records `<suite> (raised <Class>: <message>)` as failed and not run. Every other suite still prints, and the run fails naming that suite.

### 20261006-18. `unused_join_removal`: minor findings from 20261001-27.

From the review of 20261001-27.
1. In `enclave/lib/quaack/enclave/rewrite_rules/unused_join_removal/candidates.rb` (~118), the `joining&.size == 1` guard has no test. Weakening it to `positive?` would crash the rule (nil `.last`) on a comma join with a conjunct that doesn't touch the joined table, such as `e.id = p.user_id`. Add a three-item comma join with an unrelated column equality.
2. In `catalog/foreign_keys.rb` (~46), the inheritance-child refusal (`i.inhrelid IN (ch.oid, pa.oid)`) has no test. Add one, or drop the restriction if it isn't needed for soundness.
3. No spec pins a self-referencing FK, such as `employees e JOIN employees m ON e.manager_id = m.id`. The review found it fires correctly.
4. Coverage: `unread?` (~100) counts references by name across the whole query, so it refuses whenever another scope reuses the joined table's name. Examples: the same join in both UNION ALL branches, or Rails' `posts.user_id IN (SELECT "users"."id" FROM "users" ...)` next to `JOIN users`. Count per scope instead, so these can fire.

- **Depends on:** 20261001-27.
- **Came from:** The review of 20261001-27.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** Tests now pin a three-item comma join past an unrelated equality, a joining and a joined table that are inheritance children (refusal kept), and a self-referencing foreign key. The "read nowhere else" count is now per scope (`unused_join_removal/reads.rb`): only references inside the joining SELECT count, and a `name.column` or `name.*` in a nested SELECT whose own FROM binds the name first is that SELECT's. So the same join in each UNION ALL branch is removed in each, and Rails' `IN (SELECT users.id FROM users ...)` next to `JOIN users` fires. Bare columns of the table's columns still block at any depth inside the SELECT. Gems bumped to 0.1.15.

### 20261006-13. Step counts: candidate-runs' measured count leaves out timed-out runs.

From the review of 20261004-1. candidate-runs sends `measured` as the kept runs only (`enclave/lib/quaack/enclave/steps/candidate_runs.rb` ~37), but its summary reads it as the total (`driver/lib/quaack/driver/counted_summary.rb` ~84-86). When every run times out, the line says "No rewrites to measure", and "Measured 5 rewrite runs, 2 timed out" really means 2 out of 7. baseline and index-baseline do count timed-out runs in their totals. Send kept plus timed out as `measured`, or change the wording. Also, no realistic index-rank run gives a non-zero `combined`, so only a direct unit test covers it.

- **Depends on:** 20261004-1.
- **Came from:** The builder and review of 20261004-1.
- **Design:** Progress lines for `quaack run`.
- **Status:** done
- **Landed:** candidate-runs now sends `measured` as kept runs plus timed-out runs, the total, as baseline and index-baseline do. So "Measured N rewrite runs, M timed out" reads M of N. "No rewrites to measure" shows only when there were no runs. The driver needed no change. The side note (only a direct unit test covers index-rank's non-zero `combined`) was set aside and filed as 20261006-24. All three gems went to 0.1.16, with the `rake full` stamp.

### 20261004-5. Build the original query's scenarios once, not once per rewrite.

`steps/counterexamples.rb` calls `ScenarioTests.run` once per candidate. Each call builds a new `Builder`, which rebuilds the same scenarios for the original query and loses its probe caches. Build them once per run and share them across candidates, so the outcomes stay the same.

- **Depends on:** 20261004-2.
- **Came from:** The build of 20261004-2.
- **Design:** rewrite-test.
- **Status:** dropped
- **Dropped by the user (2026-10-07):** It was an optimization only, and the cheap version is stale: each rewrite already gets its own enclave process. A batch `rewrite-test` isn't worth building without evidence that scenario building costs much. If 20261004-27 shows that it does, file a new task.
- **Set aside (2026-10-07):** The builder found this stale as written. `rewrite-test` handles one rewrite per call. The driver (`CounterexampleStage#rewrite`) makes a separate enclave call for each rewrite, and each call already builds the original's scenarios once. Repeated builds happen across processes, so sharing in memory changes nothing. A real fix crosses the protocol. Option 1 is a batch `rewrite-test` taking several `--search` values in one process, which means changing the driver's `CounterexampleStage` and resume. Option 2 caches built scenarios in the enclave store. It adds trust-boundary surface, and probe caches still rebuild. With either option, the vacuity guard depends on each rewrite's `honour` copies, so only the Builder's output can be shared. The builder recommends option 1. The user to decide: drop it, or rewrite it as option 1.

### 20261006-15. Orphaned-build cancel: minor findings from 20261006-9.

From the review of 20261006-9 (`enclave/lib/quaack/enclave/build_connection.rb`).
1. Nothing tests the 30s deadline that refuses `index_build_orphan_running` (~45).
2. If two runs share a racetrack database and build the same DDL at once, the second cancels the first run's live build. Before, the second would have failed on the duplicate name instead. Say in DESIGN.md whether runs may share a racetrack. If they may, scope the cancel to backends with no client.
3. If the role can see an orphan's query (`pg_read_all_stats`) but can't signal it, say because a superuser owns it, `pg_cancel_backend` raises a raw permission error (~47). Refuse it by rule instead.
4. Nothing tests the `state = 'active'` filter (~59).

- **Depends on:** 20261006-9.
- **Came from:** The review of 20261006-9.
- **Design:** index-build.
- **Status:** done
- **Landed:** `BuildConnection.cancel_orphans(..., wait:)` returns the pids it cancelled. A `pg_cancel_backend` permission error is refused as `index_build_orphan_cancel_denied`, with no cause attached. Real-Postgres tests cover the 30s deadline (a backend that ignores the cancel), the permission refusal (a role that can see the orphan but can't signal it), and the idle filter. DESIGN.md says a racetrack serves one run at a time. Also fixed: `IndexBuild::Error` had no `rule`, so every index-build refusal went out as `internal_error`. It now goes out under its own fixed rule name. All three gems went to 0.1.17, with the `rake full` stamp.

### 20261004-14. Give each mechanical rewrite rule its own doc page, with examples, and link to it from the report.

The mechanical rules (rewrite-rules) are listed in a table in DESIGN.md. Move each one to its own page, `docs/transforms/<rule_name>.md`, named exactly as the rule appears in the enclave's `RULES` (for example `docs/transforms/implied_predicate_removal.md`). Each page has:
- what the rule does, and when it applies and refuses (from the DESIGN.md table and the rule's code comments);
- any assumption it rests on, such as `denormalized_equal`;
- at least one example: the SQL before the rule and the SQL after, written as an ordinary Rails-style query. These come from 20261001-29, which no longer has them.

DESIGN.md's table stays as a short index: one line per rule, linking to its page.

In the final report, where a rewrite's source is a rule, link the rule's name to its page on GitHub: "Where it came from: made by QUAACK's own rewrite rule [implied_predicate_removal](https://github.com/benchub/quaack/blob/main/docs/transforms/implied_predicate_removal.md)."
- Build the URL only from a rule name on the shared constant list of rule names, never from text in the enclave's message. A name not on the list gets no link, as now.
- HTML-escape the link.

Tests:
- a spec that every rule in `RULES` has a page in `docs/transforms/`, and every page there names a rule in `RULES`, so a new rule can't land without its page;
- a report spec for the link, and one showing that a name not on the list gets no link.

Do this after 20261001-29 if it's in flight, since both touch the same DESIGN.md table.

- **Depends on:** none.
- **Came from:** The user, 2026-10-04.
- **Design:** rewrite-rules, report.
- **Status:** done
- **Landed:** Each rule in RULES now has its own page, `docs/transforms/<rule>.md`. A page says what the rule does and when it refuses, what it rests on, and gives a real before/after example made by running the rule on Postgres against a Rails-style schema. DESIGN.md's rewrite-rules table is now an index that links to the pages. In the report, "Where it came from" links a rule's name to its GitHub page through `Report::RuleLinks#source_html`. A link is built only from an exact match in `Protocol::StepCounts::RULE_NAMES`, and the output is escaped. Any other name stays plain text. `spec/transform_docs_spec.rb` checks that every rule has a page, every page names a rule, and DESIGN.md's index links each one. Driver and docs only, with no version bump. Built in parallel with 20261006-15 at the user's request.

### 20261006-17. Clock binding: overloaded user functions.

From the second review of 20261006-5. `clock_params` (`enclave/lib/quaack/enclave/insert_clock_words.rb` ~131-137) checks `reads_clock?` over every overload's parameter types. With a user function overloaded as `f(text)` and `f(date)`, `fx.f($1)` into a `text` column, with `$1 = 'today'`, is anchored to a date, though Postgres resolves the unknown argument to `f(text)` and would load `'today'`. Anchor only when every candidate's parameter type at that position is a date/time type, or else bind as written and refuse it.

- **Depends on:** 20261006-5.
- **Came from:** The second review of 20261006-5.
- **Design:** counterexamples inserts, clock anchoring.
- **Status:** done
- **Landed:** `Types#reads_clock?(firm: true)` (`enclave/lib/quaack/enclave/insert_clock_words.rb`) now anchors a `$n` only when every candidate type for each of its targets agrees on reading it as a real date/time type (`disagree?`). With `f(text)` and `f(date)` both defined, `fx.f($n)` is bound as written and refused as `clock_literal`. A single `f(date)`, casts, `daterange`, `::date[]`, date columns, and a domain over date still anchor. All three gems went to 0.1.18, with the `rake full` stamp.

### 20261006-14. `rule_rewrites` guard: drops a future rule's rewrites without a word.

From the review of 20261001-28. `rewrite_payload.rb` (~46) leaves a rule rewrite out of `rule_rewrites` when it holds a constant that isn't in the redacted query and isn't in `RULE_CONSTANTS` (`1`, `true`). No rule writes any other constant today. But a new rule that writes `NULL` or `0` would have its rewrites dropped without a word, and the LLM might repeat them. Add a spec that runs every rule in RULES over the existing rule fixtures and checks that each constant they write is in `RULE_CONSTANTS`, so adding a rule forces the list to be updated.

- **Depends on:** 20261001-28.
- **Came from:** The review of 20261001-28.
- **Design:** llm-rewrites, rewrite-rules.
- **Status:** done
- **Landed:** `enclave/spec/rule_constants_postgres_spec.rb` runs every rule in RULES on its `docs/transforms` page's schema and Before query, filling placeholders from a LITERALS table, then redacting. It asserts that the rule fires and that every rewrite it takes part in holds only the redacted query's constants plus `RULE_CONSTANTS`, collected with `RewritePayload.constants`. A separate example fails when a rule in RULES has no page, schema, Before block, or LITERALS entry. No rule writes a disallowed constant today. The change is tests only, with no version bump. The review noted two harmless nits and filed no task for them: a stale LITERALS entry for a removed rule wouldn't be flagged, and one check is repeated.

### 20261006-16. Timeout docs: two gaps from 20261006-8.

From the review of 20261006-8. DESIGN.md (~277) still says only "`quaack start` and `quaack run` refuse" a bad driver.json. `quaack setup` refuses one too now, even for a bad `jump_command` it never uses. README.md (~189) gives only `5400` as a flag example. DESIGN.md also shows `90.5`, which the code accepts.

- **Depends on:** 20261006-8.
- **Came from:** The review of 20261006-8.
- **Design:** config.
- **Status:** done
- **Landed:** DESIGN.md now says `quaack start`, `quaack setup`, and `quaack run` all refuse a bad driver.json, and that setup checks the whole file, `jump_command` included. README.md gives `5400` or `90.5` as the flag examples. Docs only, landed with 20261006-26.

### 20261006-26. Rule pages: style nits from 20261004-14.

From the review of 20261004-14.
1. The "Before" query in `docs/transforms/not_in_to_not_exists.md` reads `NOT users.id IN (...)`, the deparser's form, not `users.id NOT IN (...)` as Rails writes it. Show the Rails form, or say the query is shown as QUAACK deparses it.
2. DESIGN.md's rule index (~813-824) writes SQL keywords bare in the descriptions but in backticks in the Needs column. Pick one style.

- **Depends on:** 20261004-14.
- **Came from:** The review of 20261004-14.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** The Before block in `docs/transforms/not_in_to_not_exists.md` is unchanged. A new note says queries are shown as QUAACK deparses them, so Rails' `users.id NOT IN (...)` reads `NOT users.id IN (...)`. The "What it does" column in DESIGN.md's rule index now puts SQL keywords in backticks, like the Needs column. Docs only, landed with 20261006-16.

### 20261006-10. Stats trimming: minor findings from 20261001-7.

From the builder and review of 20261001-7.
1. A table alias with a column list, such as `FROM orders o(a, b)`, makes `o.a` keep a column named `a`, not the real column it renames, so the real column's stats can be dropped. Map aliased column names back to the real columns, or keep the whole table when an alias carries a column list (`enclave/lib/quaack/enclave/stats_payload.rb`).
2. DESIGN.md (llm-index-ideas, ~755) and the comment at `stats_payload.rb` ~16-19 say a column qualified by a CTE's alias counts for every table with that name. In the code, a CTE referenced by its own name (`FROM recent`, then `recent.x`) maps to a table named `recent`. Nothing is dropped, since the CTE body's own references are counted, but fix the wording or treat CTE names like subquery aliases.

- **Depends on:** 20261001-7.
- **Came from:** The builder and review of 20261001-7.
- **Design:** llm-index-ideas, llm-rewrites.
- **Status:** done
- **Landed:** `StatsPayload` maps each name in a table alias's column list (`FROM orders o(a, b, c)`) to the real column at that position in the outbound stats. Those columns are in attnum order with dropped columns skipped, the same way Postgres skips them, and the review checked this against real Postgres with a dropped column. A list longer than the known columns keeps the whole table. The subset still only removes entries. The code comment and DESIGN.md now say a CTE name resolves like a table of that name. All three gems went to 0.1.19, with the `rake full` stamp.

### 20261006-23. Parallel suites: minors from 20261006-12.

From the review of 20261006-12.
1. A suite whose thread raised prints only its header, with no `cd ... && ...` command line to rerun it (`Rakefile` ~88-92). Print the command line too.
2. The raise test (`spec/rakefile_spec.rb` ~298-320) has no root `.` suite, so nothing checks that a root suite that raised stays out of `ran`.

- **Depends on:** 20261006-12.
- **Came from:** The review of 20261006-12.
- **Design:** None (test infrastructure).
- **Status:** done
- **Landed:** A suite whose thread raised now prints its `cd ... && ...` rerun line under its header, as every other suite does (`rerun_line` in the `Rakefile`). A separate test checks that a root suite that raised is never counted as run, and that the run fails with the root-must-run rule. This is test infrastructure only, with no version bump.

### 20261006-22. Deploy cleanup: minor findings from 20260929-20.

From the review of 20260929-20.
1. `gem uninstall --user-install` also uninstalls from GEM_HOME (`driver/lib/quaack/driver/deploy_cleanup.rb` ~72). If the same old version sits in a writable GEM_HOME, such as an rbenv or asdf Ruby, it could be removed there too. Deploy never installs there. Check whether pinning `--install-dir Gem.user_dir` instead is cleaner.
2. If the listing or an uninstall fails after a good install and version check, deploy exits 1 even though the new version is live (`deploy.rb` ~116-124). Consider making cleanup failures a warning.
3. The "leaving <newer>" path (~69) is hard to reach for real, since a newer `quaacks` would win the bin wrapper and fail the version check first. Its test reaches it only through a planted gem with no executable.

- **Depends on:** 20260929-20.
- **Came from:** The review of 20260929-20.
- **Design:** Deploying the enclave.
- **Status:** done
- **Landed:** Deploy's uninstall now runs `gem uninstall --install-dir "$(ruby -e 'print File.realpath(Gem.user_dir)')"`, which touches only the user gem directory. A copy in a separate GEM_HOME is left alone, and a real-gem test checks that. The realpath is needed under symlinked homes. A failed listing, uninstall, or old-file removal after a good install prints a warning naming the step and host, and deploy still exits 0. A failed listing skips the rest of the cleanup. The "leaving <newer>" path has a comment saying why it's hard to reach. DESIGN.md matches. Driver only, no version bump.

### 20261006-7. Sendable columns: loose ends from 20261006-3.

From the builder of 20261006-3.
1. The other catalog queries in `planner_statistics/catalog.rb` (tables, pg_stats, indexes, extended statistics) still use bare operators. They don't decide what's sent, but a planted operator could make them answer wrongly. Qualify them. Related: 20260930-13, 20260930-14.
2. Dedupe now drops partial indexes whose predicates use a newly withheld type (inet, `"char"`, bit and the like). That's fail-closed by design, but it's a behavior change: say so in DESIGN.md, or let those predicates through when they carry no values.

- **Depends on:** 20261006-3.
- **Came from:** The builder of 20261006-3.
- **Design:** statistics, index-dedupe, trust boundary.
- **Status:** done
- **Landed:** Every operator, function, and cast in the four statistics catalog queries (`planner_statistics/catalog.rb`) is now `pg_catalog`-qualified: `OPERATOR(pg_catalog.=)`, `pg_catalog.array_to_json`, and `::pg_catalog.text`. That closes a leak where a planted `public.array_to_json` put customer emails into extended statistics' frequencies, which classify sent unchecked. The new `PiiClassification::OutboundShape` refuses classify with `statistics_bad_shape`, storing nothing, when a statistic has the wrong shape:
- frequencies or `null_frac` outside 0..1
- a non-finite `n_distinct`
- `correlation` outside -1..1
- kinds not drawn from d/f/m/e
- non-boolean null flags
- `n_distinct` or `dependencies` not in Postgres's text format

Tests plant operators, `array_to_json`, and a `public.text` type, and include an inheritance parent. DESIGN.md documents dedupe's fail-closed drop of partial indexes on withheld types, and a test pins it. All three gems went to 0.1.20, with the `rake full` stamp. It passed its second review after one fix round.

### 20261007-1. The orphan-cancel deadline test flakes under load.

`enclave/spec/index_build_step_postgres_spec.rb` ~496 is the deadline test from 20261006-15. It runs a backend that ignores `pg_cancel_backend`, with `wait: 1`, and expects `index_build_orphan_running`. During 20261006-7's first `rake full`, with every suite running in parallel, the error wasn't raised. The test passed alone and on the rerun. A flaky test in the per-commit check costs a rerun every time it trips. Find the race, maybe the orphan not yet active, or the stubborn function not yet looping when the wait starts. Make the setup wait for a state it can observe instead of relying on timing.

- **Depends on:** 20261006-15.
- **Came from:** The builder of 20261006-7, 2026-10-07.
- **Design:** index-build.
- **Status:** done
- **Landed:** The deadline test now waits until the stubborn backend shows `state = 'active'` and `wait_event = 'PgSleep'`, and the function keeps its whole sleep loop inside the block that catches the cancel. That closes the statement-boundary gap where a cancel could stop it under load. The fix rests on reasoning: the old flake never reproduced. Five review runs and ten builder runs under load passed. Landed with 20261006-25 and 20261006-21. Test only.

### 20261006-25. Orphan cancel: two test nits from 20261006-15.

From the review of 20261006-15. Changing `cancelled |= pids` to `+=` in `enclave/lib/quaack/enclave/build_connection.rb` (~51) leaves the "once each" test green (`enclave/spec/index_build_step_postgres_spec.rb` ~416), because the orphan stops after the first cancel. Only tests read the return value. Separately, the permission test (~441) leaves the orphan blocked until `after` closes the locker, after which it may finish building. Terminate it in the test.

- **Depends on:** 20261006-15.
- **Came from:** The review of 20261006-15.
- **Design:** index-build.
- **Status:** done
- **Landed:** The "once each" test now uses a backend that survives three cancels, so `|=` changed to `+=` turns it red. The permission test terminates its orphan. Landed with 20261007-1. Test only.

### 20261006-21. index-build: test that a DDL in several combinations is built once.

From the review of 20261004-12. Dropping `.uniq` in `enclave/lib/quaack/enclave/build_order.rb` (~16) leaves `index_build_step_postgres_spec.rb` green. No fixture there has a DDL in more than one combination, so nothing catches an index built or counted twice. Add a fixture where a DDL is in both `top` and `combination`, or in two searches. Assert that the total and the built list have no duplicates.

- **Depends on:** 20261004-12.
- **Came from:** The review of 20261004-12.
- **Design:** index-build.
- **Status:** done
- **Landed:** A new test sets a DDL in several combinations, and also sets it aside twice. It asserts the DDL is built and counted once, in progress, `index_build`, and burndown. Dropping `.uniq` turns it red. Landed with 20261007-1. Test only.

### 20261006-20. Picker CHECK values: minor findings from 20261004-4.

From the review of 20261004-4 (`enclave/lib/quaack/enclave/scenarios/picker.rb`, `enclave/spec/scenarios_postgres_spec.rb`).
1. The `LIKE 'x%'` test's title and comment (spec ~225-228) say the hit groups are left out. The code actually keeps a hit row with `role_state = 'active'`, which fails the atom but passes the CHECK. Fix the wording.
2. No test separates the CHECK-passing fallback from `:skip` (picker.rb ~48). If the fallback always returned `:skip`, every test would still pass, though S3 and S6 would lose their rows. Add an assertion on those rows.
3. The non-near `:skip` branch (picker.rb ~48) is effectively dead and has no test. With CHECK values appended, it's reached only when a column's CHECKs reject each other's values, and `Checks#satisfying` already refuses that. The near-miss `return :skip if near` (~46) has no test that tells it from a fallback either. Pin both, or simplify.

- **Depends on:** 20261004-4.
- **Came from:** The review of 20261004-4.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** In `enclave/spec/scenarios_postgres_spec.rb`, the `LIKE 'x%'` test's title and comment now say what happens: the hit keeps `'active'`, which passes the CHECK but fails the atom. A new test checks S3's and S6's rows, so a fallback that returns `:skip` goes red. Another new test pins the near-miss `return :skip if near` with a join, where no near miss can fail the atom. The non-near `|| :skip` (picker.rb ~48) isn't dead, as this entry said. It guards contradictory CHECKs on one column, and join keys with disjoint CHECKs. Without it, a NOT NULL column gets a NULL. It's left as is, and filed as 20261007-5. Test only.

### 20261004-87. Plan tree blocks column: minors from 20261004-82.

1. A step with only one counter shows it as its total (hit missing, read 9 shows "9"). Postgres always writes both, so it's unlikely; show "not recorded" instead, or say why not. The spec pins today's behavior.
2. Postgres counts an InitPlan's blocks in the step that runs it, not the step it hangs from, so they can appear twice in the table. The header ("with the steps under it") and DESIGN.md are true but incomplete; say so.
3. The header doesn't say block counts are totals over all loops, while "actual rows" are per loop. A step run many times can show 1 row next to thousands of blocks. Say so in the header or a note.

- **Depends on:** 20261004-82.
- **Came from:** The review of 20261004-82.
- **Design:** report.
- **Status:** done
- **Landed:** A step with only one of its two block counters now shows "not recorded" (`Plans#step_blocks`). A note under the original plan table (`Plans::BLOCKS_NOTE`) explains two things: block counts are totals over every run of a step, while actual rows are per run, and InitPlan blocks can appear twice. DESIGN.md matches. Driver only. Landed with 20261004-59.

### 20261004-59. Collapsed report sections: hidden warnings and links into closed sections.

These are review minors from 20261004-50.

- **Warnings hidden in a closed section.** A rewrite's summary line gives no hint of two warnings inside its section: that it relies on something the data holds today but the schema doesn't enforce, and the list of conditions the test data never exercised. The README tells readers to read those rewrites extra carefully. Add a short flag to the summary line, such as "⚠ relies on data" or "untested conditions". Coordinate with 20261004-51, which rewords the untested-conditions note.
- **Links lead into closed sections.** "Its SQL is under rewrite X, above" and "See rewrite X under the queries" link to the `<article>` around a closed `<details>`, so the target stays collapsed. Point the link at the `<details>` and open it on `:target` without JavaScript (for example, give the `<details>` the id). Otherwise, reword the links to say "expand rewrite X".
- **The not-ranked table's note is incomplete.** It says "Who proposed it" reads "not recorded" for your query with new indexes. The cell also reads that way for a rewrite whose source is unknown or that's missing from the payload. Make the note cover those cases.

- **Depends on:** 20261004-50.
- **Came from:** The review of 20261004-50, 2026-10-05.
- **Design:** report.
- **Status:** done
- **Landed:** A rewrite's summary line flags when its collapsed section holds the empirical or untested-conditions warning (`Rewrites#warning`). Each rewrite's id is now on its `<details>`, and a CSS-only `:target` rule shows the section when a link is followed. That needs a recent browser; older ones leave the section closed. The not-ranked note now covers unknown-source and missing-from-payload rewrites. DESIGN.md matches. Driver only. Landed with 20261004-87.

### 20261006-1. Waiting-for-the-LLM line: minors from 20261004-84.

From the review of 20261004-84.
1. `driver/spec/pipeline_progress_spec.rb` (~432): the new `it` has no blank line before it.
2. `progress.rb` (~107-110): the `sub_step` comment still says a repeated note "is left out on a terminal"; it can now print as a wait line.
3. Removing `note &&` in `Progress#shown` stays green. Harmless today, since no step note repeats its step's line, but nothing pins it. Add a test or drop the guard.

- **Depends on:** 20261004-84.
- **Came from:** The review of 20261004-84.
- **Design:** Progress lines for `quaack run`.
- **Status:** done
- **Landed:** Added the missing spec blank line and fixed the `sub_step` comment. Dropped the `note &&` guard in `Progress#shown`: no realistic note reaches it, and the review checked every `note` and `step_note` caller. Driver only. Landed with 20261001-11.

### 20261001-11. Progress output: minor findings.

The review of 20261001-8 found two minor items:

1. Nothing tests the skip line that operator-rewrites prints on a resumed run with `--rewrites`. If that line broke, every later `[n/18]` number would be off by one, and no spec would catch it. Nothing tests the rewrite-correctness skip note for each rewrite either. Add a cli_run progress spec that resumes with `rewrites_generated` and `operator_rewrites_checked` set and passes `--rewrites`. It should assert `[6/18] operator-rewrites: already done, skipping`, and cover the rewrite-correctness note too.
2. In `Progress#step`, if the first `say` raises, such as EPIPE on stderr, `start` is still nil. The rescue's `since(nil)` then raises a TypeError that hides the real error. Set `start` before the first `say`.

- **Depends on:** 20261001-8.
- **Came from:** The review of 20261001-8, 2026-10-01.
- **Design:** The `quaack run` command.
- **Status:** done
- **Landed:** Item 1: a new cli_run spec pins the operator-rewrites skip line on a resumed run with `--rewrites` (step 7 of 19), and the rewrite-correctness skip note for each rewrite. Breaking either one turns it red. Item 2 was already done: `clocked` sets the start before the first `say` (b74ba62), and existing specs pin it. Driver only. Landed with 20261006-1.

### 20261007-4. The orphan deadline test hangs, not fails, when the deadline breaks.

From the review of 20261007-1. In `enclave/spec/index_build_step_postgres_spec.rb` (~552), the "won't stop" example builds a stubborn function that survives 1,000,000 cancels. With the deadline check broken, it loops forever instead of failing. Make the function stop after a bounded time, for example with a final `pg_sleep(60)` after a capped count, or wrap the example in `Timeout.timeout(30)`.

- **Depends on:** 20261007-1.
- **Came from:** The review of 20261007-1.
- **Design:** index-build.
- **Status:** done
- **Landed:** The "won't stop" example now wraps `cancel_orphans` in `Timeout.timeout(30)`, so a broken deadline fails in about 35 seconds with a clear error instead of hanging the run. A cap inside the stubborn function wouldn't have worked: it runs once per row of the `CREATE INDEX`, so the build still wouldn't end. Test only.

### 20261007-2. Deploy cleanup warnings: test gaps from 20261006-22.

From the review of 20261006-22.
1. Replacing `return unless out` with `out ||= ""` in `driver/lib/quaack/driver/deploy.rb` (~127) leaves every test green, since an empty listing also plans nothing. Pin "a failed listing skips all cleanup" in a way an empty listing can't satisfy.
2. If the remote `ruby -e 'print File.realpath(...)'` fails (`deploy_cleanup.rb` ~60), its stderr isn't captured, so the warning shows only gem's "not installed" text.
3. No test plants a failing old-gem-file removal on its own.

- **Depends on:** 20261006-22.
- **Came from:** The review of 20261006-22.
- **Design:** Deploying the enclave.
- **Status:** done
- **Landed:** Changes to deploy cleanup:
- **Uninstall command.** It's now `{ d=$(ruby -e 'print File.realpath(Gem.user_dir)') && gem uninstall --install-dir "$d" ...; } 2>&1`, so a failed realpath runs no uninstall and the warning shows ruby's error. Before this, a failed realpath ran `gem uninstall --install-dir ""`. RubyGems reads that as the current directory, the remote `$HOME`, so it passed silently and could uninstall from `$HOME` if that was a gem dir. The review checked the new command under `sh` and `dash`.
- **Planning.** `prune` now always plans from `out.to_s`. A new test plants a listing that prints versions and then fails, and checks that nothing is removed.
- **Old gem files.** A failed old-gem-file removal now has its own warning test.

Driver only, no version bump.

### 20261007-6. Report sections: minors from 20261004-87 and 20261004-59.

From the review of 20261004-87 and 20261004-59.
1. The rewrite summary's warning hint (`driver/lib/quaack/driver/report/rewrites.rb` ~156) uses `atoms(entry)`, so it still says some conditions went untested after a later round checked them all. Use the conditions still unchecked, or say "at first", and add a spec.
2. The `details.query:target` outline rule (`template.html.erb` ~36) has no test. Assert it, or drop it.
3. Add a code comment by the `::details-content` rule. It needs Chrome 131+, Safari 18.4+, or Firefox 143+. Older browsers land on the closed section.
4. Wording option for the hint: "Read it with care: it relies on what your data holds today. The test data also left some of its conditions untested."

- **Depends on:** 20261004-59.
- **Came from:** The review of 20261004-87 and 20261004-59.
- **Design:** report.
- **Status:** done
- **Landed:** The hint in a rewrite's summary is now based on `unchecked_atoms`, so it goes away once a later round checks every condition. When both warnings apply, it uses the two-sentence wording. A spec checks the `details.query:target` outline rule, and a code comment gives the browser versions `::details-content` needs. Driver only. Landed with 20261006-19 item 1.

### 20261001-13. Streamed progress: minor findings.

The review of 20261001-12 found two minor items:

1. Progress lines count toward the transport's output cap. An index-build run that builds a very large number of indexes could hit `output_too_large` from the progress lines alone. That fails safe, but consider leaving room for one line per index, or not counting progress lines toward the cap.
2. The driver's progress block runs inside the transport's read loop. If the block raises or runs slowly, it holds up reading, and that can push the run past its timeout. Consider rescuing the block's errors and logging them.

- **Depends on:** 20261001-12.
- **Came from:** The review of 20261001-12, 2026-10-01.
- **Design:** The transport.
- **Status:** done
- **Landed:** Item 2: `Transport::Base#on_line` now catches a StandardError from the progress block, such as `Errno::EPIPE` when stderr closes. It warns once ("quaack: progress output failed ...; the run goes on without it."), stops calling the block, and reads the call to its end. The result is checked as usual. Interrupt still stops the run. Item 1 no longer applies: index-build makes one call per index, so progress lines no longer pile up toward the output cap. Driver only.

### 20261003-1. `copilot_cli`: pin the drain after the child exits.

The third review of 20261002-12 found one surviving mutation. Returning before the adapter drains stdout and stderr after the child's exit status arrives still passes every spec. It also passed an ad hoc check with 120KB on each pipe, so it's no known bug. But nothing pins the ordering, and a reply still in the pipe when the child exits could be cut short. Add a spec where the fake writes a large reply (at least several pipe buffers) and exits at once, and assert the whole reply arrives. Confirm the mutation goes red.

- **Depends on:** 20261002-12.
- **Came from:** The third review of 20261002-12, 2026-10-03.
- **Design:** LLM client.
- **Status:** done
- **Landed:** A new spec in `driver/spec/copilot_cli_adapter_spec.rb` pins the drain after the child exits. The fake `copilot` writes about 316KB, holds back its last 4KB until signalled, then writes it and exits. A spec thread holds the GVL, so the adapter wakes only after the exit status is ready. The spec asserts the whole reply parses in one call. With the drain moved after the status return, it went red 20 of 20 runs in the build and 5 of 5 in review. With the real code it passed 10 of 10. Spec only.

### 20261004-68. Inline SQL: minors from 20261004-53.

The review of 20261004-53 found:
1. `Report.named` names rewrites from the raw run ID, but `View` uses the scrubbed one for `Words.rewrite` and `Words.search`. A run ID containing `\u0001` or `\u0002` would get mismatched rewrite names. Real run IDs are generated, so either use one source for both or refuse such a run ID.
2. An index method other than btree, such as "(gin)", sits outside the SQL span. Decide whether it belongs inside.

- **Depends on:** 20261004-53.
- **Came from:** The review of 20261004-53, 2026-10-05.
- **Design:** report.
- **Decided by the user (2026-10-07):** Item 2: put the index method inside the SQL span, as `USING gin (...)`, so copy-paste gives working SQL.
- **Status:** done
- **Landed:** Item 1: `Report.render` strips SQL marks from the run ID once (`Format.unmarked`), and both the payload's rewrite names and the view use that one ID. A marked run ID used to give one rewrite two names. Item 2: for a non-btree index, the inline SQL span is now the candidate's own DDL after `CREATE INDEX ON`, such as `public.t USING brin (created_at) WHERE a < ?`, so the old ` (brin)` label outside the span is gone. Btree keeps `public.t (a, b)`, since the default method can be left out. Escaping is unchanged, and partial indexes keep their `WHERE`. Driver only.

### 20261004-85. Closed output pipes: minors from 20261004-62.

1. `QuietStream` only guards `print`. Every write to it uses `print` today, but a later `puts`, `write`, `<<` or `printf` would skip the guard silently. Guard the other write methods, or pin with a spec that they're unused.
2. `quaack setup` changed without docs or tests: `Progress` wraps every stream, so with stderr closed setup now runs its steps silently instead of dying at its first progress line, yet its own `quaack setup failed:` message is unwrapped and still raises `Errno::EPIPE` (exit 1). Decide setup's rule to match `quaack run`, test it with a real `IO.pipe`, and say so in DESIGN.md.
3. With `quaack run … 2>&1 | head`, stdout closes too: the run tears down and writes the report, then printing the report's path raises `Errno::EPIPE` out of `cli.run`. DESIGN.md says so. Decide whether that should exit cleanly with the run's real exit code.

- **Depends on:** 20261004-62.
- **Came from:** The review of 20261004-62 and its builder.
- **Design:** Progress lines for `quaack run`.
- **Decided by the user (2026-10-07):** On a closed pipe, finish and exit with the real code. Ignore EPIPE on progress and on printing the report path, so the run finishes, writes its report, and exits with its real exit code. Setup follows the same rule, its own failure message included.
- **Status:** done
- **Landed:** The user decided (2026-10-07) to finish and exit with the real code:
- `QuietStream` now guards `puts`, `write`, `printf`, `putc`, and `<<` as well as `print`.
- `quaack setup` wraps stdout and stderr, so with a closed pipe it runs every step and exits 0, 1, or 64, its failure and usage messages included.
- `quaack run` wraps stdout as well as stderr, so `2>&1 | head` writes the report, tears down, and exits with its real code.
- The report file and the ssh pipes are still unwrapped and fail loudly.

The specs use real closed `IO.pipe`s, and one spawns `exe/quaack`. DESIGN.md is updated. Driver only.

### 20261007-7. Deploy cleanup: comment and brittle specs from 20261007-2.

From the review of 20261007-2.
1. The comment at `driver/lib/quaack/driver/deploy_cleanup.rb` (~59) says gem takes an empty `--install-dir` "as no dir at all". It actually resolves to the current directory, the remote `$HOME`. Fix the comment.
2. `driver/spec/deploy_spec.rb` (~252) matches the exact `pinned` command string, so three specs fail on any command text change, not on behavior. Move them to behavioral checks.

- **Depends on:** 20261007-2.
- **Came from:** The review of 20261007-2.
- **Design:** Deploying the enclave.
- **Status:** done
- **Landed:** The comment in `deploy_cleanup.rb` now says gem resolves an empty `--install-dir` to the current directory, the remote `$HOME`. The three deploy specs that matched the exact `pinned` command string now check behavior. A `stub_gem` wrapper on the fake jump server's PATH logs each `gem uninstall` and runs the real gem, and the specs check what's left installed. Removing `--install-dir`, `&&`, or `realpath` still turns them red. This is driver only.

### 20261007-8. Progress-block rescue: minors from 20261001-13.

From the review of 20261001-13.
1. In `driver/lib/quaack/driver/transport/base.rb` (~89-98), `Reply.progress(line)` now runs inside the rescue. A parse error of the driver's own would read as "progress output failed" and switch progress off. The whole-run parse still catches real problems. Move `Reply.progress` out of the rescue.
2. In `driver/lib/quaack/driver/pipeline.rb` (~363-366), `build_index` sets `total` before its `note` call. If the block raised first, `total` would stay 0 and `build_indexes` would skip the remaining indexes. That can't happen today, but it's fragile. Pin the order with a test, or don't let `total` depend on the block finishing.

- **Depends on:** 20261001-13.
- **Came from:** The review of 20261001-13.
- **Design:** Transport, progress lines.
- **Status:** done
- **Landed:** `Reply.progress` now runs outside the rescue in `Transport::Base#on_line`. Only the progress block's own errors are caught, in the new `hand`. A driver bug in reading a progress line now ends the call, the way it did before 20261001-13. `build_index` keeps `total` set before its `note` call, and a new test pins that order, so a failing note can't make `build_indexes` skip indexes. Driver only.

### 20261007-5. Picker: pin or refuse the non-near `:skip` guard.

From the builder of 20261006-20. `enclave/lib/quaack/enclave/scenarios/picker.rb` (~48) returns `:skip` when no candidate passes every CHECK. That happens with contradictory CHECKs on one column (`CHECK (n > 10) CHECK (n < 5)`, `WHERE n = 1`), or with join keys whose CHECKs don't overlap. Without the guard, the scenarios get NULL in those columns, which breaks NOT NULL. Neither setup is realistic. Pin the guard with one of those fixtures, or refuse such queries cleanly and list them in DESIGN.md as unsupported in v1. Don't delete it.

- **Depends on:** 20261006-20.
- **Came from:** The builder of 20261006-20.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** A Postgres-backed spec in `enclave/spec/scenarios_postgres_spec.rb` pins the Picker's non-near `:skip` guard. The fixture is `fx.x (n integer NOT NULL CHECK (n > 10) CHECK (n < 5))` with `WHERE n = 1`. No scenario row holds NULL, and every scenario loads. Replacing `|| :skip` with `|| nil` turns it red. The guard is kept, not changed to a refusal, so the change is spec only with no version bump.

### 20261007-10. Closed pipes: minors from 20261004-85.

From the review of 20261004-85 (`driver/lib/quaack/driver/quiet_stream.rb`, `cli.rb`).
1. `quaack start` (`cli.rb` ~77), `quaack deploy` (~88), and the usage paths before the wrap still write to unwrapped streams. If the same rule should apply everywhere, wrap them too.
2. `QuietStream` rescues every `IOError` and `SystemCallError`, so a full disk (ENOSPC) on a regular-file stdout drops the report path line without a word. The report file itself still fails loudly. Consider rescuing only `Errno::EPIPE`, `IOError`, and `ECONNRESET`, so ENOSPC stays loud.
3. `flush` isn't guarded. An explicit `flush` on a closed pipe would raise, though nothing calls it today.

- **Depends on:** 20261004-85.
- **Came from:** The review of 20261004-85.
- **Design:** The `quaack run` command, `quaack setup`.
- **Status:** done
- **Landed:** `CLI#initialize` now wraps stdout and stderr in `QuietStream` for every `quaack` command, including `start`, `deploy`, `--version`, and every usage path. `QuietStream` skips a write only when the stream is gone: `Errno::EPIPE`, `Errno::ECONNRESET`, or `IOError` (`QuietStream::GONE`). ENOSPC and other failed writes still raise. `flush` gets the same guard. It also sets `sync = true` on the stream it wraps. A buffered pipe stdout was flushed at spawn, and the EPIPE it raised couldn't be caught, so `quaack run ... 2>&1 | head` would die at its first ssh call. Spawned real-executable specs cover start, deploy, and usage errors on a closed pipe. DESIGN.md is updated. Driver only.

### 20261003-4. Readable report: minor findings.

The build and both reviews of 20261001-18 found these:

- **Run the full check.** 20261001-18 landed without the enclave suite or the Docker-backed root specs. Run `bundle exec rake` on `main` and fix what's red, starting with the three assertions in `spec/pipeline_replay_spec.rb` that were reworded and never executed.
- **Test gaps where a wrong change stays green** (the code is right):
  - The LLM row's "Already existed" count: the fixture has one `covered_by_existing` and one `duplicate`, so swapping them passes. Use different counts.
  - The kB to MB and MB to GB boundaries, and `Format.apart`'s rounding (it replaced `Format.fewer` in 20261004-65).
  - The "It built and measured" paragraph being left out when there's a winner.
  - `not_better` when the original timed out, `worse_on`'s timed-out branch, and a ranked label that also timed out.
  - `index_rows` taking only the `original` search; `share` for a selectivity of 0; `node` preferring actual rows.
  - The outcome column for five of the fates under "Stopped for another reason"; only `rewrite_test_failed`, `footprint_tie`, and `unfinished` are pinned.
  - An index whose label result-comparison dropped: counting `result_mismatch` as not better stays green (`accountability.rb:84`).
  - The escape on a fate's `round` (`template.html.erb:46`): the sentinel payload's fate doesn't print one. Add a `counterexamples_disproved` rewrite.
- **"Planner ignored" counts indexes HypoPG refused,** which the planner was never asked about. Reword it or count them apart.
- **The "refused on arrival" note leaves out a reason.** For rule rewrites, rewrite-rules' `failed_checks` also covers an assumption-check assumption failure and clock anchoring. The README has the same gap.
- **An index on a quoted table name with a space** reads "with a new index on CREATE INDEX ON ...", since `Candidates::DDL` wants `\S+` for the table.
- **`Format.apart` may raise `FloatDomainError`** (this note was written about `Format.fewer`, which 20261004-65 replaced; check whether it still applies) if the original read 0 blocks on the slow values.
- **The README promises "a warning in the report"** for an operator rewrite the LLM doubts (near line 489). The payload carries no operator-rewrites warnings, so no report has ever shown one. Send them, or change the README.
- **LLM call counts are the driver's in-memory counts,** so a resumed run shows only the calls made since it resumed.
- **Confirm with the user** the two choices the builder made: the seventh rewrites column, and showing rewrite-rules rule names.

- **Depends on:** 20261001-18.
- **Came from:** The build and both reviews of 20261001-18, 2026-10-03.
- **Design:** report, negative-result, burndown.
- **Status:** done
- **Landed:** Seven items were already done or no longer applied. Changes:
- **Index DDL.** The new `Report::IndexDdl` splits index DDL with pg_query's scanner, cutting by bytes. Quoted, keyword, and non-ASCII table names now print right; any other DDL prints whole.
- **Index-ideas column.** "Planner ignored" became "Planner ignored or couldn't try", with a note that HypoPG couldn't create those ideas.
- **LLM call counts.** A note says the counts cover this run of quaack only.
- **Operator-rewrite warnings.** The README describes them as counted but not yet shown. Sending them would need a version bump.
- **Tests.** Nine test gaps are closed: the LLM row, size switch points, timed-out branches, fates, and an escaped round.

Driver and docs only. Two choices the entry left for the user are filed as 20261007-11.

### 20260929-1. OpenAI-compatible adapter loose ends.

These are minor findings from the build and round-one review of 20260928-4:
- **Unverified provider facts.** The build couldn't reach any provider's docs (blocked by network policy), so these are unchecked:
  - which providers enforce JSON schemas today, one of 20260928-4's own bullets;
  - the base URLs and example models in README.md's provider table;
  - whether Gemini's compatible endpoint, Ollama, and OpenRouter accept `max_completion_tokens` (add a fallback to `max_tokens` if one doesn't).

  Check them with docs access or against live providers (`script/llm_smoke.rb`). Until then, soften the README's wording: "check your provider's docs; these were current when written".
- **Reasoning models run short.** They spend `max_completion_tokens` on reasoning too, and the callers send 4000 or 8000. A long think ends with finish reason `length` and empty content, which is `llm_bad_response`. Pick a non-reasoning example model for OpenAI, or document the headroom they need, or add a per-provider token multiplier or a `reasoning_effort` setting.
- **The fallback fires on any 400 or 422 while a schema is sent.** An unrelated 400, such as context too long, costs one extra counted attempt. A provider that answers a schema-validation miss with a 400 (Groq's `json_validate_failed`, from memory) turns schema mode off for the whole run. Narrow the trigger to errors whose `param` is `response_format` (the gem exposes `error.param`), or document it.
- **`script/llm_smoke.rb`'s Groq example contradicts itself.** It sets `GROQ_API_KEY` with no `api_key_env`, so the key is read from `OPENAI_API_KEY` and the example fails `llm_auth`. Show `OPENAI_API_KEY=$GROQ_API_KEY`, or a driver.json with `api_key_env`.
- **The shared example "keeps the API key out of its error messages" is weak for OpenAI.** FakeOpenAI's error bodies never echo the key. Plant the sentinel key in the scripted 401 body.
- **No openai_compatible spec for the CLI's default builder.** The case in `cli_run_spec.rb` under "with the real client builder" still builds with FakeLLM. See 20260928-6.
- **The openai gem sends `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID`, and `OPENAI_CUSTOM_HEADERS` to any `base_url`,** Groq included. The README only warns about it. Stop passing them to non-OpenAI base URLs.
- **`OPENAI_BASE_URL` is honored when the `llm` block has no `base_url`,** matching the gem. Decide whether that's wanted.
- **`reask?` checks `error.rule == "llm_bad_response"`,** which is always true there. Drop the check or explain it.
- **Untested: the `text &&` guard in `reask?`** (`client.rb`). Dropping it keeps every spec green, and then a schema ask that the adapter itself failed (cut short, a refusal, or empty) re-asks with a nil assistant turn and costs an extra call. Add a spec: with a schema, `finish_reason: "length"` gives `llm_bad_response` with one counted call.
- **Untested: how narrow the fallback trigger is.** Widening `rescue *REJECTED` to every `APIStatusError` keeps every spec green, and then a schema ask whose 429s or 5xxs outlast the retries would fire the fallback and could turn schema mode off for the run. Add a spec: with a schema, three 429s give `llm_rate_limited` with three calls, each carrying `response_format`.
- **Untested: the adapter's `::OpenAI::Errors::Error` rescue branch.** Plant a body that makes the gem raise `ConversionError`, and assert `llm_bad_response` with a nil cause. Or drop the branch if no realistic body reaches it.
- **`choices: null` gives a different detail** ("couldn't be read as a message") than a missing `choices` ("had no choices"), and no spec covers the null case. Both are a clean `llm_bad_response`.
- **A `base_url` ending in `/chat/completions` fails with a confusing 404.** The `openai` gem appends `/chat/completions` itself, so the user's first live run went to `.../openai/v1/chat/completions/chat/completions` and failed `llm_bad_request`. Provider docs usually show the full endpoint URL, so this mistake will be common. Refuse it in `LLM.settings` with a usage error naming `base_url` (for example, "base_url must be the API root, such as https://api.groq.com/openai/v1, without /chat/completions"), or strip the suffix. `script/llm_smoke.rb` could also print the rule and message instead of a stack trace.
- **Stray lockfile line.** 20260928-4's Gemfile.lock change also added a `bundler` checksum line. Drop it, or keep it knowingly.

- **Depends on:** 20260928-4.
- **Came from:** The build report and both reviews of 20260928-4.
- **Design:** Where QUAACK runs.
- **Decided by the user (2026-10-07):** Ignore `OPENAI_BASE_URL`. Only driver.json decides where asks go.
- **Status:** done
- **Landed:** The adapter ignores `OPENAI_BASE_URL`, as the user decided on 2026-10-07. It always passes `base_url`, which defaults to `https://api.openai.com/v1`. `OPENAI_ORG_ID`, `OPENAI_PROJECT_ID`, and `OPENAI_CUSTOM_HEADERS` reach only the exact host `api.openai.com`, matched without regard to case. Specs check that lookalike hosts (`api.openai.com.evil.example` and `api.openai.com@evil.example`) never get them.

Other changes:
- The plain-text fallback fires only on a 400 or 422 about `response_format`.
- A `base_url` ending in `/chat/completions` is refused.
- `reask?` is simplified.
- The ConversionError and `choices: null` paths are pinned.
- The key-echo example takes a planted key.
- The CLI's default openai_compatible builder is specced.
- `script/llm_smoke.rb` exits cleanly on failure.
- The README uses a model that doesn't reason, and says to check provider docs.

This is driver-only. It passed its second review after one fix round, which added the lookalike-host specs.

### 20260930-14. Unqualified catalog names elsewhere in the enclave.

The 20260930-9 builder listed catalog relations and functions the enclave still reads without `pg_catalog.`, outside run-server. Each can be shadowed by the same search_path setup. Qualify them, or decide per step which are safe, such as ones on the arena, which QUAACK builds itself.

- arena_runner/sequences.rb: `pg_sequence`, `pg_get_serial_sequence()`.
- arena_schema.rb, arena_schema/domain_checks.rb, arena_schema/unique_indexes.rb: `format_type()`, `pg_get_expr()`, `pg_attribute`, `pg_attrdef`, `unnest()`, `pg_get_constraintdef()`, `pg_constraint`, `pg_class`, `pg_namespace`, `to_regclass()`, `pg_type`, `pg_get_indexdef()`, `generate_series()`, `pg_depend`, `pg_proc`, `pg_index`.
- assumption_check.rb, from_functions.rb, relation_qualifier.rb, steps/rewrite_check.rb: `unnest()`.
- index_build.rb: `pg_relation_size()`, `pg_class`, `pg_namespace`, `pg_index`, `unnest()`.
- measurement.rb: `pg_prepared_statements`.
- planner_statistics/catalog.rb: `pg_stats`. This one reads production, so it matters most.
- racetrack.rb: `count(*)`. redaction/binding.rb: `json_agg()`.
- result_comparison/tiebreaker.rb, scenarios/ties.rb, scenarios/values.rb, value_pools.rb: `pg_type`, `pg_range`, `pg_attribute`, `pg_collation`, `pg_enum`, `count()`.
- schema_dump.rb: `pg_database`, `current_database()`, `current_setting()`. These also read production.
- single_candidate_test.rb: the hypopg functions live in the extension's schema, not `pg_catalog`, so they need the extension's schema, not `pg_catalog.`.
- steps/index_search.rb: `format_type()`.

- **Depends on:** 20260930-9.
- **Came from:** The build of 20260930-9.
- **Design:** What goes into the enclave.
- **Decided by the user (2026-10-07):** Qualify every catalog relation, function, operator, and cast the enclave reads, arena reads included. Add a spec that flags unqualified catalog names in enclave SQL, so new code can't slip back.
- **Scoped by the user (2026-10-07):** A survey found 77 SQL sites with 493 unqualified names across about 45 enclave files. Most are bare operators and casts. Build this in stages. This task covers the production and racetrack reads, about 20 sites, plus the spec. The spec allowlists the files not yet fixed and fails if a file is added to that list. Arena reads go to 20261007-9. The survey script is in the build-20260930-14 scratch folder.
- **Status:** done
- **Landed:** Stage 1, as the user scoped it on 2026-10-07. Every catalog relation, function, operator, and cast is now `pg_catalog`-qualified in these reads:
- **Production:** schema_dump, inventory/production, run_server_check, user_schema, relations, relation_qualifier, from_functions, volatility_check, and volatility_check_cast_sql.
- **Racetrack:** racetrack, measurement, index_build (its SQL is now in index_build_sql.rb), build_connection, and single_candidate_test.

Forms that can't take a qualified operator were restructured (`IN`, `LIKE`, `IS NOT DISTINCT FROM`, row `=`, simple CASE). The review checked each one against the original on real Postgres, NULLs included. HypoPG's schema is read from `pg_extension`.

`enclave/spec/catalog_names_spec.rb` scans the enclave's SQL for any unqualified name. It allows only files on a frozen list of 29 for 20261007-9, and the list may only shrink. Planted-shadow tests cover every read it fixed. All three gems went to 0.1.21, with the `rake full` stamp. It passed its second review after one fix round, which pinned the list so it can't grow. Stage 2 is 20261007-9.

### 20261003-13. `quaack deploy` diagnosis: minor findings, round three.

Minor findings from the review of 20261003-9:

- **The ruby half of the `PLAIN_PATH` filter is untested** (`deploy_diagnosis.rb:126`, `other_gem`). Checking only the gem path keeps all specs green. Add a test with ESC in the ruby path, and expect the general sentence.
- **The advice can leave quaacks uninstalled** (`deploy_diagnosis.rb:105-107`). If the first `ruby` on PATH is 3.4 but the first `gem` belongs to an older Ruby, putting 3.4's bin first doesn't install quaacks for 3.4. Add "then run `quaack deploy` again". The older `other_ruby` message has the same gap.

- **Depends on:** 20261003-9.
- **Came from:** The review of 20261003-9, 2026-10-03.
- **Design:** Deploy.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. The ruby half of the plain-path check is tested, and both PATH messages now end by saying to run `quaack deploy` again. The builder's check had three timing or docker-race failures on a loaded machine (deploy_spec.rb:141 and :271, test_postgres_spec.rb:596), and each passed when rerun alone.

### 20260929-2. Several LLM providers in one run.

Let one run use more than one LLM provider, for two reasons. Different models propose different rewrites, indexes, and counterexamples, which is more of the chaos QUAACK wants. And spreading asks across providers stretches free tiers further, since each has its own rate and daily limits.

Each ask is stateless: it sends its whole conversation, and no provider holds a session. So asks can move between providers freely, with one exception. A multi-turn exchange must stay on one provider: llm-index-ideas' replacement round, llm-counterexamples' counterexample rounds, and the re-ask from 20260928-4. Otherwise a model is shown another model's reply as if it were its own.

Ideas to settle before building:
- **Configuration.** An `llms` list in driver.json, each entry shaped like today's `llm` block, with a name.
- **Routing policy.** Options:
  - round-robin per ask;
  - pinning steps to providers;
  - fan-out, where llm-rewrites and llm-index-ideas ask every provider and take the union, deduplicated by the usual checks;
  - failover, moving on to the next provider after `llm_rate_limited` or `llm_unavailable`, and remembering that for the rest of the run.
- **Adversarial pairing.** Have llm-counterexamples use a different model from the one that wrote the rewrite, so the model hunting for counterexamples isn't grading its own work.
- **Burndown.** Count calls per provider as well as per step (burndown), so the report shows where the calls went.
- **Cost.** Fan-out multiplies calls, so make it opt-in per step.

- **Depends on:** 20260928-4.
- **Came from:** The user, 2026-09-29.
- **Design:** Where QUAACK runs, llm-index-ideas, llm-rewrites, llm-counterexamples, burndown.
- **Decided by the user (2026-10-07):** Make routing configurable among all the ideas above: failover, round-robin per ask, fan-out (opt-in per step), and pinning steps to providers. A provider type may appear more than once. For example, two `copilot_cli` entries with different models count as two providers. Make adversarial pairing configurable too, with the complementary model as an option: llm-counterexamples uses a different provider from the one that wrote the rewrite. That means tracking which provider and model produced each idea, rewrite, and counterexample, and the final report should show it.
- **Decided by the user (2026-10-07), on the drafted design:**
  1. Cap under fan-out: five in all per call for v1, interleaved across providers.
  2. Pairing author: the same entry, or any entry with the same `model` string. No family key.
  3. A later turn that fails: the softer option, in v1. Generator three keeps its first-round ideas and skips the replacements. llm-counterexamples starts the remaining rounds fresh on another provider, passing what earlier rounds found as plain context, not as the model's own turns, and only what the driver already holds and already sends to an LLM.
  4. Fail over on more rules: `llm_bad_response` fails over to the next provider. `llm_auth` from an attempt drops that provider for the run with a loud progress line and goes on, and the run fails only if no provider is left. `llm_bad_request` still fails the step. Startup `llm_auth` (credentials missing when the client is built) still stops the run at startup, since that's config the operator can fix before anything runs.
  5. Fan-out branches run one after another.
  6. A list with no routing defaults to `round_robin`, not `failover`.
- **Design landed:** DESIGN.md's "Several LLM providers," under "Where QUAACK runs," with edits to the LLM client and `llm` block paragraphs, llm-index-ideas, llm-index-refine, llm-rewrites, operator-rewrites, llm-counterexamples, rewrite-index-ideas, report, and burndown.
- **Status:** done
- **Landed:** Split into 20261007-13, 20261007-14, 20261007-15, 20261007-16, 20261007-17, and 20261007-18; design landed in DESIGN.md.

### 20261006-19. Measured plans: minor findings from 20261004-86.

From the review of 20261004-86.
1. `View::NO_MEASURED_PLAN` (`driver/lib/quaack/driver/report/view.rb` ~36) blames an older measurement run for every nil plan. That's the only path to a nil plan today, but a new path would make the sentence wrong. Tie the wording to the cause, or check it when one is added.
2. An unstable set stores its most-blocks plan twice, in `"plan"` and in `"plans"` (`enclave/lib/quaack/enclave/measurement.rb` ~105-106). The storage cost is small.

- **Depends on:** 20261004-86.
- **Came from:** The review of 20261004-86.
- **Design:** report, measure.
- **Landed (2026-10-07), item 1:** `View::NO_MEASURED_PLAN` now names no cause: "QUAACK has no measured plan for the winner, so the blocks it read at each step aren't recorded." Item 2 is still open (enclave storage, which needs a version bump).
- **Status:** done
- **Landed:** 2026-10-07, item 2, after one review with no blocking findings. Each measurement stores its plans once, under "plans" (every run's for an unstable set, the first run's for a stable one), and every reader goes through `Measurement.plan`, which returns the most-blocks run's plan. A store written by an older enclave keeps a stable set's plan under "plan", which the new reader doesn't read, so a run resumed across a redeploy reports no measured plan for such a set: no crash and no leak, and the report's existing fallback says so. Enclave change, unreleased until the next batch bump.

### 20261007-11. Report: two choices to confirm with the user, plus a wording nit.

From 20261003-4 (readable report minors), which left these open for the user:
1. Should the rewrites table keep its seventh column?
2. Should the report show rewrite-rules rule names? Rule names now link to their `docs/transforms` pages from "Where it came from".
3. Nit from its review: the note at `driver/lib/quaack/driver/report/template.html.erb` (~221) still says "planner ignored". The column now reads "Planner ignored or couldn't try".

- **Depends on:** 20261003-4.
- **Came from:** The builder and review of 20261003-4.
- **Design:** report.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. Decided by the user (2026-10-07): keep the seventh rewrites column, "Stopped for another reason", and show rule names linked to their docs/transforms pages; both already held, so only the note under the index-ideas table changed, to name the column "planner ignored or couldn't try" in full.

### 20261002-14. The network guard specs read the real `~/.config/anthropic`.

`spec/network_guard_spec.rb` and `driver/spec/network_guard_spec.rb` build a real `Anthropic::Client`. Its constructor (`warn_env_shadow`, then `Anthropic::Credentials.auto_discoverable_credentials?`) reads `~/.config/anthropic/active_config` from the developer's home. Under a sandbox that blocks that path, the specs fail with `Errno::EPERM` instead of testing the guard. Specs shouldn't touch the developer's real credential files at all. Point the SDK's config discovery at an empty temp directory for these specs (whatever env var or home override the SDK honors), and check that the suite never opens anything under the real `~/.config/anthropic`. Check the other specs that build SDK clients for the same leak.

- **Depends on:** none.
- **Came from:** The 20261002-13 build, 2026-10-02.
- **Design:** Development (CLAUDE.md, the full check).
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `spec/support/no_real_credentials.rb` points `ANTHROPIC_CONFIG_DIR` at an empty temp dir for every spec process and its children, `IsolatedInstall` sets it again in its unbundled child env, and the network guard specs prove the gem never reads the default path under a trapped HOME.

### 20261003-12. `rake full`: fail fast on an unreadable version, and fix a comment.

Minor findings from the review of 20261003-8:

- **The nil-version check runs last.** It sits in `write_full_replay_stamp` (Rakefile ~33), so an unreadable version file is caught only after the whole 38-minute run. Call `gem_versions` at the start of `full` to fail fast.
- **`spec/full_replay_selection_spec.rb` overstates its coverage.** Its comment says it covers the run "as `rake full` runs it", but it swaps in its own spec task. Only the new `spec/rakefile_spec.rb` test checks that the variable reaches the child suites. Fix the comment.
- **Suite time still left:** `candidate_runs_step_postgres_spec` and the baseline, schema-dump and step specs spend their time in real Postgres. Trimming them wasn't cheap or clearly safe in 20261003-8. Look again only if the per-commit check gets slow.

- **Depends on:** 20261003-8.
- **Came from:** The review of 20261003-8, 2026-10-03.
- **Design:** none (development tooling).
- **Status:** done
- **Landed:** 2026-10-07, items 1 and 2, after one review with no blocking findings. `rake full` reads the versions before RuboCop and the specs and stamps the versions it read; the selection spec's comment is fixed. Item 3 needed no work.

### 20261001-14. Unreadable `~/.quaack/runs` reads as an unknown run ID.

Found by the build of 20260929-27. With `~/.quaack` or `~/.quaack/runs` unreadable (mode 000), `Runs#host` treats the run record as missing, so `quaack run` says "unknown run ID" instead of saying it can't read the record. Refuse an existing but unreadable path the way `DriverConfig.read` now does, with a message that names no absolute path.

- **Depends on:** 20260929-27.
- **Came from:** The build of 20260929-27.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `Runs` refuses an existing but unreadable record as `Runs::Unreadable` ("can't read ~/.quaack/runs/<id>.json (permission denied)"), naming no absolute path, and `quaack setup` and `quaack run` share `SetupCommand.where`. A missing record, or a `~/.quaack/runs` that's a file, still reads as an unknown run ID.

### 20261001-15. DriverConfig: minor findings.

Minor findings from the review of 20260929-27:

- The not-a-regular-file check in `DriverConfig#there?` (driver_config.rb:35) is untested. A directory driver.json is already refused through EISDIR, so replacing the check with `true` stays green. It matters for a FIFO, where `File.read` would block. Add a FIFO example, or drop the check.
- In cli_run_spec.rb's unreadable-directory example, if the `mkdir_p` line raised, `locked` would be nil and the `ensure`'s `File.chmod(0o700, nil)` would hide the real error with a TypeError. Guard the chmod.
- A dangling driver.json symlink counts as no config, since `File.stat` follows it and gets ENOENT. A user whose symlink points at a moved file silently gets the defaults. Consider refusing a symlink whose target is missing.

- **Depends on:** 20260929-27.
- **Came from:** Review of 20260929-27, round one.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. A FIFO driver.json is refused without being read (with a bounded spec), a dangling driver.json symlink is refused as bad_driver_config naming only the config path, and the spec's chmod is guarded.

### 20261007-12. LLM adapters: findings from 20260929-1.

From the builder of 20260929-1.
1. The Anthropic adapter's `llm_auth` message is the gem's full error, body included. If a 401 body echoed the key, the key would show in QUAACK's output. The OpenAI-compatible adapter keeps that message to the status. Plant the key in the shared key-echo example for Anthropic and Bedrock, then trim their messages the same way.
2. A 200 response whose `choices` is a string, or holds a number, raises `NoMethodError` out of the OpenAI-compatible adapter uncaught. Refuse it as `llm_bad_response`.
3. These provider facts haven't been checked against docs or live providers: base URLs, example models, which providers enforce schemas, and `max_completion_tokens` support on Gemini, Ollama, and OpenRouter.

- **Depends on:** 20260929-1.
- **Came from:** The builder of 20260929-1.
- **Design:** Where QUAACK runs, LLM providers.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. Every adapter's shared key-echo example plants the key in the 401 body, and the Anthropic adapter's llm_auth message keeps only the status. A `choices` that isn't an array of objects is llm_bad_response. Provider facts were checked against the providers' docs on October 7, 2026: the Gemini example model is now `gemini-3.8-flash`, and the docs say Ollama ignores `max_completion_tokens`.

### 20261007-3. Statistics hardening: minors from 20261006-7.

From the second review of 20261006-7.
1. `COLLATE "C"` in `enclave/lib/quaack/enclave/planner_statistics/catalog.rb` (~31, 39, 54) is still unqualified. A planted collation changes only row order, not values. Use `COLLATE pg_catalog."C"`.
2. The `\d+` runs in `OutboundShape`'s NDISTINCT and DEPENDENCIES regexes (`pii_classification/outbound_shape.rb` ~22-26) have no length cap. With qualification in place, this is defense in depth only.
3. `flag_lists?` (~90-92) says "one list per MCV item" but doesn't check that the counts match.

- **Depends on:** 20261006-7.
- **Came from:** The second review of 20261006-7.
- **Design:** statistics, classify, trust boundary.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `COLLATE pg_catalog."C"` in the planner-statistics catalog reads, with a planted-collation test; length caps on the outbound statistics shape's numbers (column numbers four digits, counts and degree parts 10); and the MCV null-flag list count must match the item count. Enclave change, unreleased until the next batch bump.

### 20261001-4. Payload trimming: minor findings.

The review of 20261001-3 found three minor items:

1. The spec in `enclave/spec/index_payload_step_postgres_spec.rb` (around lines 104–107) works out its expected best candidate by copying the code it tests. Write the expected value out directly instead. The spec near line 130 already pins the behavior on its own terms.
2. `IndexPayload#best` doesn't explicitly exclude refused candidates the way `Refinement.used?` does. That's harmless while a refused result never carries a used plan, but adding `!r["refusal"]` would make it explicit.
3. When a query uses a partitioned parent, the payload drops the partitions' CREATE TABLE and index statements, even though the plans name the partitions. Decide whether to keep the DDL for partitions of the query's tables.

- **Depends on:** 20261001-3.
- **Came from:** The second review of 20261001-3, 2026-10-01.
- **Design:** llm-index-ideas.
- **Decided by the user (2026-10-07):** Item 3: keep the partitions' CREATE TABLE and index DDL in the payload for partitions of the query's tables.
- **Status:** done
- **Landed:** 2026-10-07, items 1 and 2, after one review with no blocking findings. The spec's best candidate is written out (`(note, status)`, which costs about half the others on the seeded data), and `IndexPayload#best` skips refused candidates, so a refused candidate's plans never go out. Item 3 dropped by the user (2026-10-07): qualify refuses queries on partitioned parents (`partitioned_relation`), so the only partition a query can reach is a leaf it names, whose DDL already goes out. Enclave change, unreleased until the next batch bump.

### 20261001-16. Bedrock provider: minor findings.

Minor findings from the review of 20260930-11:

- Keys for another provider break a one-run override. `check_applies` (llm.rb:267) checks keys against the provider after `QUAACK_LLM_PROVIDER` overrides it, so `QUAACK_LLM_PROVIDER=anthropic` against a bedrock block fails naming `aws_region`. The user's answer, 2026-10-01: loosen it. Ignore keys that belong to a provider other than the one in effect, so the override works for one run.
- A bad `AWS_REGION` or `AWS_DEFAULT_REGION` isn't checked (bedrock_adapter.rb:398). In bearer mode `"us east 1"` raises `URI::InvalidURIError` out of the client build, and `quaack run` crashes with a backtrace. In SigV4 mode the same typo reads as `llm_auth: the AWS credentials couldn't be loaded`. Apply the `aws_region` check to the variables, and make a bad value a usage error naming the variable, not the value.
- The region pattern (llm.rb:219) rejects `eusc-de-east-1`, the AWS European Sovereign Cloud region, since it requires a two-letter prefix. Allow `[a-z]{2,4}`.
- The "spec-time network guard, for Bedrock" describe (bedrock_adapter_spec.rb:317-340) builds `Anthropic::BedrockClient` outside `without_aws_credentials`, so it reads the developer's real `~/.aws/config` and `~/.aws/credentials`. It's harmless today. Wrap it.
- Mutation `credentials&.set?` to `credentials` (bedrock_adapter.rb:408) survives: no spec covers the chain returning credentials that aren't set, such as an empty key in a profile. Add one, or drop `.set?`.
- DESIGN.md's llm block paragraph still says the provider is "`anthropic` or `openai_compatible`", which contradicts the bedrock paragraph after it. Add bedrock to the list.
- README nit: the gem also reads `ANTHROPIC_BEDROCK_BASE_URL` when no `base_url` is set. Mention it, or say QUAACK ignores it.

- **Depends on:** 20260930-11.
- **Came from:** Review of 20260930-11, round one.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 2026-10-07, after a review with one blocking finding, a fix round, and a clean second review. With `QUAACK_LLM_PROVIDER` naming another provider, the block is checked and then ignored whole, so its `base_url`, `api_key_env`, and `model` can't carry a credential to a host meant for another provider; `openai_compatible` and `bedrock` then need `QUAACK_MODEL`. A bad `AWS_REGION` or `AWS_DEFAULT_REGION` is a usage error naming the variable, the region pattern takes a two-to-four-letter prefix (`eusc-de-east-1`), the Bedrock network-guard spec no longer reads the real `~/.aws`, `.set?` has a spec, and DESIGN.md and the README cover the override and `ANTHROPIC_BEDROCK_BASE_URL`.

### 20260926-56. Items left from 20260923-27, -28, -35, -38.

- **Needs a decision:** functions, types, operators, and names inside string literals aren't qualified. Rewrite them, or refuse them?
- **Shared parse helper:** merge PlanExpression's parse helper with CanonicalPlan's parse step. Refactor only, but it changes a shared signature.
- **ArgumentError rules:** give rules to the ArgumentErrors raised in PredicateAtoms and IndexCandidate. For IndexCandidate, decide whether to change the error class callers rescue.
- **Operator messages:** a driver-side table mapping rules to text for operators. The texts need deciding.

- **Depends on:** 20260923-27, -28, -35, -38.
- **Came from:** Their build and reviews.
- **Design:** qualify, volatility, input.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Rewrite them (schema-qualify functions, types, operators and names inside string literals).
- **Decided by the user (2026-10-07):** Give IndexCandidate its own error class, `IndexCandidate::Error`, with a fixed rule name, and update callers to rescue it.
- **Decided by the user (2026-10-07), on the builder's finding:** the general version needs a type checker, so qualify only what's exact for now. Qualify relations, types, collations, and `regclass` and `regtype` literals exactly. Qualify a function or explicit operator only when exactly one schema on the path other than pg_catalog has that name. Leave names found only in pg_catalog bare. Names that several schemas define (the citext `=` case) stay bare, and later steps run with the plan's `search_path`. Refuse `regproc`, `regprocedure`, `regoper`, and `regoperator` literals as unsupported in v1. The full version is 20261007-21.
- **Landed (2026-10-07):** the shared parse helper (`PlanExpression.parse_bare`, used by `CanonicalPlan#fingerprint`) and the error rules (`PredicateAtoms::Error` with `not_a_query_parse` and `using_column_unreplaceable`; `IndexCandidate::Error`, rule `invalid_index_candidate`, rescued by its callers), after one review with no blocking findings. The qualification landed later the same day (see below). "Operator messages" moved to 20261007-29. Enclave change, unreleased until the next batch bump.
- **Status:** done
- **Landed:** 2026-10-07, the qualification, after one review with no blocking findings. NameQualifier qualifies relations, types, collations, and regclass and regtype literals exactly, and a function or explicit operator only when exactly one schema on the path other than pg_catalog has it. qualify stores the plan's search_path, with "$user" as the production role, and RunServer.connect sets it on every racetrack and arena connection. regproc, regprocedure, regoper, and regoperator literals are refused as unsupported_reg_literal. Rewrite candidates get the same treatment. Earlier the same day: the shared parse helper and the error rules. Operator messages were left for the user, as 20261007-29. Enclave change, unreleased until the next batch bump.

### 20261007-19. Deploy diagnosis: sentence order in the not-installed message.

From the review of 20261003-13. In the `not_installed` message (`driver/lib/quaack/driver/deploy_diagnosis.rb`), "Then run `quaack deploy` again." now comes before "The quaacks on PATH there, <path>, is another one, ...". Move the other-quaacks sentence before the advice, so the message ends with what to do.

- **Depends on:** 20261003-13.
- **Came from:** The review of 20261003-13.
- **Design:** Deploy.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. The not-installed message gives the other-quaacks sentence before the advice, so it ends with what to do, and all four not-installed examples match the whole message.

### 20261007-9. Qualify catalog names in the enclave's arena reads (stage 2 of 20260930-14).

20260930-14 qualifies the production and racetrack reads and adds a spec that allowlists the remaining files. This task qualifies every catalog relation, function, operator, and cast in the rest of the enclave's SQL: the arena, arena schema, scenarios, insert checks, rewrite-rules catalog, assumption checks, volatility checks, and so on. Shrink the spec's allowlist to empty. Forms that can't take an `OPERATOR(...)` prefix need restructuring: `IN (list)`, `IS [NOT] DISTINCT FROM`, `NULLIF`, `LIKE`, and simple `CASE`. Arena objects come from the production schema dump, so a planted operator can shadow there too.

Also from the review of 20260930-14 stage 1:
- Several files still on the list run on the racetrack, not just the arena. Each is a racetrack read, so qualify it first: `assumption_check*`, `rewrite_rules/catalog*`, `steps/rewrite_check.rb`, `server_clock.rb` (`NOW_SQL`, run on every measurement), `result_comparison/tiebreaker.rb`, `steps/index_search.rb` (~145), and `rewrite_candidate_check.rb`.
- `single_candidate_test/hypopg.rb` (~508): no test covers `quote_ident` on HypoPG's schema. Add a schema that needs quoting, such as `"Hypo"`.
- `user_schema.rb` `SHADOW_SQL`: no shadow test covers the `found.kind` and `found.name` comparisons. Only the static spec catches a bare `=` there.
- In `enclave/spec/index_build_step_postgres_spec.rb` (~355) and `volatility_check_spec.rb` (~587), the new blocks went in under comments that belong to the next block. Move them.
- The header comments in `insert_check.rb` (~29) and `rewrite_candidate_check.rb` (~31) say the connection is production. They actually get the arena and racetrack connections.

- **Depends on:** 20260930-14.
- **Came from:** The user's scoping of 20260930-14, 2026-10-07.
- **Design:** trust boundary.
- **Status:** done
- **Landed:** 2026-10-07, the racetrack half, after a review with one blocking finding, a fix round, and a clean second review. Every racetrack file on the entry's list is qualified, each with a shadow test: `server_clock.rb`'s `NOW_SQL`, `rewrite_candidate_check.rb`, the type-name reads in `steps/index_search.rb` and `steps/rewrite_check.rb` (now in `StructuralDiscard`), `assumption_check*`, `result_comparison/tiebreaker.rb`, and `rewrite_rules/catalog*`. A planted `=` could make a contradicted denormalized-equal assumption read as met; it's fixed, and user columns are compared with their own type's `=` from its default btree family (`assumption_check/equality.rb`), so citext stays case-insensitive. The other stage-1 review notes are done, and the allowlist holds only the 18 arena files, which moved to 20261007-31. Enclave change, unreleased until the next batch bump.

### 20261007-27. Specs: keep the AWS SDK off the real `~/.aws`.

From the review of 20261002-14. The AWS SDK's default credential chain, used by `BedrockClient`, can read the developer's real `~/.aws/config` and `~/.aws/credentials` when no keys are passed. The specs seen pass explicit keys or set `AWS_*`, so no live leak was found, but nothing guards it the way `ANTHROPIC_CONFIG_DIR` now guards `~/.config/anthropic`. Point `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` at empty files for every spec process, and prove it with a trapped HOME.

- **Depends on:** 20261002-14.
- **Came from:** The review of 20261002-14.
- **Design:** Development.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `NoRealCredentials` also points `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` at empty files and sets `AWS_EC2_METADATA_DISABLED=true` for every spec process and its children, and a trapped-HOME test proves the SDK reads neither default file nor the metadata endpoint. The review's two minors weren't filed: the root suite builds no Bedrock client in-process, and the SSO and login caches are reached only through the now-empty config files.

### 20261007-20. Measurement: pin which run a stable set keeps.

From the review of 20261006-19. Changing `runs.take(1)` to `runs.last(1)` in `enclave/lib/quaack/enclave/measurement.rb` keeps every spec green: the only stable fixture is three identical runs. Give the stable fixture different Execution Times and assert the first run's plan is the one stored.

- **Depends on:** 20261006-19.
- **Came from:** The review of 20261006-19.
- **Design:** measure.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. A stable fixture whose runs differ only in Execution Time pins that the first run's plan is the one stored; keeping the last, the middle, or the slowest run turns it red. Test only.

### 20261007-22. `CastlessIndex`: the IndexCandidate::Error rescue is untested.

From the review of 20260926-56. In `enclave/lib/quaack/enclave/castless_index.rb`, narrowing the rescue to `Deparse::Error` alone breaks no spec. It looks unreachable, since the predicate comes from a candidate that already passed `parse_predicate`. Prove it unreachable and drop the rescue, or add a spec that reaches it.

- **Depends on:** 20260926-56.
- **Came from:** The review of 20260926-56.
- **Design:** input.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. The IndexCandidate::Error rescue in `CastlessIndex.predicate` was unreachable: every candidate's predicate comes through the constructor's normalization, which already round-trips the exact text `parse_predicate` reads. It's removed; `Deparse::Error` stays. Enclave change (dead code only), unreleased until the next batch bump.

### 20261007-13. The `llms` list and its config.

Parse and check `llms` and `llm_routing` in `~/.quaack/driver.json`, as DESIGN.md's "Several LLM providers" says: names, per-entry keys with their position, the list's size, both `llm` and `llms`, and `llm_routing` without `llms`. Keep `llm` working as a one-entry list, and no block as Anthropic named `anthropic`. Add `QUAACK_LLM`, and refuse `QUAACK_MODEL`, `QUAACK_LLM_PROVIDER`, and `QUAACK_LLM_BASE_URL` with `llms`. Build every entry's client before touching the jump server, so a bad entry or startup `llm_auth` stops the run, naming the entry. Check `llm_routing`'s keys too (modes, pinned names, `fan_out` only on its three steps, `counterexample_pairing`'s values, and `require_different` with fewer than two providers), even though nothing acts on them yet. Routing is "always the first entry," so behavior doesn't change yet. It changes only the driver and bumps no `VERSION`, since the main session bumps per batch.

- **Depends on:** 20260928-4.
- **Came from:** The split of 20260929-2.
- **Design:** Where QUAACK runs, Several LLM providers.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `LLM.providers` (`driver/lib/quaack/driver/llm/providers.rb`) parses and checks `llms` and `llm_routing` as DESIGN.md says; an `llm` block or no block is a one-entry list named after its provider, with its overrides unchanged; `QUAACK_LLM` picks entries, and the three old override variables are refused with `llms`. `quaack run` builds every entry's client before it touches the jump server, naming the entry in a failure, and routing is still the first entry only. The builder's choices, not yet in DESIGN.md: positions count from 0; `QUAACK_LLM` applies to a lone block by its provider name; a pinned step's pool is its pinned names in pinned order, less what `QUAACK_LLM` drops, and an empty pool is a usage error; `fan_out` is refused on other steps even when false. They're in 20261007-33.

### 20261007-30. NameQualifier: test gaps and two edge cases.

From the review of 20260926-56's qualification. These pieces have no test that goes red when they break:
1. The USAGE filter in the Catalog SQL (`has_schema_privilege(n.oid, 'USAGE')`). The test role is a superuser. Use a non-superuser role and a schema it can't use.
2. The `"$user"` substitution in `steps/qualify.rb` `written_path`. The stored-path spec uses `sales, public`.
3. Lowercasing unquoted regclass names in `RegLiteral.identifier` (`'ORDERS'::regclass`).
4. The regtype round-trip check `same?`.
5. The collation encoding filter (`EXTRA`).
6. The `OPERATOR_KINDS` filter changes nothing today: the keyword operators all exist in pg_catalog. Keep it as defense, and say so, or drop it.

Edge cases:
7. Racetrack setup's `CREATE EXTENSION IF NOT EXISTS hypopg` now follows the stored path, so it fails when the path names only schemas the dump didn't restore (`search_path = reporting` with a query on `public.orders`). Use `WITH SCHEMA`, or refuse the run.
8. The rewrite candidate check qualifies candidates on the racetrack, so `"$user"` and USAGE come from the run server's role, while the original was qualified on production. A function production has but the racetrack subset lacks would stay bare in a candidate.

- **Depends on:** 20260926-56.
- **Came from:** The review of 20260926-56's qualification.
- **Design:** qualify.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. Items 1 to 5 have tests that go red under their mutations; item 6's filter stays as a commented defense. Item 7: racetrack setup creates the `quaack` schema first and installs HypoPG `WITH SCHEMA quaack` (an existing install stays where it is), and the quaack-schema check allows only the hypopg extension and its members besides `clock_anchor()`. Item 8: qualify's stored search_path drops schemas the operator's role can't use, and rewrite-check qualifies candidates with `RunServer.plan_settings`, so they resolve with production's `"$user"` and USAGE. Enclave change, unreleased until the next batch bump.

### 20261007-23. Driver run records and config: minors from 20261001-14 and 20261001-15.

From the reviews of 20261001-14 and 20261001-15.
1. `setup_command.rb` (~69) reads the run record again in its EnclaveError rescue. If the record turns unreadable mid-setup, `Runs::Unreadable` escapes as a backtrace. Reuse the host and `where` it already read.
2. `quaack setup` has only a root-skipped unreadable-record spec. Add one that runs under root too, such as a directory where the record should be.
3. A run record that isn't valid JSON raises `JSON::ParserError` out of `Runs#read`, so `quaack run` and `quaack setup` crash with a backtrace. Refuse it as a usage error that names the record by `~`.
4. A dangling `~/.quaack` symlink makes driver.json read as missing, so the user silently gets the defaults. Refuse it the way a dangling driver.json is refused.

- **Depends on:** 20261001-14, 20261001-15.
- **Came from:** The reviews of 20261001-14 and 20261001-15.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-07, after a review with one blocking finding, a fix round, and a clean second review. Setup reuses the record it read first, so a record that turns unreadable mid-setup no longer crashes it; setup has an unreadable-record spec that runs under root; a record that isn't valid JSON or isn't an object is a usage error naming it by `~` and never its contents; and a dangling `~/.quaack` symlink is refused, while a working symlinked `~/.quaack` (or one to a file) still reads as no config.

### 20261004-79. Funnel partial-band tests, from 20261004-78.

- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. Tests pin a partly counted band's grey paint, its top line centred on the known count with the hatch at full width, and its stage's own words; a stage with "in" but no "out" says "not recorded" in the burndown table's went-on cell.
- **Depends on:** 20261004-78 (done)
- **Came from:** the review of 20261004-78.
- **Design:** report.

These parts of `driver/lib/quaack/driver/report/funnel.rb` have no test that goes red when they break:
1. The grey paint of unknown and partial bands (`UNCOUNTED`). Painting a partial band solid blue, which reads as a made-up "went on" count, stays green.
2. The partial band's solid top line is centred at `left = (WIDTH - known) / 2`. Changing it to `(WIDTH - width) / 2` stays green, which moves the line off-centre when "came in" is narrower than `UNKNOWN`.
3. The hatch on a partial band spans the band's full width. Hatching only `known` wide stays green.
5. From the review of 20261004-69: passing `stage` to a partial band's label (`funnel.rb` ~118) is untested; replacing it with `nil` stays green.
4. While here: the table's "Went on" cell for a stage with "came in" but no "went on" is an empty `<td>`, not "not recorded".

### 20261002-3. `not_in_to_not_exists`: minor findings.

Minor findings from both reviews of 20261001-25:

- The fresh alias can collide with a table name or alias that no column mentions: `Tree::Names` collects only names in column references. The rewrite then fails to plan and plan-pruning drops it. Collect FROM names too.
- Untested lines: the fresh alias avoiding a taken name (`not_in_to_not_exists.rb:178`); `assumptions.uniq` (`:83`); `realias!` keeping column aliases (`:187`).
- A column whose type is a domain with a NOT NULL constraint doesn't count as not null, since `AssumptionCheck` reads only `pg_constraint`'s `n` and `p`. Conservative: a missed rewrite, not a wrong one.
- The rule assumes `=` gives true or false for two non-NULL values. A user-defined `=` that returns NULL breaks that. Noted in the rule's header.
- Extensions for later: row-valued NOT IN, set-operation subqueries arm by arm, NOT IN outside the top-level WHERE, `<> ALL`.

- **Depends on:** 20261001-25.
- **Came from:** The build and both reviews of 20261001-25.
- **Design:** assumption-check, rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. Item 1 was a real bug (`FROM public.users users_1 CROSS JOIN public.groups users_1`): the shared `Tree::Names` now also takes every table and alias name in the query, so every rule that makes fresh aliases avoids them. Item 2's lines have tests. Item 3 won't be done: a NOT NULL domain column can still hold NULL, so counting the domain would be unsound; a test pins the refusal and the rule's header says why. Item 4 was stale (the header already states it). Item 5's extensions are new features, filed as 20261007-38. The review noted that a 62- or 63-character base name plus `_N` passes Postgres's 63-byte limit, already listed in 20261002-5 for or_to_union but true of every rule using `Tree::Names`. Enclave change, unreleased until the next batch bump.

### 20261007-32. Racetrack qualification: minors from 20261007-9.

From the reviews of 20261007-9.
1. No test covers the both-NULL case of the IS DISTINCT FROM rewrite in `denormalized_equal.rb` (`COALESCE(..., a IS NULL AND b IS NULL)` to `COALESCE(..., false)` stays green).
2. The arena runner's slow clock-read behavior specs ("doesn't keep a timed-out statement...", both "nonzero session default" examples) pass with a fast clock, on main before this change too. Make them need the slow clock.
3. No shadow tests for the `pg_trigger.tgenabled` rewrite in `rewrite_rules/catalog/foreign_keys.rb` or the `pg_range.rngsubtype = ANY` rewrite in the tiebreaker. Only the static spec covers them.
4. `AssumptionCheck::Equality` refuses copy and parent columns whose types share no btree `=` (char(n) with text, int4 with numeric, float8 with int4, arrays), where a bare `=` used to accept them. The direction is safe. List it in DESIGN.md as unsupported in v1, or add a cast fallback that keeps citext right.
5. No test covers `Equality.base` following domains (domain columns would silently refuse), the `$1::type` cast, or the `rows.size == 1` guard.

- **Depends on:** 20261007-9.
- **Came from:** The reviews of 20261007-9, rounds one and two.
- **Design:** trust boundary.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. Specs pin the both-NULL IS DISTINCT FROM rewrite, make the slow-clock arena runner examples need the slow clock (`SlowClockRead`), shadow-test the `tgenabled` and `rngsubtype = ANY` rewrites, and cover `Equality`'s domains, its cast's schema, and both one-operator guards. No cast fallback: DESIGN.md's denormalized_equal paragraph now lists the type pairs refused in v1 (mixed numeric kinds, char(n) or citext with text, and any arrays, ranges, multiranges, or composites, even of one type). Specs and docs only.

### 20261007-26. Outbound statistics shape: per-column counts.

From the review of 20261007-3. `one_list_per_item?` checks how many MCV null-flag lists there are, but not that each list has one flag per column, and `most_common_freqs` and `most_common_base_freqs` aren't counted against the MCV items. Defense in depth only.

- **Depends on:** 20261007-3.
- **Came from:** The review of 20261007-3.
- **Design:** statistics, classify, trust boundary.
- **Status:** done
- **Landed:** 2026-10-07, after a review with one blocking finding (a vacuous test), a fix round, and a clean second review. The outbound statistics shape now needs one MCV null flag per column of the statistics object (counted from its definition with pg_query, an expression counting as one), `most_common_freqs` and `most_common_base_freqs` together and of one length, and that length equal to the MCV item count when the items go out. Mismatches are `statistics_bad_shape`, naming no value. Real Postgres 18 extended statistics with expressions still pass. Two untested defensive guards (`column_count`'s one-statement check, `!width.nil?`) weren't filed. Enclave change, unreleased until the next batch bump.

### 20261007-35. Run records: read once, and type-check the jump host.

From the reviews of 20261007-23.
1. `Runs#where` reads the record three times per call (host, server, port). A record that changes between reads gives a clean usage error today, but one read is simpler and can't mix two versions.
2. `Runs#host` and `where` pass a non-string `jump_host` (`{"jump_host": 5}`) straight through, unlike `server` and `port`, which are checked on read. Refuse it as an unreadable record.

- **Depends on:** 20261007-23.
- **Came from:** The reviews of 20261007-23, rounds one and two.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `Runs#where` reads the record once, and a record whose `jump_host` isn't a string (missing, null, a number, a list) is refused as unreadable, naming it by `~` and never its contents. Every record `quaack start` has written since 20260926-1 carries a string jump host, so no real record is newly refused.

### 20261007-34. index-test: resolve `"$user"` with the production role.

From the review of 20261007-30. `IndexDdlCheck`'s volatility check gets the plan's settings from `steps/index_test.rb` but runs on the racetrack connection, so `"$user"` there means the run server's role, while the hypothetical index is built in a session that uses the stored path. They disagree only when the racetrack has a schema named for one of those roles holding a function of the same name. Pass `RunServer.plan_settings(store)` there, as rewrite-check now does, and check the other racetrack users of the plan's settings. Also: the item-5 test of 20261007-30 fakes a collation's encoding with a direct `pg_catalog.pg_collation` UPDATE, which is fragile; find a sturdier setup if there is one.

- **Depends on:** 20261007-30.
- **Came from:** The review of 20261007-30.
- **Design:** qualify, index-test.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. index-test's GeneratorThree filter and counterexample-round's `Counterexamples.prepare` take `RunServer.plan_settings(store)`, so their volatility checks resolve names on the run's stored path, as the racetrack and arena sessions do. 20261007-30's collation test now uses a LATIN1 database instead of a catalog UPDATE. Not filed, from the review: for a run stored before 20261007-30 (no stored path), counterexample-round now checks with the plan's path while its arena session keeps the run server role's; they differ only when that plan sets a non-default path and the arena has same-named functions of different volatility. Enclave change, unreleased until the next batch bump.

### 20261007-24. LLM adapter errors: keep keys and driver bugs out of them.

From the review of 20261007-12.
1. The Anthropic adapter's llm_auth error keeps the gem's APIError, whose message can quote the key, as its `cause`, and the OpenAI-compatible adapter does the same. A crash backtrace that prints the cause chain would show it. Drop the cause, or replace it with one that holds only the status. Check Bedrock, which depends on the cause today.
2. The OpenAI-compatible adapter turns any NoMethodError from inside `@openai.chat.completions.create` into llm_bad_response, which also covers the driver's own `Attempts`, the burndown count, and the transport. A planted driver bug came back as "the reply couldn't be read as a message", with no backtrace. Check the parsed `choices` shape at the edge instead, or rescue only errors from the gem's coercion.
3. The Copilot CLI adapter's llm_auth message quotes the tail of the command's stderr. Check that it can't hold a token, or keep only a fixed sentence.

- **Depends on:** 20261007-12.
- **Came from:** The review of 20261007-12.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-07, items 1 and 3, after a review with a blocking finding in item 2, a fix round, a second review that found another, and a split. An llm_auth from the Anthropic and OpenAI-compatible adapters keeps no cause, since the gem's error can quote the key, and Bedrock gives its status-only message through a `refused(status)` override; a shared example checks the message, inspect, body, whole cause chain, and backtrace, and `quaack run` never prints a quoted-back key. Copilot CLI's llm_auth is a fixed sentence, and its llm_unavailable stderr tail shows GitHub tokens and anything after `Bearer` as `[token]`. Item 2 (letting driver bugs surface instead of the `rescue NoMethodError`) failed both reviews and moved to 20261007-36; its attempt stays on branch `task/20261007-24` until then.

### 20261007-31. Qualify catalog names in the enclave's arena reads (stage 3 of 20260930-14).

20261007-9 qualified the racetrack reads. This task qualifies the 18 arena files still on `enclave/spec/catalog_names_spec.rb`'s allowlist, about 400 findings, and shrinks the list to empty: `arena.rb`, `arena_runner/deferred.rb`, `arena_runner/pipeline.rb` (its `ARM_SQL` `set_config`), `arena_runner/sequences.rb`, `arena_schema.rb`, `arena_schema/domain_checks.rb`, `arena_schema/unique_indexes.rb`, `clock_defaults.rb`, `counterexamples/evaluated.rb`, `denormalized_fixture.rb`, `insert_check.rb`, `insert_clock_words.rb`, `insert_values.rb`, `rewrite_rules/existence_in_flip.rb`, `scenarios/ties.rb`, `scenarios/types.rb`, `scenarios/values.rb`, and `value_pools.rb`. Where SQL compares user columns, use the column type's own `=` (`AssumptionCheck::Equality`), not `pg_catalog.=`, or citext and the like change meaning.

Notes from the 20261007-9 builder: a `#{X}` interpolation is inlined by the scanner only when `X` is a plain-string constant in the same file, and `%<x>s` format placeholders show up as operators, so put them inside string literals. The builder's survey script is `build-20261007-9/findings.rb` in that session's scratchpad; rebuild it if it's gone.

- **Depends on:** 20261007-9.
- **Came from:** The split of 20261007-9.
- **Design:** trust boundary.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. All 18 arena files are qualified and the catalog-names allowlist is empty, with a shadow spec (`arena_catalog_shadow_postgres_spec.rb`) over ArenaSchema, Scenarios, the counterexample insert checks, the arena build, DenormalizedFixture, and the pipeline's timeout. `DenormalizedFixture.update_sql` compares with each column type's own `=` (`DenormalizedEqual.conditions`), so citext stays case-insensitive; pairs with no shared `=` fail the load, as assumption-check refuses them. ExistenceInFlip's `=` stays the query's own, now built as a node. The scanner reads adjacent literals as one string and exempts only `value_pools.rb`'s `format_type` casts (`CatalogNames::FORMAT_TYPE_HOLES`). Also fixed: an unqualified cast in `scenarios/row_set.rb`, and `scenarios/checks.rb` accepting a CHECK operator printed as `OPERATOR(pg_catalog.op)` under shadowing. Enclave change, unreleased until the next batch bump.

### 20261007-14. The router: sessions, failover, round-robin, and pinning.

Add the router and its sessions, and move every LLM caller onto them, so each multi-turn unit stays on one provider. Add pools from pinning, `round_robin` (the default) and `failover`, with the one cursor for the run. Fail over at a unit's first ask on `llm_rate_limited` and `llm_unavailable` (mark the provider down), `llm_auth` (drop it for the run, with the loud line), and `llm_bad_response` (move on without marking it down). Keep `llm_bad_request` failing the step. Fail the step with the last rule and the list of what was tried when a unit runs out of providers. A later ask that fails keeps today's behavior, failing the step, though it marks or drops the provider; 20261007-15 softens that. Count calls per provider in the burndown's in-memory counts, and add the progress and failure lines. Reword llm-index-refine's prompt from "You already proposed candidates" to say an LLM already proposed them. It changes only the driver and bumps no `VERSION`, since the main session bumps per batch.

- **Depends on:** 20261007-13.
- **Came from:** The split of 20260929-2.
- **Design:** Several LLM providers (Asks, units, and sessions; Routing; Accounting; Progress and failure messages), llm-index-refine.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `LLM::Router` (`driver/lib/quaack/driver/llm/router.rb`) hands out a session per unit and keeps every ask in it on one provider. Each step's pool comes from pinning, and its mode from the step or the run (round_robin with one cursor, or failover). At a unit's first ask, `llm_rate_limited` and `llm_unavailable` mark a provider down, `llm_auth` drops it with a loud line, `llm_bad_response` moves on, and `llm_bad_request` fails the step; a later ask that fails marks or drops its provider and fails the step (20261007-15 softens that). Every LLM caller runs through it, the burndown counts calls per provider, and progress lines name the provider for an `llms` list. A lone `llm` block or no block reads exactly as before. The refine prompt says "An LLM already proposed candidates" and "The candidates' results", and the 14 corpus `prompt.md` files for both refine steps were edited to match while their replies stay, as 20261001-28 and 20261004-95 did. For the user to confirm: failover-mode units don't move the round_robin cursor.

### 20261007-37. Report: the went-on "not recorded" cell uses the number style.

From the review of 20261004-79. The new went-on cell renders `<td class="num">not recorded</td>`, while every other "not recorded" cell uses `class="missing"` through `count_cell` (`driver/lib/quaack/driver/report/view.rb`). Use `count_cell(record["out"])` there and update the spec at `driver/spec/report_spec.rb` (~1570).

- **Depends on:** 20261004-79.
- **Came from:** The review of 20261004-79.
- **Design:** report.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. The burndown table's went-on cell uses `count_cell`, so a missing count renders `<td class="missing">not recorded</td>` like every other one, and numbers render as before.

### 20261002-4. `distinct_join_to_exists`: minor findings.

Minor findings from the build and both reviews of 20261001-26:

- No committed spec runs this rule through `quaacks rewrite-rules`; only `key_in_self_join` is covered that way. A review probe showed the path works. Add one.
- One guard in `Tree.tables?` (a FROM item with no table) is killed only by a pg_query segfault, not an assertion. Have the rule refuse a nil table explicitly.
- Composite keys are refused. Supporting them needs not-null stated per key column.
- A unique index in a different collation or operator class from its column could make DISTINCT's equality differ from the index's. An `AssumptionCheck` matter, shared with the other rules.
- Select-list expressions beside the key, and subqueries in conditions on the kept table alone, are refused though some are sound.
- `Catalog#columns` on a star with no single-column key costs a catalog query per column. One query for the table's keys would be cheaper.
- `spec/support/test_postgres.rb:245` raises when two spec processes remove the same stale container at once, which gives spurious red runs while agents run in parallel. Treat "already in progress" as success.

- **Depends on:** 20261001-26.
- **Came from:** The build and both reviews of 20261001-26.
- **Design:** assumption-check, rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. A `quaacks rewrite-rules` spec runs the rule end to end with a sentinel. The rule takes a key of several columns: a unique index whose columns are all selected (and all in the ORDER BY under a LIMIT), with `unique` over them and `not_null` for each; `Catalog#keys` reads a table's unique indexes once. The shared `unique` assumption check (`assumption_check/index_equality.rb`) now needs each key column's default operator class and the column's own collation unless both are deterministic, so a `COLLATE "C"` index on a case-blind column no longer counts (this also covers 20261003-35's nondeterministic-key item); ordinary unique indexes, including on ICU databases, still count. Test Postgres treats "removal already in progress" as removed. Item 2 was stale (the guard was already there); item 5's subqueries moved to 20261007-44. Enclave change, unreleased until the next batch bump.

### 20261007-39. denormalized_equal: accept same-type arrays, ranges, and composites.

From the review of 20261007-32. `AssumptionCheck::Equality` refuses two columns of the same array, range, multirange, or composite type, since their default btree opclasses take polymorphic input types. That's a false refusal in the safe direction, and rare, since denormalized_equal compares an id copy, a join key, and a type column. Accept the polymorphic `array_ops`, `range_ops`, `multirange_ops`, and `record_ops` `=` when both sides have exactly the same type, and drop them from DESIGN.md's v1-unsupported list.

- **Depends on:** 20261007-32.
- **Came from:** The review of 20261007-32.
- **Design:** trust boundary, assumption checks.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. When both columns have exactly the same array, range, multirange, or composite type, `AssumptionCheck::Equality` uses the polymorphic `=` of `array_ops`, `range_ops`, `multirange_ops`, or `record_ops`, which matches a bare `=` (citext elements and fields stay case-insensitive); different such types are still refused. Both denormalized_equal and the denormalized fixture take it, and DESIGN.md's v1-unsupported list names only different types. Enclave change, unreleased until the next batch bump.

### 20261007-33. The `llms` list: minors from 20261007-13.

From the review of 20261007-13.
1. `QUAACK_LLM` with a lone `llm` block refuses a name that isn't the block's, but no spec covers it (dropping `picked` from `one_provider` stays green). Its message says "different names from llms in ~/.quaack/driver.json" when the file has no `llms`. Add the spec and fix the wording.
2. The Bedrock adapter's build-time messages hardcode `llm.aws_region` and `llm.aws_profile` (`bedrock_adapter.rb` ~48–55), so an `llms` entry is told to set the wrong key. Name `llms[i].aws_region` for an entry, and update the cli spec that locks the old wording in.
3. Write the builder's choices into DESIGN.md's "Several LLM providers": positions count from 0 (`llms[0]`); `QUAACK_LLM` applies to a lone `llm` block by its provider name, including after a `QUAACK_LLM_PROVIDER` switch; a pinned step's pool is its pinned names in pinned order, less the entries `QUAACK_LLM` drops, and an empty one is a usage error; pinned names are checked against every entry; `"fan_out": false` is refused on the other steps too; and `"llm": null` beside `llms` counts as both.

- **Depends on:** 20261007-13.
- **Came from:** The review of 20261007-13.
- **Design:** Several LLM providers.
- **Status:** done
- **Landed:** 2026-10-07, after one review with no blocking findings. `QUAACK_LLM` with a lone `llm` block or none refuses another name with a message that names the one provider and says the file has no `llms`, never the variable's value. `LLM::Settings` carries `at` (`llm` or `llms[i]`), so the Bedrock build messages name the entry's own key. DESIGN.md's "Several LLM providers" records the choices from 20261007-13: positions from 0, `QUAACK_LLM` with a lone block, pinned pools, `fan_out: false` refused elsewhere, `"llm": null` counting as present, and, pending the user's confirmation, that failover-mode units don't move the round_robin cursor.

### 20261002-5. `or_to_union`: minor findings.

Minor findings from both reviews of 20261001-24:

- **A clock literal outside the OR isn't anchored.** In `WHERE c.due >= 'today' AND (o.note = 'x' OR c.archived)`, the conjunct is copied into each arm, so its `$n` appears twice. `LiteralSet::Feeds` (`literal_set.rb:186`) then marks it `:shared_placeholder`, `ClockLiterals.implicit_types` finds no type, and the rewrite reads the real clock while the original reads the anchor. rewrite-test, counterexamples or result-comparison could then report a sound rewrite as a rule bug. Fix in clock-anchor: type a placeholder when every occurrence feeds a column of the same date type.
- **Guarding arms can raise.** Split arms are all evaluated, so `i.qty = 0 OR i.total / i.qty > 10 OR o.vip` raises division by zero where the original returns rows. Never wrong rows. Refuse, or note it in DESIGN.md.
- With LIMIT and no ORDER BY, the rewrite returns a different but valid set of rows. Confirm rewrite-test and counterexamples don't report that as a rule bug.
- Test gaps: the `@columns` cache key's schema part (`catalog.rb`); column names of 62 or 63 characters, which the `_1` suffix pushes past Postgres's limit (no rewrite results, but untested).
- DESIGN.md's row leaves out several refusals: a subquery in the select list or ORDER BY; unqualified columns, a bare `*`, or ORDER BY an output name; an unnamed cast, COALESCE or CASE over a column; NATURAL or USING joins; ONLY; column aliases.
- Extensions for later: composite keys, GROUP BY, outer joins, a bare `*`.

- **Depends on:** 20261001-24.
- **Came from:** Both reviews of 20261001-24.
- **Design:** clock-anchor, rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-07, after a review with one blocking finding, a fix round, and a clean second review. Clock anchoring types a placeholder only when every place it appears feeds a column predicate of one date or timestamp type, so a clock literal in each arm of a rewrite is anchored. Fresh aliases from `Tree::Names` fit Postgres's 63-byte limit, for every rule. or_to_union refuses an OR whose arms could raise where the original wouldn't (casts, function calls, or indexing over columns, operators other than comparisons, scalar subqueries), since Postgres evaluates a single OR's arms in order and stops at the first true one; arms reading the same tables stay in one branch. Tests cover the catalog cache key and a LIMITed rewrite that keeps other rows; the rule's page lists every refusal. Enclave change, unreleased until the next batch bump.

## After version 1.

These tasks are worth doing, but they don't block version 1. Pick them up after the full pipeline (20260922-65) works.

### 20261007-36. OpenAI-compatible replies: let driver bugs surface without crashing on bad 200s (item 2 of 20261007-24).

Split from 20261007-24, whose item 2 didn't pass its second review. The goal: a NoMethodError from a driver bug (in `Attempts`, the burndown count, or the transport) must surface as itself, not as `llm_bad_response`, while every malformed 200 reply still ends as `llm_bad_response` with no cause. Main today wraps the whole `chat.completions.create` in `rescue NoMethodError`, which hides driver bugs.

What the 20261007-24 attempt learned, on branch `task/20261007-24` (commits aeb1e19 and 89f5b24, kept for reference until this task lands):
- Checking the reply's shape before the gem coerces it works for JSON bodies: empty, `null`, `true`, numbers, arrays, strings, non-JSON text, `choices` that aren't an array of objects, a `message` that isn't an object, `tool_calls` that aren't an array of objects.
- Round one: a check that passed non-Hash bodies through let `""`, `null`, `true`, and `tool_calls: "x"` crash with NoMethodError.
- Round two: the check parsed every 200 body as JSON whatever its content-type, but the gem's `Util.decode_content` parses only when the content-type matches its `JSON_CONTENT` pattern and otherwise hands back a `StringIO`, so a 200 with `text/plain` or no content-type (hand-rolled shims, some proxies) crashed with `undefined method '[]' for an instance of StringIO`. Treat a non-JSON content-type on a 200 as unreadable.
- Also crashing: a tool call whose `function` is a string (`fetch` on String). Pre-existing on main: a choice with no `message`, and a tool call with no `function`.
- FakeOpenAI always sends `application/json`; let it send other content types. The round-two reviewer's probe ran about 50 body shapes through the real adapter.

- **Depends on:** 20261007-24.
- **Came from:** The second review of 20261007-24, 2026-10-07.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The OpenAI-compatible adapter checks every 2xx reply before the gem reads it: a content-type the gem wouldn't parse as JSON, a body that isn't a JSON object, and any malformed `choices`, `message`, `tool_calls`, or `function` shape are `llm_bad_response` with no cause. main's `rescue NoMethodError` is gone, so a driver bug surfaces as itself. A reviewer's probe of about 80 bodies, and of gzip, deflate, chunked, and truncated replies over a real socket, found no crash the branch has that main doesn't. Builds on 20261007-24's item 2.

### 20261007-15. A later turn that fails.

Add DESIGN.md's softer handling of a later ask that fails with a rule that fails over. llm-index-ideas and rewrite-llm-index-ideas keep their first-round ideas and skip the replacement round. llm-counterexamples starts the rewrite's remaining rounds fresh on another provider from its pool, less those its rounds already failed on: one user message with the payload as the first round sent it, then each earlier round's inserts and that round's feedback, in the words already sent, under "Earlier rounds, run by another model." Never as the model's own turns. Rounds count on, so no rewrite gets more than three. The step fails when no provider is left. `llm_bad_request` still fails the step. Add their progress lines. Test with sentinels that the fresh start's prompt holds only the payload, the earlier inserts, and the feedback text, and that the enclave sees no new input. It changes only the driver and bumps no `VERSION`, since the main session bumps per batch.

- **Depends on:** 20261007-14.
- **Came from:** The split of 20260929-2, and the user's answer on 2026-10-07 to take the softer option in v1.
- **Design:** Several LLM providers (Routing), llm-index-ideas, llm-counterexamples.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. A later ask that fails over raises `Router::LaterError`. llm-index-ideas and rewrite-llm-index-ideas then keep their first-round ideas and go on without replacements. llm-counterexamples starts the remaining rounds fresh on a provider this rewrite hasn't failed on, in one user message holding the payload as round one sent it and each earlier round's inserts and feedback under "Earlier rounds, run by another model.", never as the model's own turns; rounds keep counting, so no rewrite gets more than three, and with no provider left the step fails. Sentinel tests show no provider name or model in any prompt. For the user to confirm: with a lone `llm` block the index-ideas steps now keep their first-round ideas where they used to fail, and the new lines call the provider "The LLM"; a rewrite's fresh start also skips a provider whose first-round reply couldn't be used. The lone-block message regression the review found is 20261007-49.

### 20261007-41. Arena qualification: minors from 20261007-31.

From the builder and review of 20261007-31.
1. The `tableoid`/`ctid` qualification in `arena_runner/deferred.rb` has no test that goes red. With `public.=(oid,oid)` planted, the old code fails loudly with `insert_failed` rather than giving a wrong answer, so add a deferred-rows shadow example.
2. `ValuePools::BOUNDARIES` matches format_type names with `\A(text|...)`. Under a shadowed `text`, the name becomes `pg_catalog.text`, so text boundaries are skipped. Values are less thorough, never wrong.
3. The catalog-names scanner can't see SQL built from pieces that don't start with a keyword, such as `row_set.rb`'s `$i::#{type}` (the same format_type case as `FORMAT_TYPE_HOLES`).
4. Older than 20261007-31: `scenarios/checks.rb` takes a bare operator from `pg_get_constraintdef` as pg_catalog's, so a CHECK bound to a `public.>` that sits first on the path prints bare and is accepted as simple. The likely effect is a scenario load failure, not a wrong result.

- **Depends on:** 20261007-31.
- **Came from:** The builder and review of 20261007-31.
- **Design:** trust boundary.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. A shadow example covers deferred rows; value pools match boundaries on a pg_catalog-qualified type name; the catalog-names scan reads placeholder casts built on their own, with `TYPE_NAME_HOLES` (renamed from `FORMAT_TYPE_HOLES`) exempting two qualified type names; and Scenarios refuse, as `complex_check`, a table or domain CHECK that depends on an operator outside pg_catalog that no extension owns, read from `pg_depend`, not the printed text (citext, ltree, hstore, enum, and domain CHECKs still pass). Not filed, from the review: a CHECK on a hand-made non-extension operator is now refused, and an extension-owned operator that shadows a builtin is trusted. Enclave change, unreleased until the next batch bump.

### 20261007-28. Bedrock region and override checks: minors from 20261001-16.

From the reviews of 20261001-16.
1. Changing `REGION_VARIABLES.find` to `.reverse.find` in `env_region` (`bedrock_adapter.rb`) survives: no bearer-mode spec sets both `AWS_REGION` and `AWS_DEFAULT_REGION` to valid, different values. Add one that asserts `AWS_REGION` wins.
2. `AMAZON_REGION` isn't checked. The AWS SDK reads `AWS_REGION`, then `AMAZON_REGION`, then `AWS_DEFAULT_REGION`. Add it to `REGION_VARIABLES` in that order, or say it's unsupported.
3. Widening the region prefix from `[a-z]{2,4}` to `[a-z]{2,9}` survives. Add a spec that refuses a five-letter prefix.
4. On a provider switch, a block key that doesn't apply even to the block's own provider (such as `api_key_env` on a `copilot_cli` block) isn't refused, so the mistake shows up only on the next run without the override. Refuse it on a switch too.

- **Depends on:** 20261001-16.
- **Came from:** The reviews of 20261001-16, rounds one and two.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. Region variables are read in the AWS SDK's order, `AWS_REGION`, `AMAZON_REGION`, then `AWS_DEFAULT_REGION`, and a bad value in any of them is a usage error naming the variable, in both bearer and SigV4 mode. Specs pin the order and refuse a five-letter region prefix. On a `QUAACK_LLM_PROVIDER` switch, keys that don't apply to the block's own provider are refused, while a valid block switched for one run still works.

### 20261007-45. denormalized_equal: minors from 20261007-39.

From the review of 20261007-39.
1. `DenormalizedFixture.update_sql` has no refusal test sensitive to the same-type rule: its "different composite types" example fails on the copy's own cast first. Find a pair that only the rule refuses, or say why none exists.
2. A user-made `=` on one specific composite or array type (with no default btree opclass) is what a bare `=` picks, but `Equality` uses the generic `record_eq` or `array_eq`, as it does for enums with `anyenum`. Refuse when an exact-type `=` exists outside the family, or note it in DESIGN.md as unsupported in v1.

- **Depends on:** 20261007-39.
- **Came from:** The review of 20261007-39.
- **Design:** trust boundary, assumption checks.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. `Equality.operator` refuses when the `=` it found doesn't take exactly the columns' types and an `=` that does exists in any schema, since a bare `=` would pick that one; across 55 realistic type pairs with common extensions installed, nothing newly refuses. The denormalized fixture's different-composite-types test now depends on the same-type rule, through an assignment cast. Enclave change, unreleased until the next batch bump.

### 20261007-48. OpenAI-compatible replies: minors from 20261007-36.

From the review of 20261007-36.
1. `TypeError` is still in the adapter's rescue list, so a TypeError from a driver bug shows up as `llm_bad_response`. Narrow it the way NoMethodError was.
2. A float overflow such as `"created":1e400` crashes with FloatDomainError from the gem's coercion (main too). Refuse it at the edge.
3. A custom tool call whose `custom` is missing or a string is now refused where main read the text. QUAACK sends no tools, so it's harmless; note it or relax it.
4. The `rescue JSON::ParserError` in `completion?` is redundant with the outer rescue.

- **Depends on:** 20261007-36.
- **Came from:** The review of 20261007-36.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. TypeError is out of the adapter's rescue list, so a driver bug surfaces as itself; a float past the double range anywhere in a reply is `llm_bad_response` instead of crashing the gem's coercion; a custom tool call is read whatever `custom` holds, as the gem does; and the redundant inner ParserError rescue is gone. A reviewer's probes of about 140 shapes found no malformed reply that crashes. Not filed: an overflowing float in a field the gem never reads is now refused where main read the text.

### 20261007-46. `or_to_union` and `Tree::Names`: minors from 20261002-5.

From the reviews of 20261002-5.
1. LIKE or ILIKE whose pattern is a column can raise only in the rewrite (`o.vip OR i.name LIKE i.pat` with `pat = 'ab\'`: "LIKE pattern must not end with escape character"). `AEXPR_LIKE` and `AEXPR_ILIKE` sit in `SAFE_KINDS` whatever the pattern is. Treat them as safe only when the pattern side has no column.
2. No test covers refusing an index into a column (`A_Indirection`) or the `expr.name.size == 1` check in `safe?`. Add tests, or drop what can't raise.
3. Implicit casts the planner inserts aren't in the parse tree (`numeric_col = real_col` casts to float4, which can overflow). Note it in the rule's page.
4. `Tree::Names` records taken names as written, but Postgres cuts identifiers over 63 bytes, so a fresh name can equal a taken name's cut form (61 `x`s plus `_1_more` against `fresh("x" * 62)`). Add each taken name's 63-byte cut to the set.
5. Item 3's test comment says rewrite-test and counterexamples compare this way, but the test exercises only `ResultComparison.compare_in_both_orders`. Reword it.
6. 20261003-3 says "20261002-5 moves `RuleBugs` onto an allowlist"; that's item 1 of 20261002-2. Fix the reference there.

- **Depends on:** 20261002-5.
- **Came from:** The builder and reviews of 20261002-5.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. or_to_union counts a LIKE or ILIKE arm as safe only when its pattern is a string constant whose trailing backslashes pair off; a column, a parameter, NULL, or ESCAPE refuses the rewrite, since Postgres checks a pattern only as it reads rows and a constant or parameter pattern ending in a lone backslash raises too. Because QUAACK turns constants into parameters before the rule runs, an OR with a LIKE arm now never splits. Tests pin the index-into-a-value and qualified-operator refusals, the page notes the planner's own casts, and the result-comparison comment is reworded. Item 4 was stale: pg_query already cuts identifiers to 63 bytes, so `Names` only sees cut names, and a test pins that. Enclave change, unreleased until the next batch bump. For the user: whether to allow parameter LIKE patterns anyway.

### 20261007-49. A lone `llm` block: keep the API's detail after a skipped replacement round.

From the review of 20261007-15. With a lone `llm` block, an `llm_rate_limited`, `llm_unavailable`, or `llm_auth` at the replacement round now marks the provider down, so the next ask (llm-index-refine) fails at once without a call: `llm_rate_limited: every LLM provider llm-index-refine may use failed: anthropic (llm_rate_limited). <sizes>`. In `Router#exhausted` (~229), `tried.last.last` is the down rule's string, not an `Error`. That names the provider and uses the list form, which a lone block shouldn't, and the API's own detail (a retry hint, say) never reaches the operator, since the going-on line drops it. Before 20261007-15 the run failed one step earlier with the detail. For a lone block, fail the later unit with the stored original `Error`, or keep the detail in the going-on line. Also: DESIGN.md should describe the lone-block going-on lines and that a lone block now keeps first-round ideas, once the user confirms; and a pipeline spec should pin the enclave's round numbers 1, 2, 3 across a fresh start.

- **Depends on:** 20261007-15.
- **Came from:** The review of 20261007-15.
- **Design:** Several LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. With a lone `llm` block, the router stores each marked-down provider's original `Error`, and the next unit re-raises it unchanged, so the operator sees the API's own detail and the skipped ask's sizes, with no provider name and no list form; across 70 lone-block cases every line and error reads as before 20261007-14. A pipeline spec pins the enclave's round numbers 1, 2, 3 across a fresh start. DESIGN.md describes the lone-block behavior, pending the user's confirmation, and (fixed at landing) says `llm_bad_response` marks nothing. For the user: after a skipped round, the step that fails is a later one, while the message's sizes name llm-index-ideas.

### 20260929-18. The prompt pack's leak check flags LLM replies that invent a sentinel date.

A hand run of `script/prompt_pack/run.rb orm_join group_having` finished, then `check_leaks` aborted. It found the `min_quantity_since` sentinel date, `2024-02-08`, in these three committed replies:

- `spec/fixtures/llm_corpus/group_having/llm-counterexamples-4/reply-claude-3.md`
- `spec/fixtures/llm_corpus/group_having/llm-counterexamples-5/reply-gemini-3.md`
- `spec/fixtures/llm_corpus/group_having/llm-counterexamples-9/reply-claude-3.md`

It's a false positive. No prompt in the corpus holds that date. The models generated runs of consecutive dates, such as 2024-02-01 to 2024-02-13, that happen to cross it. Still, the script can't finish on main today. Pick a fix: move the sentinel dates somewhere a model won't wander into, such as a far-off year, or scan only the prompts, since replies can't leak what the prompts never held.

- **Depends on:** nothing open.
- **Came from:** Review of 20260929-13, round one.
- **Design:** none. Test harness and prompt pack only.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The prompt pack's leak check (`PromptPack.leaks`) no longer scans LLM reply files, matched by the same exact name rule the replay uses, so a model that invents a sentinel-like date isn't flagged. Every prompt, chat, and other file stays scanned, and everything QUAACK sent, earlier turns included, lives in a scanned `prompt.md` or `chat.md`, so a reply that echoes a leak is still caught through its prompt. Planted-leak tests cover every scanned kind of file. Not filed: the glob skips the corpus root's README and the replay's planted root, as before.

### 20261007-50. Bedrock region lookup: match the SDK on empty variables.

From the review of 20261007-28. `env_region` skips an empty region variable and moves on to the next. The AWS SDK takes the first variable that's set (`compact.first`); when that one is empty it skips the rest and goes to the profile's region. So `AWS_REGION=""` with a valid `AWS_DEFAULT_REGION` gives a different region in bearer mode, and in SigV4 mode a bad `AMAZON_REGION` behind an empty `AWS_REGION` is refused though the SDK would never read it. Match the SDK's rule, or document the difference. Also, the `no_region` message names only `AWS_REGION`; mention `AMAZON_REGION` and `AWS_DEFAULT_REGION` too.

- **Depends on:** 20261007-28.
- **Came from:** The review of 20261007-28.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. `env_region` takes the first region variable that's set, as aws-sdk-core does, and an empty one hides the rest: bearer mode then has no region, and SigV4 mode falls to the profile. The no-region message names all three variables and the profile. Not filed: "one of X, Y, and Z" could read "X, Y, or Z".

### 20261007-43. Unique keys: minors from 20261002-4.

From the review of 20261002-4.
1. `catalog/keys.rb`'s `u.n <= i.indnkeyatts` filter is untested; dropping it lets INCLUDE columns join candidate keys, which would refuse `SELECT DISTINCT t.a` for `UNIQUE (a) INCLUDE (b)` and demand `b` not null. Add a test with an INCLUDE index.
2. The per-catalog `@keys` memo in `keys.rb` is untested (performance only).
3. The shared check refuses a unique index with a non-default operator class even when its `=` matches the default's (`text_pattern_ops`, `varchar_pattern_ops`). Allow a class whose equality operator is the default class's, with a test.

- **Depends on:** 20261002-4.
- **Came from:** The review of 20261002-4.
- **Design:** rewrite-rules, assumption checks.
- **Status:** done
- **Landed:** 2026-10-08, after a review with one blocking finding, a fix round, and a clean second review. The shared `unique` check compares a unique index's operator class `=` with the default btree class's for the column's own type (domains unwrapped), falling back to the class's input type when the column's type has none of its own, so a `text_ops` or `text_pattern_ops` index on a citext column no longer counts as unique; that closes a hole 20261002-4 had put on main. A class whose `=` matches the default's, such as `text_pattern_ops` on text, now counts. Tests cover INCLUDE columns in candidate keys and the keys memo. DESIGN.md (finished at landing) says what happens with no default class. Not filed: three defensive guards reachable only with planted classes. Enclave change, unreleased until the next batch bump.

### 20261007-53. Unused run-server flags: minors from 20261003-22.

From the review of 20261003-22.
1. No test pins that no warning prints when the flags are used: making it print even when run-server runs with flags keeps every spec green. Add one (run-server runs with `--host`, and stderr has no "Ignoring").
2. README's example line drops the backticks around `quaack start` and shows only the setup form; under `quaack run` with setup all done, the line has no step number and no `(run-server)` suffix. Match the real lines.

- **Depends on:** 20261003-22.
- **Came from:** The review of 20261003-22.
- **Design:** `quaack setup`.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. Specs pin that no warning prints when run-server runs with the flags it's given, and the README shows both forms of the line exactly as printed. Not filed: the warning joins three or more flags without an Oxford comma.

### 20261007-40. LLM errors: Copilot token patterns, and causes on other rules.

From the reviews of 20261007-24.
1. The Copilot CLI tail redaction misses `Bearer:`, two spaces or a tab after "Bearer", and Copilot API session tokens with no prefix (`tid=...;exp=...;8kp=1:...`). It matters only for llm_unavailable stderr, so this is defense in depth.
2. Only llm_auth drops its cause. The Anthropic and OpenAI-compatible adapters' other API errors still keep the gem error, body included, as their cause. Decide whether any of those bodies can hold a secret, and drop or trim the cause where one could.

- **Depends on:** 20261007-24.
- **Came from:** The reviews of 20261007-24.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The Copilot CLI stderr redaction also catches `Bearer` with a colon, an equals sign, extra spaces, or a tab, in any case, and Copilot API session tokens with no prefix (`tid=` or `8kp=`); it stays linear on a megabyte of stderr. No API error from the Anthropic, Bedrock, or OpenAI-compatible adapters keeps the SDK's error as its cause, since a gateway's headers or body could echo a key; the visible detail is unchanged. The Anthropic and Bedrock detail itself still prints the whole body and URL: that's 20261007-54.

### 20261007-55. Copilot token redaction: quoted Bearer tokens, and test gaps.

From the review of 20261007-40.
1. Regression: the old pattern redacted `Bearer "SECRET"` and `Bearer 'SECRET'`; the new `[^\s"']+` can't start at a quote, so those print unredacted. Redact a quoted token too, with tests for both quote kinds.
2. The shared "keeps no cause on any API error" example plants sentinels in response headers, but `error_text` never reads headers, so that half can't fail. Have `error_text` include `headers.inspect` when the error has headers, and prove it catches a planted header sentinel in a kept cause.
3. No test has a session token holding `tid=` without `8kp=`, so a mutation to only `8kp=` survives. Add one.

- **Depends on:** 20261007-40.
- **Came from:** The review of 20261007-40.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The Copilot CLI redaction handles a quoted Bearer token, keeping the quotes, and a token after `Bearer: `, which used to leave the token showing; it stays linear on megabytes of hostile stderr. A test covers a session token with `tid=` and no `8kp=`, and the spec helper `error_text` reads each error's headers, so the no-cause example's header sentinels can fail. Not filed: a Bearer token inside escaped JSON quotes, and one after two quotes, still show; both are unlikely in Copilot stderr.

### 20261007-16. Provenance and the report.

Write `~/.quaack/runs/<run ID>.llm.json` as DESIGN.md's Provenance says: mode 0600, written whole and renamed into place after each LLM step, kept across resumes, with names, models, store names, rules, and counts only. Record the fresh starts and skipped replacement rounds from 20261007-15. Show in the report the provider and model for each rewrite, which providers ran each rewrite's counterexample rounds, the per-provider rows in the who-proposed tables, the "LLM providers" table, and LLM calls by step and provider. Anything the record lacks is "not recorded." Pairing's outcome and warning come in 20261007-17. It changes only the driver and bumps no `VERSION`, since the main session bumps per batch.

- **Depends on:** 20261007-15.
- **Came from:** The split of 20260929-2.
- **Design:** Several LLM providers (Provenance), report, burndown.
- **Status:** done
- **Landed:** 2026-10-08, after a review with one blocking finding (a partly vacuous test), a fix round, a clean second review, and a merge of main. The driver keeps `~/.quaack/runs/<run ID>.llm.json` (mode 0600, written to a temporary file and renamed) with which provider and model wrote each rewrite, ran each rewrite's counterexample rounds, and wrote each round of index ideas, plus the providers marked down. It holds names, models, store names, rules, and counts only, and is read back through a strict shape check. The report shows each LLM rewrite's provider and model, who wrote each round of test data, per-provider rows in the who-proposed tables ("not recorded" when they don't add up), an LLM providers table, and LLM calls by step and provider. Nothing new crosses the trust boundary. For the user: per-provider "planner ignored or couldn't try" stays "not recorded" (it would need an enclave change); a resumed run keeps an entry's model as first recorded.

### 20261007-54. Anthropic and Bedrock error details print the whole response body.

From the builder of 20261007-40. For rules other than llm_auth, the Anthropic adapter's detail (and so Bedrock's) is the gem's own message, which is `{url:, status:, body:}`, so the whole error body prints. Anthropic's own bodies hold only a type, a message, and a request ID, but a `base_url` can point at a gateway or proxy (LiteLLM, a corporate gateway) whose 4xx or 5xx body could echo a key or other secret. The OpenAI-compatible adapter shows only `error.message`, or the body when it has none. Show only the body's `error.message` for Anthropic and Bedrock too, and scrub the adapter's own key from any detail, with sentinel tests through a fake gateway that echoes the key in a 400 and a 500 body.

The URL prints too, so also scrub a key in a `base_url` query string (from the review of 20261007-40).

- **Depends on:** 20261007-40.
- **Came from:** The builder of 20261007-40, 2026-10-08.
- **Design:** LLM providers, trust boundary.
- **Status:** done
- **Landed:** 2026-10-08, after a review with one blocking finding (untested scrub entries), a fix round, and a clean second review. Anthropic and Bedrock errors other than llm_auth read `the API answered <status>: <message>`, with the body's `error.message` (or Bedrock's top-level `message`), never the gem's `{url:, status:, body:}`; with no usable message, only the status. Every detail has the adapter's own credentials (Anthropic `api_key` and `auth_token`; Bedrock's bearer token and AWS access key, secret key, and session token) and each `base_url` query value of eight characters or more, raw and decoded, replaced with `[key]`. Each scrub entry has a sentinel test through a fake gateway that echoes it.

### 20261007-51. Equality: refuse a half-exact `=` too.

From the review of 20261007-45. `EXACT_SQL` looks only for an `=` taking exactly (left, right). Postgres's operator resolution prefers the candidate with the most exact argument matches, so a user `=` with one side exact (`=(pair, record)`, `=(varchar, text)` against varchar columns, `=(mood, anyenum)`) also wins over the polymorphic one, and `Equality.operator` still picks the family's. Refuse when an `=` exists whose argument types exactly match either column's while the family's inputs differ, or list it in DESIGN.md as unsupported in v1. Needs a user-planted, unusual operator.

- **Depends on:** 20261007-45.
- **Came from:** The review of 20261007-45.
- **Design:** trust boundary, assumption checks.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. `Equality` refuses when any `=`, in any schema, matches the column types exactly in more argument positions than the family's `=` does, since Postgres keeps the candidates with the most exact matches first; so `=(pair, record)`, `=(varchar, text)`, and `=(mood, anyenum)` now refuse. Probes of 60 and 33 realistic type pairs with common extensions show nothing newly refused. Enclave change, unreleased until the next batch bump.

### 20261006-24. index-rank: cover a non-zero `combined` count with a real run.

Set aside from 20261006-13. No realistic index-rank run in the specs gives a non-zero `combined` (the number of indexes in the best combination), so only a direct unit test of the count function covers it. Add a Postgres fixture where a combination of two indexes beats the best single index, and assert the step_counts line's `combined`.

- **Depends on:** 20261006-13.
- **Came from:** The builder and review of 20261004-1, then 20261006-13.
- **Design:** index-rank, progress lines for `quaack run`.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. A real index-search run on a self-join of orders produces a three-index combination that beats the best single index, and the spec checks `combined: 3` in step_counts, the combination's DDLs, and no leaks. Test only; ten runs gave the same order, since index-rank breaks every tie on the DDL.

### 20261007-17. Adversarial pairing.

Add `counterexample_pairing` with `any`, `prefer_different`, and `require_different`. The author is the entry that wrote the rewrite, or any entry with the same `model` string, read from the provenance record. Apply it to a fresh start of the remaining rounds too. Add the run-time failure for `require_different`, the outcome in the provenance record, and the report's pairing line and its warning when the pairing wasn't met or couldn't be checked. The startup check is 20261007-13's. It changes only the driver and bumps no `VERSION`, since the main session bumps per batch.

- **Depends on:** 20261007-16, since pairing reads a rewrite's author from the provenance record.
- **Came from:** The split of 20260929-2.
- **Design:** Several LLM providers (Adversarial pairing), llm-counterexamples, report.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. `llm_routing.counterexample_pairing` works for llm-counterexamples. Under `prefer_different`, the rewrite's author (the entry that wrote it, or one with the same model string, read from the provenance record) goes last; under `require_different` it's left out, and with nothing else left the step fails as `llm_unavailable`, naming the rewrite and its author. Fresh starts keep the pairing. Each counterexample unit records met, not_met, not_applicable, or unchecked, and the report says whether each rewrite's pairing was met, with a warning when it wasn't or couldn't be checked. No provider name or model reaches a prompt or the enclave.

### 20261007-18. Fan-out.

Add `fan_out` for llm-rewrites, llm-index-ideas, and rewrite-llm-index-ideas. Run branches one after another, never at once. Send each union in one interleaved call after dropping exact repeats, so the caps of five stay the step's in all. Drop a failed branch with its line and go on, failing the step only when every branch failed or one hit `llm_bad_request`. Give each branch its own replacement round, keeping its first-round ideas if that round fails. Map outcomes back to branches by position for provenance. It changes only the driver and bumps no `VERSION`, since the main session bumps per batch.

- **Depends on:** 20261007-16.
- **Came from:** The split of 20260929-2.
- **Design:** Several LLM providers (Routing, Limits), llm-index-ideas, llm-rewrites.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings, and a merge of main (with 20261007-17). With `"fan_out": true` on llm-rewrites, llm-index-ideas, or rewrite-llm-index-ideas, the step runs its unit on every healthy provider in its pool, one after another. The union goes to the enclave in one interleaved call per round, with exact repeats dropped, so the enclave's cap of five still holds and drops the rest as `too_many`. Each branch asks for its own replacements, a branch whose replacement round fails keeps its first-round ideas, a branch that fails over is dropped with a progress line, and `llm_bad_request` fails the step. Provenance credits each outcome to its branch by position, and the report's per-provider rows read it. Driver only; no enclave or protocol change. This finishes the split of 20260929-2.

### 20261007-57. Error-detail scrub: minors from 20261007-54.

From the builder and reviews of 20261007-54.
1. A token from an `ant auth login` profile isn't scrubbed, though it's sent as `Authorization: Bearer` like `auth_token`, so a gateway could echo it. Unusual (a profile with a gateway `base_url`), and the token rotates. Scrub the profile's current token too, read when the error happens.
2. A non-secret query value of eight characters or more (`?provider=anthropic`) is replaced everywhere in the message, so "anthropic" becomes `[key]`. Scrub only whole tokens, or only values that look like secrets.
3. A very short own key (a one-character test secret) wrecks the message (`the API an[key]wered`). Real keys are long; scrub own keys only above a minimum length or at token boundaries.
4. A password in the `base_url` itself (`https://user:pass@host`) and a key in the `base_url` path aren't scrubbed. Scrub them, or list them as unsupported in DESIGN.md.
5. `APIErrorDetail.query_values`'s `rescue URI::InvalidURIError` is untested, and `LLM::URL` allows strings `URI.parse` rejects. Add a test.

- **Depends on:** 20261007-54.
- **Came from:** The builder and reviews of 20261007-54.
- **Design:** LLM providers, trust boundary.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The error-detail scrub also covers every bearer token the Anthropic adapter actually sent (so an `ant auth login` profile token too), a password or user in `base_url`, and its path segments of 16 characters or more. Secrets of 16 characters or more are scrubbed anywhere; shorter ones only as whole tokens, so `anthropic-version` stays readable. `LLM::URL` now refuses a `base_url` that `URI.parse` rejects, since the anthropic gem would otherwise raise with the whole URL, key included, in its message. DESIGN.md lists the two cases left unsupported in v1.

### 20261007-59. Pairing: minors from 20261007-17.

From the review of 20261007-17.
1. No test covers `require_different` with no recorded author: dropping the author nil check from `Pairing#active?` stays green, and would crash with a NoMethodError once every provider fails. Add a test that it falls back to the usual "every LLM provider ... failed" error.
2. The capitalization of the pairing warning after another warning in `Cautions#warning` has no test.
3. Rule-made and operator rewrites are recorded as `unchecked`, where DESIGN.md's outcomes imply "not applicable". Update DESIGN.md's provenance section, or tell those rewrites apart in the pipeline (for example, by a missing `rewrites` entry in a record that otherwise has llm-rewrites data).

- **Depends on:** 20261007-17.
- **Came from:** The review of 20261007-17.
- **Design:** Several LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. A spec pins that `require_different` with no recorded author fails with the usual every-provider error, and another pins the pairing warning's capital after an earlier warning. DESIGN.md's provenance section says the record can't tell a rule-made or operator rewrite from an LLM rewrite with no recorded author, so unless the pairing is `any` (wording fixed at landing) it records both as couldn't be checked, and the report tells them apart by source.

### 20261007-61. Error-detail scrub: invalid percent encodings, and encoded own keys.

From the review of 20261007-57.
1. A `base_url` with an invalid UTF-8 percent sequence (`?k=SECRET%E2`, `/SECRETPATHKEY0123%E2/`) passes `LLM::URL`, but decoding it gives an invalid byte string, and `APIErrorDetail.scrub` then raises a `RegexpError` whose message quotes the secret, escaping `detail` with the SDK's error as its implicit cause. Main already had this for query values; 20261007-57 extended it to path segments. Drop decoded values that aren't valid encoding, or refuse such a `base_url` in the settings, with a sentinel test.
2. A URL-encoded echo of a Bedrock bearer token or AWS session token (base64, with `+`, `/`, `=` as `%2B`, `%2F`, `%3D`) isn't scrubbed, since own keys get no encoded form. Scrub the encoded form too, or list it as unsupported in v1.

- **Depends on:** 20261007-57.
- **Came from:** The review of 20261007-57.
- **Design:** LLM providers, trust boundary.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The error-detail scrub turns the text and every secret into valid UTF-8 first and never raises (a seeded fuzz of random bytes and encodings pins it), keeps a `base_url` value that decodes to invalid UTF-8 in dropped and replaced forms, and matches every secret as written or URL-encoded per character, in either hex case, so an encoded echo of a Bedrock bearer token or session token is scrubbed. It stays linear on a megabyte of text. Not filed: three edge cases with secrets that are themselves invalid UTF-8, and double-encoded echoes.

### 20261007-42. The router: minors from 20261007-14.

From the review of 20261007-14.
1. A unit whose last provider fails with `llm_auth` prints no loud drop line, since the line only prints when there's a next provider. The step's failure message still names `<name> (llm_auth)`. Print the drop line anyway.
2. When providers are named, running out lists each provider's rule but drops its detail (the API's reason from 20261001-1), and failover lines don't carry it either. Keep a short reason per provider, as long as it names no value.
3. The router builds its `Error` without `cause:`, so Ruby's implicit cause is the client's error, not the SDK's. Nothing reads it today; set it on purpose, or to nil, consistently with 20261007-24.
4. Untested guards: `&& !@down.key?(name)` in `Router#failed` (equivalent today) and `.uniq(&:object_id)` in `Router#burndown` (every client has its own burndown). Test them or drop them.
5. The corpus's saved refine replies answer the old refine wording, as other hand-edited corpus prompts do since 20261001-28 and 20261004-95. Record which prompt wording each corpus directory's replies answered (a note or marker), or rerun the prompt pack for them.

- **Depends on:** 20261007-14.
- **Came from:** The review of 20261007-14.
- **Design:** Several LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after a review with two blocking findings, a fix round, and a clean second review. With an `llms` list, router lines and the list of what was tried carry each provider's reason (the adapter's scrubbed detail, one line, at most 120 characters), and an `llm_auth` on the last provider still prints its loud line; a lone `llm` block reads as before. The router raises with `cause: nil`, the `@down` guard has a test, and the unused `.uniq` is gone. The corpus README records which replies answer an older prompt. Found in review and fixed here: the OpenAI-compatible adapter's detail was the gem's `status=… url=…` message with nothing scrubbed, so a gateway-echoed key could reach step failures (already on main) and now router lines; it now reads `the API answered <status>: <message>` through the same scrub, covering its key, OpenAI organization and project, and `base_url` secrets.

### 20261007-56. Provenance: minors from 20261007-16.

From the reviews of 20261007-16.
1. Untested: recording the refinement round (`Provenance#refinement!` and its pipeline call), the rewrite searches' index ideas (`record:` on `RewriteIndexStage`), "records the first round even when it wrote none", and the writer-side filters (`rewrites!`'s `.grep(REWRITE)`, `down!`'s rule check, `Shape.tallies`'s `.slice`).
2. Untested: "kept as first recorded" on a resume, the `File::EXCL` guard, and tightening an existing looser runs directory to 0700.
3. DESIGN.md says every per-provider count blanks when the record doesn't add up, but in the rewrites table only proposed and not kept do; the outcome columns, attributed by store name, stay. Fix the wording or the code, and the spec that checks only `.take(2)`.
4. `skipped!` appends, so a rerun of a search's llm-index-ideas step can repeat a skipped round.
5. A provider marked down in an earlier run still shows as marked down after a resume where it worked, since `down!` only adds. Decide, and say so in DESIGN.md.
6. The template's per-provider note shows even when the rows don't split, under mutation; add a test that it's absent.

- **Depends on:** 20261007-16.
- **Came from:** The reviews of 20261007-16.
- **Design:** Several LLM providers, report.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. Tests now cover the refinement round, the rewrite searches' index ideas, an empty first round, the writer-side filters, keeping an entry as first recorded, the `File::EXCL` guard, and tightening an existing runs directory. When the record doesn't add up, every per-provider count in the rewrites table says "not recorded", as DESIGN.md says. A rerun of llm-index-ideas replaces its rounds and skips instead of appending. A resumed run clears an earlier "marked down" for each provider it asked and didn't mark down (pending the user's confirmation). The template's per-provider note is absent when rows don't split.

### 20261007-62. Router and OpenAI-compatible details: minors from 20261007-42.

From the reviews of 20261007-42.
1. `Error#naming`'s `reason:` is untested (dropping it stays green), and so is the empty-text guard in `RouterLines.short`. Test them or drop them.
2. The OpenAI-compatible adapter's status-nil branch (`return error.message unless error.status`) is untested; pin the connection-error and timeout details.
3. `OPENAI_CUSTOM_HEADERS` values, sent only to OpenAI's own API, aren't in the scrub list.
4. When an error body has no message, the whole JSON body is shown, scrubbed only of the adapter's own secrets. Show only the status there, or a fixed sentence.
5. The corpus README's list of hand-edited prompts misses 20260927-24 (commit 22072ed, which changed the counterexample prompts' OVERRIDING sentence after some replies were collected).

- **Depends on:** 20261007-42.
- **Came from:** The builder and reviews of 20261007-42.
- **Design:** Several LLM providers, LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. Tests pin `Error#naming`'s reason, the empty-reason guard, and the OpenAI-compatible detail when the API never answers. `OPENAI_CUSTOM_HEADERS` values are scrubbed. A body with no usable message, or a text body, gives only "the API answered <status>", through the same `APIErrorDetail.answered` as Anthropic. The corpus README's list of replies that answer an older prompt now includes 20260927-24.

### 20261007-60. Fan-out: minors from 20261007-18.

From the builder and review of 20261007-18.
1. A fan-out branch dropped for `llm_bad_response` isn't in the report, though DESIGN.md says "the progress line and the report say which and why". Branches dropped for rate limits, unavailability, or credentials show only as "marked down" in the providers table, with no step named. Record each failed fan-out branch with its step and rule in the provenance record, and show it in the report.
2. When two branches propose the same SQL or DDL, only the first writer gets credit in `rewrites_proposed` and the index counts (so the per-provider counts add up). Say so in DESIGN.md, or record repeats separately.

3. From the review of 20261007-56: no test checks that a provider configured but never asked in a resumed run keeps its earlier "marked down" (`up!` given every entry minus `client.down` stays green); add one.
4. From the review of 20261007-56: DESIGN.md should say a provider whose replies this run were all bad responses counts as asked and not down, without saying its replies were usable.
5. From the review of 20261007-56: when counts are blanked, the "The LLM: not recorded" row reads oddly as all "not recorded"; relabel it or drop it from a blanked table.
- **Depends on:** 20261007-18.
- **Came from:** The builder and review of 20261007-18.
- **Design:** Several LLM providers, report.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The router lists each dropped fan-out branch, and the provenance record keeps it as `failed_branches` (step, entry, and rule only, checked strictly on read-back); the report says, escaped, which branch of which step was dropped and why. DESIGN.md says only the first copy of a repeated proposal gets credit, and that a provider counts as asked when this run called it, whatever came back. A provider never asked keeps its earlier "marked down", with a test, and a blanked rewrites table leaves out the all-"not recorded" row.

### 20261007-63. OpenAI-compatible details: accept a string `error` as the message.

From the review of 20261007-62. Servers such as Hugging Face TGI send `{"error": "<text>"}`. Before 20261007-62 the whole body showed; now only the status does ("the API answered 404"). Accept a non-empty string `error` as the message, still through the scrub, with a sentinel test.

- **Depends on:** 20261007-62.
- **Came from:** The review of 20261007-62.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. For the OpenAI-compatible adapter, a body whose `error` is a non-empty string (Hugging Face TGI) gives that string as the message, scrubbed; every other shape, and Anthropic and Bedrock, are unchanged.

### 20261003-7. Intake unreadable causes: minor findings.

Minor findings from the first review of 20260929-5:

- `start.rb:72`: changing `start_with?("#{home_path}/")` to `start_with?(home_path.to_s)` stays green. Add a test where home is `/Users/bench` and the path is `/Users/benchX/q.sql`.
- `operator_file.rb:54`: removing `ENOTDIR` (a parent that's a regular file) stays green. That case would then be `not_regular_file` instead of `missing`. Pin it.
- `error_filter.rb:11`: the comment still says "for two rules" and has a stray indent. Restore the `FUNCTION` comment that was deleted from `reply.rb:55`.
- The driver repeats the list of four reasons in `reply.rb` and `enclave_error.rb`. Share one constant from the protocol gem.
- From the second review:
  - `start.rb:72`: removing `path == home_path` or either `cleanpath` call stays green. Test `--query /Users/bench` and `/Users/bench/../x.sql`.
  - `operator_file.rb` `reason`: `EIO`, `ENAMETOOLONG`, and `IOError` all become `not_regular_file`, which is misleading. Give them their own reason, or a generic one.
  - No driver spec checks that `--query '~/q.sql'` reaches the remote `quaacks` as a literal `~/q.sql`.
  - `error_filter.rb:153`: the `instance_of?(String)` check is an equivalent mutant. Keep it with a comment, or drop it.

- **Depends on:** 20260929-5.
- **Came from:** The first review of 20260929-5, 2026-10-03.
- **Design:** input.
- **Status:** done
- **Landed:** 2026-10-08, the test and comment items, after one review with no blocking findings. Specs pin `quaack start`'s laptop-home refusal (home itself, `..` and `.` forms, a trailing slash, a path beside home, and `~/` sent as a literal) and intake's ENOTDIR as missing; comments in `error_filter.rb` and `transport/error_fields.rb` are fixed. Code is unchanged. The two items that need an enclave or protocol change moved to 20261007-64.

### 20260929-14. pg_dump finder: minor findings.

Minor findings from the first review of 20260929-9.

- When no pg_dump of the server's major is found, three examples fail, not one: the replay gate, `TestPgDump.bin`'s own example, and the `PromptPack.with_env` example. CLAUDE.md says the replay spec "fails once". Gate the two finder examples the same way, or reword CLAUDE.md.
- Three pieces of code have no automated test: the load-time gate in `spec/pipeline_replay_spec.rb`, which was only checked by hand; `E2ERun.with_env`'s PATH change; and `TestPgDump.version`'s exit-status check. Ignoring the exit status survives the specs.
- If `QUAACK_TEST_PG_BIN` holds a pg_dump of the wrong major, the harness quietly falls back to the Homebrew keg. That matches the user's answer, "checks first", and the not-found message lists what each directory held. Consider saying so when it happens.

- **Depends on:** 20260929-9.
- **Came from:** Review of 20260929-9, round one.
- **Design:** none. Test harness only.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. CLAUDE.md now says every spec that runs `quaacks` fails without a matching pg_dump, with the replay and scenario-refusal specs each failing as one example, through one shared `TestPgDump.examples` gate. Specs cover the gate, `with_env`'s PATH for PromptPack and E2ERun, and `version`'s exit status, and `find` warns on stderr when it skips a directory holding pg_dump of another major.

### 20261001-6. The `llm` block in driver.json takes an optional `max_retries`.

The openai and anthropic gems retry a 408, 409, 429, or 5xx twice by default, with backoff. That's too few to ride out an overloaded provider during a long run. Add an optional `max_retries` (a non-negative integer) to the `llm` block in `~/.quaack/driver.json`, and pass it to both adapters. Without the key, keep today's default. A value that isn't a non-negative integer is a usage error naming the key, the same way other bad keys in the block are handled.

- **Depends on:** nothing open.
- **Came from:** The user, 2026-10-01, after Gemini returned 503s.
- **Design:** LLM client, driver.json.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The `llm` block and each `llms` entry take an optional `max_retries`, a JSON whole number from 0 to 10 (the range is pending the user's confirmation), that the Anthropic, Bedrock, and OpenAI-compatible adapters use in place of the gem's default of two; copilot_cli refuses it. A bad value is a usage error naming the key or the entry's position, never the value. On a `QUAACK_LLM_PROVIDER` switch it's checked and ignored with the rest of the block, and sentinel probes show no block value reaches the new provider.

### 20261007-66. `max_retries`: pin the burndown count per attempt.

From the review of 20261001-6. The new retry specs show `max_retries` bounds attempts but don't assert `burndown.llm_calls` (the reviewer confirmed `{"llm-rewrites"=>2}` and `=>4` by hand). Add the assertion to each adapter's retry spec.

- **Depends on:** 20261001-6.
- **Came from:** The review of 20261001-6.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. Each adapter's `max_retries` spec also asserts the burndown counted every attempt. Specs only.

### 20261007-65. pg_dump finder: pin the no-warning case.

From the review of 20260929-14. Removing `if found[dir]` from the warning loop in `spec/support/test_pg_dump.rb` `find` stays green, though it would warn about a `QUAACK_TEST_PG_BIN` holding no pg_dump ("which holds , not pg_dump 18"). Add `warn_to:` to the "skips a directory with no pg_dump in it" example and assert nothing is printed.

- **Depends on:** 20260929-14.
- **Came from:** The review of 20260929-14.
- **Design:** Development.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. The finder's "skips a directory with no pg_dump in it" example asserts nothing is printed. Specs only.

### 20261007-38. `not_in_to_not_exists`: extensions.

From 20261002-3's item 5. New features, not fixes: row-valued `NOT IN`, set-operation subqueries, `NOT IN` outside the top-level WHERE, and `<> ALL`. Ask the user which are worth building before starting; each must stay sound.

- **Depends on:** 20261002-3.
- **Came from:** 20261002-3.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08. Split by the user's decision into one task per extension: 20261008-2 to -5.

### 20261007-47. `or_to_union`: extensions.

From 20261002-5. New features, not fixes: composite keys, GROUP BY, outer joins, and a bare `*`. Ask the user which are worth building; each must stay sound.

- **Depends on:** 20261002-5.
- **Came from:** 20261002-5.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08. Split by the user's decision into one task per extension: 20261008-6 to -9.

### 20261008-1. DESIGN.md: drop the "pending the user's confirmation" markers.

The user confirmed them all on 2026-10-08: failover-mode units don't move the round_robin cursor; a lone `llm` block keeps its first-round index ideas when the replacement round fails; a resumed run clears an earlier "marked down" for any provider it called; per-provider "planner ignored or couldn't try" stays "not recorded"; and `max_retries` takes 0 to 10. Remove each marker from DESIGN.md and the matching code comments, and leave the text otherwise as it is.

- **Depends on:** none.
- **Came from:** The user, 2026-10-08.
- **Design:** Several LLM providers, LLM client.
- **Status:** done
- **Landed:** 2026-10-08. The five markers the user confirmed are gone from DESIGN.md, with the matching comments in `llm.rb` and two specs; nothing else changed. Docs and comments only, so the main session checked the diff instead of a separate review; the per-commit check passed.

### 20261007-52. `or_to_union`: LIKE edge cases, and parameter patterns.

From the builder and review of 20261007-46.
1. **Needs the user:** an OR with a LIKE arm no longer splits, since its pattern is a parameter by the time the rule runs, and a parameter ending in a lone backslash raises only in the rewrite. Ask whether to accept that risk for parameter patterns (a one-line change) or keep refusing.
2. With `standard_conforming_strings = off`, pg_query reads `'ab\\'` as two backslashes while the server reads one, so the parity rule misjudges it. Refuse cleanly, or list the setting as unsupported in v1.
3. ILIKE on a column with a nondeterministic collation raises only when its arm runs (`b OR v ILIKE 'x'` returns rows; the arm alone raises). Refuse it, or note it as unsupported.

- **Depends on:** 20261007-46.
- **Came from:** The builder and review of 20261007-46.
- **Design:** rewrite-rules.
- **Decided by the user (2026-10-08):** item 1: allow parameter LIKE patterns in or_to_union, and document the behavior in `docs/transforms/or_to_union.md` and DESIGN.md: the rewrite raises where the original might not if the app passes a pattern ending in a lone backslash, since the original's other arm can skip the LIKE for a row and the UNION's branch can't. No caveat in the report itself. Items 2 and 3 stay as listed.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. As the user decided, or_to_union splits an OR whose LIKE or ILIKE pattern is a parameter, and `docs/transforms/or_to_union.md` and DESIGN.md document the risk: a pattern ending in a lone backslash raises in the rewrite where the original might not; a spec pins it. With `standard_conforming_strings` off, a constant pattern holding a backslash refuses, and the setting is listed as unsupported in v1. Any LIKE or ILIKE arm refuses when a column in the database uses a nondeterministic collation, or the arm has a COLLATE. Enclave change, unreleased until the next batch bump.

### 20261003-22. `quaack setup`: loose ends.

Minor findings from the build and review of 20260928-1:

- **No run-server flags and no `run_server_command` fails as `usage`.** `quaacks run-server` refuses with `usage` (`run_server.rb:52`), so the operator sees `quaack setup failed: usage` and can't tell why. Under `quaack run` without `--keep`, the run, intake included, is then torn down. Give it its own rule, such as `run_server_unspecified`, add it to README's "Common rules" table, and say in README run-server that the flags or the config are required.
- **Flags given after run-server has passed are silently ignored.** If the database given was wrong but passed the check, the only fix is a new run. Warn when flags are given and run-server is skipped.
- **A setup failure under `quaack run` tears the run down, but under `quaack setup` it's kept.** Pick one behavior, probably keep, since nothing expensive has run yet and the operator may just need different flags.
- **The driver's unit specs don't cover skipping a late step.** Only `spec/setup_postgres_spec.rb` catches a broken skip of `racetrack-setup`. Add a unit case.

- **Depends on:** 20260928-1.
- **Came from:** The build and review of 20260928-1, 2026-10-03.
- **Design:** inventory through racetrack-setup, the steps `quaack setup` runs.
- **Landed (2026-10-08), items 2 and 4:** after one review with no blocking findings. When the run server is already checked, `quaack setup` (and `quaack run`, whether or not it runs setup) prints a line naming the run-server flags it ignores, never their values; a unit case covers skipping racetrack-setup. Still open: item 1, which needs an enclave rule (`run_server_unspecified` is decided on the jump server, so it goes in the batch), and item 3, which changes the teardown policy and needs the user: keep the run after a setup failure under `quaack run` (nothing expensive has run, and the operator may only need different flags), or tear it down (a permanent failure such as `volatile_function` leaves no run server or data copy behind).
- **Landed (2026-10-08), item 1:** after one review with no blocking findings. With run-server flags missing and no `run_server_command`, the enclave refuses as `run_server_unspecified` (exit 70, no value in the line), and the driver adds a fixed note saying what to give. Still open: item 3, for the user. When it lands, also: under `quaack run` without `--keep` the run is torn down, so the note's "give the flags" fix needs a new `quaack start` that the line doesn't say (append `Teardown.next_step` for this rule, or keep the run); and DESIGN.md (~285) says a failed setup step prints only its rule, but rules with a fixed note print `<rule>: <note>`.
- **Decided by the user (2026-10-08):** item 3: keep the run after a setup failure under `quaack run`, for debugging, and put the teardown command in the error.
- **Status:** done
- **Landed:** 2026-10-08, item 3, after one review with no blocking findings, as the user decided: when a setup step fails under `quaack run`, the run is kept for debugging and the failure line says to resume with `quaack run --run <ID>` or tear it down with `quaacks teardown --run <ID>` on the jump server. `--keep` and `ssh_failed` behave as before, and later steps' failures still tear down. DESIGN.md says a failed setup step prints `<rule>` or `<rule>: <note>`. All four items are done.

### 20261008-2. `not_in_to_not_exists`: support row-valued `NOT IN`.

One of 20261007-38's extensions, each its own task by the user's decision (2026-10-08). Extend `not_in_to_not_exists` to row-valued `NOT IN` (`(a, b) NOT IN (SELECT x, y ...)`). A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-38.
- **Came from:** The split of 20261007-38, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, after one review with no blocking findings. `(t.a, t.b) NOT IN (SELECT s.x, s.y ...)` becomes a NOT EXISTS correlated on each pair, when it's a top-level WHERE conjunct and the catalog proves every column on both sides not null; it states those assumptions per pair and refuses a nullable column, an unqualified or expression column, a column-count mismatch, an empty row, and a row column on the nullable side of a LEFT JOIN. A reviewer's 22 real-Postgres probes found no case where the rewrite returns different rows. Enclave change, unreleased until the next batch bump.

### 20261008-11. or_to_union LIKE checks: minors from 20261007-52.

From the review of 20261007-52.
1. `standard_conforming_strings` is read on the racetrack session, not production's, and nothing records production's value. Say so in DESIGN.md and the rule's page ("off for the run" reads as production's), or have inventory record production's database default and refuse on that.
2. The nondeterministic-collation check counts dropped columns (`pg_attribute` keeps a dropped column's collation), so one dropped column refuses every LIKE arm database-wide. Add `NOT attisdropped`, with a test.
3. The `typcollation` and `rngcollation` branches of the `NONDETERMINISTIC` query have no test. Test them or drop them.

- **Depends on:** 20261007-52.
- **Came from:** The review of 20261007-52.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-11 (commit 5ac3c90a). Review clean.

### 20260926-32. Measurement test gaps.

- No real-Postgres test produces an unstable literal. Making block counts move between runs deterministically, inside a read-only transaction, was hard, so only the `summarize` unit test covers that path.

- **Depends on:** 20260926-27, 20260926-31.
- **Came from:** Their build.
- **Design:** baseline.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260926-32 (commit 2e4e08ba). Review clean.

### 20261008-12. Setup failures: minors from 20261003-22 item 3.

From the review of 20261003-22 item 3.
1. Only four of setup's steps have a "kept after failure" test; leaving `racetrack-setup` out of `Setup.failed?` stays green. Add one example that loops over every step's subcommand.
2. Move `Teardown`'s message builders (`failed`, `done`, `interrupted`, `skipped`, `later`, `kept`) into a small module so the class is back under RuboCop's length limit, and drop the `rubocop:disable`.
3. Name the jump host in the teardown step (`ssh <jump> quaacks teardown --run <ID>`), since `where[:jump]` is known, here and in the existing kept and skipped messages.
4. Ctrl-C during a setup step tears the run down under `quaack run` but `quaack setup` keeps it. Pick one, or say in DESIGN.md why they differ.

- **Depends on:** 20261003-22.
- **Came from:** The review of 20261003-22 item 3.
- **Design:** `quaack setup`, teardown.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-12 (commit 60cd36c8). Review had no blocking findings; its minors went to 20261008-13.

### 20261008-10. Deflake `transport_spec.rb:630` (EPERM from Process.kill).

`driver/spec/transport_spec.rb:630` ("lets an error in reading a progress line end the call…") fails now and then with `Errno::EPERM` from `Process.kill` in `driver/lib/quaack/driver/transport/child.rb` (~92). It's been seen in four builders' per-commit checks on 2026-10-08 under load, and each passed on rerun. Find the race (likely signalling a child that has exited and whose pid was reused, or a process group that's gone) and fix it in the code if the code is wrong, else in the spec, so it can't fail on timing.

- **Depends on:** none.
- **Came from:** Per-commit checks on 2026-10-08.
- **Design:** Development, driver transport.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-10 (commit c61b34c7). Review had no blocking findings; its minors went to 20261008-14.

### 20261007-44. `distinct_join_to_exists`: subqueries in conditions on the kept table.

From 20261002-4's item 5. The rule refuses a subquery in a condition on the kept table. Allowing it needs the column resolver to understand subquery scopes, so inner columns aren't resolved against outer tables. Must stay sound; refuse anything unclear.

- **Depends on:** 20261002-4.
- **Came from:** The builder of 20261002-4.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261007-44 (commit 6042d237). Review had no blocking findings; its minors went to 20261008-15.

### 20261008-13. Setup failure messages: minors from 20261008-12.

The review of 20261008-12 found these minor issues.

1. `driver/spec/teardown_spec.rb` hard-codes the 11 setup subcommands. A new step added to `Setup::STEPS` but left out of that list would stay green. Assert that the list equals `Setup::STEPS.map(&:subcommand)`, or loop over `STEPS` directly.
2. In README.md, the `driver_error` row at about line 771 still says the message "gives the teardown command to run on the jump server". Under `quaack run`, it now gives `ssh <jump> quaacks teardown ...` to run from the laptop.
3. The printed teardown command shows the jump host as is: no shell quoting, no `--`, and none of the ssh options the transport adds. Quote it, or say in the docs that it's the plain form. The jump host comes from the operator's own config, so the risk is low.
4. A DESIGN.md sentence about a signal during setup ("keeps the run the same way, as `quaack setup` does: it prints ...") reads as if `quaack setup` prints the line. Only `quaack run` does.

- **Depends on:** 20261008-12.
- **Came from:** The review of 20261008-12, 2026-10-08.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-13 (commits ae291596, 5b183839). Review had no blocking findings; its minor went to 20261008-17.

### 20261008-14. `Child.signal` fallback: untested branches from 20261008-10.

The review of 20261008-10 found that two branches of the EPERM fallback in `driver/lib/quaack/driver/transport/child.rb` have no test:

1. The fallback's own `Process.kill(name, pid)` still raises EPERM for a live process the driver can't signal. Replacing it with `nil` keeps every test green. A test needs a process the driver can't signal. If there's no clean way to get one, a test that fakes `Process.kill` at the edge, so the group signal and the pid signal both raise EPERM, is enough.
2. The ESRCH rescue on the second kill, for a child reaped between the two kills.

- **Depends on:** 20261008-10.
- **Came from:** The review of 20261008-10, 2026-10-08.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-14 (commit 26bca3bb). Review clean.

### 20261008-6. `or_to_union`: support composite keys.

One of 20261007-47's extensions, each its own task by the user's decision (2026-10-08). Extend `or_to_union` to composite keys (a UNION that dedupes on a key of several columns). A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.

- **Depends on:** 20261007-47.
- **Came from:** The split of 20261007-47, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-6 (commit bf334df0). Review had no blocking findings; its minors went to 20261008-18.

### 20261007-25. Ollama replies have no token cap.

From the builder of 20261007-12. Ollama's OpenAI-compatible API ignores `max_completion_tokens` and reads only `max_tokens`, so a reply from Ollama has no limit. Sending `max_tokens` as well to hosts other than OpenAI's would cap it, but OpenAI's reasoning models reject `max_tokens`, and how other providers handle both isn't checked. Find a safe way, such as a per-provider setting, and test it.

- **Depends on:** 20261007-12.
- **Came from:** The builder of 20261007-12.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261007-25 (commit ecd65fb1). Review had no blocking findings; its minor went to 20261008-19.

### 20261007-29. Operator messages for enclave rules.

The last item left from 20260926-56: a driver-side table that maps enclave rules to text for operators. The texts need the user's decision. Draft them for the rules that reach an operator and show the user before building.

- **Depends on:** 20260926-56.
- **Came from:** 20260926-56.
- **Design:** input.
- **Decided by the user (2026-10-08):** draft the wording yourself and build it; the user will review it in the report.
- **Decided by the user (2026-10-08), on the builder's survey (170 to 200 sendable rules):** specific messages only for the rules an operator can act on (input, intake, config, connections, run server, arena and racetrack setup, pg_dump, store, run state); every other rule gets one shared line: "QUAACK hit an internal check it can't recover from. This is a QUAACK bug: report the rule name and the step." The enclave publishes its list of sendable rules, and a spec checks every rule is either messaged or marked internal. The list is an enclave change, so it goes in the next batch.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261007-29 (commits 50277436, 9c05724c, f8196ad6, bd584376) after a fix round. The second review was clean; the minors from both reviews are in 20261008-16.

### 20261008-3. `not_in_to_not_exists`: support a subquery that is a set operation.

One of 20261007-38's extensions, each its own task by the user's decision (2026-10-08). Extend `not_in_to_not_exists` to a subquery that is a set operation (`NOT IN (SELECT ... UNION SELECT ...)`). A rewrite rule must stay sound: prove the rewrite returns the same rows on every data, refuse what can't be proved, update its `docs/transforms` page and refusal list, and test with real Postgres, NULLs included.


Also, from the review of 20261008-2: (a) a row comparison on a type whose `=` isn't a btree operator (such as `box`) errors in Postgres but the NOT EXISTS rewrite returns rows, so refuse a row-valued NOT IN unless every pair's `=` is a btree operator; (b) add a test with a second shadowing FROM item that isn't a table (`public.grants u, generate_series(1, 2) g` tested by `(u.id, g.x)`).
- **Depends on:** 20261007-38.
- **Came from:** The split of 20261007-38, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-3 (commits 43300055, b8fab7f4, 658b557b). Review had no blocking findings; its minors went to 20261008-20.

### 20261008-15. `distinct_join_to_exists` subqueries: minors from 20261007-44.

The review of 20261007-44 found these minor issues:

1. Four mutations of the new resolver in `columns.rb` survive. None changes the result for valid SQL, but each leaves a line untested:
   - dropping `own?` in `inner_qualified`;
   - reversing the scope order;
   - dropping `scopes.first.any?` in `inner_star`;
   - removing `select.limit_offset` from the `from` check (no test has a subquery in `OFFSET`, though the docs say it's refused).

   Add tests that pin each line, or remove the ones that can't matter.
2. The docs page says "a column it reads from outside itself must be the kept table's". It doesn't say that the kept table's `a.*` inside a subquery is refused too, or that `ONLY` and column aliases in the subquery's `FROM` are refused.
3. `EXISTS (SELECT 1 FROM public.comments c WHERE ROW(c.id, a.id) IS NOT NULL)` is refused even though it only reads the kept table. It's a missed rewrite, not a correctness problem.

- **Depends on:** 20261007-44.
- **Came from:** The review of 20261007-44, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-15 (commit 09f8bf96). Review clean. Item 3 (ROW(...) in a subquery) stays refused by SupportedSql, which 20260923-48 covers; the implicit row-comparison form fires and is tested.

### 20260923-24. index-from-plan loose ends.

Still open from the reviews of 20260922-31:
- **Needs a decision:** common values spelled differently get a wasted partial. For example, `n = 1.5` on a numeric that pg_stats prints as `1.50` looks rare. Either skip the partial when the column side is cast, or treat a non-MCV literal as unknown when MCVs plus nulls cover about 1.
- **Booleans never reach the partial path.** Postgres prints `b = false` as `(NOT b)`, so a partial like `WHERE NOT deleted` is never proposed.
- `(InitPlan 1).col1` conditions are dropped whole, since pg_query can't parse them.
- `COLLATE` filters propose nothing.
- A 3,000-deep plan raises SystemStackError. Whoever parses stored plans should pass `max_nesting: false`.
- **Test gaps:** a blanket `rescue ArgumentError` stays green; sort equality columns from deeper scans; column refs inside function arguments; "skips a relation with no statistics" is weak.
- Fix the grammar slip "a Actual Rows".

- **Depends on:** 20260922-31.
- **Came from:** Both reviews of 20260922-31.
- **Design:** index-from-plan.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Treat a non-MCV literal as unknown when MCVs plus nulls cover about all rows.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260923-24 (commit edd75d97). Review had no blocking findings. The grammar slip, the blanket rescue, and max_nesting were already fixed. InitPlan and COLLATE moved to 20261008-21, and the review's minors to 20261008-23.

### 20260923-21. index-from-query loose ends.

Still open from the reviews of 20260922-30 and 20260923-20:
- **Join reduction.** index-from-query decides nullability from syntax alone. Once a strict WHERE conjunct on a table rejects its nulls, Postgres reduces the outer join. Then it pushes down that table's `IS NULL` and the ON conjuncts `Join#keeps?` drops, but index-from-query still skips them. HypoPG examples: `c LEFT JOIN o ... WHERE o.region = 3 AND o.note IS NULL` misses `orders(note, region)`. `c LEFT JOIN o ON o.customer_id = c.id AND c.region = 5 WHERE o.status = 1` uses `customers(region)`.
- **Tests:** nullability at depth for RIGHT and FULL joins (two mutants survive), "USING always counts" for outer joins, and the error sentinel test checking `full_message` and the cause.
- **Comment:** "a join to one still counts for the table on the other side" isn't true for an outer join to a derived table.
- **Smaller gaps:** an ORDER BY on a nullable-side table's columns becomes a wasted key; `FOR UPDATE OF o` is falsely refused; `(o).*` isn't recognized as a star; `AS o(a, b)` alias lists aren't modeled; INCLUDE covers only the select list and GROUP BY; a prefix LIKE needs `text_pattern_ops` unless the collation is C; incremental sort isn't handled.

- **Depends on:** 20260923-20.
- **Came from:** Both reviews of 20260922-30, both reviews of 20260923-20, and the 20260922-30 builder's notes.
- **Design:** index-from-query.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260923-21 (commits e052bacf..b8503f7d). Review had no blocking findings. FOR UPDATE OF and (o).* were stale: SupportedSql refuses both. Left-out items went to 20261008-24, and the review's minors to 20261008-25.

### 20260923-30. Predicate atom loose ends.

Still open from the reviews of 20260922-43:
- **Needs a decision:** NATURAL JOIN gives no atoms. When both sides are plain tables, compute the common columns, or emit a marker that can't be replaced, so the report counts it.

- **Depends on:** 20260923-29.
- **Came from:** Both reviews of 20260922-43, the second review of 20260923-29, and the builder's notes.
- **Design:** rewrite-test and vacuity-guard.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Emit a marker the report counts, and list NATURAL JOIN as unsupported in v1.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260923-30 (commits 6d0e80c0, 4f688e98). Review had no blocking findings; its minors went to 20261008-26.

### 20260924-8. Burndown loose ends.

**Needs a decision,** from the second review of 20260922-61:
- Refuse misuse, such as calling `record_dedupe` twice on the same Dedupe. (The `since` part is settled: 20261001-20 has index-test derive its starting count from the stored dedupe state.)
- Tie `record_single_candidate_test`'s report to the Dedupe's proposals.
- index-test's `unrenderable` refusal is counted as `hypopg_refused`.

- **Depends on:** 20260922-61.
- **Came from:** Both reviews of 20260922-61.
- **Design:** burndown.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Build all three.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-8 (commit d5f08f76). Review had no blocking findings; its minors went to 20261008-27.

### 20260923-36. index-dedupe loose ends.

Still open from the reviews of 20260922-32 and 20260923-31:
- **Some existing indexes never count as covering.** `IndexCandidate.from_ddl` returns nil for `ON ONLY` indexes on a partitioned parent, for any `WITH (...)` index, and for `NULLS NOT DISTINCT` unique indexes. A candidate identical to one is tested as new, and negative-result won't report it as a duplicate.
- `IndexSql.normalize_predicate` should re-parse its output. `'x'::mytype(lower('bob'))` is stored as `'x'::mytype()`.
- The doc comment should say array bounds on a cast (`status::text[12345]`) aren't checked, like integer typmods.
- Dead code: `left = unwrap(node.lexpr)` in `column_comparison?`, and the unreachable `A_Const` check in `plain_type?`.

- **Depends on:** 20260923-31.
- **Came from:** The reviews of 20260922-32 and 20260923-31, and the builder's notes.
- **Design:** index-dedupe.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260923-36 (commit e79c7628). Review had no blocking findings; its minors went to 20261008-28. normalize_predicate's re-parse was already fixed by 20260923-55, and ON ONLY is unreachable in v1. Also covers 20261008-23 item 3 (boolean folding).

### 20260924-24. Production inventory loose ends.

Still open from the build and reviews of 20260922-16:
- No `statement_timeout` on the production connection, so a host that silently drops packets hangs the step. The operator's `PGCONNECT_TIMEOUT` covers only the connect.
- The recorded "production values" are the operator's session values, including `PGOPTIONS` and `ALTER ROLE ... SET`. Fix the DESIGN.md wording, or connect with `options: ""`.
- Qualify `current_setting` and `json_array_elements_text` with `pg_catalog.`, so a role's search_path can't shadow them.
- `"memory_command": null` counts as not configured, but DESIGN.md says it's `bad_config`. There's no upper bound on the memory size.
- A background child holding stdout makes the memory command wait out its timeout, and a `setsid` child escapes the process-group kill.
- `ProductionServer` prints NOTICE lines into the rake output.
- **Surviving mutants:** config's invalid UTF-8 handling; memory's double space before the unit, `reap`, TIMEOUT and MAX_OUTPUT values, and spawn failure; inventory closing its connection; the step's hardcoded `major_version`.

- **Depends on:** 20260922-16.
- **Came from:** The build and reviews of 20260922-16.
- **Design:** inventory.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-24 (commits 48cd01ac, 7b852462, 5b5fb6bc). Review had no blocking findings. The pg_catalog qualification was already done. The review's minors and the builder's keepalive note went to 20261008-30.

### 20260923-57. Rewrite candidate check loose ends.

Still open from the reviews of 20260922-10:
- `RewriteCandidateCheck` still has its own qualify and `plain_table!`. Switch it to `Relations.check`, so its non-table rules become per-kind. Its spec expectations change with it.

- **Depends on:** 20260922-10.
- **Came from:** The reviews of 20260922-10.
- **Design:** What goes into the enclave.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260923-57 (commits 13575877, 59be0414, 272f3382, 6d829843) after a fix round. The second review was clean. Its findings on main's behavior went to 20261008-31 and -32, and the first review's minors are in 20261008-29.

### 20260924-9. Load-order loose ends.

**Needs a decision,** from the reviews of 20260924-5:
- A third load order, such as rotating each table's run by one. It would catch a tie pick exactly in the middle of an odd-sized group, and a rare top-N heapsort pick, which both orders agree on today.
- Self-referencing foreign keys always fail the reverse load, as `reverse_load_failed`, which discards every candidate for tree-shaped tables. Keep such tables in forward order, or reverse them level by level.

- **Depends on:** 20260924-5.
- **Came from:** Both reviews of 20260924-5.
- **Design:** fixture-compare.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-05):** Fix self-referencing FKs (reverse them level by level, or keep such tables in forward order, whichever is sound) and add a third load order.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-9 (commit 59b1b63b). Review had no blocking findings; its minors and cost note went to 20261008-33.

### 20260924-26. statistics loose ends.

Still open from the build and reviews of 20260922-19:
- pg_stats and pg_stats_ext silently hide columns the operator can't SELECT, so a role with limited privileges gets missing statistics with no error. Detect it, and refuse or record it.
- Values and names aren't converted to UTF-8, unlike SchemaDump. A non-UTF-8 database with non-ASCII values may be refused at the store write.
- The pg_stats inherited-filter mutant is killed only by luck, since row order decides which duplicate wins.
- A column type whose array delimiter isn't a comma, such as `box`, makes PgArray raise and abort statistics. List it as unsupported in v1, or skip it.

- **Depends on:** 20260922-19.
- **Came from:** The build and reviews of 20260922-19.
- **Design:** statistics.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-26 (commit 73dbb2f2). Review had no blocking findings. Hidden table columns are refused as column_statistics_hidden. What non-owner roles still lose (pg_stats_ext, expression-index statistics, row security) went to 20261008-34.

### 20260924-28. literals loose ends.

Still open from the build and reviews of 20260922-21:
- Django date filters get no worst-case or typical value. psycopg2 writes `'...'::timestamptz`, `'...'::date`, and `'{..}'::bigint[]`, which redact turns into cast placeholders, and literals always falls back on those. Handle a cast placeholder whose cast matches the column's type.
- The boolean `t`/`f` check at `literal_set.rb:326` survives mutation. Pin it with a planted bad value, or drop it.

- **Depends on:** 20260922-21.
- **Came from:** The build and reviews of 20260922-21.
- **Design:** literals.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-28 (commit a6c46854). Review had no blocking findings; its minors went to 20261008-36.

### 20260924-3. Intake loose ends.

Still open from the reviews of 20260922-13:
- **Orphaned partial runs.** SIGKILL, an OOM kill, or SIGXFSZ during intake can leave a 0700 run directory holding production literals, and print no run ID. Tiny signal windows around `Store.create` and after `done` do the same. Add a sweeper, such as `quaacks teardown --orphans`, or have intake sweep old runs with no finished marker.
- **The query isn't checked against the plan.** A SELECT query with an UPDATE's plan is accepted. Compare the relations and statement type.

- **Depends on:** 20260922-13.
- **Came from:** Both reviews of 20260922-13.
- **Design:** input.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Decided by the user (2026-10-08):** Intake sweeps old orphans on its own: each `quaacks start` deletes run directories older than about a day that never finished intake. Intake also refuses a plan whose statement type differs from the query's, or whose tables differ from the query's in either direction.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-3 (commit 0996366c). Review had no blocking findings. The table check runs in qualify, since intake can't see the catalog. The RLS minor went to 20261008-37.

### 20260924-29. Run server check loose ends.

Still open from the build and reviews of 20260922-25:
- Per-tablespace `random_page_cost` and `seq_page_cost` aren't checked. Record production's tablespace spcoptions in inventory, then compare them.
- `shared_preload_libraries` that change plans, such as pg_hint_plan, aren't compared.
- PGTZ and PGDATESTYLE in the operator's environment change both sessions' TimeZone and DateStyle, so the check compares session values, not server values.
- The debug_parallel_query test goes through the recorded-value path, not the boot_val path its name suggests.

- **Depends on:** 20260922-25.
- **Came from:** The build and reviews of 20260922-25.
- **Design:** inventory and run-server.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-29 (commits c69dbddd, 48beeaaa, d4691891, b4bce20e) after a fix round that bumped StoreFormat to 5. The second review was clean. Minors went to 20261008-38.

### 20261008-31. Rewrite candidates: a regclass literal reveals that a relation exists.

The second review of 20260923-57 found this. It's already true on main, and 20260923-57 neither causes it nor makes it worse. It's the same kind of leak that review treated as blocking, so take it up soon.

The candidate check compares relations against the original's set, but it never sees a name inside a string literal:

- **Qualified literal.** A candidate with `'anyschema.t'::regclass` is accepted. It plans when `t` exists and fails to plan when it doesn't. The LLM can use that to probe whether any relation exists in the racetrack, which holds production's schema.
- **Unqualified literal.** With the role QUAACK connects as, an unqualified `'sent_t'::regclass` is accepted when that role's schema holds `sent_t`. When it doesn't, the inbound check refuses it as `unknown_relation`.

The fix is to check the relations named in regclass literals against the original's set, or to refuse regclass literals (and regtype and the rest) in candidates unless the original has the same literal. Test it with sentinel relations that the original doesn't use, and assert that a hidden name and a missing one get the same outcome.

- **Depends on:** 20260923-57.
- **Came from:** The second review of 20260923-57, 2026-10-08.
- **Design:** What goes into the enclave.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-31 (commits c6ba58b6, f4f8f78d, db0d6aeb, 456556a8) after a fix round. The second review was clean. Its minors went to 20261008-39; the first round's are in 20261008-35.

### 20260924-6. Narrow the fixture-compare fail-closed rule for top-N queries.

Any `ORDER BY ... LIMIT` whose output includes a type left out of the tiebreaker (json, jsonb, xml, citext, hstore, PostGIS, interval, numeric[], and composites of those) is refused, even when the sort key is unique. That refuses every candidate for common top-N queries over such tables, and those are prime rewrite targets. Options: rerun both queries without their LIMIT and OFFSET, and refuse only on a real hidden tie. Or add `::text` sort keys for left-out columns.

- **Depends on:** 20260922-47.
- **Came from:** Second review of 20260923-54.
- **Design:** fixture-compare.
- **Decided by the user (2026-10-08):** Rerun both queries without their LIMIT and OFFSET, and refuse only on a real hidden tie.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-6 (commit 8c118441). Review had no blocking findings; its minors went to 20261008-40.

### 20261008-34. Statistics a non-owner production role can't see: extended statistics, expression indexes, and row security.

The build and review of 20260924-26 found these on real Postgres 18. Nothing refuses or records them today.

1. **Expression-index statistics are hidden from non-owners.** A role with table-level SELECT that doesn't own the table gets no pg_stats rows for an expression index. The index's `columns` comes back `{}`.
2. **Extended statistics are hidden from non-owners.** That role's `pg_stats_ext` rows are hidden too, so every `extended_statistics` data field is nil. That looks the same as "not analyzed yet".
3. **Row security hides every row.** On a table with row-level security enabled, a non-owner role with SELECT gets no pg_stats rows at all. The run passes with `columns=[]`, and the `has_column_privilege` fallback doesn't catch it. A `row_security_active(oid)` check would.

A read-only production role is usually a non-owner, so items 1 and 2 hit the most common setup. **Needs a decision:** refuse (as with `column_statistics_hidden`, which would refuse most read-only roles whenever the query's tables have extended statistics or expression indexes), or record what's missing in the report and go on. Item 3 hides all column statistics, so refusing seems right there.

Also from the review: the `NOT s.stainherit` clause in `ANALYZED_SQL`, and the `ORDER BY ..., s.inherited` next to `AND NOT s.inherited`, change nothing in normal runs. Drop them, or leave them as guards.

- **Depends on:** 20260924-26.
- **Came from:** The builder and review of 20260924-26, 2026-10-08.
- **Design:** statistics.
- **Decided by the user (2026-10-08):** Go on without hidden extended and expression-index statistics, and say in the report which were missing. Refuse with a clear rule when row security hides every column's statistics.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-34 (commits e00f064b, 97a04632, 54d94a5f). Review had no blocking findings; its minors went to 20261008-42.

### 20261008-32. Rewrite candidates: whether a function, type, collation, or operator exists is visible.

The second review of 20260923-57 found these. Both are already true on main.

1. **Existence shows in the outcome.** A candidate can name any function, type, collation, or operator, even ones the original doesn't use, and its outcome shows whether that name exists:
   - A qualified `hidden.vfn()` gets `volatile_function` when the function exists and is volatile, and the error line names it. When it doesn't exist, the candidate fails later as `failed_to_plan`.
   - In the schema of the role QUAACK connects as, an unqualified name that exists plans, and one that doesn't fails to plan.

   It needs a decision: how much of the catalog's contents outside the query is secret from the LLM? One option is to limit candidates to the original's non-relation names plus pg_catalog's. Another is to accept this and document it.
2. **New bare names skip the `"$user"` check.** When more than one schema on the path has a function or operator, `NameQualifier` leaves the name bare, and it resolves at run time through the plan's search path. `UserSchema` at intake covers only the original's names. So a rewrite that adds a new overloaded name could be tested against a different object than the application's role would get. That happens only when a schema named for a role holds an overload of that name.

- **Depends on:** 20260923-57.
- **Came from:** The second review of 20260923-57, 2026-10-08.
- **Design:** What goes into the enclave.
- **Decided by the user (2026-10-08):** Lock it down and document it. Candidates may use only the original's functions, types, collations, and operators, plus pg_catalog's. If a rewrite needs a new user-defined function to be faster, that function isn't coming from the mechanical rewrite rules, and an LLM can't be trusted blindly to provide one.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-32 (commits 7a43f6f0, 53e6c5c7, ea55fa63) after a fix round. The second review was clean. Minors from both rounds are in 20261008-41.

### 20261001-5. An LLM error reads the reason out of a JSON array body.

Gemini's OpenAI-compatible endpoint answered a 503 and QUAACK printed no reason. Its error body seems to be a JSON array, such as `[{"error": {"message": "..."}}]`, which isn't confirmed. The detail code from 20261001-1 only reads a Hash or a String. When the body is an array, take the error message from its first element the same way. If no message is there, give the whole body as JSON. `llm_auth` stays status-only.

- **Depends on:** 20261001-1.
- **Came from:** The user, 2026-10-01, a Gemini 503 with no reason shown.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261001-5 (commits 077e202a, aa03a92b). Review had no blocking findings; its minor went to 20261008-43.

### 20260927-18. Make rewrite-test scenarios load instead of skipping them.

20260926-60 skips a rewrite-test scenario whose fixture won't load and marks its atoms untested. That's acceptable for now, but a scenario that won't load means those atoms go untested. Find out why such scenarios fail (constraints or triggers the scenario builder doesn't model: exclusion constraints, triggers on the arena tables, complex CHECKs, and so on), and make the builder produce rows that load. Or refuse the query up front with a clear rule, so atoms aren't silently left untested.

Also: fixture-compare still disproves every candidate when a scenario won't load (`:fixture_load_failed`). That fails safe for v1, but it rejects correct rewrites; once scenarios load, it stops mattering. And add a guard-level spec that a `:query`-step `ArenaRunner::Error` isn't swallowed by `VacuityGuard.loaded_exercised_atoms` (today, removing the step check stays green).

- **Depends on:** 20260926-60.
- **Came from:** User direction, 2026-09-27.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260927-18 (commits c0a0ca54, bfc015d2). Review had no blocking findings; its minors went to 20261008-47.

### 20261001-10. The full schema dump finds the schemas its objects reference, and takes overrides.

Replaces the hard-coded `dba` of 20261001-9. Objects in the dumped namespaces, such as functions, can reference schemas that weren't dumped, and then arena won't load. Find those schemas and add them to the dump, for example by parsing the dump with pg_query and collecting the schemas named in function bodies, defaults, types, and the like, then dumping again until nothing new turns up. Also let the operator name extra schemas to include, for example a list in the `quaacks` config. Settle the details with the user before building: which references count, whether a dependency query against the catalog (`pg_depend`) beats parsing, and where the override lives.

Also add an arena spec that loads a dump whose function references `dba` objects, end to end. That was the original `arena_dump_load_failed` symptom, and the review of 20261001-9 found no test covering it.

Handle objects the operator can't read. Including the `dba` schema made pg_dump fail with `pg_dump_failed`, because the operator's role had no read access to two of its tables. pg_dump locks every table it dumps, so one unreadable table fails the whole dump. Dump only the objects the dumped namespaces actually depend on, not whole extra schemas, and then decide what to do about a needed object that still can't be read. For example, check privileges first with `has_table_privilege` and refuse with a rule that names the problem (`dump_object_unreadable`) and counts the unreadable tables, rather than letting pg_dump fail with no reason. Settle this with the user too.

- **Depends on:** 20261001-9.
- **Came from:** The user, 2026-10-01.
- **Design:** schema-dump, arena-setup.
- **Decided by the user (2026-10-08):** Find the extra objects by walking pg_depend from the dumped objects. The operator names extra schemas in an `extra_dump_schemas` list in ~/.quaack/config.json. When a needed table can't be read, refuse with `dump_object_unreadable` before running pg_dump, and name the unreadable tables. They go to the operator only, through the error line's checked fields, the way `fk_cycle` names its tables, and never to the LLM.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261001-10 (commits d67a882a, 9c094ed7). Review had no blocking findings; its minors went to 20261008-48.

### 20261007-21. Qualify functions and operators that several schemas define (full version of 20260926-56's qualification).

20260926-56 qualifies only what's exact without knowing the query's types (the user's choice, 2026-10-07). This task does the rest: resolve each function and operator call's argument types the way Postgres does, so QUAACK can tell which schema's overload wins when several schemas on the path define the name (citext, hstore, postgis, and ltree in `public` all define `=`), and qualify it with that schema. It also covers the keyword forms with no qualified syntax (IN, BETWEEN, LIKE and ILIKE, IS DISTINCT FROM, NULLIF, simple CASE, USING and NATURAL joins) and `regproc`, `regprocedure`, `regoper`, and `regoperator` literals, which v1 refuses. It's large: split it further when it's picked up, for example type resolution first, then each keyword form.

- **Depends on:** 20260926-56.
- **Came from:** The 20260926-56 builder's report and the user's decision, 2026-10-07.
- **Design:** qualify.
- **Status:** done
- **Landed:** 2026-10-08, part 1 merged from task/20261007-21 (commits ef101e0a, b1d359ef, 6cc61bc2) after a fix round. The second review was clean. Parts 2 and 3 were split into 20261008-44 and -45, and the minors went to 20261008-46.

### 20261008-19. `token_limit_param` in an `llms` entry: add the missing test.

The review of 20261007-25 found that no spec covers `token_limit_param` inside an `llms` entry. That leaves two things untested: whether the value carries through, and the `llms[N].token_limit_param` error text. It works, but DESIGN.md's claim that "an `llms` entry takes it the same way" isn't pinned. Add tests like the `max_retries` ones in `driver/spec/llm_providers_spec.rb`.

- **Depends on:** 20261007-25.
- **Came from:** The review of 20261007-25, 2026-10-08.
- **Design:** LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-19 (commit 7c800446). Review clean.

### 20261008-17. DESIGN.md: one stale teardown sentence.

The review of 20261008-13 found one stale sentence in DESIGN.md's "Where QUAACK runs", near line 275. It says the operator tears the run down "with `quaacks teardown --run <ID>` on the jump server", and that the driver "prints the teardown command to run later on the jump server". That contradicts the sentence below it. Since 20261008-12 and -13, every printed teardown command is the `ssh -- <jump> quaacks teardown --run <ID>` form, run from the laptop. Reword the stale sentence to match.

- **Depends on:** 20261008-13.
- **Came from:** The review of 20261008-13, 2026-10-08.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-19 (commit d37c2de4). Review clean, with one minor that went to 20261008-49.

### 20261008-16. Operator messages: minors from 20261007-29.

The review of 20261007-29 found these minor issues:

1. **The scan allows dynamic raises by file, not by site.** `enclave/spec/error_rules_spec.rb` approves a whole file, so a new dynamic raise in an approved file goes unnoticed. For example, `r = "run_server_dyn" + "x"; fail!(r, ...)` in `run_server_check.rb` passed. Track dynamic raise sites individually (by method, or by a count per file), so a new one fails until someone reviews it.
2. **Leftover periods.** `INTERNAL_NOTE` still ends in ".", though every other note dropped its final period. When only teardown is left and the rule is INTERNAL, `Teardown.failure` prints "...and the step.. To go on, ...".
3. **Capitalization.** New notes start with a capital after "rule: ", but the older ones start lowercase. Pick one style.
4. **Rule classes.** Two rules could move out of INTERNAL:
   - `index_build_orphan_running`: after a driver timeout kill, the operator can wait and then resume, so it could get a note.
   - `plan_gate_not_comparable`: arguably a v1 limit rather than a bug.

5. **Advice after teardown, from the second review.** The `plan_gate_mismatch_likely_stale_statistics` note says "Restore a fresh backup on the run server, or run ANALYZE in the racetrack database". The plan gate fails during index-search, though, so teardown has already run, and with `destroy_command` set, that run server is gone. Better: make sure the backup the next run server restores from is fresh and analyzed.
6. **`index_build_orphan_cancel_denied` is borderline INTERNAL** (`enclave/lib/quaack/enclave/build_connection.rb:60`). The operator could cancel the CREATE INDEX backend by hand and resume.

- **Depends on:** 20261007-29.
- **Came from:** The review of 20261007-29, 2026-10-08.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-16 (commit f158d2c2). Review had no blocking findings; its minor went to 20261008-50.

### 20261008-49. Teardown message fallback when no jump host is known.

From the review of 20261008-17. When `jump` is nil, `TeardownMessages.run` and `command` still fall back to "run this on the jump server: quaacks teardown --run <ID>", but DESIGN.md now describes only the `ssh -- <jump>` form. Check whether `@jump` can ever be nil. If it can't, remove the fallback. If it can, mention it in DESIGN.md.

- **Depends on:** 20261008-17.
- **Came from:** The review of 20261008-17, 2026-10-08.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-49 (commits b45dacc4, 4fda3d85). Review clean; a stale usage comment went to 20261008-50.

### 20261008-27. Burndown refusals: minors from 20260924-8.

The review of 20260924-8 found these minor issues:

1. **DESIGN.md overstates the once-per-search refusal.** Production never calls `record_dedupe` or `record_single_candidate_test`. It records through `record_once`, which quietly skips a second record rather than refusing it, so the refusal guards only the adapter API. DESIGN.md's new sentence reads as if the step itself refuses. Reword it.
2. **No test pins the `dedupe:` pass-through.** Nothing in `index_burndown_spec.rb` checks that `IndexBurndown.record_search` passes its `dedupe:` through. Replacing the call with a bare `tested_counts` record keeps that spec green.

- **Depends on:** 20260924-8.
- **Came from:** The review of 20260924-8, 2026-10-08.
- **Design:** burndown.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-49 (commits f42c5c55, 6c2b6292). Review clean; the mutation was confirmed red. A wording nit went to 20261008-50.

### 20261008-51. `quaack start --database`: name production's database.

The user is blocked (2026-10-08): `PGDATABASE` lives in their login profile on the jump server, and a non-interactive ssh session doesn't load it, so the production connection goes to the wrong database. Add an optional `--database <name>` to `quaack start` and `quaacks intake`, mirroring `--port`:

- Check it the same way as a run-server database name.
- Record it as a `production_database` entry, kept beside `server` and `production_port`, and also in the driver's run record.
- Use it in every production connection (inventory, qualify, statistics, volatility, and the schema-dump catalog reads) and in pg_dump's `--dbname`.

Without the flag, nothing changes, and libpq's setup picks the database, as today. The database name is the operator's own configuration, like the server name, and it never goes out. Update the connection-failure note, which today says the database comes from libpq, and DESIGN.md.

- **Depends on:** none.
- **Came from:** The user, 2026-10-08, blocked on a run.
- **Design:** input, inventory.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-51 (commit aa62fb90). Review had no blocking findings; its minors went to 20261008-52.

### 20260924-25. redact loose ends.

Still open from the reviews of 20260922-23, 20260924-11, and 20260924-16:
- **Decided, not built:** a plan more than about 48 levels deep can't go out through egress. Refuse it with a clear rule, and list it as unsupported in v1.
- Placeholders of different types can collide on one plan literal. With `$1 = 101` and `$2 = B'101'`, `X'05'` matches 101. No value leaks, but `$n` and the row annotation can be wrong. Prefer the candidate whose type matches the literal's cast.
- Expressions Postgres treats as equal but that are written differently get separate placeholders. They fail closed as `prepare_failed`.
- Date and timestamp normalization for row annotations, through the racetrack.
- Masks on planner-made TRUE and FALSE inflate the masked count.
- The 42P18 retry depends on English `lc_messages`, and preparing in a failed transaction gives 3B001, not 25P02.
- PredicateAtoms should use redact's numbering. SingleCandidateTest and ArenaRunner should adopt Binding, so types get declared through PREPARE.

- **Depends on:** 20260924-16.
- **Came from:** The reviews of 20260922-23, 20260924-11, and 20260924-16.
- **Design:** redact.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260924-25 (commit c5c275ef). Review had no blocking findings. The items left out, and the review's minors, went to 20261008-53.

### 20260929-22. The subset dump takes a query table in a system schema.

With a `pg_toast` table as a query relation, the subset's `--table` dump fails with `pg_dump_failed`. With `pg_catalog.pg_namespace`, the subset probably gets catalog DDL. `Relations.check` may let catalog tables through, since they're relkind `r`. A query on a system catalog isn't something QUAACK can tune, so refuse it cleanly, with a rule such as `system_relation`, early in qualify. List it as unsupported in v1.

- Also from the 20260929-19 review: suppose no `public` schema exists, and every query relation and extension is in a system schema. Then the full dump gets no `--schema` flags, and pg_dump dumps every schema. Refusing system relations fixes this too.

- **Depends on:** 20260929-19.
- **Came from:** The build and review of 20260929-19.
- **Design:** qualify, schema-dump.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260929-22 (commit 4241e14f). Review had no blocking findings. The main session ran the mutations: dropping system! made 7 tests fail, and changing the pg_ prefix made 6 fail. Minors went to 20261008-54.

### 20260929-16. PgBouncer support: minor findings.

Minor findings from the review of 20260929-8.

- DESIGN.md's run-server says a pooler must hold no idle server backends when the check runs, but not how the operator gets there. After an earlier run, or a psql session through the pooler, PgBouncer can hold several idle backends. Every one but the one QUAACK reuses then fails `run_server_other_clients`. Say how to clear them: PgBouncer's `RECONNECT` or `KILL`, waiting out `server_idle_timeout`, or `pg_terminate_backend` on the named pids. Also put this in the README's troubleshooting.
- `TestPostgres::Server#pgbouncer_port`: if PgBouncer's startup fails partway, such as on the readiness timeout, the next call starts `pgbouncer -d` again, and probably fails with a confusing error because one is already running.

- **Depends on:** 20260929-8.
- **Came from:** Review of 20260929-8, round one.
- **Design:** run-server.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260929-22 (commit 11f6b224). Review had no blocking findings; its minors went to 20261008-54.

### 20260930-12. Anthropic credential wording nits.

Minor findings from the review of 20260930-8:

- In DESIGN.md's LLM client section, "So an empty value there is `llm_auth`" leans on "there" to mean the first of the two variables that's set. Say it outright.
- The class comment in driver/lib/quaack/driver/llm/anthropic_adapter.rb still uses semicolons ("wins; then ... not empty; else ..."). Split it into sentences.

- **Depends on:** 20260930-8.
- **Came from:** Review of 20260930-8, round one.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260930-12 (commit a50504d8). Review clean.

### 20260930-13. Run server check shadowing: one untested qualification, and operators.

Minor findings from the review of 20260930-9:

- In `RunServerCheck::PLANNER_SQL`, the second `pg_catalog.pg_settings_get_flags(name)`, the one in the WHERE clause, has no test that fails when it's unqualified. Under `search_path = public, pg_catalog`, a `public.pg_settings_get_flags` returning `'{}'` drops every EXPLAIN-flagged setting outside Query Tuning. A run server with `SET effective_io_concurrency = 7` then passes when it should fail with `run_server_guc_mismatch`. Add that example to the "a search_path whose public schema shadows the catalog" group. The reviewer confirmed it goes red with the qualifier removed.
- Operators (`=`, `<>`, `LIKE`, `= ANY`) in the check's SQL aren't qualified. Exploiting that needs a deliberately built operator in `public`, and a blunt one breaks the planner check first. List it as unsupported in v1 in DESIGN.md's run-server, or qualify with `OPERATOR(pg_catalog.=)`.

- **Depends on:** 20260930-9.
- **Came from:** Review of 20260930-9, round one.
- **Design:** run-server.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260930-12 (commit 14a33cbb). Review clean; the operators had already been qualified by earlier work.

### 20260929-29. An operator's cancel shouldn't count as disproving a rewrite.

In Counterexamples (`counterexamples.rb:89-91`) and ScenarioTests (`scenario_tests.rb`), a candidate query that fails with `statement_canceled` is recorded as a disproof, `match` false, just like a timeout. It errs on the safe side, since it can only reject a rewrite. But a cancel from someone else says nothing about the candidate: a valid rewrite is silently lost, and the report says "disproved in rewrite-test ... (rule statement_canceled)". RunDiscipline raises on a cancel that isn't its timeout. The arena side should probably do the same, and end the step with an environment error instead of recording a verdict.

- **Depends on:** 20260923-37.
- **Came from:** Review of 20260923-37, round one.
- **Design:** rewrite-test and counterexamples.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260929-29 (commit a54d37f7). Review had no blocking findings; its minors went to 20261008-55.

### 20260930-6. `clients` shape checks: minor findings, round three.

Minor findings from the review of 20260929-12:

- The 24-hour-clock test runs `BACKEND_START_SQL` alone, not `OTHER_CLIENTS_SQL`. Inlining an HH12 format into the query in place of the constant stays green before noon UTC. Assert `OTHER_CLIENTS_SQL.include?(BACKEND_START_SQL)`, or run the query itself against a temp view `pg_temp.pg_stat_activity` with a pinned afternoon `backend_start`.
- In enclave/spec/error_filter_spec.rb, the subclass cases' `to_json` override never runs, because egress's plain-data check rejects a subclass first. The comment saying it "writes itself out as a sentinel" is misleading. Fix the comment.
- Watch for a flake in "names the oldest other client first" (run_server_check_postgres_spec.rb). It failed once in one review run and passed on every rerun. Look into it only if it recurs.

- **Depends on:** 20260929-12.
- **Came from:** Review of 20260929-12, round one.
- **Design:** run-server.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260930-6 (commit 6cf4eebf). The diff is 5 lines of spec and comment, reviewed by the main session. The builder confirmed the new assertion goes red when HH12 is inlined. The flake didn't recur in 10 runs.

### 20261002-1. Rule generator: minor findings.

Minor findings from both reviews of 20261001-22:

- **Legacy inheritance.** `AssumptionCheck`'s `unique` ignores `INHERITS` children, whose rows a parent's key doesn't cover, so `key_in_self_join` can drop rows on such a parent. Make `unique` unmet when the table has non-partition children, and list it in DESIGN.md as unsupported. Partitioned tables are fine.
- **Test gaps where a wrong change stays green:** no firing example on a non-public schema (`key_in_self_join.rb:51`, hardcoding `public` survives); no column-free arm predicate such as Rails's `1=0` (`arm.rb:99`); no IN inside a nested AND (`tree.rb:52`); the single-column guard (`arm.rb:79`) and single-statement guard (`tree.rb:37`); the marker's `over_cap` (`steps/rewrite_rules.rb:48`).
- The rules' exemption from `too_many` can't be observed, since the generator's cap and `RewriteCheck::MAX` are both 5. Share one constant.
- A rule file can't be required alone: it uses `RewriteRules::Rewrite`, defined in the file that requires it. Move `Rewrite` to its own file.
- `Tree::Names`'s comment says it avoids every name in the tree. It collects only names in column references.
- A query with three or more matching INs never gets its fully rewritten form, given depth two and the cap of five.
- Wider coverage for later: nested SELECTs and derived tables, unqualified columns, an IN in a join's ON, `= ANY (subquery)`.

- **Depends on:** 20261001-22.
- **Came from:** The build and both reviews of 20261001-22.
- **Design:** assumption-check, rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261002-1 (commits d7c43ea4, ae073c20, 26ea7411, 31ff1b92). Review had no blocking findings. The shared cap, over_cap, and the Tree::Names comment were stale. Leftovers went to 20261008-56.

### 20261002-2. Running the rules: minor findings.

Minor findings from the build and both reviews of 20261001-23:

- **False rule bugs from rewrite-test and counterexamples.** `RuleBugs.disproved_by` counts any failed `rewrite_tested_<n>` whose rule isn't `discarded`. ScenarioTests also fails a rewrite with `unsupported_order` (a WITH TIES original, for one) and with ArenaRunner's errors: `query_failed`, `statement_timeout`, `statement_canceled`, `begin_failed`. None compared results. Use an allowlist, as result-comparison's `MISMATCHES` does. counterexamples can't be told apart yet: `rewrite_round_<n>` doesn't store the round's rule, and `match` is false for `query_failed` too. Store it.
- **Postgres 18 removes the one-arm self-join itself,** so `key_in_self_join`'s rewrite of `t.id IN (SELECT t2.id FROM t t2 WHERE P)` plans like the original and plan-pruning prunes it. DESIGN.md's rewrite-rules' table says each rule is something the planner doesn't do. Say which cases still matter (the `UNION ALL` arms, and servers before 18).
- `rewrite-check` has the double-store window that rewrite-rules closed: a call that dies after storing rewrites and before its marker stores them again on rerun.
- A rule-made rewrite that fails the checks counts in rewrite-rules' `failed_checks` and in plan-pruning's drops, so rewrite-rules' out isn't plan-pruning's in. Settle it with 20261001-19.
- A store where llm-rewrites ran before rewrite-rules existed gets its rule rewrites numbered after llm-rewrites'. DESIGN.md's rewrite-rules says "before llm-rewrites'" without the exception.
- `CounterexampleStage` asks `status` again right after `RewriteStage` did.
- Test gaps where a wrong change stays green: `rule_bugs` when nothing beat the original (`report_payload.rb:74`); "shows the rewrite-rules row first" only checks against rewrite-test (`report_spec.rb:188`); a rerun with two or more stored rule rewrites, or after a call that stored only some; the rewrite-rules and plan-pruning records going in one write; the rewrite-test disproof line's source label (`report.rb:171`).
- The spec helper `compared` builds result-comparison's entry by hand. Call `ResultComparison.entry`.
- An empty `rules` renders "made by QUAACK's rules " with nothing after it (`report.rb:113`).
- In a negative result, a rule-made rewrite that plan-pruning pruned now reads "(made by QUAACK's rule ...): disproved in rewrite-test ... (rule discarded)". 20261001-17 fixes the root cause.

- **Depends on:** 20261001-23.
- **Came from:** The build and both reviews of 20261001-23.
- **Design:** rewrite-rules, rewrite-test, counterexamples, report, burndown.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261002-2 (commits d5a007c5, 41e442d1, 9b146ef8). Review had no blocking findings. Leftovers and minors went to 20261008-57.

### 20260926-42. Report loose ends, part three.

- The ScenarioTests dropped count isn't stored anywhere readable. Store it in `rewrite_tested_<n>` and show it in the report.
- "Whether counterexamples covered them" shows only the `evidence` flag, because per-round covered shapes aren't stored.
- A plan node with no `Schema` is matched to a table by name only when exactly one subset table has that name.
- LLM call counts on a resumed run include only calls from the current process.

- **Depends on:** 20260926-34, -38.
- **Came from:** Their build and review.
- **Design:** report.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260926-42 (commits f2182682, 5ae8fa31). Review had no blocking findings. Item 2 was already done, and item 4 is documented only. The minor went to 20261008-58.

### 20260927-17. Covering-check and volatility-list gaps.

- `ColumnRefs.in` skips subqueries, so an outer-table column read only inside a correlated subquery isn't counted in `read_columns`, and an INCLUDE can look covering when it isn't. This costs performance only.
- `VOLATILE_FUNCTIONS` in `value?` is a fixed name list matched on the last name only. It misses user-defined volatile functions and wrongly flags a user function with a built-in's name. It's a backstop behind volatility.

- **Depends on:** 20260927-13, -15.
- **Came from:** Review of 20260927-13 to -16.
- **Design:** index-from-query.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20260927-17 (commit 6b09c8ff). Review had no blocking findings; its minors went to 20261008-59.

### 20261008-55. Foreign cancels: minors from 20260929-29.

The review of 20260929-29 found these minor issues:

1. **A cancel on BEGIN or ROLLBACK still counts as a disproof.** It arrives through `TransactionStatus` with `step: :transaction`, so `Cancel.foreign?` misses it. In `Counterexamples.compare` it still gives `match: false`. Treat a `statement_canceled` there the same way.
2. **No spec reruns a step after a cancel.** Add one that reruns the step and checks that it succeeds and stores exactly one result.

- **Depends on:** 20260929-29.
- **Came from:** The review of 20260929-29, 2026-10-08.
- **Design:** rewrite-test and counterexamples.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-55 (commit a0d6c6b0). Review had no blocking findings; its minors went to 20261008-60.

### 20261008-58. Report `dropped`: pin the non-negative guard.

From the review of 20260926-42. The `!dropped.negative?` half of the egress guard in `report_payload.rb` has no test, and removing it keeps everything green. Add a test that stores `"dropped" => -1` and expects nil.

- **Depends on:** 20260926-42.
- **Came from:** The review of 20260926-42, 2026-10-08.
- **Design:** report.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-55 (commit ecb82cbc). Review clean.

### 20261008-50. Orphan index-build notes: advice that's moot after teardown.

From the review of 20261008-16. `index_build_orphan_running` and `index_build_orphan_cancel_denied` fire in index-build during `quaack run`, and that run is torn down, often along with the run server. The note's "wait for it or cancel it yourself, then resume" advice only applies with `--keep`, or when teardown fails. Word these notes like the stale-statistics note, or make the advice depend on the run being kept.


Also, from the review of 20261008-49 and -27: the usage comment at `driver/lib/quaack/driver/teardown.rb:12` doesn't show the now-required `jump:`. And DESIGN.md's "the burndown's own calls that record one stage at a time" should name `record_dedupe` and `record_single_candidate_test`.
- **Depends on:** 20261008-16.
- **Came from:** The review of 20261008-16, 2026-10-08.
- **Design:** Where QUAACK runs.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-50 (commit b8657898). It's a small driver-words and docs diff, reviewed by the main session.

### 20261008-40. Top-N hidden-tie check: test gaps from 20260924-6.

The review of 20260924-6 found these test gaps. In each case the code behaves correctly today.

1. **Nonzero constant OFFSET.** No test covers one, such as `OFFSET 1 LIMIT 1` with a tie at the window's edge. A mutation of the window's start would likely survive.
2. **Non-constant OFFSET.** No test covers its refusal (`shape.offset.nil?`).
3. **LIMIT inside a subquery or CTE.** No test covers it.
4. **ORDER BY an expression.** No test covers a tie on an expression sort key that straddles the window.

- **Depends on:** 20260924-6.
- **Came from:** The review of 20260924-6, 2026-10-08.
- **Design:** fixture-compare.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-40 (commit d8701871). The main session ran four mutations on tiebreaker.rb, and each one turned the new tests red. The inner-LIMIT and CTE case (item 3) is now a bug, 20261008-61.

### 20261008-18. `or_to_union` composite keys: minors from 20261008-6.

The review of 20261008-6 found these minor issues:

1. **Missing rule-level tests.** The rule refuses these key cases, but `or_to_union_postgres_spec.rb` has no test for them. The fact-level `assumption_check_postgres_spec.rb` covers some of them.
   - a deferrable composite key
   - an expression index
   - a domain key column
   - a citext key column
2. **Incomplete refusal bullet.** The bullet in `docs/transforms/or_to_union.md` leaves out two conditions: the key must not be deferrable, and each column must compare as the column's own `=` does.
3. **Repeated column in the assumption.** An index like `(a, b, a)` states a `unique` assumption that lists a column twice. It's sound, since the carried columns are de-duplicated, but it's untidy.

- **Depends on:** 20261008-6.
- **Came from:** The review of 20261008-6, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-18 (commit f29eaa07). Review had no blocking findings. The expression-index test minor went to 20261008-64.

### 20261008-20. `not_in_to_not_exists` over a UNION: minors from 20261008-3.

The review of 20261008-3 found these minor issues:

1. **No test covers the recursion in `Columns.deduped?`.** That's the check for a UNION without ALL nested under a UNION ALL. Cutting it to `!sub.all` stays green. Test `(SELECT t.b ... UNION SELECT r.b ...) UNION ALL SELECT q.b ...` on `box` columns. Postgres errors on the original, and the mutated rule would rewrite it.
2. **The branch type check refuses more than it needs to.** It compares branch types with their typmod (through `format_type`), so `varchar(10) UNION varchar(20)` is refused even though the rewrite would be sound. Consider comparing types without the typmod. Either way, say in the docs page and DESIGN.md how typmods are treated.

- **Depends on:** 20261008-3.
- **Came from:** The review of 20261008-3, 2026-10-08.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-18 (commit e4306d7c). Review clean. Typmods are now ignored, which the review checked as sound on real Postgres.

### 20261008-62. Progress lines name the LLM, not just "the LLM".

The user asked for this on 2026-10-08. Many `quaack` output lines say "the LLM", such as `quaack: [2/18] Waiting for the LLM (llm-index-ideas) 27s`. The driver knows which `llms` entry each call goes to, so name it: the entry's provider and model, for example `Waiting for Anthropic claude-opus-5-5 (llm-index-ideas) 27s`. Use the entry's `name` if it has one.

- **Fan-out:** when a step calls several entries at once, the line should still make sense. For example: `Waiting for 3 LLMs: anthropic claude-opus-5-5, openai gpt-5, ollama llama4 (llm-index-ideas) 27s`, or the ones still pending as each finishes. Keep it to one line, and shorten it sensibly when there are many entries.
- **Failover:** name the entry currently being tried, and say when QUAACK switches to the next one.
- **Pairing:** say which entry is the author and which is the reviewer.

Every user-visible line that says "the LLM" gets the same treatment where the driver knows the entry. Lines that come before any entry is chosen keep the generic wording. Model and provider names are the operator's own config, so nothing here crosses the trust boundary. Update DESIGN.md and README examples to match, and pin the new lines in specs.

- **Depends on:** 20261007-18 (multi-provider routing).
- **Came from:** The user, 2026-10-08.
- **Design:** LLM providers, quaack run.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-62 (commits 10bb1251, 8de798ba, 84de43c0, b41fc509, eae901da) after a fix round. The second review was clean, and its minor went to 20261008-65. This also covers the user's report of out-of-order counterexample lines.

### 20261008-47. Scenario loading: minors from 20260927-18.

The review of 20260927-18 found these minor issues:

1. **The booking-table example doesn't test the `&&` part.** The `(room WITH =, during WITH &&)` example stays green when the `=` columns aren't added to `uniques`, because its rows never happen to overlap. Make it force overlapping `during` values.
2. **The generated-column skip is too broad.** It drops boundary values for every column of the table. Skip only the columns the generation expression reads, from `pg_depend` or by parsing the expression.
3. **`EXCLUDE USING gist (during WITH &&)` is refused, and that's common.** Booking and scheduling tables use it. Give each row's range column a distinct, non-overlapping value, such as `[2i, 2i+1)`, instead of refusing.
4. **The equality check matches the operator by name only.** It checks `oprname = '='` but not the namespace, and not that the operator is a btree equality. Check both.

- **Depends on:** 20260927-18.
- **Came from:** The review of 20260927-18, 2026-10-08.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-47 (commits cdc5b792, 8bc0805a). Review had no blocking findings; its minors went to 20261008-66.

### 20261008-61. Fixture-compare: a LIMIT inside a subquery or CTE isn't checked for hidden ties.

The builder of 20261008-40 found this on real Postgres. `Tiebreaker.hidden_cut_tie?` (`result_comparison/tiebreaker.rb`) only looks at the outer query's cut. A subquery such as `(SELECT ... ORDER BY grp LIMIT 1) s` keeps an arbitrary row from a tie. Two equivalent queries can then keep different tied rows that differ only in a left-out column such as jsonb. The comparison returns `{match: false, rule: :value}`, so a correct rewrite is called wrong. That fails safe, but a correct rewrite is lost. The CTE form (`WITH s AS (... LIMIT 1)`) is probably affected the same way, but that isn't confirmed.

Either apply the hidden-tie check to each LIMIT or OFFSET at any depth, or refuse a query with an inner LIMIT or OFFSET as `unsupported_order`, and list it in DESIGN.md as unsupported in v1. The failing test is in `scratchpad/build-20261008-40/tests.diff`. Also check whether an inner cut could ever give a false match, not just a false mismatch.

- **Depends on:** 20260924-6.
- **Came from:** The builder of 20261008-40, 2026-10-08.
- **Design:** fixture-compare.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-61 (commits 95b141cd, f1269ea4, 171e5460) after a fix round. The second review was clean. This fixes a soundness bug in which an inner cut could give a false match. The minor went to 20261008-67.

### 20261008-63. Report: calls, wait time, and tokens for each LLM model.

The user asked for this on 2026-10-08. The report should show a table with one row per LLM model the run used, in the form provider and model, or the `llms` entry's name. Each row gives:

- the number of calls
- the total time spent waiting for replies
- the tokens used: input, output, and total, or cached and reasoning tokens where the provider reports them

Count failed and retried calls and show them, so a failover shows up. Add a total row.

On a resumed run, include the earlier processes' numbers, saved in the provenance record `~/.quaack/runs/<id>.llm.json` the same way 20260926-42 saves `llm_calls`.

Token counts come from each adapter's usage data. A provider that gives none shows "not reported", not 0. This is the operator's own data, kept on the laptop, so nothing crosses the trust boundary. Update the DESIGN.md report section and pin the table in specs.

- **Depends on:** 20260926-42, 20261007-18.
- **Came from:** The user, 2026-10-08.
- **Design:** report, LLM providers.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-63 (commits 46b31376, 3e1cd831) after a fix round. The second review was clean. Its minors went to 20261008-68.

### 20261008-65. Index-refine notes still say "the LLM's".

From the second review of 20261008-62. The refine step's notes in `pipeline.rb`, around lines 120-122, still say "the LLM's": "Reading how the LLM's index ideas did" and "Testing the LLM's revised index ideas". Name the entry with `Router#possessive`, the same way the other notes do.

- **Depends on:** 20261008-62.
- **Came from:** The second review of 20261008-62, 2026-10-08.
- **Design:** quaack run.
- **Status:** done
- **Landed:** 2026-10-08, merged from task/20261008-63 (commit 7889e73e). Review clean.

### 20260929-26. The full dump misses objects in other schemas that dumped objects depend on.

Found while building 20260929-21. `pg_dump --schema=X` dumps only the objects in X. So anything a dumped object depends on in another schema is missing, and arena's load fails with `arena_dump_load_failed`. The builder confirmed each case below with a throwaway spec:

1. **A sibling FK.** A table in a dumped schema has an FK into a schema that isn't dumped, and it isn't in the query's FK chain. For example, `s.sib REFERENCES z.p`, with the query on `s.q`. `--schema=s` brings in all of `s`, `s.sib` included, but not `z`. The ancestor schemas 20260929-21 adds come in whole too, so their other tables can do the same. This is the case most likely to hit the user's Canvas shard schemas.
2. **A column type or domain in another schema,** such as `CREATE DOMAIN types.pos ...` used by `s.q`.
3. **A column default that calls a function in another schema,** such as `DEFAULT util.one()`.
4. **A default that uses a sequence in another schema,** such as `DEFAULT nextval('seqs.ids')`.

Check constraints and triggers likely have the same gaps as items 2 to 4.

- **Needs a decision:** close the dumped schema set over dependencies, or refuse cleanly and list it as unsupported in v1. Closing over could mean the FKs of every table in the dumped schemas, or walking `pg_depend` from the dumped objects to the schemas they depend on. It could also pull in large unrelated schemas.

- **Depends on:** 20260929-21.
- **Came from:** The build of 20260929-21.
- **Design:** schema-dump, racetrack-setup.
- **Decided by the user (2026-10-05):** Refuse cleanly, and list it as unsupported in v1.
- **Status:** dropped
- **Landed:** Nothing built. Superseded by 20261001-10 (the user's decision of 2026-10-08), which closes the dumped schema set over pg_depend instead of refusing (d67a882a). Cases 1, 3, and 4 have direct tests; case 2 moved to 20261008-69.

### 20261008-69. Schema dump: test a domain or column type from a schema that isn't dumped.

20261001-10 walks pg_depend from every dumped object, and that walk follows types and domains. But no spec covers case 2 of 20260929-26: a dumped table whose column uses a domain or type (`CREATE DOMAIN types.pos ...`) from a schema the query doesn't name. Add a real-Postgres spec in `enclave/spec/schema_dump_postgres_spec.rb` showing the dump pulls in that schema and the arena load succeeds. Mutation-check it.

- **Depends on:** 20261001-10.
- **Came from:** The stale check of 20260929-26, 2026-10-08.
- **Design:** schema-dump.
- **Status:** done
- **Landed:** 1bc225b3 (spec only, no bump). Review clean.

### 20261003-3. Report payload: minor findings.

The build and review of 20261001-17 found these:

- **`excluded` goes out as stored.** The report message's top-level `excluded` map sends selection's reason strings straight from the selection entry. Send them through a closed list, as `RewriteFate` does.
- **Selection calls every result-comparison discard `result_mismatch`,** a timeout included. The rewrite's fate is right, but the per-label `excluded` reason still says `result_mismatch` for a result-comparison timeout.
- **`RewriteFate::FAILURES` is a hand copy** and misses `transaction_closed`, which `ArenaFixture::Error::RULES` has. A rewrite-test or counterexamples failure with that rule goes out with a nil rule. Build the list from `RULES.keys` plus `unsupported_order`.
- **Two branches no test needs.** `NegativeResult`'s `once` sends an index declined for two different reasons once for each, and grouping by the index alone stays green. `RewriteFate`'s `production` handles selection saying `result_mismatch` when result-comparison's entry has no failing verdict, which `Selection` can't produce, and dropping that stays green. Test each or drop it.
- **negative-result still repeats other spellings of one predicate:** `amount > 10` and `amount > '10'::numeric`; `status IN ('a', 'b')` and `status = ANY (ARRAY['a'::text, 'b'::text])`; the varchar form `(status)::text = ANY ((ARRAY[...])::text[])`.
- **Rewrite numbering gaps.** `CandidateRuns.candidates` and `IndexBuild.searches` stop at the first gap in rewrite numbers, while the report lists rewrites across gaps. A rewrite after a gap would never be measured and would read `unfinished`. Find out whether a real run can leave a gap, and make the two agree.
- **`NegativeResult.disproved` is a shim** kept only for `RuleBugs`. Item 1 of 20261002-2 moves `RuleBugs` onto an allowlist; have it use `RewriteFate` and `ResultComparator::MISMATCHES`, then delete the shim and `RuleBugs`' own copy of `MISMATCHES`.
- **`e2e/run.rb`'s `why_none`** now tallies rewrite fates, and nobody has run it since.
- **`spec/pipeline_replay_spec.rb` takes about 24 minutes** on its own. See whether it can share setup or run less.

- **Depends on:** 20261001-17.
- **Came from:** The build and review of 20261001-17, 2026-10-03.
- **Design:** report, negative-result.
- **Status:** done
- **Landed:** 5ef097be, items 1 to 7 (enclave; on the unreleased list). Items 8 (e2e/run.rb why_none) and 9 (replay spec time) not built; moved to 20261008-70. Review clean.

### 20260926-53. Candidate clock anchoring loose ends.

- `RewriteEntry.run_sql` falls back to `"sql"` for entries without `anchored_sql`. Only hand-written spec fixtures and stores from before the change hit it. Consider requiring `anchored_sql` and updating the fixtures (about 30 writes).

- **Depends on:** 20260926-52.
- **Came from:** 20260926-52 build and review.
- **Design:** clock-anchor.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 74fb84e8 (enclave; on the unreleased list). Review clean. Minors noted, not filed: one counterexample override (rewrite_2) is redundant; no egress spec for the KeyError case, but ErrorFilter never reads error content.

### 20261008-70. Report payload: leftovers from 20261003-3.

- **`result_not_compared` survives a mutation.** Removing it from `Selection::REASONS` stays green; add a test that sends every REASON through `MeasuredLabels.excluded`.
- **CastlessIndex misses the array-literal form.** `x = ANY ('{1,2}'::int[])`, which plans print, doesn't merge with `x IN (1, 2)`. Nested `ARRAY[ARRAY[...]]` elements key oddly too (rare).
- **`fval` keys by raw text,** so `10` and `10.0` key apart (harmless).
- **Selection entries stored before 20261003-3** still say `result_mismatch` for a timeout. The fate is still right.
- **Not built from 20261003-3:** `e2e/run.rb`'s `why_none` hasn't been run since it tallied fates; `spec/pipeline_replay_spec.rb` takes about 24 minutes alone.

- **Depends on:** 20261003-3.
- **Came from:** The build and review of 20261003-3, 2026-10-08.
- **Design:** report, negative-result.
- **Status:** done
- **Landed:** 2c2b00f7, items 1 and 2 (enclave; on the unreleased list). Review clean; a whitespace mutation of the literal regex survives but can't cause a wrong merge. Items 3 (10 vs 10.0) and 4 (old entries) dropped as harmless. Item 5: e2e/run.rb crashes, filed as 20261008-71; replay spec speed filed as 20261008-72.

### 20261008-71. `e2e/run.rb` crashes: the harness passes a plain LLM client.

Found while building 20261008-70. Every case tried (`036`, `054`, `034`) crashes before `why_none` with `NoMethodError: undefined method 'branches' for an instance of Quaack::Driver::LLM::Client`. `rewrite_generation.rb:106` and `generator_three.rb:120` call `@client.branches`, which only `llm/fan_out.rb` defines. The harness needs to build the fan-out router the way the real driver does, and a spec should run at least one e2e case so this can't rot again. Then check that `why_none`'s fate tally reads right.

- **Depends on:** 20261008-62.
- **Came from:** The build of 20261008-70, 2026-10-08.
- **Design:** none (test harness).
- **Status:** done
- **Landed:** 62231633 (harness and root spec only, no bump). Review clean. Case 036's why_none prints: no fix selected (declined: unused 4; existing: covered 5; rewrites: not_better 1); needs the LLM. Leftovers filed as 20261008-73.

### 20260927-22. Reply parsing loose ends.

These are minor findings from the review of 20260927-21:
- `embedded_objects` builds every `{` start, then retries `JSON.parse` at each later `}`. That scan is worse than quadratic: 16 KB of brace-heavy prose takes 13s, and a 28 KB fenced reply takes 1.1s. Scan the starts lazily, stop at the first match, and cap the number of starts.
- A reply cut off at max_tokens now reports "didn't match the schema" instead of "wasn't valid JSON".
- In `longest_object`, the `is_a?(Hash)` check is dead code.
- No test covers a required key that has no type (the `ReplyShape` `key?` mutation survives).

- **Depends on:** 20260927-21.
- **Came from:** Review of 20260927-21.
- **Design:** LLM client.
- **Set aside (2026-10-08):** Nothing landed. Branch `task/20260927-22` (b9267735, 2d02b503) bounded the scan with a shared 1000-parse budget, but the second review found it still hides fenced JSON after about 20 lines of prose with braces (each junk start tries every `}` end, so it spends the budget). Next try: a string-aware brace-depth scan, so each `{` parses only at its balanced `}` (linear per start, no budget needed), and the error words cut-off as "wasn't valid JSON". Reuse the branch's specs, including the 33-brace prose repro and the ReplyShape no-type key test (item 4). Delete the branch once this lands.
- **Status:** done
- **Landed:** 709edcf2, 494873db (driver only, no bump), from a second attempt after the first was set aside. Second review clean; on 26 realistic replies the output matched main, and 75-89 KB replies went from 26-75 s to under 5 ms. One rare regression filed as 20261008-74.

### 20261008-74. Reply parsing: a stray `{` and stray quotes that balance can hide the JSON.

Found by the second review of 20260927-22. `Use {the "plan:\n```json\n{"a": ["x"]}\n```\nsee "notes} ok` parses on the old scan but now says "wasn't valid JSON": the stray `{` pairs with the prose `}`, the two prose quotes swallow the real object's braces into a string, and no restart happens. Rare (it needs all four). Fix: when an outer span fails to parse, rescan just past its `{`, within the existing restart cap. Also, a reply with an unclosed stray `{` plus a complete non-matching object says "wasn't valid JSON", not "didn't match the schema".

- **Depends on:** 20260927-22.
- **Came from:** The second review of 20260927-22, 2026-10-08.
- **Design:** LLM client.
- **Status:** done
- **Landed:** 6884ce14, ea335850 (driver only, no bump). First review blocked on junk speed; fixed by rescanning only a failed span's interior. Second review clean: realistic replies match main, junk 6-28 ms. The wording item wasn't built; it and the review's minors went to 20261008-75.

### 20261008-73. e2e harness: leftovers from 20261008-71.

- **Unconfirmed cases.** 054 and 034 timed out under host load during the build of 20261008-71 and weren't rerun. Run them alone and fix or file what breaks.
- **Output lost on timeout.** `e2e/run.rb` buffers stdout when it's redirected, so a killed run leaves an empty log. Set `$stdout.sync = true`.
- **Pipeline options differ from the CLI.** The harness doesn't pass `rewrites:`, `stderr:`, `setup:`, or `home:` the way the CLI does. Check whether any of them changes what a case exercises.
- **`spec/e2e_run_spec.rb` checks only the verdict and detail shape,** not `why_none`'s tally numbers. Pin them if they're stable.
- **`why_none` says "covered" for every existing index,** so the count adds nothing beyond "exists".

- **Depends on:** 20261008-71.
- **Came from:** The build and review of 20261008-71, 2026-10-08.
- **Design:** none (test harness).
- **Status:** done
- **Landed:** 10ceaddb, 3b20c57d (harness and root spec only, no bump). Review clean. Case 054 passes; case 034 exposed an uncapped baseline, filed as 20261008-76. rewrites:, stderr:, and setup: left out on purpose (comment in run.rb).

### 20260927-19. Set-aside loose ends.

These are minor findings from the review of 20260927-11:
- There's no cap on set-asides. The worst realistic case is about 2 extra real builds per low-cardinality table, per search (about 18 for a 3-table join with 2 rewrites). Add a per-search cap, or limit set-asides to the moved key-only variant.
- There are two low-cardinality thresholds: the generator's hardcoded 50 (`TableCandidates::LOW_CARDINALITY`) and classify's configurable one used by `UnusedSetAside`. Unify them.

- **Depends on:** 20260927-11.
- **Came from:** Review of 20260927-11.
- **Design:** index-from-query, index-test, index-build.
- **Status:** done
- **Landed:** 3a7d8298, 56334f04 (enclave; on the unreleased list). Review clean. Cap of 2 picked by the builder to match e2e 055. Minors filed as 20261008-77.

### 20261008-77. Set-asides: leftovers from 20260927-19.

- **The cap takes the first two in report order,** not the most useful. On a 2-3 table join, the first table's two unused variants can use up both slots and starve the second table. Spread the cap across tables (one per table first), or rank.
- **`index_search_step_postgres_spec.rb:97` recomputes the generator_one count with `low_cardinality: []`.** That's right only because its fixture has no low-cardinality columns. Pass the real list.

- **Depends on:** 20260927-19.
- **Came from:** The review of 20260927-19, 2026-10-08.
- **Design:** index-from-query, index-test.
- **Status:** done
- **Landed:** c46bf95b, fb888ac9, 85d1056e (enclave; on the unreleased list). Review clean. Noted, not filed: the report-order re-sort is untested, but with a cap of 2 the picks are already in report order, so it only matters if the cap grows.

### 20260927-28. Parser note loose ends, and the Postgres 18 upgrade.

- When pg_query ships a Postgres 18 parser, upgrade it and drop the parser note (20260923-1).
- The driver builds the `query_unparsable` note from its own pg_query, not the enclave's. The two usually match because both install from the same lockfile. If they don't, the note names the wrong grammar. The enclave could send its parser major version as a plain integer.
- `clock_anchoring.rb` "the query doesn't parse" has no note. Intake refuses such a query first, so that message can't be reached today.
- `parser_version_spec.rb` restates the formula, so it stays green when `MAJOR` is wrong. Assert the literal 17.
- The sentinel test in `relation_qualifier_spec.rb` checks only the exception message, not the egress output.

- **Depends on:** 20260923-1.
- **Came from:** Reviews of 20260923-1.
- **Design:** none.
- **Status:** done
- **Landed:** c4fb2e97, items 4 and 5 (spec only, no bump). Review clean; the builder's planted leak through an allowed field went red. Item 3 dropped (note-only, unreachable). Item 1 moved to 20261009-1, item 2 to 20261009-2.

### 20260927-27. Replay wrong-rewrite spec gaps.

These are minor findings from the review of 20260927-24:
- The per-query spec "finds the wrong rewrite whenever the llm-rewrites reply holds the wrong condition" runs no expectation for queries whose reply lacks the condition.
- `PipelineReplay.wrong` matching the whole rewrite hash (`to_s`) instead of its `"sql"` field survives mutation.
- From the review of 20260927-26: `spec/prompt_pack_chat_spec.rb` doesn't check that "You were asked:" labels the first ask and "Your reply:" labels the planted reply. Swapping them stays green.

- **Depends on:** 20260927-24.
- **Came from:** Review of 20260927-24.
- **Design:** none.
- **Status:** done
- **Landed:** 80c97ddb (spec only, no bump). Review clean; each new assertion goes red under its mutation.

### 20260927-29. Deploy loose ends.

- `QUAACKS_DEV_CHECKOUT=1` turns off the driver-present guard, and it's a plain environment variable. No production path sets it, but an operator could export it on a jump server by mistake.

- **Depends on:** 20260923-2.
- **Came from:** Reviews of 20260923-2.
- **Design:** Where QUAACK runs.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** 853717a8, 99ec757f (enclave exe; on the unreleased list). Review clean. Noted, not filed: a Bundler git-sourced install would put the repo root two levels up, but deploy is gem install only.

### 20261003-5. Report payload: what the index accountability table still lacks.

20261001-18 stayed in the driver (the user, 2026-10-03), so these cells of the report say "not recorded", and 20261001-19 and -20 won't fill them:

- **Built and measured, not better, and ranked, per source.** `indexes` in the report message carries no source. The store has it (`IndexCandidate` sources). Send it through a closed list of QUAACK's constants.
- **Already existed and planner ignored, for the two generators.** The index-dedupe and index-test drops aren't recorded by source.
- **Already existed and planner ignored, in a winning report.** `negative` goes out only when nothing is ranked. Send the declined and existing lists every time.
- **The plan with the new indexes.** The payload has a plan only for rewrites, and that plan is the rewrite with no new indexes, even when the winning label ran with some. Send the winning label's plan, for an index-only winner too.

Then have the report render them. Trust boundary: sources are constants, DDL goes through CandidateDdlRedaction, and a plan node sends only its type, relation, index name, and row counts.

- **Depends on:** 20261001-18, -20.
- **Came from:** The build of 20261001-18, 2026-10-03.
- **Design:** report, negative-result.
- **Status:** done
- **Landed:** 37f43e4b, 342db1f6 (protocol, enclave, and driver; on the unreleased list). Bullets 1 and 4 were stale (done by 20261004-80 and -86). Review clean; a planted raw-DDL leak on the new path went red. Minors filed as 20261009-3.

### 20261008-75. Reply parsing: leftovers from 20261008-74.

- **Dedupe is untested.** Dropping `.reject { |s, _| @spans.key?(s) }` in `Spans#added` stays green, but `{"x" {"y" }}` x100 then re-parses (235 parses for 200 braces). Add a nested-span shape that pins the exact parse count. The `@restarts.positive?` guard in `rescan` and the `interior.include?('"')` check are redundant or speed-only, so drop the guard or leave both.
- **Wording (decided by the user, 2026-10-09: LLM replies must be valid JSON; an ambiguous reply is just invalid, so "wasn't valid JSON" stays and nothing changes).** `oops { then {"a": 1}`, an unclosed stray `{` plus a complete object that fails the schema, says "wasn't valid JSON". The scan alone can't tell it from a reply cut off mid-object that holds a parsable inner object. That case must keep "wasn't valid JSON". Needs a design call, for example whether the unclosed `{` comes before or after every parsed object.

- **Depends on:** 20261008-74.
- **Came from:** The build and reviews of 20261008-74, 2026-10-08.
- **Design:** LLM client.
- **Partly landed (2026-10-09):** Item 1 (53d4b537, 2bb83215; driver only). Item 2, the wording, is still open and needs a design call.
- **Status:** done
- **Landed:** - **Landed:** Item 1 in 53d4b537, 2bb83215 (driver only). Item 2 needed no change: the user decided on 2026-10-09 that ambiguous replies stay invalid JSON.

### 20261008-76. Baseline has no cap on the original query's runtime.

Found by 20261008-73. e2e case 034 ran 25 minutes inside `quaacks baseline` without finishing: literals' worst-case pick (`tier = 'standard'`) makes its `NOT IN` rescan `orders` per customer, and baseline runs the original three times per literal set with no `statement_timeout`, since later steps' timeouts derive from the baseline. On a real replica a slow enough original keeps QUAACK busy for an hour or more with no sign of ending.

- **Decided (user, 2026-10-09):** Option (1), a configurable ceiling per baseline run that refuses cleanly ("the original exceeded the cap"), but the default is one hour, not five minutes. The original is the query we are trying to fix, so it may well be terrible. The e2e harness may pass a lower cap so case 034 finishes.

- **Depends on:** none.
- **Came from:** The build of 20261008-73, 2026-10-08.
- **Design:** baseline, run-discipline.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 997d2a1f, merged in 1ab6dd1e. Adds the `baseline_cap_seconds` config key (default 3600), passed as the statement_timeout for each baseline run. A timeout refuses with `baseline_original_exceeded_cap`, and the driver has a note for it. The e2e harness is unchanged (see 20261009-5).

### 20261009-4. Burndown funnels: width is what's in the pipe.

Reported by the user, 2026-10-09, against 20261004-55's funnels. Each band is drawn from its own record's `in` to its `out`, so a generator stage (in 0) starts from a point, and the bands don't join up. What the user wants instead: the width shows how many things are in the pipe. Every band starts exactly as wide as the band before it ended. A stage that adds nothing and drops nothing keeps that width. One that drops (or sets aside) narrows, and one that adds widens. So the bottom is top + added − dropped − set aside, which should equal the stage's `out`. The first band starts at zero width.

- **Decided (user, 2026-10-09):** (1) If a stage's recorded `in` doesn't match the previous band's end, that's a counting bug. The drawing carries the running width anyway. A spec over the recorded runs must catch any such mismatch, and the bug that causes it gets fixed. In report quaack-20261008T211715Z-c349a0af.html, "Checking what each rewrite assumes" says 4 came in, after the rules (4) and the LLM (4) leave 8, and the next stage says 8 again. It probably counts only the rule rewrites. Find that and fix it. (2) The index search for rewrites ("Index ideas for the rewrites: …" stages) counts index ideas, not rewrites, so it comes out of the rewrite funnel into a third funnel, with its own table and its own scale. The rewrite funnel then goes straight on to "Choosing indexes for each rewrite".
- **Also (user, 2026-10-09):** Give each stage its own color from a fixed, accessible palette, so a stage keeps its color across reports. Unknown and partial bands stay grey. Make the hover show more: the band <title> lists the full added, dropped, and set-aside breakdowns, plus a short note on what the stage does if a source for that text already exists.
- **Unknown bands:** a "not recorded" row keeps the running width, grey and striped as now, never narrower than UNKNOWN. A partial row (in known, out not) keeps the width it came in at.
- **Depends on:** none.
- **Came from:** The user, 2026-10-09.
- **Design:** report, burndown.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 2eb2a14b. The funnel now draws a running width, gives each stage its own color, and shows a fuller hover. The index search for rewrites is its own funnel. The enclave now counts rule rewrites in assumption-check and plan-pruning. No stage-description note went in, since no source text exists (see 20261009-9).

### 20261009-6. Selection: keep the top three in each kind of change.

Asked for by the user on 2026-10-09, for the new verdict (20261009-7). selection keeps the top three candidates by total blocks across every label. Instead, keep the top three in each of three kinds:
- the same query with new indexes (`original:top:<n>` and the original's combinations),
- a rewrite with new indexes,
- a rewrite with no new indexes (`rewrite_<n>:none`).

Each ranked label carries its kind in the report payload, from a fixed list in the protocol gem. The ranked-candidates section of the report groups by kind and ranks within each one. A label that falls outside its kind's top three keeps the `below_top_three` fate. Update DESIGN.md's selection and report sections.

- **Depends on:** none.
- **Came from:** The user, 2026-10-09.
- **Design:** selection, report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 2d66ff7f and 4c441ca3. Selection keeps the top three per kind (`Protocol::CandidateKinds`), and each `top` entry carries its kind, which egress and the driver check. The report groups the ranking by kind. Left over: the `below_top_three` wording ("three other candidates did better") now means three others of its kind. Fold that into 20261009-10's wording pass.

### 20261009-5. Baseline cap: leftovers from 20261008-76.

- **e2e case 034** runs its original for many minutes. Any cap low enough to finish quickly makes baseline refuse instead. Make the case finish, for example with a lighter dataset or a planted query that isn't pathological, without lowering the default.
- **Dead code:** `Baseline.entry` still handles timed-out sets, and its spec "clamps the candidates' timeout when every set timed out" still tests that, but `call` now refuses first. Remove both.
- **Untested:** the driver's fixed note for `baseline_original_exceeded_cap` has no `fixed_notes_spec` coverage, and neither does the full path from `Baseline::Error` through ErrorFilter to an egress line.

- **Depends on:** 20261008-76.
- **Came from:** The build and review of 20261008-76, 2026-10-09.
- **Design:** baseline.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** aac806fc. Removes the dead timed-out handling in `Baseline.entry`, and adds specs for the fixed note and for the path from `Baseline::Error` to an egress line. Case 034 moved to 20261009-15: every lighter dataset also made the original beat the rewrite.

### 20261009-12. Report: open rule documentation links in a new tab.

Asked for by the user on 2026-10-09. Links to a rule's documentation page, such as "Where it came from: made by QUAACK's own rewrite rule key_in_self_join", should open in a new tab. Give them `target="_blank" rel="noopener"` (`RuleLinks#rule_link`). In-page `#` links are unchanged.

- **Depends on:** none.
- **Came from:** The user, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 4b6ab067, plus spec fixes in the following commits through a4f3d20d. `RuleLinks#rule_link` adds `target="_blank" rel="noopener"`. Driver only.

### 20261009-10. Report: say "the original query", not "your query".

Reported by the user, 2026-10-09. The report and its notes often say "your query", for example "planned the same as your query" and "against 3,454 for your query as it is". That's ambiguous. It could mean the original query, a rewrite the operator supplied (operator-rewrites), or the question the operator is really asking the database. Everywhere it means the original query, say "the original query", or "the original query's". Change "your query as it is" too. Any phrase that means something else should name that thing plainly, such as "your own rewrite". As of 2026-10-09 it appears about 25 times across five files under driver/lib, enclave/lib, and protocol/lib. Grep for "your query" in DESIGN.md and the specs too. Report text built from enclave words, such as reasons, may live in the enclave or protocol. That makes it an enclave change, so add it to the unreleased list.
- **Also:** the `below_top_three` wording in report/candidates.rb and rewrites.rb ("three other candidates did better") should say three others of its kind (from 20261009-6).

- **Depends on:** none.
- **Came from:** The user, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 20ffa4da, driver and README only. Every "your query" that meant the original now says "the original query", and below_top_three says "three others of its kind".

### 20261009-11. Report: style the query sections, and keep their collapse control on screen.

Asked for by the user on 2026-10-09. The `<details>` sections in "The queries" are hard to close once a long query is open, because their summary is far above. Do two things:
- **Style them like the verdict.** Give each section a light background with a strong accent stripe on the left, styled the way the verdict section is, but in a different color. Show it in both light and dark themes.
- **Keep the summary on screen.** Make each open section's `<summary>` bar `position: sticky` at the top of the window, in the same light background, with a "▲ Collapse" label on its right. While the section is open and any of it is on screen, the bar stays pinned, and a click closes the section. When the section is closed, the label reads "▼ Expand", or says nothing. Pick what reads best.
- **No script.** Decided by the user on 2026-10-09: pure CSS only. The report runs no script (DESIGN.md report), so don't build a separate floating button.

Check that `:target` links to a rewrite's SQL still open and scroll to the right place, and that the sticky bar doesn't cover the target. Update DESIGN.md's report section.

- **Depends on:** none. Land it after 20261009-7 if both edit the template at the same time.
- **Came from:** The user, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** Item 1: a new cli_run spec pins the operator-rewrites skip line on a resumed run with `--rewrites` (step 7 of 19), and the rewrite-correctness skip note for each rewrite. Breaking either one turns it red. Item 2 was already done: `clocked` sets the start before the first `say` (b74ba62), and existing specs pin it. Driver only. Landed with 20261006-1.

### 20261009-14. Report: plainer wording for a rewrite that wasn't better.

Reported by the user, 2026-10-09. The `not_better` fate (`report/rewrites.rb`) reads: "It passed every test, but didn't read enough fewer blocks than your query. To count, a candidate must read more than 5% fewer blocks on the slow values, and no more than 5% more on any others." That's awkward. The user's wording: "It passed every test, but was less than a 5% performance improvement, so QUAACK did not bother to rank it on real data." One correction: a `not_better` rewrite was measured on the real data, and it fell short there. So say something like "It passed every test, but on the real data it was less than a 5% improvement, so QUAACK didn't rank it." When the minimax verdict shows it failed by reading more than 5% more blocks on another value, say that instead, for example "… but on the real data it read over 5% more blocks on some values, so QUAACK didn't rank it". Use that only if the payload can tell the two cases apart. Otherwise keep one sentence that covers both, and file a task for the split. Keep the 5% figures tied to the minimax constants, not hard-coded twice.

- **Depends on:** 20261009-10, which changes the same strings.
- **Came from:** The user, 2026-10-09.
- **Design:** report, minimax.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 095ef363, driver only. A new `NotBetterFate` module picks a sentence from the not_better labels' minimax verdicts: "less than a 5% improvement", "read over 5% more blocks on some values", or one sentence that covers both. Minor and not filed: a redundant `verdicts.empty?` guard. The 5% figure is still hard-coded in the template and in candidates.rb, since protocol doesn't carry the minimax constant.

### 20261009-13. Report: make "passed every test" and "conditions untested" agree.

Reported by the user, 2026-10-09. A rewrite's section can say "It passed every test, …" and then "Read it with care: the test data left some of its conditions untested." The reader can't tell whether it passed. What's true: every test QUAACK ran passed, but the test data never exercised some of the rewrite's conditions (`Cautions#unchecked_atoms`), so those parts are unproven. Say it that way. One example: "Every test QUAACK ran passed, but the test data never exercised some of its conditions, so those parts are unproven." Name the conditions if the payload already carries them, and don't invent any. Also, the caution prints twice when the section is open: once in the summary line, which DESIGN.md keeps so a closed section doesn't hide it, and again in the body. Show it once while the section is open, or make the two read as one.

- **Also (user, 2026-10-09): the untested-conditions note under each rewrite** (`Rewrites::UNTESTED`, `atoms_note`). It's convoluted. List only the conditions no test ever exercised, and leave out the ones the LLM's counterexample rows covered later ("checked later"), since those did get checked. If there are none, show nothing. Lead with one plain sentence, for example: "QUAACK's tests never made these conditions from the original query both true and false, so they can't show the rewrite handles them the same way:". Keep the summary-line warning in step with it.
- **Depends on:** none. Land after 20261009-10 and 20261009-11, which touch the same text and markup.
- **Came from:** The user, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** eb744c17, driver only. The red-first check was confirmed by the reviewer. Leftovers are in 20261009-18.

### 20261009-17. Sort a partial index's top-level AND conditions, so equal predicates read the same.

Reported by the user, 2026-10-09. The same run proposed both of these:
- `(context_id, id) WHERE context_type = 'Course' AND workflow_state <> 'deleted' AND type = 'Assignment' AND (muted IS NULL OR NOT muted)`
- `(context_id) INCLUDE (id) WHERE context_type = 'Course' AND type = 'Assignment' AND workflow_state <> 'deleted' AND (muted IS NULL OR NOT muted)`

Their predicates are the same, but in a different order, so the two are hard to compare. When QUAACK writes or normalizes a partial index's predicate, sort the operands of each AND by their deparsed text. Do the same for each OR's operands, and apply it at every level of nesting. Never move a condition across an AND/OR boundary. `c AND b AND a` becomes `a AND b AND c`, and `c OR (b AND a)` becomes `(a AND b) OR c`, but never `a OR b AND c`. Work on pg_query's parse tree (BoolExpr args), never on strings, so precedence is preserved.

Apply it in two places:
- index DDL that QUAACK emits: the generators, the LLM's ideas after they pass the checks, and the report
- index-dedupe's normalization, so ideas that differ only in order merge (check whether it already does)

The sort must be deterministic and must not change meaning. Test that sorted and unsorted predicates give the same EXPLAIN on Postgres.

- **Depends on:** none.
- **Came from:** The user, 2026-10-09.
- **Design:** index-dedupe, index-from-query, report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** be298628 and 63e15ad1. `PredicateSort` runs inside `IndexSql.normalize_predicate`, which every `IndexCandidate` passes through. Leftovers are in 20261009-19.

### 20261009-7. Report: the verdict as a headline and one table.

Asked for by the user on 2026-10-09. Today the verdict is three paragraphs, which is too much for a summary and too little to choose from. Replace it with:

- **A headline.** "The verdict: substantial improvements possible" when the best row reads at least 30% fewer blocks on the slow values than the original. "The verdict: minor improvements possible" when it beats the original by less than that. "The verdict: QUAACK found nothing that could help" when nothing beat the original.
- **One table**, one row per kind, ranked by improvement:
  - best rewrite with new indexes,
  - best rewrite with the same indexes,
  - the original with new indexes,
  - the original with the same indexes (the baseline, 0%).

  Columns are Plan, Blocks read (slow values), Index Δ, and Improvement. Index Δ is the net change in index size, today the built size of the new indexes, and 0 for the same indexes. Improvement uses the same percentage rule as the ranked tables ("over 99% fewer").

  A kind with no candidate still gets its row, with ⚠ and a short reason, and a hover (`title`) that says more. Examples: "No new index found that the original query could use", "No rewrite survived testing", and "No rewrite beat the original without an index". Each reason comes from the fates and burndown the payload already carries. Don't invent any.
- **Caveats** go below the table as short ⚠ lines, each linking to its detail lower in the report. Examples: runs that timed out, and statistics the production role couldn't see, with what the second one may throw off.

The user's mock-up:

```
The verdict: substantial improvements possible

Plan                             Blocks read     Index 𝚫    Improvement
Best rewrite, index change       1,612           +56MB      53%
Best rewrite, same indices       2,000           0          42%
Original query, same indices     3,454           0          0%
Original query, index change     3,454           n/a        0%
  (no new indices were found for that the original query could use)
```

The user wasn't happy with how the last row shows "none found". Use ⚠ and a hover instead.

- **Depends on:** 20261009-6, and 20261009-4 if both touch the report template at once.
- **Came from:** The user, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** b42cd6a9, 0aed78c0, 9958adf4, and 15dc9dc0, driver only. The new `Verdict` module adds a headline (substantial at 30% or more, minor below that, or nothing found), a table with one row per kind plus the baseline, ⚠ rows whose reasons come from measured labels, and ⚠ caveat lines with Details links. For now the index change counts only the added size (see 20261009-8).

### 20261009-19. Predicate sort: leftovers from 20261009-17.

- **Untested:** an existing index whose predicate pg_indexes writes in a different order from a candidate's must still match in index-dedupe. Add a Postgres spec: create a partial index, then propose its predicate reordered, and expect it to come back as already covered.
- **Nested same-op groups:** `c AND (b AND a)` may sort differently from `a AND b AND c`. Flatten nested ANDs inside an AND, and nested ORs inside an OR, before sorting, if pg_query doesn't already do that. Pin it with a spec.

- **Depends on:** 20261009-17.
- **Came from:** The review of 20261009-17, 2026-10-09.
- **Design:** index-dedupe.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 6ed6344b. `IndexSql.comparable` now sorts, fixing `from_indexdef` returning nil for existing indexes whose predicates were out of order. `PredicateSort` flattens nested AND and OR groups that share an operator. Cast differences moved to 20261009-20.

### 20261009-15. e2e case 034: assert the baseline cap refusal instead.

Split from 20261009-5. Case 034's original is pathological on purpose, since that's what lets the rewrite win. Every lighter dataset tried (fewer or wider `orders` rows, more `work_mem`) let the original hash its `NOT IN` and beat the rewrite. So the case can't finish quickly and still make its point. Proposed: run 034 with a short `baseline_cap_seconds` in its e2e config, and assert that baseline refuses with `baseline_original_exceeded_cap` and shows the driver's note. That turns the case into an end-to-end test of the cap. Keep the "rewrite beats a pathological NOT IN" claim only if another case can show it cheaply.

- **Depends on:** 20261009-5.
- **Came from:** The build of 20261009-5, 2026-10-09.
- **Design:** baseline, e2e.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** d8468ebb, harness only. case.json gains optional `config` and `expect_stop` keys. Case 034 runs under a 5 s cap and passes, in about 57 s, when baseline refuses with `baseline_original_exceeded_cap`. The "rewrite beats a pathological NOT IN" claim is still made only by the case's verify.rb proof.

### 20261009-9. Funnel hover: say what each stage does.

Left over from 20261009-4. The user asked for more detail on hover. The hover already shows full counts, but no text says what each stage does, so none was added. Write one short, plain sentence per stage, in a Words table, drawn from DESIGN.md's stage descriptions. Show it in each band's hover and in the table row's tooltip.

- **Depends on:** 20261009-4.
- **Came from:** The build and review of 20261009-4, 2026-10-09.
- **Design:** report, burndown.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** df48e307 and 6d44e820, driver only. `StageSentences` gives each of the 16 burndown stages one sentence, checked against DESIGN.md and pinned word for word. It shows in each funnel band's hover and in each burndown row's `title`, and says "the rewrite" in the rewrites' index table.

### 20261009-20. index-dedupe: match predicates that differ only in implicit casts.

Found in the build of 20261009-19. `pg_get_indexdef` writes an existing index's predicate with Postgres's implicit casts, such as `context_type::text = 'Course'::text`. A candidate written without them (`context_type = 'Course'`) has different predicate text, so index-dedupe never sees that the existing index covers it. Realistic schemas use `varchar` and `text` columns, as in the user's report on 2026-10-09, so this hits real runs. One option is to let Postgres normalize the candidate's predicate. On the racetrack, create the candidate as a hypothetical index (or wrap it in an `EXPLAIN`), read the predicate back as Postgres deparses it, and then compare. Another is to strip casts to the column's own type on both sides through pg_query. Pick the safer of the two. Never drop a cast that changes meaning, such as one to a different type or collation. Test against real Postgres with `varchar` and `text` columns.

- **Depends on:** 20261009-19.
- **Came from:** The build of 20261009-19, 2026-10-09.
- **Design:** index-dedupe.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** f324e399 and 311bcdc7. `ImplicitCast` strips `::text` casts from an existing index's predicate, only for bare varchar or text columns of known type, compared with a text constant. It also rewrites `= ANY` to `IN` and `<> ALL` to `NOT IN`. Leftovers are in 20261009-21.

### 20261009-8. Suggest dropping an existing index that a new one makes truly redundant.

Asked for by the user on 2026-10-09. QUAACK only ever adds indexes. When a winning new index makes an existing index truly redundant, suggest dropping that one, and count its size against the verdict's Index Δ (20261009-7). One example is an existing index whose key columns are a leading prefix of the new one's, with the same predicate, no unique constraint, and nothing else depending on it. The user expects this to be rare. Suggest a drop only when the redundancy is certain. Never suggest one on a guess. This needs scoping first. Ask what counts as certain: constraints, unique indexes, indexes that other queries may use, and replica-only usage stats.

- **Decided (user, 2026-10-09):** (1) Redundant means a strict prefix only. The existing index has the same access method. Its key columns are a leading prefix of the new index's, in the same order, opclass, and collation. Its predicate is the same, or both have none. Its INCLUDE columns are all covered by the new index's keys or INCLUDE. It's non-unique and backs no constraint (PK, UNIQUE, EXCLUDE). It's not an expression index, unless the expressions match exactly. Implication between partial predicates is out. (2) Suggest the drop, never make it. Say plainly that other queries may use the index, and report its idx_scan count from production's pg_stat_user_indexes as a number (shape-class data), so the operator can judge. Index Δ subtracts the dropped index's size.
- **Depends on:** 20261009-7.
- **Came from:** The user, 2026-10-09.
- **Design:** index-dedupe, report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 96b9a9c2, df93d4d2, and 2708bea6. `RedundantIndexes` applies the user's strict-prefix rule. Each ranked label's `suggested_drops` carries name, size_bytes, and idx_scan, and `Protocol::SuggestedDrops` checks it in egress and in the driver. The report suggests drops, never makes them, and warns that other queries may use the index. The Index change nets out the dropped sizes. The looser `makes_redundant` column was removed. As with dedupe before 20261009-20, a cast in a partial predicate can make a match miss (the safe direction).

### 20261009-16. Report: a full dark theme.

Came from 20261009-11's review. The report has no dark theme. A partial one, with dark body text over sections left light, made the verdict, the tables, and the SQL blocks unreadable, so it was taken out. Move every hardcoded color in the template into CSS custom properties on `:root`, and redefine all of them under `@media (prefers-color-scheme: dark)`. That covers the verdict, the bug box, table heads, the baseline and differs rows, SQL blocks, notes, missing cells, borders, the query sections, and the funnel's text and palette. Check contrast for each, and look at the result in a browser.

- **Depends on:** 20261009-11.
- **Came from:** The review of 20261009-11, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** driver only. Moves every report color into 26 CSS variables on `:root`, each redefined under `prefers-color-scheme: dark`, including the funnel palette. Contrast is AA in both themes (computed from the hex values). Specs reject color literals and dark gaps. Not yet looked at in a browser.

### 20261009-18. Report: a rewrite's "relies on your data" caution reads twice when open.

From 20261009-13's review. The body's `p.warn` now repeats the whole summary warning, including "it relies on what your data holds today" and the pairing warning. The `p.empirical` paragraph right below it says the first of those again. In an open section, say each caution once.

- **Depends on:** 20261009-13.
- **Came from:** The review of 20261009-13, 2026-10-09.
- **Design:** report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 9066b08c, driver only. `Cautions#warning(body: true)` leaves out the data clause that `p.empirical` already states, and the summary warning stays whole. Minor, not filed: no spec covers every combination of cautions.

### 20261009-21. ImplicitCast: leftovers from 20261009-20.

- **Untested:** loosening `bare_text_const` keeps every spec green. Add a spec in which the constant's cast isn't plain text, such as `col::text = 'abc'::varchar(3)`, and the cast must stay.
- **Empty array:** `array_consts` accepts an empty `ARRAY[]` and would produce `IN ()`. Postgres prints `'{}'::text[]` instead, so this shouldn't happen in practice, but refuse it rather than emit invalid SQL.

- **Depends on:** 20261009-20.
- **Came from:** The review of 20261009-20, 2026-10-09.
- **Design:** index-dedupe.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** `array_consts` refuses an empty array, which used to crash pg_query's deparser. A `::name` constant spec pins `bare_text_const`. Minor, not filed: the empty-array spec's red was a segfault, not an assertion failure.

### 20260926-29. Remaining test-infrastructure unknowns.

- The 1216-failure run is still unexplained. Two guesses, neither confirmed: spec processes in different PID namespaces or sandboxes on the same hostname, where `kill(0)` returns ESRCH; or containers dying outside our code, such as a Docker Desktop restart or OOM. Watch for a repeat.
- A resumed run still restarts counterexamples at round 1 (from 20260926-25).

- **Needs a decision (asked 2026-10-09):** The restart is still true, but nothing can be double counted. The burndown records only when a rewrite is decided. Picking up at round N+1 would need each earlier round's inserts and feedback. Option (1): save them in the driver's provenance record (`~/.quaack/runs/<id>.llm.json`) and replay them through `fresh_message`. If the enclave's `rewrite_round_<n>` disagrees, restart at round 1. Option (2): drop the item as correct by design, since a resume loses at most three LLM asks per interrupted rewrite. Storing the inserts in the enclave is ruled out, because it would send LLM SQL back out. The main session leans toward (2), given cost first.
- **Depends on:** 20260926-21, 20260926-25.
- **Came from:** Build of 20260926-21 and -25.
- **Design:** counterexamples; CLAUDE.md Development.
- **Status:** done
- **Landed:** - **Dropped (user, 2026-10-09):** stale or covered, per the note above. Nothing was built.

### 20260926-49. Schema dump, clock anchoring and deparse items left over.

- An empty conninfo has no defined behavior in the schema dump, and no test.
- Restore LLM candidates by their anchored form, not by position. This is a large redesign.
- The subset DDL doesn't restore into an empty arena on its own (schemas, types, extensions), and a partitioned query table needs its parent in the dump.
- Table sort order for EUC_JP and WIN1252 databases.

- **Proposed drop (2026-10-09, awaiting the user):** Item 1 is stale, because the only caller always sets host. Item 2 is the large redesign: drop it, or reopen it as its own task if candidate SQL ever shows in the report. Item 3 is stale, because fixtures use the full dump and partitioned parents are refused. That leaves only a rare query on a leaf partition. Item 4 is real but rare (non-ASCII table names in EUC_JP or WIN1252 databases). Add an "unsupported in v1" note to DESIGN.md instead of building it.
- **Depends on:** 20260924-15, -22, -23.
- **Came from:** Build and review of those tasks.
- **Design:** schema-dump, clock-anchor, input.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Status:** done
- **Landed:** - **Dropped (user, 2026-10-09):** stale or covered, per the note above. Nothing was built.

### 20260926-55. Keyset and expression-unique leftovers.

- No pools for `=` or `<>` row comparisons, or rows built on expressions (listed as a v1 limit).
- Perturb-and-retry for colliding expression keys.
- A generated column counts as NULL when an expression key is worked out.

- **Proposed drop (2026-10-09, awaiting the user):** Item 1 is a documented v1 limit, pinned by vacuity_guard_postgres_spec.rb:60, and it marks the atoms untested. Item 2 is covered by the try-later-pool-values step, with the dropped groups counted (DESIGN.md:1193, :1426). Item 3 landed in 20260927-17 (f3598049).
- **Depends on:** 20260926-40, -44.
- **Came from:** Their build and review.
- **Design:** rewrite-test.
- **Trimmed (2026-09-29):** finished and note-only items removed. Git history has the full entry.
- **Landed so far:** 2026-10-08, task/20260927-17 (commit f3598049). A unique expression index that reads a generated column is now refused as `expression_unique_index`. Still open: perturb-and-retry, and the pools (a v1 limit).
- **Status:** done
- **Landed:** - **Dropped (user, 2026-10-09):** stale or covered, per the note above. Nothing was built.

### 20261003-11. `transitive_predicate_copy`: close test gaps, accept typmods, reach more columns.

Findings from the build and review of 20261002-7:

- **An untested soundness guard.** Equalities come only from the WHERE and inner-join ONs, which is right, but no test pins it. A mutation that also took equalities from outer-join ONs stayed green. Add `FROM posts p JOIN users u ON u.id = p.id LEFT JOIN accounts a ON p.account_id = u.account_id WHERE u.account_id IN (1,2)` and expect no rewrite.
- **`Catalog#default_btree?`'s `families.size == 1`** (catalog.rb ~146) survives being changed to `>= 1`. Test it, or accept it as untested.
- **Typmods block common Rails rewrites.** `Catalog::Info.type` comes from `format_type`, so `varchar(255) = varchar` and `numeric(10,2) = numeric(12,2)` are refused. Compare base types (`atttypid`) instead.
- **Enum, domain and array columns are refused,** since they have no default btree family of their own. Resolve the base type or the generic family (`anyenum`, `anyarray`) if it's safe.
- **Inner joins nested on an outer join's nullable side get no copies,** though copying within that nested inner join would be sound.

- **Depends on:** 20261002-7.
- **Came from:** The build and review of 20261002-7, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 79023b37. Columns are compared by base type, so typmods are ignored. Enums map to the `anyenum` btree opclass. A spec pins that outer-join ONs supply no equalities. Domain and array columns, the `families.size == 1` guard, and inner joins nested under an outer join stay refused (rare). Leftovers are in 20261009-22.

### 20261003-25. FK-cycle breaking: loose ends.

Minor findings from the build and review of 20261003-17:

- **One code path has no test.** No test has a nullable foreign key from a table in a cycle to a table outside it. If "this edge is in a cycle" is changed to "this table is in any cycle", every test stays green (`topology.rb:73`). Add that case.
- **A DEFAULT in a cut column stays DEFAULT.** If the default references a row that isn't loaded yet, the load fails. Load NULL there instead, or say in DESIGN.md that this case is unsupported.
- **Atoms on subquery or CTE columns aren't counted as reading a column.** They have no table. vacuity-guard keeps this safe, but check whether it ever refuses a query it shouldn't.
- **Partitioned tables with foreign keys may not load through the counterexample path.** The builder's attempt failed with `fixture_load_failed`. Reproduce it, and fix it or list it as unsupported.

- **Depends on:** 20261003-17.
- **Came from:** The build and review of 20261003-17, 2026-10-03.
- **Design:** rewrite-test, llm-counterexamples.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 5bcdcf90, spec and DESIGN.md only. Item 1: a spec pins that a nullable FK from a cycle table to an outside table stays uncut. Item 2: an "Unsupported in v1" note covers a DEFAULT in a cut column on the counterexample path (fails safe as insert_failed). Items 3 and 4 were stale: `read?` only orders cuts, and partitioned parents are refused at qualify.

### 20261009-23. Suggested drops miss partial indexes on varchar columns.

Found by the Opus review of the 0.1.29 batch, 2026-10-09. `RedundantIndexes#existing` calls `IndexCandidate.from_indexdef(entry["definition"])` without `types:`. That leaves the `::text` casts on an existing index's predicate, which then never equals a new candidate's. So on Canvas-style tables, where `workflow_state` and similar columns are varchar, no drop is ever suggested for a partial index. That's a missed drop, never a wrong one. Pass the table's `column_types` through, the way `planner_statistics.rb` does. Also, `ImplicitCast.strip_comparison` only strips when the column is on the left, so `'x'::text = (col)::text` keeps its casts. Handle the constant-on-the-left form too, if Postgres ever prints it that way for an index predicate. Check that first. Test against real Postgres with a varchar partial index.

- **Depends on:** 20261009-8, 20261009-20.
- **Came from:** The Opus review of 0.1.29, 2026-10-09.
- **Design:** index-dedupe, report.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** ba6088fd. `RedundantIndexes` passes each table's `column_types` to `from_indexdef`, so varchar partial indexes match. `ImplicitCast` strips the constant-on-left form too, keeping operand order. Leftovers are in 20261009-24.

### 20261009-22. `transitive_predicate_copy`: leftovers from 20261003-11.

- **Doc page:** `docs/transforms/transitive_predicate_copy.md` still says "differ in type". Say that typmods are ignored and enums are accepted.
- **Untested:** an enum against text, or two different enum types, must still be refused. Add a spec. A `bpchar(n)` against `bpchar(m)` pair with trailing spaces is untested too. Add one, or refuse bpchar pairs.

- **Depends on:** 20261003-11.
- **Came from:** The review of 20261003-11, 2026-10-09.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 9b2f7e0e, spec and doc only. The doc page now matches the base-type and enum rule. New specs refuse enum vs text and two different enums. A bpchar(3) vs bpchar(5) copy is shown sound on real Postgres.

### 20261009-24. Pin that operand order matters in predicate matching.

From the Opus review of 20261009-23. Nothing commutes the sides of a comparison, so `'a' < ws` never equals `ws < 'a'`, but no test pins it. Add specs: an existing `'deleted' <> ws` against a candidate `ws <> 'deleted'`, and `'a' < ws` against `ws < 'a'`. Each pair must not match in dedupe or in RedundantIndexes. (A later normalization that commutes `=` and `<>` would be safe, but it must flip `<` and `>` correctly.)

- **Depends on:** 20261009-23.
- **Came from:** The Opus review of 20261009-23, 2026-10-09.
- **Design:** index-dedupe.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** d717f933, spec only. Operand order is pinned in dedupe and RedundantIndexes for `<>` and `<`.

### 20261003-14. `cte_hoist_dedupe`: build-time loose ends.

Out-of-scope findings from the build of 20261002-8:

- **Untyped body placeholders are treated as text.** If Postgres can't infer a placeholder's type in a CTE body, `self_contained?` prepares it as text. Some bodies may then be refused, or matched, for the wrong reason. Check whether this costs real rewrites.
- **Unqualified table names resolve with the catalog connection's `search_path`.** If that differs from the app's, the rule could judge a body against the wrong table. Pin the search_path, or refuse unqualified names when it's ambiguous.
- **Some older refusal tests in the rule spec have no positive control.** Mutation testing shows they aren't vacuous, but a positive twin for each would make that obvious.

- **Depends on:** 20261002-8.
- **Came from:** The build of 20261002-8, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** spec only. Six positive controls, each paired with a refusal test. Item 1 was stale: placeholders are prepared as unknown, and their type can't change name resolution. Item 2 was stale: rules run on `qualified_query`, so tables are already schema-qualified.

### 20261003-26. `union_outer_filter_removal`: widenings, and duplicate candidates.

From the build of 20261002-9:

- **Widen the rule where it's sound.** It now refuses:
  - arms whose output columns come from a CTE or subquery, since the catalog gives no types for them;
  - arms whose column types differ harmlessly, such as `int` and `bigint`;
  - unqualified columns, column aliases, and correlated subqueries in conjuncts.
  
  Widen each only with a soundness argument and a real-Postgres test.
- **The same rewrite can come out twice.** The rule can fire both before and after `cte_hoist_dedupe`, so the candidate list may hold the same SQL reached by different rule orders. Drop candidates whose SQL matches one already listed.

- **Depends on:** 20261002-9.
- **Came from:** The build of 20261002-9, 2026-10-03.
- **Design:** rewrite-rules.
- **Status:** done
- **Landed:** - **Dropped (2026-10-09):** Nothing was built. Duplicates are already dropped: `RewriteRules.chained` keeps a shared `seen` set and counts each duplicate under its rule, with specs. Widening to int/bigint arms isn't simply sound, because arithmetic in a conjunct can overflow on int where the bigint copy doesn't, so the rule keeps refusing. The other widenings are rare and stay refused in v1.

### 20261003-32. rewrite-test: loads that fail on `IS NULL` and skipped groups.

These were found in the second review of 20261003-23, and they fail safe (the load fails, so the rewrite is refused):

- **`IS NULL` on a nullable FK column fails the load.** The NULL goes into the parent primary key's class. Seen on an acyclic schema.
- **A group that skips leaves orphaned copies.** This is 20261003-30's mechanism in an acyclic schema: `courses JOIN accounts LEFT JOIN templates t … WHERE t.id IS NULL`. 20261003-30 may fix it in general. If so, add a test here and close this task.
- **An anti-join on a cut edge itself** fails the load for every candidate. Recheck it after 20261003-30.

- **Depends on:** 20261003-30.
- **Came from:** The second review of 20261003-23, 2026-10-03.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 316ba2fe and 44042a9b. In `Builder#bound_value`, a NOT NULL key-class member whose atom picks NULL takes the class key instead, so only the child FK holds NULL. Items 2 and 3 were already fixed by 20261003-30, and regression specs were added for them. Opus review: sound, and the IS NULL atom is exercised both ways (the dropped-filter rewrite is disproved by row_count). Minor and not filed: the `:skip` path in the new branch is untested.

### 20261003-35. `distinct_join_to_exists`: loose ends from 20261002-16.

These are minor findings from building and reviewing 20261002-16:

- **`catalog/calls.rb` matches a function by name only, across schemas.** A user function in another schema with the same name as a known-safe one is treated as safe. Match on the schema too, or refuse when the name is ambiguous.
- **A bare key column in ORDER BY under LIMIT is refused.** Rails often sends `ORDER BY id LIMIT n`. It's safe when the key is the outer table's unique key, so allow it.
- **The rule's description string is stale.** It no longer says what the rule matches.
- **The cache key test is weak.** Make it fail if the cache key drops an input.
- **The `x.*` check needs a test** that goes red if the check is removed.
- **A nondeterministic-collation key with a `COLLATE "C"` unique index** (pre-existing). `DISTINCT` folds `Ann` and `ann` together, but the unique index lets both rows exist, so dropping `DISTINCT` changes the result. Refuse when the key's collation is nondeterministic and differs from the unique index's.

- **Depends on:** 20261002-16.
- **Came from:** The build and review of 20261002-16, 2026-10-03.
- **Design:** rewrite-rules, `distinct_join_to_exists`.
- **Note (2026-10-07):** the nondeterministic-collation key with a `COLLATE "C"` index is covered by 20261002-4's shared unique check (`assumption_check/index_equality.rb`).
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** f46ba899 and 357afdd6. A bare `ORDER BY <key>` is now accepted, with or without LIMIT, when every output of that name is the kept table's column (`order_by.rb`). The description is fixed. New tests cover the cache key, `x.*`, and collation. The function-schema and nondeterministic-collation items were already handled. Opus review: sound.

### 20261003-37. rewrite-test values: loose ends from 20261003-34.

These are minor findings from building and reviewing 20261003-34:

- **A base table aliased with a column list** (`reads.rb` `Tables#add` and `qualifier`). In `FROM fx.customers c(id, name, status)`, `c.status` reads `customers.lsn`, but `Reads` treats `lsn` as unread and fills it with NULL. Fix: treat an alias with a column list as reading every column of its table.
- **ParentRows' self-FK fix depends on foreign-key order** (`parent_rows.rb` `foreign_keys`). The `next if` skip looks only at `fixed`, not at `pairs`.
  - Example: `code NOT NULL UNIQUE`, a self-FK `root_code → code`, and an FK `code → regions`. When the self-FK comes first, the second FK overwrites `code`, and the load fails.
  - No test covers the other order, so the mutation `fixed.merge(pairs)` → `fixed` survives.
  - The same skip lets a later FK overwrite a NULL that an earlier nullable FK set.
- **Three-part column references resolve by their table part only** in `Reads`, ignoring the schema.

- **Depends on:** 20261003-34.
- **Came from:** The build and review of 20261003-34, 2026-10-03.
- **Design:** rewrite-test.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 91985ce2 and 1ef53296. ParentRows' new `share` lets a second NOT NULL FK on a column reuse the first one's value, with a parent row that holds it. That also fixes the self-FK-order load failure. `Reads` treats a column-list alias as reading every column. Three-part refs are left alone (no realistic wrong fixture). Minor and not filed: a partly overlapping composite FK can still fail loudly.

### 20261004-3. Tighten 20261003-38's SQLSTATE filtering.

The review of 20261003-38 found four minor issues:
- Class 42 includes 42501, a permission error. It isn't caused by the value, so it probably shouldn't count as `bad_value`.
- A value can cause a P0001 (raised by a trigger or function) or 54000 (program limit) error. These now fail the whole step as `internal_error`, when they should count as `bad_value`.
- The re-raised PG::Error still carries the value in its message. Only ErrorFilter keeps it from leaving the enclave. Wrap it with `cause: nil` and a message that carries only the sqlstate.
- The timeout and termination tests check weakly that the value is absent. Make them use a sentinel value and assert that it never appears in the output.

- **Depends on:** 20261003-38.
- **Came from:** The review of 20261003-38.
- **Design:** rewrite-test, ErrorFilter.
- **Status:** done
- **Landed:** - **Landed (2026-10-09):** 15a828af. P0001 and 54000 are bad_value, and 42501 isn't. Other PG errors are re-raised as `Redaction::Error(:internal_error, sqlstate)` with `cause: nil`. The timeout and termination sentinel tests check the whole error chain. Leftover in 20261009-25.
