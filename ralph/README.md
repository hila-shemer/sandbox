# Ralph — Autonomous Implementation Loop

A three-role harness for autonomous coding with Claude. Sonnet plans and
executes; Opus is called periodically as a stronger outside eye to catch
drift. Named after Ralph Wiggum for reasons that presumably made sense at
the time.

## Quick Start

```bash
# ── Option A: simple task (bug fix, single feature, port) ──────────────
# Sonnet reads the codebase and generates a focused plan from a one-liner.
ralph-init-simple.sh "add dark mode toggle to settings screen"
# → implementation_plan.md

# ── Option B: complex project (new app, multi-phase rewrite) ───────────
# Step 1: use description_prompt.md as a Claude sub-agent to interview you
#         and produce a detailed project_description.md.
# Step 2: generate a full implementation plan (uses Opus):
ralph-init.sh project_description.md
# → implementation_plan.md

# ── Run the loop ───────────────────────────────────────────────────────
./ralph.sh implementation_plan.md

# Or skip the reviewer and run Sonnet solo (cheaper, fine for simple tasks):
./ralph.sh implementation_plan.md --sonnet-only

# Resume an interrupted hierarchical run:
./ralph.sh implementation_plan.md --resume
```

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  ralph.sh                                                  │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ OUTER LOOP: Planner (Sonnet)                         │  │
│  │                                                      │  │
│  │  • Reads plan + memory files + git log + real code   │  │
│  │  • Verifies executor's previous work (reads files!)  │  │
│  │  • Writes CURRENT_TASK.md for next slice             │  │
│  │  • Exits on COMPLETE or BLOCKED                      │  │
│  │                                                      │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │ INNER LOOP: Executor (Sonnet, ≤8 iters)       │  │  │
│  │  │                                                │  │  │
│  │  │  • Reads CURRENT_TASK.md + memory files        │  │  │
│  │  │  • Implements, commits, runs test-runner agent │  │  │
│  │  │  • Updates memory files                        │  │  │
│  │  │  • Exits on TASK_DONE / BLOCKED / max iters    │  │  │
│  │  │                                                │  │  │
│  │  │  ┌──────────────────────────────────────────┐  │  │  │
│  │  │  │ PERIODIC: Reviewer (Opus, Mode A)        │  │  │  │
│  │  │  │  Every REVIEW_INTERVAL iters, or on      │  │  │  │
│  │  │  │  BLOCKED. Mid-task drift check.          │  │  │  │
│  │  │  └──────────────────────────────────────────┘  │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  │                                                      │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │ PERIODIC: Reviewer (Opus, Mode B)             │  │  │
│  │  │  Every OUTER_REVIEW_INTERVAL planner cycles.   │  │  │
│  │  │  Reviews the last N cycles as a window. Main   │  │  │
│  │  │  defense against Sonnet-planner drift.         │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  │                                                      │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │ ON EXIT: Exit Gate (Opus)                     │  │  │
│  │  │  Every DONE/COMPLETE/BLOCKED claim before the  │  │  │
│  │  │  loop exits. Verifies the claim against the    │  │  │
│  │  │  plan and real code; on rejection rewrites     │  │  │
│  │  │  STATUS.md to non-terminal so the loop         │  │  │
│  │  │  continues. Guards against premature exits.    │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### Four Roles

**Planner (Sonnet)** — called between task slices. Sees the full plan, all
memory files, and the git log. Crucially, it also **reads the actual
filesystem** to verify the executor's work against its claims in STATUS.md.
Writes the next CURRENT_TASK.md or declares the project complete.

**Executor (Sonnet)** — the workhorse. Reads CURRENT_TASK.md and the memory
files, implements code, commits, and runs tests via the `test-runner` Haiku
sub-agent. Doesn't need to see the full plan. Doesn't need to reason about
big-picture progress — just executes the current slice.

**Reviewer (Opus)** — called periodically in two modes:
  - *Mode A (mid-task)*: inside the executor's inner loop, every N executor
    iterations or when the executor hits BLOCKED. Catches drift within a
    single task slice. In practice rarely fires because Sonnet usually
    finishes a slice in one iteration — kept as backup.
  - *Mode B (outer-cycle)*: between planner cycles, every N planner cycles.
    Reviews the work of the last N cycles collectively — the primary defense
    against a cheaper Sonnet planner silently drifting off-course across
    multiple cycles.

In both modes Opus doesn't write new tasks; it diagnoses problems and leaves
guidance in the memory files. Can make small targeted fixes (a config typo,
a missing import) but doesn't do real implementation.

**Exit Gate (Opus)** — called every time the planner or executor claims a
terminal status (DONE, COMPLETE, or BLOCKED), before the loop actually exits.
Reads the implementation plan, memory files, and real source code to verify
the claim. Outputs `GATE: CONFIRMED` or `GATE: REJECTED`. On rejection, it
rewrites STATUS.md (and the first line of CURRENT_TASK.md if needed) to a
non-terminal state so the next planner cycle continues. This guards against
the common failure mode of Sonnet writing `DONE` when it only finished a
sub-task, or declaring `BLOCKED` on a problem it could have solved.

### Why a Separate Reviewer?

Sonnet catches obvious blockers but misses subtle drift — working confidently
in the wrong direction. The periodic reviewer catches drift mechanically,
without depending on Sonnet's self-awareness, and uses a stronger model so
its verdicts carry more weight than Sonnet second-guessing itself.

The reviewer is also the mechanism for unblocking: when Sonnet writes BLOCKED,
the reviewer diagnoses the issue, writes guidance into DECISIONS.md/PROBLEMS.md,
rewrites STATUS.md with a path forward, and the inner loop continues.

## Files

```
ralph.sh                — main orchestrator
ralph-init.sh           — generates implementation_plan.md from a spec file
                          (uses Opus; suited for complex/multi-phase projects)
ralph-init-simple.sh    — generates implementation_plan.md from a brief task
                          description string or file (uses Sonnet; suited for
                          bug fixes, single features, small ports)
sonnet_prefix.md        — execution prompt prefix (prepended to task spec)
sonnet_suffix.md        — execution reminders (appended after task spec)
planner.md              — planner prompt: reviews work, writes next task
reviewer.md             — reviewer prompt: mid-task + outer-cycle diagnosis
exit_gate.md            — exit gate prompt: terminal-status verification before loop exit
plan_prompt.md          — full plan template used by ralph-init.sh; asks Opus
                          for phases, dependencies, success criteria, risk flags,
                          and testing strategy
simple_plan_prompt.md   — leaner plan template used by ralph-init-simple.sh;
                          tells Sonnet to read the codebase first, then produce
                          a proportionate plan (1–3 phases for most tasks)
description_prompt.md   — Claude sub-agent prompt for the complex flow. Use it
                          as a sub-agent (via /agents or the Agents panel) to
                          interview you about your project and produce a
                          project_description.md for ralph-init.sh. Covers:
                          constraints, interfaces, functional requirements,
                          out-of-scope items, starting state, risks, and
                          definition of done.
agents/                 — sub-agent definitions shipped with ralph (e.g.
                          test-runner.md, a Haiku agent the executor uses
                          to run ./run_tests.sh without bloating its context)
```

## Memory Files (created at runtime in the project directory)

```
STATUS.md           — current state, rewritten each iteration
DECISIONS.md        — append-only log of architectural decisions
PROBLEMS.md         — append-only log of failed approaches
CURRENT_TASK.md     — the active task Sonnet is working on (written by planner)
```

### Test Harness

The executor maintains `run_tests.sh` — a project-specific script that runs
the test suite and writes results to `test_results.txt`. The harness invokes
this script between iterations so the planner and reviewer always see fresh
test state. You do not need to write this script; Sonnet creates it on the
first iteration that adds testable code and keeps it current as new tests
land.

When the executor wants to check whether tests pass, it invokes the
`test-runner` Haiku sub-agent (shipped in `ralph/agents/test-runner.md`) via
the Agent tool rather than running the script inline. This keeps bulk test
output out of the executor's context and runs the check on a cheaper model.
The agent is installed into `~/.claude/agents/` the first time the container
starts; tweaks survive restarts (the sandbox entrypoint doesn't overwrite an
existing agent file).

## Modes

### Hierarchical (default): `./ralph.sh plan.md`

Planner → Executor (with periodic reviews) → Planner → repeat. Best for
complex or multi-day projects.

### Flat: `./ralph.sh plan.md --sonnet-only`

Sonnet reads the full plan directly and loops until DONE or BLOCKED. Cheaper,
simpler, fine for well-scoped projects.

## Resuming an Interrupted Run

If a hierarchical run is killed mid-phase, re-run with `--resume`:

    ./ralph.sh implementation_plan.md --resume

`--resume` is not supported with `--sonnet-only`.

### How it works

On every run (resume or not) ralph writes a phase marker to `.ralph/phase`
immediately before each phase begins:

| Value              | Meaning                                                   |
|--------------------|-----------------------------------------------------------|
| `planner-pending`  | Planner call in flight (or about to start)                |
| `executor-pending` | Planner finished; executor not yet run or still running   |
| `between-cycles`   | Executor returned; outer review or next planner up next   |
| `idle`             | Clean termination (COMPLETE / BLOCKED / max cycles hit)   |

On `--resume`, ralph reads the marker, cross-checks against `CURRENT_TASK.md`
and `STATUS.md`, and re-enters at the right phase:

- `planner-pending` → re-run the planner
- `executor-pending` + non-terminal `CURRENT_TASK.md` → skip planner, re-run executor
- `between-cycles` + `STATUS.md` present → start next planner cycle
- `idle` → start a fresh planner cycle
- Marker missing or inconsistent → ask Opus (via `resume.md`) to classify

### Safety checks

1. **Clean working tree.** `git status --porcelain --untracked-files=no` must be
   empty. Untracked files are tolerated; modified tracked files are not.
   Commit or stash before re-running.

2. **Terminal task short-circuit.** If `CURRENT_TASK.md`'s first line is
   `COMPLETE` or `BLOCKED`, resume exits immediately (0 or 1 respectively)
   without making any LLM call. A BLOCKED exit means the original run ended
   stuck — edit or delete `CURRENT_TASK.md` to clear the block before re-running.

3. **Fresh-state shortcut.** If no `.ralph/phase` and no memory files exist,
   resume falls through to a normal fresh start (no LLM classifier invoked).

### Smoke-test recipe

    # 1. Start a run and kill it after the planner writes CURRENT_TASK.md:
    ./ralph.sh plan.md &
    PID=$!
    # Wait until .ralph/phase contains executor-pending, then:
    kill -INT $PID
    cat .ralph/phase    # → executor-pending

    # 2. Resume — the executor runs on the existing CURRENT_TASK.md:
    ./ralph.sh plan.md --resume
    # Log will show: "Resume: skipping planner, executing existing CURRENT_TASK.md"
    # (no "Planner cycle N" header on the first iteration)

## Configuration

| Variable                | Default          | Description                             |
|-------------------------|------------------|-----------------------------------------|
| `RALPH_DIR`             | script dir       | Where prompt .md files live             |
| `PLANNER_MODEL`         | `sonnet`         | Model for the planner                   |
| `SONNET_MODEL`          | `sonnet`         | Model for the executor                  |
| `OPUS_MODEL`            | `opus`           | Model for the reviewer (both modes)     |
| `MAX_INNER`             | `8`              | Executor iterations per task slice      |
| `MAX_OUTER`             | `50`             | Planner cycles before abort             |
| `MAX_FLAT`              | `100`            | Iterations in `--sonnet-only` flat mode before abort |
| `REVIEW_INTERVAL`       | `4`              | Mid-task review every N executor iters (0=off) |
| `OUTER_REVIEW_INTERVAL` | `3`              | Outer-cycle review every N planner cycles (0=off) |
| `RALPH_LOG`             | `ralph-<ts>.log` | Log file path (one per run by default)  |
| `RETRY_MAX_ATTEMPTS`    | `30`             | Attempts per `claude` call before aborting the loop |
| `RETRY_BASE_DELAY`      | `30`             | Seconds before the first retry; doubles each failure |
| `RETRY_MAX_DELAY`       | `900`            | Cap on per-retry backoff (15 min by default) |

## Docker Usage

Ralph is designed to run in a container. Minimal setup:

```dockerfile
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y git curl && \
    # Install Claude CLI
    # Install project toolchains (Android SDK, Node, Gradle, etc.)
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY ralph/ /opt/ralph/

ENV RALPH_DIR=/opt/ralph
ENV PATH="/opt/ralph:$PATH"
```

Run with your project mounted:

```bash
docker run -v $(pwd):/workspace -e ANTHROPIC_API_KEY ralph \
  ./ralph.sh implementation_plan.md
```

Key considerations:
- Mount the project directory so git history persists across container restarts
- The container needs network access for the `claude` CLI
- Mount dependency caches (Gradle, npm, etc.) to avoid re-downloading each run
- Both Opus roles need filesystem access — they read source files, run tests,
  check git state. Make sure the `claude` CLI invocation preserves tool use.

## Observability

Each `ralph.sh` invocation creates one log file, `ralph-<timestamp>.log`
(override with `$RALPH_LOG`), that receives both:

- status markers from the `log()` helper (iteration boundaries, lifecycle
  events), and
- the tee'd stdout of every `claude -p` call, prefixed with a header like
  `=== [HH:MM:SS] Planner cycle 3 ===` so you can tell which call
  you're reading.

To watch progress live in another pane:

```bash
tail -f ralph-*.log
```

`ralph-init.sh` and `ralph-init-simple.sh` each emit their own
`ralph-init-<timestamp>.log` alongside the generated plan, with the same
streaming contract.

The `ralph-*.log` glob is `.gitignore`'d at the repo root — add the same
pattern to your project's `.gitignore` if you're running ralph against
another repo.

## On Filesystem Access

Both Opus roles (planner and reviewer) are designed to **read actual files and
run commands**, not just process the piped-in snapshots. The snapshots of
memory files and git log are piped in for quick orientation, but the prompts
explicitly instruct Opus to verify by reading source code, running tests, and
checking git diffs.

This means the `claude` CLI must be invoked in a mode that supports tool use
(file reading, bash execution). If your CLI setup doesn't support this in pipe
mode, you may need to adjust the invocation — e.g., using `claude --prompt`
with a file instead of piping, or using the API directly with tool definitions.

## Design Notes

### Memory file design

Three files, three purposes:

- **STATUS.md** is ephemeral state — rewritten every iteration. Answers "where
  are we right now?"
- **DECISIONS.md** is permanent knowledge — append-only. Prevents the loop from
  relitigating settled choices. Without it, iteration 15 might contradict a
  decision from iteration 3.
- **PROBLEMS.md** is permanent negative knowledge — append-only. Prevents
  rediscovering dead ends. Without it, the same failed approach gets tried
  repeatedly across iterations.

The append-only rule on DECISIONS.md and PROBLEMS.md is critical. STATUS.md
gets rewritten because it's current state; the other two accumulate history
that no single iteration should erase.

### The "broken state" policy

The harness allows an iteration to end with broken or uncommitted code. Forcing
a revert before exit would lose progress. The next iteration (or the reviewer)
has the context via STATUS.md to decide how to proceed. The git log provides
the last-known-good commit if a revert is needed.

### Token economics (rough estimates)

- Sonnet planner call: ~$0.03-0.12 (reads full plan + memory + inspects code)
- Sonnet executor call: ~$0.02-0.08
- Opus reviewer call: ~$0.10-0.30 (reads task + memory + inspects code),
  amortized over `OUTER_REVIEW_INTERVAL` planner cycles
- Haiku test-runner agent call: trivially small per invocation
- Typical task slice (no outer review): 1 planner + ~1 executor = ~$0.05-0.20
- Full project (10 task slices, default intervals): ~$1.00-4.00
- Flat `--sonnet-only` mode: roughly 2-3x cheaper than hierarchical now that
  the planner and executor are the same model
