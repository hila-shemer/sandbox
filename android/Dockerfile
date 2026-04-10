# --- Stage 1: extract git-tracked files from build context ---
# Uses `git ls-files` so the copied tree matches the repo's tracked files
# (including uncommitted modifications), without hardcoded file lists.
FROM ghcr.io/hila-shemer/android-dev:latest AS source
WORKDIR /src
COPY . /src
RUN git config --global --add safe.directory /src && \
    mkdir -p /out && \
    cd /src && \
    git ls-files | xargs cp --parents -t /out

# --- Stage 2: final image ---
FROM ghcr.io/hila-shemer/android-dev:latest

# Create non-root user matching host UID (keeps volume-mounted file ownership sane)
ARG HOST_UID=1000
ARG HOST_GID=1000
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
    mkdir -p /app && chown dev:dev /app

COPY --from=source --chown=dev:dev /out /app

USER dev
WORKDIR /app

RUN chmod +x gradlew entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/bin/bash"]
