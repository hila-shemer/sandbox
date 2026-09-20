#!/bin/bash
# drain.sh <group> <dest-dir>
#
# Copies a group's staged patches out to a host directory - the step that gets
# work off a container, and a deliberate one. Containers write patches to a
# group volume rather than into a host checkout, because N containers sharing
# one host directory is the clobbering bug we keep hitting with shared
# worktrees, minus the visibility.
set -e
GROUP="${1:?usage: drain.sh <group> <dest-dir>}"
DEST="${2:?dest dir required}"
mkdir -p "$DEST"
docker run --rm -v "fresh-patches-${GROUP}":/src:ro -v "$DEST":/dst \
    alpine:latest sh -c 'cp -a /src/. /dst/ 2>/dev/null || true; ls -la /dst'
echo "drained fresh-patches-${GROUP} -> $DEST"
echo "apply with: git am $DEST/<name>/*.patch"
