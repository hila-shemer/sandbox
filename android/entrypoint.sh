#!/bin/bash
set -e

# Keep Claude Code CLI up to date. The base image bakes a version in at /usr/bin,
# but it drifts as Anthropic releases new versions. Install a fresh copy into a
# dev-writable prefix on the persistent home volume — that directory sits ahead
# of /usr/bin on PATH (see the export below), so the user-local copy wins when
# present and we fall back to the baked-in binary if the install fails (e.g.,
# offline). The prefix persists across restarts so only true upgrades re-download.
export NPM_CONFIG_PREFIX=/home/dev/.npm-global
export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
mkdir -p "$NPM_CONFIG_PREFIX"
if npm install -g @anthropic-ai/claude-code@latest >/dev/null 2>&1; then
    echo "[entrypoint] claude updated to $(claude --version 2>/dev/null || echo '?')"
else
    echo "[entrypoint] claude auto-update failed — falling back to baked-in version"
fi

# Sync Claude preferences from host (read-only mount) into the persistent home volume.
# Only copies preferences — auth files (sessions, .claude.json) are left untouched.
# settings.json is merged rather than overwritten so container-written keys
# (e.g. skipDangerousModePermissionPrompt, set on first accept of
# --dangerously-skip-permissions) survive restarts.
if [ -d /host-claude ]; then
    mkdir -p /home/dev/.claude
    for item in CLAUDE.md agents; do
        src="/host-claude/$item"
        dst="/home/dev/.claude/$item"
        [ -e "$src" ] && cp -r "$src" "$dst"
    done
    if [ -f /host-claude/settings.json ]; then
        dst=/home/dev/.claude/settings.json
        if [ -f "$dst" ]; then
            jq -s '.[0] * .[1]' "$dst" /host-claude/settings.json > "$dst.merged" \
                && mv "$dst.merged" "$dst"
        else
            cp /host-claude/settings.json "$dst"
        fi
    fi
fi

# Install ralph-shipped sub-agents (e.g. test-runner, a Haiku agent used to
# offload test execution from the main loop). Copied only when not already
# present so tweaks by the Claude inside the container — or by the host —
# survive restarts. The persistent home volume is what retains them.
if [ -d /opt/ralph/agents ]; then
    mkdir -p /home/dev/.claude/agents
    for src in /opt/ralph/agents/*.md; do
        [ -f "$src" ] || continue
        dst="/home/dev/.claude/agents/$(basename "$src")"
        [ -e "$dst" ] || cp "$src" "$dst"
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
- There's an Android emulator attached. run `adb devices` and it should show up.
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

# Exclude ralph's runtime memory files from git without touching the project's
# tracked .gitignore. `save-patch` does `git add -A`, so anything not excluded
# here would otherwise leak into exported patches.
cat >> /app/.git/info/exclude <<'EOF'
# ralph runtime memory (autonomous loop)
STATUS.md
DECISIONS.md
PROBLEMS.md
CURRENT_TASK.md
ralph.log
EOF

# Make ralph available on PATH and auto-approve tool use from its claude calls
# (the container itself is the permission boundary). Idempotent via sentinel.
if ! grep -q '# sandbox-ralph' /home/dev/.bashrc 2>/dev/null; then
    cat >> /home/dev/.bashrc <<'EOF'

# sandbox-ralph
export NPM_CONFIG_PREFIX=/home/dev/.npm-global
export PATH="/home/dev/.npm-global/bin:/opt/ralph:$PATH"
export CLAUDE_FLAGS="--dangerously-skip-permissions"
EOF
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
