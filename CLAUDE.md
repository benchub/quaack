# QUAACK.

README.md is the design. BACKLOG.md holds the work that's left. BACKLOG-COMPLETE.md holds the work that's done.

## Language and tools.

- Write QUAACK in Ruby. Use the pg_query gem for all SQL parsing, deparsing, and tree walking.
- Use Docker for anything that needs Postgres, including tests. The test suite starts its own throwaway Postgres containers with HypoPG. It never uses a shared or long-lived database.

## Development.

- Use Ruby 3.4. Homebrew's `ruby@3.4` is keg-only, and the system Ruby on PATH is 3.1, so put 3.4 first on PATH for every command:

  `PATH=/opt/homebrew/opt/ruby@3.4/bin:$PATH bundle exec rake`

- That one command runs RuboCop and then every spec suite. Each suite runs in its own process: `protocol/spec`, `enclave/spec`, `driver/spec`, and the cross-gem specs in `spec/`.
- Run `bundle install` first on a fresh checkout. The committed `.bundle/config` installs gems into `vendor/bundle`, never globally.
- The repo holds three gems, `protocol/` (shared), `enclave/`, and `driver/`, all in one root `Gemfile`. The enclave gem must never depend on the driver gem or an LLM SDK. The driver must never load the enclave gem. `spec/boundary_spec.rb` enforces both rules, and `spec/boundary_checker_spec.rb` proves the checker catches planted violations. If you add an LLM SDK that isn't listed in `spec/support/boundary.rb`, add it there.

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
   - The work does what the task and README say.
4. **Fix once.** Send the review findings back to the same builder, so it keeps its context. It gets one more try.
5. **Review again.** Run a second review with a fresh reviewer agent.
6. **Land.** Landing means merging the task's branch into `main` locally. There are no pull requests. If the second review is clean, land the work. If it still has findings:
   - Land the parts that are sound.
   - Never land code with an unresolved trust-boundary or correctness finding.
   - Add a new BACKLOG.md task for each finding that's left, pointing back to the original task ID.
   The original task moves to BACKLOG-COMPLETE.md only if what landed covers it. Otherwise it stays open, with a note saying what landed.
7. **Record.** Findings that are real but out of the task's scope become new backlog tasks at any round, not just the last one.

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
