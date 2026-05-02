#!/bin/bash
# sandbox.sh {run|attach|stop|clear} {loop|android|llm} [--name PREFIX] [--detach] [-- CMD...]
#
# --name PREFIX   Launch/manage a named container with its own /app volume.
#                 Multiple named containers can run concurrently against the
#                 same project while sharing the home volume (auth + memories).
# --detach        Start the container in the background (non-interactive).
#                 Prints the container ID; use `docker logs -f <id>` to tail.
# -- CMD...       Command to run inside the container instead of bash.
#                 Example: -- ralph implementation_plan.md
set -e

usage() {
    echo "usage: $0 {run|attach|stop|clear} {loop|android|llm} [--name PREFIX] [--detach] [-- CMD...]" >&2
    exit 1
}

cmd="${1:-}"
variant="${2:-}"

case "$variant" in
    loop|android|llm) ;;
    *) usage ;;
esac

shift 2

# Parse optional flags
CONTAINER_NAME=""
DETACH=false
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)    CONTAINER_NAME="${2:?--name requires a value}"; shift 2 ;;
        --detach|-d) DETACH=true; shift ;;
        --)        shift; EXTRA_ARGS=("$@"); break ;;
        *)         echo "Unknown argument: $1" >&2; usage ;;
    esac
done

export SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
export PROJECT_NAME="${PROJECT_NAME:-${PROJECT_DIR##*/}}"
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)

# Named containers get a volume suffix so their /app is isolated, and a
# distinct compose project name so container names don't clash.
if [[ -n "$CONTAINER_NAME" ]]; then
    export CONTAINER_NAME_SUFFIX="-${CONTAINER_NAME}"
    export COMPOSE_PROJECT_NAME="${variant}-${PROJECT_NAME}-${CONTAINER_NAME}"
else
    export CONTAINER_NAME_SUFFIX=""
    # Leave COMPOSE_PROJECT_NAME unset — Compose uses its default (directory name).
fi

compose="$SANDBOX_DIR/$variant/docker-compose.yml"
service="claude-$variant"

case "$cmd" in
    run)
        mkdir -p "$PROJECT_DIR/patches" "$PROJECT_DIR/.notes"
        docker compose -f "$compose" build
        if $DETACH; then
            cid=$(docker compose -f "$compose" run -d -T --rm "$service" "${EXTRA_ARGS[@]}")
            echo "Started: $cid"
            echo "Logs:    docker logs -f $cid"
        else
            exec docker compose -f "$compose" run --rm "$service" "${EXTRA_ARGS[@]}"
        fi
        ;;
    attach)
        if [[ -n "$CONTAINER_NAME" ]]; then
            cid=$(docker ps \
                --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
                --format "{{.ID}}" | head -1)
        else
            cid=$(docker ps --filter "ancestor=$service" --format "{{.ID}}" | head -1)
        fi
        if [ -z "$cid" ]; then
            echo "No running ${service}${CONTAINER_NAME:+ (name: $CONTAINER_NAME)} container found" >&2
            exit 1
        fi
        exec docker exec -it "$cid" bash
        ;;
    stop)
        exec docker compose -f "$compose" down
        ;;
    clear)
        volume="claude-app-${PROJECT_NAME}${CONTAINER_NAME_SUFFIX}"
        echo "Removing volume: $volume"
        docker volume rm "$volume" && echo "Cleared — volume will be re-seeded from image on next run." \
            || echo "Volume not found (already clear)."
        ;;
    *)
        usage
        ;;
esac
