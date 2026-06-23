# Shared sandbox Dockerfile. The final stage's base image is parameterized
# via BASE_IMAGE (default: loop-base). Variant compose files override it —
# e.g. android passes claude-android-base. Stage 1 always pulls loop-base,
# which is minimal and just needs `git` for the ls-files extraction.

# Must be declared before the first FROM so it is in global scope and visible
# to both FROM lines (Docker scoping rule for ARGs used in FROM).
ARG REGISTRY=ghcr.io/hila-shemer
ARG BASE_IMAGE=${REGISTRY}/claude-loop-base:latest

# --- Stage 1: extract git-tracked files from build context ---
# Uses `git ls-files` so the copied tree matches the repo's tracked files
# (including uncommitted modifications), without hardcoded file lists.
# Edge cases (this stage is ephemeral — only /out is carried into Stage 2, the
# .git of /src is discarded, so `git add -A` here has no lasting side effect):
#   - files present but nothing tracked (e.g. unpacked archive, empty index):
#     `git add -A` so they get copied.
#   - truly empty context: seed a placeholder so the entrypoint has something to
#     commit as `baseline` (an empty `cp` would otherwise exit 123).
FROM ${REGISTRY}/claude-loop-base:latest AS source
WORKDIR /src
COPY . /src
RUN git config --global --add safe.directory /src && \
    mkdir -p /out && \
    cd /src && \
    if [ -z "$(git ls-files)" ]; then git add -A 2>/dev/null || true; fi && \
    if [ -n "$(git ls-files)" ]; then \
        git ls-files -z | xargs -0 cp --parents -t /out; \
    else \
        printf '%s\n' '# Sandbox seed placeholder' 'The build context had no git-tracked files; commit files and rebuild to extract your project.' > /out/DEMO.md; \
    fi

# --- Stage 2: final image ---
FROM ${BASE_IMAGE}

# Create non-root user matching host UID (keeps volume-mounted file ownership sane)
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG PROJECT_DIR=/app
RUN if getent passwd ${HOST_UID} > /dev/null; then \
        usermod -l dev -d /home/dev -m $(getent passwd ${HOST_UID} | cut -d: -f1); \
    else \
        useradd -u ${HOST_UID} -m -s /bin/bash dev; \
    fi && \
    if getent group ${HOST_GID} > /dev/null; then \
        groupmod -n dev $(getent group ${HOST_GID} | cut -d: -f1) 2>/dev/null || true; \
    else \
        groupadd -g ${HOST_GID} dev; \
    fi && \
    mkdir -p /app /app-seed && chown dev:dev /app /app-seed && \
    mkdir -p "${PROJECT_DIR}" && chown dev:dev "${PROJECT_DIR}"

COPY --from=source --chown=dev:dev /out /app-seed

USER dev
WORKDIR /app

# Harmless no-op when gradlew isn't present (loop variant); needed for android.
RUN [ -f gradlew ] && chmod +x gradlew || true

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
