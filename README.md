# sandbox

Container-based development environments for running Claude Code on a host
machine. Two variants:

- **`loop/`** — lightweight container with Claude Code + generic dev tools + C
  toolchain. Intended for ralph-style autonomous loops on arbitrary projects.
- **`android/`** — everything in `loop/` plus OpenJDK 21, the Android SDK
  (platforms-34, build-tools 34.0.0, platform-tools), and a companion
  Cuttlefish container serving as the target device over ADB.

Both variants bake the target project into `/app` at build time (via `git
ls-files`), let Claude Code edit and commit inside the container against an
isolated git history, and expose `./patches` at `/output` for extracting
artifacts back to the host.

## Layout

```
base/
  Dockerfile.claude-loop-base       Ubuntu 24.04 + generic + C toolchain + Claude Code
  Dockerfile.claude-android-base    FROM loop-base, adds JDK + Android SDK
loop/
  Dockerfile                        User setup + project bake, FROM claude-loop-base
  docker-compose.yml
  entrypoint.sh
android/
  Dockerfile                        User setup + project bake, FROM claude-android-base
  docker-compose.yml                Adds a Cuttlefish service, GPU, depends_on healthcheck
  entrypoint.sh                     Also waits for ADB at cuttlefish:6520
  entrypoint-cuttlefish.sh          Runs inside the Cuttlefish container
```

## Base images

The two base images are **not** part of `docker compose build` — they are built
manually and pushed to a registry the per-project Dockerfiles pull from.

```
docker build -t ghcr.io/hila-shemer/claude-loop-base:latest \
    -f base/Dockerfile.claude-loop-base base/
docker push ghcr.io/hila-shemer/claude-loop-base:latest

docker build -t ghcr.io/hila-shemer/claude-android-base:latest \
    -f base/Dockerfile.claude-android-base base/
docker push ghcr.io/hila-shemer/claude-android-base:latest
```

Rebuild when the toolchain needs to change; otherwise reuse the cached image.

## Prerequisites

- Linux host with Docker / `docker compose`.
- One-time volume creation for each variant you use:

  ```
  docker volume create claude-loop-home
  docker volume create claude-android-home
  ```

- For the `android/` variant: NVIDIA GPU with the container toolkit configured.
- Host `~/.claude` directory (mounted read-only so Claude Code preferences —
  `CLAUDE.md`, `agents`, `settings.json` — carry into the container).

## Usage

Both variants are driven by two environment variables:

- `PROJECT_DIR` — absolute path to the project you want to work on. Becomes
  both the Docker build context and the owner of `/output` (via
  `$PROJECT_DIR/patches`).
- `SANDBOX_DIR` — absolute path to this repo. Used to locate the Dockerfile
  and mount the entrypoint scripts.

Optional:

- `HOST_UID`, `HOST_GID` — default to `1000`. Set these if your host user id
  isn't 1000 so files written to bind-mounted directories end up owned by the
  host user.

### `loop/` — Claude-only container

```
export SANDBOX_DIR=$HOME/proj/sandbox
export PROJECT_DIR=$HOME/proj/my-project
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)
mkdir -p "$PROJECT_DIR/patches"

docker compose -f "$SANDBOX_DIR/loop/docker-compose.yml" build
docker compose -f "$SANDBOX_DIR/loop/docker-compose.yml" run --rm claude-loop
```

The project tree is baked into `/app`; a fresh git repo is initialized on
first run. Edits stay isolated from the host; use `/output` (= host's
`$PROJECT_DIR/patches`) to export patches or artifacts.

### `android/` — Claude + Cuttlefish device

```
export SANDBOX_DIR=$HOME/proj/sandbox
export PROJECT_DIR=$HOME/proj/my-android-project
export HOST_UID=$(id -u)
export HOST_GID=$(id -g)
mkdir -p "$PROJECT_DIR/patches"

docker compose -f "$SANDBOX_DIR/android/docker-compose.yml" build
docker compose -f "$SANDBOX_DIR/android/docker-compose.yml" run --rm claude-android
```

The Cuttlefish service starts first; `claude-android` waits on its
healthcheck and then connects ADB to `cuttlefish:6520`. The Cuttlefish web UI
is exposed on <https://localhost:1443>.

Inside the container:

```
adb devices                     # cuttlefish:6520
./gradlew assembleDebug
./gradlew installDebug
```

## Volumes

- `claude-loop-home` / `claude-android-home` (external) — `/home/dev` inside
  each container. Persists Claude auth/session state, shell history, gradle
  caches, etc.
- `cf-images` (managed by compose) — caches Cuttlefish's `cvd fetch` output so
  subsequent starts skip the multi-GB download.
- `$PROJECT_DIR/patches` → `/output` — bind mount for getting files out of the
  container.
- `$PROJECT_DIR/.notes` → `/home/dev/notes` — bind mount for untracked scratch
  files (plan.md, design notes, etc.). Bidirectional; lives outside `/app` so
  the container's git never sees it.

## Notes

- The `claude-android` container runs with SELinux labeling disabled
  (`label:disable`) and seccomp unconfined. These are workarounds for a Fedora
  host with container storage on a `/home` bind mount; harmless elsewhere.
- The Cuttlefish container runs `privileged: true` — it needs direct KVM and
  device access to boot the virtual Android device.
