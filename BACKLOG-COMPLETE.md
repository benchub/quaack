# QUAACK completed backlog.

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
