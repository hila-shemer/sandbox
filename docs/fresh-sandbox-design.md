# Variant B: a fresh sandbox — one repo, clean Claude, no fleet config

Home Fleet Agent sandbox-JollyCoyote — 2026-09-20
Status: **built, run, and proposed. Nothing outside throwaway containers has changed.**

This covers **variant B only** — a fresh sandbox with none of the host
configuration. **Variant A** (the host configuration sandboxed) is not a thing
to build: it already exists as `sandbox.sh run` today. §7 gives its delta.

An earlier revision of this note framed the work as closing a security leak.
**That framing was wrong and is withdrawn.** The container runs Claude Code, so
it reading Claude credentials is the tool working. There is no security finding
in this task and none of what follows is one.

---

## 1. What "without claude-control" actually means

It is **prompt and context hygiene**, not isolation.

The ask was that a container agent working on one repo should not be carrying
the fleet protocol around. That is a question about what goes into the agent's
context, and it has a plain answer: fleet-protocol material is irrelevant to an
agent editing a repo, and worse than irrelevant, because the host's global
CLAUDE.md instructs an agent to declare fleet states and message a Manager that
a fresh sandbox does not have.

So the single property variant B needs is:

> **The container agent should not believe it is a fleet member or try to act
> like one.**

Everything in the check below is that one property, tested four ways.

## 2. Context-hygiene check

Measured against the stock mount set first, then against B.

| Check | Stock | B | Why it matters |
|---|---|---|---|
| `manager.json` marker readable | yes | no | a marker present is an agent that may try to address a Manager |
| `cc-socks` session sockets | no | no | already absent in stock; nothing to do |
| claude-control hook entries in `settings.json` | **23 of 27** | **0** | see below — this one is a live bug, not hygiene |
| fleet-protocol prose in user CLAUDE.md | yes | no | manager protocol, host topology, port inventories; contradicts the sandbox's own conventions |
| target repo's own CLAUDE.md present | yes | yes | repo conventions belong with the repo |

**The hooks are a real correctness bug in the stock sandbox**, independent of
any of this. Counted exactly, reconciling two different measurements:

- **27** hook entries total (every event × every command)
- **23** of them reference `~/.claude/claude-control/live/...`
- across **3** distinct scripts — `bin/cc-hook-log`, `hooks/session-start.py`,
  `hooks/session-state.py`
- plus **2** more pointing at `~/proj/kgrab-cresume/session-registry.sh`

So **25 of 27 hook entries reference host paths that do not exist inside a
container**, and fail on every session event. Both earlier numbers were right;
they were counting entries and distinct scripts.

B copies a `jq 'del(.hooks)'`-filtered file instead of merging.

**Negative control.** A check that only ever passes is not evidence. The same
script run against the stock mount set reports the stock column above — four
rows differing — so it can fail and did.

## 3. How auth reaches the container

Unchanged from stock, and no machinery was added.

`entrypoint.sh:25` in the stock sandbox says it copies preferences and leaves
auth files alone, and it does: nothing injects credentials in either design.
Claude reads `$HOME/.claude/.credentials.json` → `/home/dev/.claude/.credentials.json`,
which lives on the persistent home volume — `claude-loop-home` in stock, the
per-group volume in B. Both need one interactive login, after which it persists
across runs.

Measured in B: `/pref` carries `CLAUDE.md`, `project-memory`, `settings.json`
and nothing else; `/home/dev/.claude/.credentials.json` is absent on a fresh
group and `/home/dev` is on the group volume. So the first run of a new group
costs one login and later runs cost none. Dropping the `~/.claude` mount did not
change this, because that mount was never the auth path.

## 4. Group model

The group is the sharing unit. For B this is mostly about not making N
containers step on each other; it matters much more for variant A.

| Per group | Shared in-group | Across groups |
|---|---|---|
| `cleanroom-home-<g>` → `/home/dev` | auth, npm-global, history, memories | separate volume |
| `cleanroom-<g>` bridge, `10.202.N.0/24` | containers reach each other | separate bridge; traffic dropped |
| `cleanroom-patches-<g>` → `/output` | staged patches | separate volume |
| `cleanroom-app-<g>-<repo>` → `/app` | — | one per repo |

Measured: group `alpha` across two repos shared `/home` (a marker written by one
container was read by the other) while keeping separate trees (282 files vs 70).
Group `beta` saw no marker and landed on a different subnet.

**Patches go to a group volume, not a host directory.** `save-patch` writes to
`/output` = `cleanroom-patches-<g>`; a human drains it with `drain.sh`. The
reason is collision, not secrecy: N containers writing into one host checkout is
the clobbering failure we keep hitting with shared worktrees, with less
visibility. Proven end to end — the container ran `save-patch`, `git status` in
`~/proj/claude-control` showed nothing written into the checkout, and the drain
produced a patch that `git am` accepts.

**Octet allocation reads Docker, not just the registry file.** `groups.tsv` sits
next to the script, so a second checkout restarts numbering; testing hit exactly
that and Docker refused with *pool overlaps with other one on this address
space*. The allocator now unions the file with the subnets of live `cleanroom-*`
networks. Re-verified: the second group took `.11` rather than colliding on `.10`.

## 5. Network

Per-group bridge with a `/24` from `10.202.0.0/16`.

- default bridge has **no egress** — `nslookup` times out, `ping 8.8.8.8` 100% loss.
  `inet gw`'s forward chain is `policy drop` and `172.17/16` matches no accept rule.
- `10.202.x` **has egress** — DNS resolved, ping succeeded, and the reserved
  rule's counter moved `0 → 1`, confirming that rule carried it
  (`ip saddr 10.202.0.0/16 oifname "eno2" accept`, masqueraded by `gw_nat`).
- **cross-group traffic is dropped** — `10.202.99.x` could not reach
  `10.202.98.2`; the gw rule only accepts outbound via `eno2`, and Docker adds
  its own per-network drop.
- `--network host` also reaches the network but puts the container on flatpot's
  loopback (grafana, the cloud-init seed, squid, gunicorn). Not needed here, so
  not used.

## 6. Storage

Volumes live in `/home/docker/volumes`; image layers in `/home/containerd` (10 G).
Both on the 81 G `/home`, 27 G free. `/tmp` is a 124 G tmpfs and costs RAM.

Group homes go on `/home` as ordinary named volumes. What a group home exists to
persist is the login; on `/tmp` every reboot would cost one interactive auth
round per group. **Per-group growth is unmeasured** — see §7.

`claude-loop-base` was never rebuilt, re-pulled or pruned. B builds no image at
all: it runs the existing base with a bind-mounted entrypoint, so it adds no
layers and has no recovery path that depends on fetching the base again.

## 7. What is built, and the delta for variant A

**Built and run (B)** — `fresh/{fresh.sh,entrypoint-fresh.sh,drain.sh,README.md}`
against `~/proj/claude-control`: 282 files seeded, `baseline` tag intact, the
hygiene rows of §2, egress on `10.202.10.2`, `claude --version` → 2.1.201.
Re-verified from the landed layout so `../save-patch` resolves.

**Variant A is not a build.** `sandbox.sh run` already *is* the host
configuration sandboxed: `entrypoint.sh` copies the host `CLAUDE.md`, `memory/`,
`agents/`, the merged `settings.json` and `projects/<key>/memory`, and
`claude-loop-home:/home/dev` is already the persistent home. What it has is a
three-item delta:

1. **25 of 27 hook entries point at host paths absent in the container** (§2).
2. **claude-control is not reachable from inside.** `docker-compose.base.yml`
   mounts only `save-patch` and `screenshot` into `/usr/local/bin` — no
   wrappers, no `cc-socks`. So the container inherits hooks asserting it is a
   fleet member while having no way to message a Manager.
3. **`/home` is one `claude-loop-home` volume, not per-group.** This is the only
   genuinely new construction in A, and B's group model is directly reusable.

**(1) and (2) are the same defect and must be resolved the same way: pick one
and make it true.** Either mount claude-control (wrappers + `cc-socks`) so the
hooks resolve and the agent really is a fleet member, or strip those hook
entries so it honestly is not. **My recommendation is to strip**, for A as it
stands today: a container that can reach the host fleet can also perturb the
fleet that is supervising it, which is the coupling `sandbox` exists to avoid,
and the wiring to make it genuinely work is item 3's per-group control plane
rather than a mount of the host's. Half-wired is the one unacceptable answer,
and half-wired is what ships today — it looks like a working agent and stalls
silently, which is the failure this fleet exists to catch.

**Measured for A's item 3:** a group `/home` volume is **608 K after one run**
(`/home/docker/volumes/fresh-home-b1/_data`). That is a first-run floor, not a
steady state — it predates any npm-global install, model cache or session
history, so it bounds nothing. A long autonomous run is still needed before the
81 G `/home` budget can be reasoned about, and that run has not happened in
either variant.

**Still unproven:** no long autonomous agent run inside either variant; A's
fleet plumbing has not been tested end to end, and should not be asserted to
work until it has been.

## 8. Proposals on the page

| # | What | Independent? |
|---|---|---|
| **#261** | superseded — its stated reason is the withdrawn security framing. **Should be denied.** Never applied, so denying it runs nothing and just clears the row. | — |
| **#263** | adds `fresh/` (variant B) on branch `fresh-variant` | yes |
| **#269** | the hook strip: a bug fix to the *existing* `loop/`+`android/` on branch `hook-strip` | yes |

#263 and #269 are deliberately separate rows — either is useful without the
other, and #269 fixes something that is broken today regardless of whether
variant B ever lands.

**#269, verified three ways in a container** (patched `entrypoint.sh` +
`HOST_HOME` from compose):

- fresh copy, `HOST_HOME=/home/hila` → **27 → 2 entries**, survivors are the
  `git-mega` check and the session-end `echo`, both written against `$HOME`/`~`
- merge path with a pre-existing container-written key → 2 entries **and the
  container key survived**, so merge semantics are intact
- `HOST_HOME` unset → **27 entries, unchanged**: the fallback is exactly
  today's behaviour, which keeps the entrypoint safe outside compose

That last case doubles as the negative control — the filter is keying on the
host path, not deleting indiscriminately. Testing is also what turned up the
`kgrab-cresume` pair, which neither the Manager nor I predicted; it is the
second thing this task found that way.

Left behind: nothing. All test networks and volumes removed; an empty `patches/`
directory an early iteration created in `~/proj/claude-control` has been removed
and that checkout is as it was found.
