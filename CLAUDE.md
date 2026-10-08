# QUAACK.

DESIGN.md is the design. BACKLOG.md holds the work that's left. BACKLOG-COMPLETE.md holds the work that's done.

## Language and tools.

- Write QUAACK in Ruby. Use the pg_query gem for all SQL parsing, deparsing, and tree walking.
- Use Docker for anything that needs Postgres, including tests. The test suite starts its own throwaway Postgres containers with HypoPG. It never uses a shared or long-lived database.

## Development.

- Use Ruby 3.4. Homebrew's `ruby@3.4` is keg-only, and the system Ruby on PATH is 3.1, so put 3.4 first on PATH for every command:

  `PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec rake`

- There's no hosted CI. Run that per-commit check before landing anything. It runs RuboCop and every spec suite, but keeps the recorded pipeline replay to the planted runs, the `key_in_self_join` rule run, and the first recorded run of the first model for each prompt-pack query.
- Run `PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec rake full` when a task bumps any gem `VERSION` in `protocol/lib/quaack/protocol/version.rb`, `driver/lib/quaack/driver/version.rb`, or `enclave/lib/quaack/enclave/version.rb`. It runs everything the per-commit check runs, plus every recorded pipeline replay variant, and writes `spec/fixtures/full_replay_versions.json` when it passes. Commit that stamp with the version bump; the per-commit check fails and says to run `rake full` when the current versions don't match the stamp. Run `rake full` on its own: it refuses to run after `spec` or `default` in the same rake command, since Rake wouldn't run the specs again.
- Version bumps go in batches (decided by the user, 2026-10-07). A task that changes enclave or protocol behavior doesn't bump a `VERSION` itself. It lands after the per-commit check, and its ID goes on the "Unreleased enclave changes" list at the top of BACKLOG.md. One commit then closes the batch: it bumps all three gems together, passes `rake full`, commits the stamp, and empties the list. While the list isn't empty, `main` isn't deployable, because the driver and the enclave report the same version but the enclave code has changed. Close the batch before anyone deploys from `main`.
- The jump servers are ARM (`aarch64-linux`), like the development Macs. Nothing needs to support x86_64.
- Both commands run every spec suite in its own process, from its own directory, all at the same time, so a run takes about as long as the slowest suite. Each suite's output is held until it finishes, then printed whole under a header that names the suite, says whether it passed, and gives its wall time. The suites are the cross-gem specs in the root `spec/`, plus each top-level directory other than `vendor/` that has a `spec/` folder: today that's `protocol/`, `enclave/`, and `driver/`. The `Rakefile` finds them, so a new gem's specs run without being listed anywhere. Every suite runs even after one fails. The run fails if any suite fails, if a suite runs no examples, or if the root `spec/` suite didn't run.
- Run `bundle install` first on a fresh checkout. The committed `.bundle/config` installs gems into `vendor/bundle`, never globally.
- Docker must be running for both commands. Specs that need Postgres fail, not skip, without it. `spec/support/test_postgres.rb` builds a Postgres 18 image with HypoPG from `spec/support/postgres/Dockerfile`, starts one container per spec process, and removes it at exit. To use it from a suite, see the comment at the top of that file. A container left by a crashed run carries the label `quaack.test-postgres`, and the next run removes it.
- Both commands also need a pg_dump of the test server's major version (the one in `spec/support/postgres/Dockerfile`'s `FROM` line), since the replay specs run `quaacks schema-dump`, and pg_dump refuses a newer server. `spec/support/test_pg_dump.rb` looks for it first in the directory `QUAACK_TEST_PG_BIN` names, if that's set, then in Homebrew's libpq keg (`/opt/homebrew/opt/libpq/bin`). It puts that directory first on PATH only for the `quaacks` children it starts, not for your shell. If it finds none, every spec that runs `quaacks` fails, saying what to install or set; `spec/pipeline_replay_spec.rb` and `spec/pipeline_scenario_refusal_spec.rb` each fail as one example, not one per run. If it skips a `QUAACK_TEST_PG_BIN` that holds pg_dump of another major, it says so on stderr. `brew install libpq` gives the keg, when libpq's current major is the server's.
- The `pg` gem ships prebuilt for `arm64-darwin` and `aarch64-linux` with libpq bundled, so it needs no Homebrew libpq. It's a runtime dependency of the enclave gem (`quaacks`), and it's on `Boundary::ENCLAVE_ALLOWED_GEMS`.
- The repo holds three gems, all in one root `Gemfile`: `protocol/` holds `quaack-protocol` (shared), `enclave/` holds `quaacks` (the enclave script, which runs on the jump server), and `driver/` holds `quaack-driver` (its executable is `quaack`). The enclave gem must never depend on the driver gem or an LLM SDK. The driver must never load the enclave gem. Four specs enforce this:
  - `spec/boundary_spec.rb` holds the static checks. The enclave's dependencies must exactly match the allowlist `Boundary::ENCLAVE_ALLOWED_GEMS` in `spec/support/boundary.rb`, so a new dependency fails until you review it and add it there. It also scans each gem's source for requires of the other side or an LLM SDK, even in code that never runs. For the enclave and protocol gems, it also flags requires that leave the gem or whose path isn't a plain string. It ignores `send`, `define_method`, `eval`, and the like, so ordinary metaprogramming is fine.
  - `spec/runtime_boundary_spec.rb` installs each side outside Bundler, runs it, requires every file of each repo gem it ships, builds a client for each LLM provider that needs an SDK on the driver side (which loads each LLM SDK only then), and checks that nothing it loads comes from outside the standard library and its allowed gems (the same allowlist, for the enclave) or from the other side (or, for the enclave, an LLM SDK). It guards against honest mistakes, not deliberate evasion. `spec/support/runtime_boundary.rb` says what it covers and what it can't catch.
  - `spec/boundary_checker_spec.rb` and `spec/runtime_boundary_checker_spec.rb` prove the static and runtime checks catch planted violations.
- If you add an LLM SDK that isn't listed in `spec/support/boundary.rb`, add the name it's required as to `LLM_SDK_REQUIRES` there. Both checks use that list.

## Backlog.

- Work on one backlog task at a time. Don't start building the next task until the current one has landed or been set aside. Having several tasks in flight at once invites conflicting work.
- Clarifying questions are the exception: ask them for any task at any time. If the code or design changes before the task starts, check whether the answers still hold, and ask again if they might not.
- Pick up work from BACKLOG.md. Before starting a task, check that everything it depends on is done.
- Also check that the task still needs doing. Earlier work, a changed design, or a new task may have already covered it or made it wrong. If it's stale, say so and propose updating it or dropping it instead of building it.
- If a task looks hard but would get much easier with a small change to a requirement, ask the user before doing the hard version. Say what the change is, what it would save, and what it would give up.
- When a task is done, move its full entry to BACKLOG-COMPLETE.md and set its status to `done`. Leave a one-line stub in BACKLOG.md in its place, like this:

  `### 20260922-1. Project skeleton. Done, see BACKLOG-COMPLETE.md.`

  The stub keeps the ID visible, so dependency lines still make sense and nobody opens the task again by mistake. Keeping full entries out of BACKLOG.md also keeps it small, so it costs fewer tokens to read.
- Never work on a task that's in BACKLOG-COMPLETE.md. If a finished task needs more work, add a new task to BACKLOG.md and point to the old ID.
- New tasks get an ID made of the date they're added and the next unused number for that date, such as `20260923-1`. Never reuse an ID.

## How a backlog task gets built.

1. **Clarify first.** Before any agent starts, the main session asks the user the task's open questions and anything else it needs answered. Subagents can't ask the user, so the builder's brief has to include the answers.
2. **Build.** Launch a builder agent in its own git worktree. Give it the task entry, the answers, and the rules in this file. If the builder hits something much harder than expected, or finds the task is stale, it stops and reports back instead of pushing through. The main session then takes the question to the user.
3. **Review.** Launch a separate reviewer agent with a fresh context. It gets the task entry, the diff, and this file, but not the builder's reasoning. Its job is adversarial: find what's wrong. It must check that:
   - Each test failed for the right reason before the code made it pass.
   - No test is vacuous. It breaks the code on purpose and confirms the tests go red.
   - Nothing crosses the trust boundary that shouldn't.
   - The work does what the task and DESIGN.md say.

   Keep the review scoped. Test realistic queries and setups, the ordinary SELECTs that apps and ORMs generate, and mutation-test only the task's own diff. Don't fuzz open-ended, and don't hunt through exotic encodings or setups. Label each finding **blocking** or **minor**. Blocking means a trust-boundary leak, a vacuous test, or a correctness bug on a realistic, supported case. A problem that only shows up with rare SQL or an unusual setup is minor. The fix for it is a clean refusal, listed in DESIGN.md as unsupported in v1.
4. **Fix once.** Send the blocking findings back to the same builder, so it keeps its context. It gets one more try. Minor findings go straight to BACKLOG.md as new tasks, not into the fix round. If the review has no blocking findings, there's nothing to fix: skip step 5 and land.
5. **Review again.** After a fix round, run a second review with a fresh reviewer agent.
6. **Land.** Landing means merging the task's branch into `main` locally with `git merge --no-ff`. There are no pull requests. Never squash. A squash drops the branch's history, and git then can't tell the branch was merged, so the safe `git branch -d` refuses to delete it. If the branch has a problem, such as commits missing the attribution trailer, send it back to the builder to fix on its branch before landing. Run `rake full` before landing only when the task bumps a gem `VERSION`; otherwise run the per-commit check. If the first review had no blocking findings, or the second review is clean, land the work. If the second review still has findings:
   - Land the parts that are sound.
   - Never land code with an unresolved trust-boundary or correctness finding, or with a vacuous test. A test is vacuous if it stays green when the behavior it names is broken.
   - If the second review finds vacuous tests, the builder gets one more round that fixes only those tests. A fresh reviewer then checks just those tests, by breaking the code they cover and confirming they go red. Any test that's still vacuous after that keeps its code from landing, along with the code it was meant to cover.
   - Add a new BACKLOG.md task for each finding that's left, pointing back to the original task ID.
   - If a task can't be finished within this loop, split it up. Land the pieces that passed review, and make new tasks for the rest. Each new task gets its own full loop.
   The original task moves to BACKLOG-COMPLETE.md only if what landed covers it. Otherwise it stays open, with a note saying what landed.
   Once the work is committed to `main`, remove the task's worktree and delete its branch. Don't leave finished worktrees lying around.
7. **Record.** Findings that are real but out of the task's scope become new backlog tasks at any round, not just the last one.

Every agent keeps its temporary files in its own subdirectory of the scratchpad, named for its role and task, such as `build-20260922-2/` or `review-20260923-11-r2/`. Several agents often run at once, so a file at the top of the scratchpad can get overwritten by another agent without warning. Never edit or delete another agent's scratch files.

## Test-driven development.

Every change follows red, then green:

1. Write a test for the behavior first.
2. Run it and watch it fail. It has to fail because the behavior is missing, not because of a typo, a missing file, a load error, or a broken fixture. Check that the failure message is the one the test's assertion should produce.
3. Write the smallest change that makes the test pass.
4. Run it again and watch it pass.

Don't write production code without a failing test that needs it. That includes bug fixes: first write a test that reproduces the bug.

### Tests must not be vacuous.

A test that passes whether or not the code works proves nothing. Guard against that:

- Every test makes a specific assertion about output or behavior. "It didn't raise" isn't enough unless raising is exactly what's being tested.
- Don't mock or stub the code under test. Only fake things at the edges, such as the LLM client or ssh.
- After a test goes green, break the code on purpose (flip a condition, drop a line, or return a constant) and confirm the test goes red. Then put the code back.
- For trust-boundary code, test with sentinel values and assert that they never show up in enclave output. Also test that the check catches a sentinel when one is planted, so we know the check itself works.
- Tests that need a database run against real Postgres in Docker, not a mocked connection.
