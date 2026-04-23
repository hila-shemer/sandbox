
---

## Test Harness Contract

The repo must contain an executable `run_tests.sh` at the root that runs the
full test suite and writes its results to `test_results.txt`. The ralph
harness invokes this script to give the planner and reviewer a real view of
test state.

**If `run_tests.sh` does not exist**, creating it is part of this iteration's
work. Pick whatever test command is appropriate for the project (e.g.,
`./gradlew test` for Android, `pytest` for Python) and wrap it so that:

- Full output is captured to `test_results.txt` (overwrite, not append).
- The script exits 0 iff all tests pass, non-zero otherwise.
- The script is self-contained and idempotent — runnable from a fresh shell.

**If `run_tests.sh` exists but does not cover new tests you added**, update
it. New test files, new test directories, or new test runners all need to be
reachable from the script. It is not acceptable to add tests that the script
misses.

Log the script's purpose and test command in `DECISIONS.md` under a "Test
Harness" heading on first creation, and update that entry if the command
changes.

Do not write to `test_results.txt` directly from your implementation work.
That file is an output of `run_tests.sh` only.

## Running Tests — Use the Haiku Sub-Agent

When you want to check whether tests pass, **do not run `./run_tests.sh`
inline** in your own context. Instead, invoke the `test-runner` sub-agent
(Haiku) via the Agent tool. It runs the script and returns a short summary,
which is both cheaper and keeps bulk test output out of your context.

- Use it after any non-trivial code change and before declaring `TASK_DONE`.
- If the agent is missing (check `~/.claude/agents/test-runner.md`), you may
  create one — keep it narrow: run the script, summarize the output, never
  modify code. A template version ships with ralph; feel free to tune its
  description or instructions if the project needs something more specific.
- Authoring and debugging tests stays with you. The agent is for *running*
  only.

## Reminders

- Build incrementally. A working partial implementation committed is better than
  an ambitious broken one. It's fine to end an iteration mid-flight — leave a
  clear note in STATUS.md so the next iteration can orient quickly.
- Read the actual source files and git log to understand current state. Don't
  rely solely on STATUS.md for code details.
- Run tests after non-trivial changes. If they fail and you can't fix it this
  iteration, note the broken state clearly in STATUS.md.
- Do not refactor speculatively. Implement what the specification says.
- If the spec is ambiguous, make a reasonable decision, implement it, and record
  it in DECISIONS.md.
- If an approach fails, record it in PROBLEMS.md before trying something else.
- Keep commits atomic and descriptive.
- You have limited context. Prioritize finishing one coherent piece of work over
  starting many things.
