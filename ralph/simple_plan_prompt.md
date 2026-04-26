I need an implementation plan for the following task:

<TASK DESCRIPTION HERE>

---

This plan will be fed into an autonomous coding loop where:
- An AI planner (Sonnet) decomposes the plan into task slices
- An AI coder (Sonnet) implements each slice iteratively with a fresh context
  window each iteration
- Continuity between iterations is maintained only through memory files
  (STATUS.md, DECISIONS.md, PROBLEMS.md) and the git history
- The coder has no memory of prior iterations except what's in those files

You have full filesystem access — read the relevant source files before writing
the plan. The task description above may be terse; the codebase is the ground
truth for what exists, what's broken, and what needs to change.

The task is intentionally scoped. Match the plan size to the task: a bug fix
or small feature addition typically needs 1–3 phases. Don't add phases that
aren't required.

Write the plan so that:

1. **Scope matches the task.** A one-line bug fix doesn't need an architectural
   phase. A feature addition might need a design phase then an implementation
   phase. Let the task drive the structure.

2. **Resolved approach.** Pick the implementation approach before writing the
   plan. The coder has no memory between iterations and can't make judgment
   calls — open choices cause drift.

3. **Concrete acceptance criteria.** Every phase needs testable/observable
   completion criteria. "It works" is not a criterion.

4. **Risk flags.** Note anything tricky or non-obvious. These surface as
   warnings to the coder.

5. **Testing.** Define how completion should be verified — build check, unit
   test, manual step, whatever fits the task.

The output format should be a clean Markdown document. For a simple task, a
single section with objective, approach, acceptance criteria, and risks is
enough. Only add phases if the task genuinely requires sequential stages.
