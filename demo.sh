#!/usr/bin/env bash
# Narrated CLI demo of sandbox. Runs real commands in a fresh terminal.
#
#   ./demo.sh              run from source in place (this repo is the tool)
#   DEMO_PAUSE=0 ./demo.sh no read-pauses (fast replay / self-test)
#
# Stable-only repo: there's no installed binary on PATH -- the scripts ARE the
# tool, run straight from the source tree. So no --staging/--next channels.
#
# Deliberately NO 'set -e': demo commands exit non-zero on purpose (showing a
# parser REFUSE, then accept). We want the real exit shown, not the script
# aborted. Fresh shell starts here -> absolute paths only.
#
# READ-ONLY / side-effect-free: no Docker build, no container, no network, no
# daemon. The one real run drives ralph.sh's arg parser against a throwaway
# stub `claude` in a mktemp dir, cleaned up on exit.
set -uo pipefail

SRC=/home/hila/proj/sandbox           # source dir; this repo is the tool itself
PAUSE=${DEMO_PAUSE:-3}

channel=stable
case ${1:-} in
  '') ;;
  *) echo "usage: $0   (stable-only; no channel flags)" >&2; exit 2 ;;
esac

say()  { printf '# %s\n' "$*"; sleep "$(( PAUSE > 0 ? 1 : 0 ))"; }    # explanation line (tight block)
sect() { printf '\n'; }                                               # one blank line at a section boundary
run()  { printf '\n$ %s\n' "$*"; eval "$*"; sleep "$PAUSE"; }         # show command, run for real, pause

# --- overview: assume the viewer last saw this months ago, name alone won't do
say "sandbox ($channel) -- the canonical Docker sandbox for running Claude Code"
say "in a container against any host project. Bakes your tree into /app, lets"
say "the agent edit/commit on an isolated git history, and exports changes back"
say "out as patches. Three variants: loop (generic dev), android (+Cuttlefish"
say "device over ADB), llm (+PyTorch/CUDA). Ships 'ralph', a 3-role autonomous"
say "loop (Sonnet planner+executor, periodic Opus reviewer) for unattended runs."
say "Demoing from source: $SRC  (no daemon/build -- that needs Docker)."

# --- proof of life: the tool itself, no Docker, build, or daemon needed
run "$SRC/sandbox.sh 2>&1 | head -1   # dispatcher usage (no args -> usage)"

# --- the headline: exercise ralph.sh's arg parser for real.
# ralph.sh invokes `claude`; we put a throwaway stub on PATH so nothing real is
# launched -- the parser decisions (accept/refuse + exit code) are what we show.
sect
say "Now watch ralph's launcher actually validate its flags -- for real:"
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/bash\nexit 0\n' > "$STUB/claude"; chmod +x "$STUB/claude"

sect
say "A bad flag is rejected with a usage line and exit 2:"
run "PATH=\"$STUB:\$PATH\" $SRC/ralph/ralph.sh /dev/null --garbage; echo exit=\$?"

sect
say "And --resume is only legal in hierarchical mode -- refused with --sonnet-only:"
run "PATH=\"$STUB:\$PATH\" $SRC/ralph/ralph.sh /dev/null --sonnet-only --resume; echo exit=\$?"

sect
say "That's sandbox. Real use: cd into a project, then '$SRC/sandbox.sh run loop'."
say "Source: $SRC"
