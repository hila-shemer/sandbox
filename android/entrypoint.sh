#!/bin/bash
set -e

# Sync Claude preferences from host (read-only mount) into the persistent home volume.
# Only copies preferences — auth files (sessions, .claude.json) are left untouched.
if [ -d /host-claude ]; then
    mkdir -p /home/dev/.claude
    for item in CLAUDE.md agents settings.json; do
        src="/host-claude/$item"
        dst="/home/dev/.claude/$item"
        [ -e "$src" ] && cp -r "$src" "$dst"
    done
fi

# Append sandbox-specific guidance to the user-level CLAUDE.md. Host CLAUDE.md
# is re-copied each run (above), so this stays deterministic — no drift.
cat >> /home/dev/.claude/CLAUDE.md <<'EOF'

## Sandbox container conventions

You are running inside a Docker sandbox. Conventions specific to this environment:

- **Emit patches with `save-patch [name]`.** This exports your commits since
  the `baseline` tag as a `git format-patch` series into `/output/<name>/`,
  which is bind-mounted to the host. Any uncommitted work (staged, unstaged,
  untracked) is rolled up into a final commit before export, so nothing is
  lost. Commit your work semantically as you go — those commit messages land
  on the host. Apply on host with `git am /output/<name>/*.patch`.
- **Scratch files live in `/home/dev/notes/`** (bind-mounted to the host). Put
  plans, design notes, TODOs there. It's outside `/app`, so nothing there
  appears in patches.
- **`baseline`** is a git tag on the commit made when the container started.
  Your delta from it = what you have changed. `git diff baseline` to inspect.
- **JDK 21 is at `/usr/lib/jvm/java-21-openjdk-amd64`** (Debian path), not
  `/usr/lib/jvm/java-21-openjdk` (Fedora path). If a project's
  `gradle.properties` pins `org.gradle.java.home` to the Fedora path, Gradle
  will fail with a missing-JDK error here even though JDK 21 is installed —
  override via `JAVA_HOME` on the Gradle command line or a `~/.gradle/gradle.properties`,
  don't conclude the sandbox lacks a JDK.
EOF

# Initialize a fresh git repo from the copied source so the container
# has a real git history to commit against, isolated from the host repo.
if [ ! -d /app/.git ]; then
    git -C /app init -q -b main
    git -C /app config user.email "container@sandbox"
    git -C /app config user.name "Sandbox Container"
    git -C /app add .
    git -C /app commit -q -m "baseline"
    git -C /app tag baseline
fi

# Connect to ADB target if specified (e.g. cuttlefish:6520, host.docker.internal:6520)
if [ -n "$ADB_TARGET" ]; then
    echo "Waiting for ADB target $ADB_TARGET..."
    # Start adb server first so its output doesn't interfere with connect
    adb start-server 2>/dev/null
    for i in $(seq 1 30); do
        if adb connect "$ADB_TARGET" 2>&1 | grep -q "connected to"; then
            echo "ADB connected to $ADB_TARGET"
            break
        fi
        sleep 5
    done
fi

exec "$@"
