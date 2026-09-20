#!/bin/bash
# Variant B entrypoint: a fresh sandbox. One repo, clean Claude, none of the
# host's fleet configuration.
#
# The point is context hygiene, not isolation. An agent editing a repo has no
# use for the fleet protocol, and the host's global CLAUDE.md actively tells it
# to declare fleet states and message a Manager that is not there. So
# preferences arrive through /pref - an allowlist assembled on the host - rather
# than through the stock variants' bind of all of ~/.claude.
#
# Variant A (the host config sandboxed, claude-control present) is a separate
# variant. Nothing here should grow a flag to become it.
set -e
: "${PROJECT_DIR:=/app}"

mkdir -p /home/dev/.claude

# settings.json arrives with .hooks already stripped. Copy, never merge: the
# stock merge imports 23 hook commands pointing at ~/.claude/claude-control/live,
# which does not exist in a container, so they fail on every session event.
# That is a live bug in the stock variants, not a hygiene nicety.
[ -f /pref/settings.json ] && cp /pref/settings.json /home/dev/.claude/settings.json

# A conventions file written for this variant - not the host's global CLAUDE.md
# and not a slice of it. Slicing by section rots the first time someone adds one.
[ -f /pref/CLAUDE.md ] && cp /pref/CLAUDE.md /home/dev/.claude/CLAUDE.md

# Project memory for the target repo only.
if [ -d /pref/project-memory ]; then
    enc=$(printf '%s' "$PROJECT_DIR" | tr '/' '-')
    mkdir -p "/home/dev/.claude/projects/${enc}/memory"
    cp -r /pref/project-memory/. "/home/dev/.claude/projects/${enc}/memory/" 2>/dev/null || true
fi

# Nothing here touches auth. Claude reads ~/.claude/.credentials.json off the
# group's /home volume, same as the stock variants read it off claude-loop-home:
# one interactive login per group, then it persists.

# Tracked files only, the rule the stock Dockerfile's stage 1 uses, so the tree
# matches the repo rather than whatever untracked junk is lying in it.
if [ ! -d "$PROJECT_DIR/.git" ]; then
    mkdir -p "$PROJECT_DIR"
    (cd /seed && git ls-files -z | xargs -0 -r cp --parents -t "$PROJECT_DIR")
    git -C "$PROJECT_DIR" init -q -b main
    git -C "$PROJECT_DIR" config user.email "container@sandbox"
    git -C "$PROJECT_DIR" config user.name  "Fresh Sandbox"
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -q --allow-empty -m baseline
    git -C "$PROJECT_DIR" tag baseline
fi

cd "$PROJECT_DIR"
exec "$@"
