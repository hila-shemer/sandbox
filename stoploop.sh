#!/bin/bash

export SANDBOX_DIR=$HOME/proj/sandbox
export PROJECT_DIR=`pwd`
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)

docker compose -f "$SANDBOX_DIR/loop/docker-compose.yml" down
