#!/bin/bash

# absolute path to the project you want to work on. Becomes
# both the Docker build context and the owner of `/output` (via `$PROJECT_DIR/patches`).
# PROJECT_DIR="$1"
# absolute path to this repo. Used to locate the Dockerfile
# SANDBOX_DIR=/home/nadav/proj/sandbox

export SANDBOX_DIR=$HOME/proj/sandbox
export PROJECT_DIR=`pwd`
#$HOME/proj/my-project
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)
mkdir -p "$PROJECT_DIR/patches"

docker compose -f "$SANDBOX_DIR/android/docker-compose.yml" build
docker compose -f "$SANDBOX_DIR/android/docker-compose.yml" run --rm claude-android
