#!/bin/bash
# fresh.sh <group> <repo-path> [-- CMD...]
#
# Runs an agent against one repo with claude-control neither installed nor
# visible. The group is the isolation unit: containers in a group share /home
# (auth, caches, memories) and a bridge; nothing crosses between groups.
set -e
usage() { echo "usage: $0 <group> <repo-path> [-- CMD...]" >&2; exit 1; }
GROUP="${1:-}"; REPO_ARG="${2:-}"
if [ -z "$GROUP" ] || [ -z "$REPO_ARG" ]; then usage; fi
REPO="$(cd "$REPO_ARG" && pwd)"
shift 2; [ "${1:-}" = "--" ] && shift
CMD=("$@"); [ ${#CMD[@]} -eq 0 ] && CMD=(/bin/bash)

FRESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="$(basename "$REPO")"
NET="fresh-${GROUP}"
HOMEVOL="fresh-home-${GROUP}"
APPVOL="fresh-app-${GROUP}-${NAME}"
PATCHVOL="fresh-patches-${GROUP}"
REGISTRY_FILE="${FRESH_DIR}/groups.tsv"

# Docker bridges have no egress on this host - the gw table's forward chain is
# policy drop and 172.17/16 matches nothing. 10.202.0.0/16 is accepted out eno2
# and masqueraded, so each group gets a /24 from it. --network host would also
# reach the network, but would put the container on flatpot's loopback for no
# reason - a per-group bridge is what makes groups separable anyway.
#
# Octets come from a registry rather than a hash of the name: a hash collides
# silently, and two groups on one subnet is the failure this file exists to stop.
touch "$REGISTRY_FILE"
OCTET=$(awk -v g="$GROUP" '$1==g {print $2; found=1} END{if(!found) print ""}' "$REGISTRY_FILE")
if [ -z "$OCTET" ]; then
    # Take used octets from docker, not just from this file. The registry sits
    # next to the script, so a second checkout starts numbering from scratch and
    # collides with networks the first one is still using - which is a create
    # failure at best and two groups on one subnet at worst.
    used=$( { awk '{print $2}' "$REGISTRY_FILE"
              docker network ls --filter name=fresh- --format '{{.Name}}' |
              while read -r n; do
                  docker network inspect "$n" \
                      --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null |
                      sed -n 's|^10\.202\.\([0-9]*\)\..*|\1|p'
              done
            } | sort -n | tail -1 )
    OCTET=$(( ${used:-9} + 1 ))
    if [ "$OCTET" -gt 250 ]; then
        echo "fresh: out of /24s in 10.202.0.0/16" >&2; exit 1
    fi
    printf '%s\t%s\n' "$GROUP" "$OCTET" >> "$REGISTRY_FILE"
fi

# ---- host-side sanitation: assemble /pref ---------------------------------
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

# Strip every hook. The host's hooks all point at ~/.claude/claude-control/live,
# which is absent in here, so merging them in (as the stock entrypoint does)
# just means 23 failing hook invocations per session event.
jq 'del(.hooks)' "$HOME/.claude/settings.json" > "$STAGE/settings.json"

cat > "$STAGE/CLAUDE.md" <<'CONV'
# Fresh sandbox

You are working on one repository inside a container, with a clean Claude
configuration. Read that repo's own CLAUDE.md for its conventions - this file
only covers the environment.

There is no fleet here and no Manager to ask. That is deliberate: this variant
exists so an agent working on a repo is not also carrying a fleet protocol it
cannot act on. Decide, or write the question down in your final message.

- **Emit work with `save-patch [name]`.** It exports your commits since the
  `baseline` tag as a patch series into `/output`, a volume shared by this
  group. A human drains it with `fresh/drain.sh`; nothing here writes into a
  host checkout, so parallel containers cannot clobber each other. Commit
  semantically as you go - those messages land on the host.
- **`baseline`** tags the state you started from. `git diff baseline` is your delta.
- The network works. Other groups do not.
CONV

ENC="$(printf '%s' "$REPO" | tr '/' '-')"
[ -d "$HOME/.claude/projects/$ENC/memory" ] && \
    cp -r "$HOME/.claude/projects/$ENC/memory" "$STAGE/project-memory"

# ---- group resources ------------------------------------------------------
docker network inspect "$NET" >/dev/null 2>&1 || \
    docker network create --subnet "10.202.${OCTET}.0/24" "$NET" >/dev/null
# loop-base has no /home/dev, so a fresh volume comes up root-owned and the
# unprivileged agent cannot write its own home. Seed ownership at create time.
for v in "$HOMEVOL" "$APPVOL" "$PATCHVOL"; do
    docker volume inspect "$v" >/dev/null 2>&1 && continue
    docker volume create "$v" >/dev/null
    docker run --rm -v "$v":/v alpine:latest chown 1000:1000 /v >/dev/null
done

TTY=(); [ -t 0 ] && TTY=(-it)
exec docker run --rm "${TTY[@]}" \
    --network "$NET" \
    --user 1000:1000 \
    -e PROJECT_DIR=/app -e HOME=/home/dev -e FRESH_GROUP="$GROUP" \
    -v "$HOMEVOL":/home/dev \
    -v "$APPVOL":/app \
    -v "$PATCHVOL":/output \
    -v "$REPO":/seed:ro \
    -v "$STAGE":/pref:ro \
    -v "${FRESH_DIR}/entrypoint-fresh.sh":/entrypoint.sh:ro \
    -v "${FRESH_DIR}/../save-patch":/usr/local/bin/save-patch:ro \
    --entrypoint /entrypoint.sh \
    "${REGISTRY:-spark.tail0b59ad.ts.net:5000/flatpot}/claude-loop-base:latest" "${CMD[@]}"
