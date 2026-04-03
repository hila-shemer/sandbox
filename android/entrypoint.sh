#!/bin/bash
set -e

# Initialize a fresh git repo from the copied source so the container
# has a real git history to commit against, isolated from the host repo.
if [ ! -d /app/.git ]; then
    git -C /app init -q -b main
    git -C /app config user.email "container@wcd"
    git -C /app config user.name "WCD Container"
    git -C /app add .
    git -C /app commit -q -m "baseline"
fi

exec "$@"
