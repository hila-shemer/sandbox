#!/bin/bash

set -e

REGISTRY=${REGISTRY:-ghcr.io/hila-shemer}
PUSH=0

for arg in "$@"; do
  case $arg in
    --push) PUSH=1 ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

docker build -t "$REGISTRY/claude-loop-base:latest" -f base/Dockerfile.claude-loop-base base/

docker build -t "$REGISTRY/claude-llm-base:latest" \
    --build-arg REGISTRY="$REGISTRY" \
    -f base/Dockerfile.claude-llm-base base/

if [[ $PUSH -eq 1 ]]; then
  docker push "$REGISTRY/claude-loop-base:latest"
  docker push "$REGISTRY/claude-llm-base:latest"
fi

# One-time only
#docker volume create claude-loop-home
#docker volume create claude-android-home
#docker volume create claude-llm-home
