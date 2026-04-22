# Ralph — Autonomous Implementation Loop

A three-role harness for autonomous coding with Claude. Opus plans and reviews,
Sonnet executes. Named after Ralph Wiggum for reasons that presumably made
sense at the time.

## Quick Start

```bash
# 1. Generate a plan (one-time, uses Opus)
#    Edit plan_prompt.md with your project description, then:
cat plan_prompt.md | claude --model opus > implementation_plan.md

# 2. Run the loop
./ralph.sh implementation_plan.md

# Or for simpler projects, skip Opus and run Sonnet solo:
./ralph.sh implementation_plan.md --sonnet-only
```

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│  ralph.sh                                                 │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │ OUTER LOOP: Planner (Opus)                          │  │
│  │                                                     │  │
│  │  • Reads plan + memory files + git log + real code  │  │
│  │  • Verifies Sonnet's previous work (reads files!)   │  │
│  │  • Writes CURRENT_TASK.md for next slice            │  │
│  │  • Exits on COMPLETE or BLOCKED                     │  │
│  │                                                     │  │
│  │  ┌───────────────────────────────────────────────┐  │  │
│  │  │ INNER LOOP: Executor (Sonnet, ≤8 iters)      │  │  │
│  │  │                                               │  │  │
│  │  │  • Reads CURRENT_TASK.md + memory files       │  │  │
│  │  │  • Implements, commits, tests                 │  │  │
│  │  │  • Updates memory files                       │  │  │
│  │  │  • Exits on TASK_DONE / BLOCKED / max iters   │  │  │
│  │  │                                               │  │  │
│  │  │  ┌─────────────────────────────────────────┐  │  │  │
│  │  │  │ PERIODIC: Reviewer (Opus)               │  │  │  │
│  │  │  │                                         │  │  │  │
│  │  │  │  Every 4 iters, or on BLOCKED:          │  │  │  │
│  │  │  │  • Reads real code + runs tests         │  │  │  │
│  │  │  │  • Diagnoses drift or problems          │  │  │  │
│  │  │  │  • Writes guidance into memory files    │  │  │  │
│  │  │  │  • Optionally makes small targeted fix  │  │  │  │
│  │  │  │  • Inner loop continues after review    │  │  │  │
│  │  │  └─────────────────────────────────────────┘  │  │  │
│  │  └───────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

### Three Roles

**Planner (Opus)** — called between task slices. Sees the full plan, all memory
files, and the git log. Crucially, it also **reads the actual filesystem** to
verify Sonnet's work against its claims in STATUS.md. Writes the next
CURRENT_TASK.md or declares the project complete.

**Reviewer (Opus)** — called mid-task, every N Sonnet iterations or when Sonnet
hits BLOCKED. Same model, different role: it doesn't write new tasks, it
diagnoses problems and leaves guidance in the memory files. Can make small
targeted fixes (a config typo, a missing import) but doesn't do real
implementation. The inner loop continues after a review.

**Executor (Sonnet)** — the workhorse. Reads CURRENT_TASK.md and the memory
files, implements code, commits, tests. Doesn't need to see the full plan.
Doesn't need to reason about big-picture progress — just executes the current
slice.

### Why a Separate Reviewer?

The original conversation considered having Sonnet decide when to escalate to
Opus (init5). The problem: recognizing that you're confused is itself a hard
reasoning task. Sonnet catches obvious blockers but misses subtle drift —
working confidently in the wrong direction. The periodic reviewer catches
drift mechanically, without depending on Sonnet's self-awareness.

The reviewer is also the mechanism for unblocking: when Sonnet writes BLOCKED,
the reviewer diagnoses the issue, writes guidance into DECISIONS.md/PROBLEMS.md,
rewrites STATUS.md with a path forward, and the inner loop continues.

## Files

```
ralph.sh            — main orchestrator
sonnet_prefix.md    — execution prompt prefix (prepended to task spec)
sonnet_suffix.md    — execution reminders (appended after task spec)
opus_planner.md     — planner prompt: reviews work, writes next task
opus_reviewer.md    — reviewer prompt: mid-task diagnosis and guidance
plan_prompt.md      — template for generating implementation plans
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

## Modes

### Hierarchical (default): `./ralph.sh plan.md`

Planner → Executor (with periodic reviews) → Planner → repeat. Best for
complex or multi-day projects.

### Flat: `./ralph.sh plan.md --sonnet-only`

Sonnet reads the full plan directly and loops until DONE or BLOCKED. Cheaper,
simpler, fine for well-scoped projects.

## Configuration

| Variable          | Default      | Description                             |
|-------------------|--------------|-----------------------------------------|
| `RALPH_DIR`       | script dir   | Where prompt .md files live             |
| `OPUS_MODEL`      | `opus`       | Model for planner + reviewer            |
| `SONNET_MODEL`    | `sonnet`     | Model for executor                      |
| `MAX_INNER`       | `8`          | Sonnet iterations per task slice        |
| `MAX_OUTER`       | `50`         | Planner cycles before abort             |
| `MAX_FLAT`        | `100`        | Iterations in `--sonnet-only` flat mode before abort |
| `REVIEW_INTERVAL` | `4`          | Review every N Sonnet iterations (0=off)|
| `RALPH_LOG`       | `ralph-<ts>.log` | Log file path (one per run by default) |

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
  `=== [HH:MM:SS] Opus planner cycle 3 ===` so you can tell which call
  you're reading.

To watch progress live in another pane:

```bash
tail -f ralph-*.log
```

`ralph-init.sh` emits its own `ralph-init-<timestamp>.log` alongside the
generated plan, with the same streaming contract.

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

- Opus planner call: ~$0.15-0.50 (reads full plan + memory + inspects code)
- Opus reviewer call: ~$0.10-0.30 (reads task + memory + inspects code)
- Sonnet executor call: ~$0.02-0.08
- Typical task slice: 1 planner + 1 reviewer + 5 executor = ~$0.35-1.20
- Full project (10 task slices): ~$3.50-12.00
- Flat `--sonnet-only` mode: roughly 5-10x cheaper
