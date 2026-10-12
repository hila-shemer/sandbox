# fresh — variant B: one repo, clean Claude, no fleet config

A third variant beside `loop/` and `android/`, and the first of a pair:

- **`fresh/` (variant B, this one)** — a clean Claude with none of the host
  configuration. Just the repo and its own CLAUDE.md.
- **variant A (not built)** — the host configuration running inside a sandbox,
  with claude-control present and working. A fleet agent that happens to live in
  a container. Deliberately a separate variant rather than a flag on this one:
  a shared parameterised thing drifts toward one of them and half-applies to the
  other.

## What it is for

Context hygiene. An agent editing a repo has no use for the fleet protocol, and
the host's global CLAUDE.md actively instructs it to declare fleet states and
message a Manager that a fresh sandbox does not have. The property this variant
holds is one sentence:

> the container agent should not believe it is a fleet member or try to act like one.

## How it differs from `loop/`

`docker-compose.base.yml` binds all of `${HOME}/.claude` at `/host-claude` and
the entrypoint merges the host `settings.json` whole. That merge is a live bug
for any container: **23 hook commands land pointing at
`~/.claude/claude-control/live/...`, which does not exist inside**, so they fail
on every session event.

`fresh/` does not mount `~/.claude`. Preferences arrive through `/pref`, built
on the host: `settings.json` with `.hooks` stripped, a conventions file written
for this variant, and the target repo's project memory. The repo's own
`CLAUDE.md` comes with the repo, which is where repo conventions belong.

**Auth is unchanged from stock.** Neither design injects credentials — the stock
entrypoint says as much at `entrypoint.sh:25`. Claude reads
`~/.claude/.credentials.json` off the persistent home volume, so a new group
costs one interactive login and later runs cost none.

## Groups

| per group | shared in-group | across groups |
|---|---|---|
| `fresh-home-<g>` → `/home/dev` | auth, npm-global, history, memories | separate volume |
| `fresh-<g>` bridge, `10.202.N.0/24` | containers reach each other | separate bridge |
| `fresh-patches-<g>` → `/output` | staged patches | separate volume |
| `fresh-app-<g>-<repo>` → `/app` | — | one per repo |

`groups.tsv` maps group to octet, and the allocator also reads the subnets of
live `fresh-*` networks: the registry sits next to the script, so a second
checkout would otherwise restart numbering and collide with a running network.

## Network

Docker bridges have no egress on flatpot — the `gw` table's forward chain is
`policy drop` and `172.17/16` matches no accept rule. `10.202.0.0/16` is
accepted out `eno2` and masqueraded, so each group takes a `/24`. Cross-group
traffic is dropped.

## Getting work out

```bash
fresh/drain.sh <group> ~/patches-out
git am ~/patches-out/<name>/*.patch
```

Containers stage patches to a group volume rather than writing into a host
checkout, so parallel containers cannot clobber each other.

## Use

```bash
fresh/fresh.sh <group> <repo-path> [-- CMD...]
fresh/fresh.sh core ~/proj/claude-control
```

`claude-loop-base` is used as-is and never rebuilt. If it is not local,
`docker run` pulls it from spark's registry (`spark-5868.tail0b59ad.ts.net:5000/flatpot`, the
`REGISTRY` default).
