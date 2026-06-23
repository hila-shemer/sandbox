---
name: launch-ralph-loop
description: Launch an autonomous ralph implementation loop in a new sandbox container. Use this to delegate implementation work to run in the background. Requires Docker and the sandbox repo on the host — does not work from inside a container.
---

You are helping the user spin up a named sandbox container that runs a ralph loop autonomously in the background.

## Prerequisites

- The sandbox repo is at `~/proj/sandbox` (or `$SANDBOX_DIR` if set).
- The user is in the project directory (or `PROJECT_DIR` is set).
- The implementation plan file must be tracked by git (`git add` it first if newly created — the container image is seeded from tracked files only).

## Steps

### 1. Confirm the plan file exists and is tracked

```bash
# From the project directory:
git ls-files implementation_plan.md   # or whatever the plan file is named
# If empty output, stage it first:
# git add implementation_plan.md
```

### 2. Choose a short name for this loop

Pick something descriptive: `fix-auth`, `add-tests`, `refactor-api`. It becomes the volume and container name suffix.

### 3. Launch the container

```bash
~/proj/sandbox/sandbox.sh run loop --name <loop-name> --detach -- ralph.sh <plan-file>
```

For example, from `~/proj/myproject`:
```bash
~/proj/sandbox/sandbox.sh run loop --name fix-auth --detach -- ralph.sh implementation_plan.md
```

The command prints a container ID and a `docker logs` command to tail output.

### 4. Monitor progress

```bash
docker logs -f <container-id>
# or tail the ralph log inside the container:
docker exec <container-id> tail -f /tmp/ralph-*.log 2>/dev/null || true
```

### 5. Retrieve results

Results land in `<PROJECT_DIR>/patches/<name>/` as `git format-patch` files.
Apply on the host with:
```bash
git am <PROJECT_DIR>/patches/<name>/*.patch
```

## Managing named containers

```bash
# Stop a running loop:
~/proj/sandbox/sandbox.sh stop loop --name <loop-name>

# Wipe its /app volume (forces re-seed on next run):
~/proj/sandbox/sandbox.sh clear loop --name <loop-name>

# Attach a shell to inspect state:
~/proj/sandbox/sandbox.sh attach loop --name <loop-name>
```

## Notes

- Named containers share the `claude-loop-home` volume with the main container — they inherit the same Claude auth, settings, and accumulated project memories.
- Each named container gets its own isolated `/app` volume, seeded fresh from the current project state at build time.
- Multiple named loops can run concurrently against the same project.
