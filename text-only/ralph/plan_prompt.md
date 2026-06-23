# How to Use This File
#
# This is a template. Copy it, fill in the <DESCRIBE PROJECT> section, and
# feed it to Opus to generate an implementation plan:
#
#   cat plan_prompt.md | claude --model opus > implementation_plan.md
#
# Then run the loop:
#
#   ./ralph.sh implementation_plan.md

---

I need a detailed implementation plan in Markdown for the following project:

<DESCRIBE YOUR PROJECT HERE>

---

This plan will be fed into an autonomous coding loop where:
- An AI planner (Opus) decomposes the plan into task slices
- An AI coder (Sonnet) implements each slice iteratively with a fresh context
  window each iteration
- Continuity between iterations is maintained only through memory files
  (STATUS.md, DECISIONS.md, PROBLEMS.md) and the git history
- The coder has no memory of prior iterations except what's in those files

Write the plan so that:

1. **Structure for decomposition**: Organize into logical phases/sections that
   a planner can hand off one at a time. Each section should be a coherent unit
   of work with clear boundaries.

2. **Explicit dependencies**: State which sections depend on which. The planner
   uses this to order task slices correctly.

3. **Concrete success criteria**: Every section should have testable/observable
   completion criteria. "It works" is not a criterion. "The app builds without
   errors and the login screen renders" is.

4. **Resolved decisions**: Don't leave design choices open. Pick a library, pick
   an architecture, pick a pattern. Document your reasoning. Open choices cause
   the loop to stall or make inconsistent decisions across iterations.

5. **Technical specifics**: Name the exact libraries, versions, APIs, file
   structures. The coder works from this document — vague references to "a
   suitable library" waste iterations on research.

6. **Risk flags**: Note anything that's likely to be tricky, has known pitfalls,
   or might need a non-obvious approach. These get surfaced to the coder as
   warnings.

7. **Testing strategy**: Define how each phase should be tested. Unit tests,
   integration tests, manual verification steps — whatever is appropriate. The
   coder needs to know what "done" looks like.

The output format should be a clean Markdown document with numbered sections,
each containing: objective, dependencies, deliverables, technical details,
acceptance criteria, and known risks.
