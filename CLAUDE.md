# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The **canonical Docker sandbox** pattern for running Claude Code in a container against an arbitrary host project. Three variants share one Dockerfile, one entrypoint, and one compose-base file:

- `loop/` — Claude Code + generic dev + C toolchain + Android SDK (no emulator).
- `android/` — same image as loop, plus a Cuttlefish sidecar for ADB-connected Android testing.
- `llm/` — extends loop-base with PyTorch (CUDA) + HF training stack (transformers, datasets, accelerate, peft, trl, bitsandbytes). Requires NVIDIA GPU on host.

Every change should keep the variants symmetric: shared logic in the root files, variant-specific bits gated on `$ADB_TARGET` (entrypoint) or in `<variant>/docker-compose.yml`.

## Common commands

```bash
./sandbox.sh run    {loop|android}    # build + run --rm (PROJECT_DIR=$PWD by default)
./sandbox.sh attach {loop|android}    # docker exec into a running container
./sandbox.sh stop   {loop|android}    # docker compose down
./sandbox.sh clear  {loop|android}    # remove the per-project /app volume (re-seeds next run)

./build.sh                            # build + push the base image to ghcr.io
./run_tests.sh                        # ralph.sh argument-parser + resume-flow tests (uses a stub `claude`)
```

`sandbox.sh` derives `SANDBOX_DIR` from its own path and `PROJECT_DIR` from `$PWD` (or override). `HOST_UID`/`HOST_GID` default to the invoking user's IDs so bind-mounted files end up host-owned.

The `claude-loop-base` image is **not** built by `docker compose build` — it lives on `ghcr.io/hila-shemer/` and is rebuilt manually via `build.sh`. Per-project `docker compose build` only builds the thin Stage-2 image on top. The `loop` and `android` variants use `claude-loop-base`; the `llm` variant uses `claude-llm-base` (which itself extends `claude-loop-base`).

## Architecture

### Build flow (one Dockerfile, two variants)

`Dockerfile` is shared; both variants build from `claude-loop-base`. Stage 1 always uses loop-base — it just needs `git` to run `git ls-files | xargs cp --parents` so the copied tree mirrors what's tracked (plus uncommitted modifications), without any hardcoded file list. Stage 2 copies the extracted tree to `/app-seed`.

Build context = `PROJECT_DIR` (the user's project), not this repo. Dockerfile path = `SANDBOX_DIR/Dockerfile`. This is why everything is plumbed via env vars in `docker-compose.base.yml`.

### Volume topology (read this before changing compose files)

| Mount                            | Purpose                                                    |
|----------------------------------|------------------------------------------------------------|
| `claude-app` (named, per-project)| `/app` — semi-persistent project working tree. Seeded from `/app-seed` on first run; survives container restarts so in-progress work isn't lost. `sandbox.sh clear` wipes it. |
| `claude-{loop,android}-home`     | `/home/dev` — persistent shell history, gradle cache, npm-global, Claude auth. **External** — created once with `docker volume create`. |
| `$PROJECT_DIR/patches` (bind)    | `/output` — escape hatch for `save-patch`.                 |
| `$PROJECT_DIR/.notes` (bind)     | `/home/dev/notes` — scratch outside `/app` (so it never enters patches). |
| `$HOME/.claude` (bind, ro)       | `/host-claude` — entrypoint syncs `CLAUDE.md`, `agents/`, and **merges** `settings.json` into the home volume (auth files left alone). |
| `cf-images` (android only)       | Caches multi-GB `cvd fetch` output between runs.           |

The base compose file declares `claude-app` as a volume reference but **does not name it** — naming it `claude-app-${PROJECT_NAME}` happens in each variant's compose file so each project gets its own isolated history.

### Entrypoint contract (`entrypoint.sh`)

Runs every container start, in this order:

1. `npm install -g @anthropic-ai/claude-code@latest` into the persistent `/home/dev/.npm-global` (PATH-prioritized over the baked-in `/usr/bin/claude`). Falls back to baked-in if offline.
2. Sync host preferences: copies `CLAUDE.md` + `agents/` from `/host-claude/`; **merges** `settings.json` with `jq -s '.[0] * .[1]'` so container-written keys survive.
3. Copies ralph sub-agents from `/opt/ralph/agents/*.md` into `~/.claude/agents/` only if not already present (preserves user/container tweaks).
4. Appends sandbox conventions (save-patch, baseline tag, scratch dir) to user-level CLAUDE.md. Android variant appends a JDK-path note + adb hint, gated on `$ADB_TARGET`.
5. First-run init: if `/app/.git` doesn't exist, copies `/app-seed/. → /app/`, runs `git init`, commits everything as `baseline`, tags it `baseline`. **`baseline` is load-bearing** — `save-patch` and the README's "what changed" semantics depend on it.
6. Adds ralph-runtime files (`STATUS.md`, `DECISIONS.md`, `PROBLEMS.md`, `CURRENT_TASK.md`, `ralph.log`) to `.git/info/exclude` so they never leak into `save-patch` output.
7. Exports `CLAUDE_FLAGS=--dangerously-skip-permissions` in `.bashrc` (the container itself is the permission boundary).
8. Starts `Xvfb :99` + `fluxbox` in the background and exports `DISPLAY=:99` (also persisted in `.bashrc` under a separate `# sandbox-display` sentinel so attach shells pick it up). GUI apps render headlessly; `screenshot [name]` writes a PNG to `/tmp/` for Claude to Read.
9. If `$ADB_TARGET` set: starts adb server, retries `adb connect` for ~150s.

When extending: **gate android-specific code on `$ADB_TARGET`**, not on a separate variant flag. That's the convention.

### `save-patch`

Inside the container, `save-patch [name]` rolls up any uncommitted work into a sandbox commit, then runs `git format-patch baseline..HEAD -o /output/<name>/`. Apply on host with `git am /output/<name>/*.patch`. Don't break the `baseline` tag — without it `save-patch` exits 1.

### Ralph (autonomous loop)

`ralph/` is bind-mounted read-only at `/opt/ralph`, also on `$PATH`. Three roles:

- **Planner** (Sonnet) — between task slices; reads memory + git log + actual files; writes `CURRENT_TASK.md`.
- **Executor** (Sonnet) — implements current slice, commits, runs tests via the `test-runner` Haiku sub-agent.
- **Reviewer** (Opus) — periodic outside eye, two modes: mid-task (drift inside one slice) and outer-cycle (drift across N planner cycles).

Two init paths produce `implementation_plan.md` before running `ralph.sh`:

- **Simple tasks** (bug fix, single feature): `ralph-init-simple.sh "description"` — Sonnet reads the codebase and produces a proportionate 1–3 phase plan.
- **Complex projects** (new app, multi-phase rewrite): use `description_prompt.md` as a sub-agent to produce a spec file, then `ralph-init.sh spec.md` — Opus produces a full structured plan.

Memory files (`STATUS.md`, `DECISIONS.md`, `PROBLEMS.md`, `CURRENT_TASK.md`) are runtime state in `/app`; entrypoint excludes them from git so they don't end up in patches. Resume via `--resume` reads `.ralph/phase` to re-enter at the right point. See `ralph/README.md` for prompts, modes, env-var matrix, and resume semantics.

`run_tests.sh` (this repo's own tests, not a project's) tests `ralph.sh`'s argument parser and resume flow using a stub `claude` on `PATH`. It deliberately doesn't `set -e` (it expects non-zero exits in some cases).

## Conventions

- **Variants stay symmetric.** Don't fork the Dockerfile or entrypoint per variant — gate variant logic on `$ADB_TARGET` or in compose. New shared volumes go in `docker-compose.base.yml`; only the variant-specific home volume goes in the variant compose file.
- **Don't break the `baseline` tag.** It's the contract for `save-patch` and "what changed in this run".
- **Don't add bind mounts that overlap `/app`.** `/app` is a named volume so it can survive restarts independently of host state.
- **`CLAUDE_FLAGS` is for invocation-agnostic flags only.** Mode-specific flags (`-p`, etc.) go per-call. (See `feedback_claude_flags_scope.md` in this project's auto-memory.)
- **No in-container Android emulator on Fedora.** Cuttlefish in a sidecar is the only working path; don't spend cycles re-trying KVM-in-container. (See `lesson_no_in_container_emulator_on_fedora.md`.)
