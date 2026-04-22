#!/bin/bash

cid=$(docker ps --filter "ancestor=claude-loop" --format "{{.ID}}" | head -1)
if [ -z "$cid" ]; then
    echo "No running claude-loop container found" >&2
    exit 1
fi
exec docker exec -it "$cid" bash
