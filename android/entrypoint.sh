#!/bin/bash
set -e

# Sync Claude preferences from host (read-only mount) into the persistent home volume.
# Only copies preferences — auth files (sessions, .claude.json) are left untouched.
if [ -d /host-claude ]; then
    for item in CLAUDE.md agents settings.json; do
        src="/host-claude/$item"
        dst="/home/dev/.claude/$item"
        [ -e "$src" ] && cp -r "$src" "$dst"
    done
fi

# Initialize a fresh git repo from the copied source so the container
# has a real git history to commit against, isolated from the host repo.
if [ ! -d /app/.git ]; then
    git -C /app init -q -b main
    git -C /app config user.email "container@wcd"
    git -C /app config user.name "WCD Container"
    git -C /app add .
    git -C /app commit -q -m "baseline"
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
