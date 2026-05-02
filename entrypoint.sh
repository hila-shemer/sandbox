#!/bin/bash
set -e

# PROJECT_DIR is the host project path, passed in via compose environment.
# It doubles as the container's working directory so Claude's project-memory
# key matches the host's, letting host memories propagate into the container.
: "${PROJECT_DIR:=/app}"

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

    # Sync project memories from host so the container benefits from accumulated
    # knowledge. The project memory key is the working-directory path with '/'
    # replaced by '-'. Only copied on first init — preserves container-accumulated
    # memories on subsequent restarts.
    encoded_path=$(printf '%s' "$PROJECT_DIR" | tr '/' '-')
    host_mem="/host-claude/projects/${encoded_path}/memory"
    dst_project="/home/dev/.claude/projects/${encoded_path}"
    if [ -d "$host_mem" ] && [ ! -d "${dst_project}/memory" ]; then
        mkdir -p "$dst_project"
        cp -r "$host_mem" "$dst_project/"
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
  which is bind-mounted to the host. Any uncommitted changes (staged, unstaged,
  untracked) are rolled up into a final commit before export, so nothing is
  lost. Commit your work semantically as you go — those commit messages land
  on the host. Apply on host with `git am /output/<name>/*.patch`.
- **Scratch files live in `/home/dev/notes/`** (bind-mounted to the host). Put
  plans, design notes, TODOs there. It's outside the project dir, so nothing
  there appears in patches.
- **`baseline`** is a git tag on the commit made when the container started.
  Your delta from it = what you have changed. `git diff baseline` to inspect.
- **GUI apps render to `Xvfb :99`** (started by the entrypoint along with a
  minimal `fluxbox` window manager). `DISPLAY=:99` is already in your env.
  Capture the display with `screenshot [name]` — it prints the PNG path;
  Read the file to see what the app looks like (you're multimodal). `xdotool`
  is available for synthetic input; `imagemagick` for diffing/conversion.
EOF

# Android-variant extras: gated on $ADB_TARGET being set, which only the
# android compose file does. Keeps the entrypoint single-file across variants.
if [ -n "$ADB_TARGET" ]; then
    cat >> /home/dev/.claude/CLAUDE.md <<'EOF'
- **JDK 21 is at `/usr/lib/jvm/java-21-openjdk-amd64`** (Debian path), not
  `/usr/lib/jvm/java-21-openjdk` (Fedora path). If a project's
  `gradle.properties` pins `org.gradle.java.home` to the Fedora path, Gradle
  will fail with a missing-JDK error here even though JDK 21 is installed —
  override via `JAVA_HOME` on the Gradle command line or a `~/.gradle/gradle.properties`,
  don't conclude the sandbox lacks a JDK.
- There's an Android emulator attached. run `adb devices` and it should show up.
EOF
fi

# LLM-variant extras: gated on $LLM_SANDBOX, set only by llm/docker-compose.yml.
if [ -n "$LLM_SANDBOX" ]; then
    cat >> /home/dev/.claude/CLAUDE.md <<'EOF'
- **GPU is available** via NVIDIA runtime. `nvidia-smi` to inspect;
  `python3 -c "import torch; print(torch.cuda.is_available())"` should print True.
- **HF model cache** lives in `~/.cache/huggingface` on the persistent home
  volume — models survive container restarts without re-downloading. Use
  `huggingface-cli login` or set `HF_TOKEN` in the environment for gated models.
- **Training stack pre-installed**: `torch` (CUDA), `transformers`, `datasets`,
  `accelerate`, `peft` (LoRA/QLoRA), `trl` (SFT/fine-tuning), `bitsandbytes`
  (4-bit quantization), `evaluate`, `tensorboard`, `sentencepiece`, `scipy`.
EOF
fi

# Initialize a fresh git repo from the copied source so the container
# has a real git history to commit against, isolated from the host repo.
# On first use (or after `sandbox.sh clear`), the project volume is empty —
# seed it from the image copy before initialising git.
if [ ! -d "$PROJECT_DIR/.git" ]; then
    cp -a /app-seed/. "$PROJECT_DIR/"
    git -C "$PROJECT_DIR" init -q -b main
    git -C "$PROJECT_DIR" config user.email "container@sandbox"
    git -C "$PROJECT_DIR" config user.name "Sandbox Container"
    git -C "$PROJECT_DIR" add .
    git -C "$PROJECT_DIR" commit -q -m "baseline"
    git -C "$PROJECT_DIR" tag baseline
fi

# Exclude ralph's runtime memory files from git without touching the project's
# tracked .gitignore. `save-patch` does `git add -A`, so anything not excluded
# here would otherwise leak into exported patches.
cat >> "$PROJECT_DIR/.git/info/exclude" <<'EOF'
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

# Start Xvfb + fluxbox so GUI apps inside the container can render headlessly,
# and so `screenshot` can capture the display for Claude to inspect. Xvfb is
# ~10MB RAM, fluxbox ~15MB — cheap enough to leave running unconditionally.
# DISPLAY is exported here for the exec'd command and persisted in .bashrc
# (separate sentinel) so attach shells pick it up too.
if ! pgrep -f "Xvfb :99" >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
    for _ in $(seq 1 20); do
        [ -S /tmp/.X11-unix/X99 ] && break
        sleep 0.1
    done
    export DISPLAY=:99
    fluxbox >/tmp/fluxbox.log 2>&1 &
    disown -a
fi
export DISPLAY=:99
if ! grep -q '# sandbox-display' /home/dev/.bashrc 2>/dev/null; then
    cat >> /home/dev/.bashrc <<'EOF'

# sandbox-display
export DISPLAY=:99
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

cd "$PROJECT_DIR"
exec "$@"
