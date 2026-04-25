#!/bin/bash

set -e

docker build -t ghcr.io/hila-shemer/claude-loop-base:latest -f base/Dockerfile.claude-loop-base base/
docker push ghcr.io/hila-shemer/claude-loop-base:latest

docker build -t ghcr.io/hila-shemer/claude-android-base:latest -f base/Dockerfile.claude-android-base base/
docker push ghcr.io/hila-shemer/claude-android-base:latest

# One-time only
#docker volume create claude-loop-home
#docker volume create claude-android-home
