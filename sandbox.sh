#!/bin/bash
# sandbox.sh {run|attach|stop} {loop|android}
#
# Single dispatcher replacing the per-variant {run,attach,stop}{loop,android}.sh
# scripts. PROJECT_DIR defaults to the current directory; SANDBOX_DIR is
# auto-derived from this script's location.
set -e

usage() {
    echo "usage: $0 {run|attach|stop|clear} {loop|android}" >&2
    exit 1
}

cmd="${1:-}"
variant="${2:-}"

case "$variant" in
    loop|android) ;;
    *) usage ;;
esac

export SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_NAME="${PROJECT_NAME:-${PROJECT_DIR##*/}}"
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)

compose="$SANDBOX_DIR/$variant/docker-compose.yml"
service="claude-$variant"

case "$cmd" in
    run)
        mkdir -p "$PROJECT_DIR/patches" "$PROJECT_DIR/.notes"
        docker compose -f "$compose" build
        exec docker compose -f "$compose" run --rm "$service"
        ;;
    attach)
        cid=$(docker ps --filter "ancestor=$service" --format "{{.ID}}" | head -1)
        if [ -z "$cid" ]; then
            echo "No running $service container found" >&2
            exit 1
        fi
        exec docker exec -it "$cid" bash
        ;;
    stop)
        exec docker compose -f "$compose" down
        ;;
    clear)
        volume="claude-app-${PROJECT_NAME}"
        echo "Removing /app volume: $volume"
        docker volume rm "$volume" && echo "Cleared — volume will be re-seeded from image on next run." \
            || echo "Volume not found (already clear)."
        ;;
    *)
        usage
        ;;
esac
