FROM ghcr.io/hila-shemer/android-dev:latest

# --- Root-level setup ---

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

USER dev

# Create AVD as dev user (written to /home/dev/.android)
RUN echo "no" | avdmanager create avd \
    -n wcd_test \
    -k "system-images;android-34;google_apis;x86_64" \
    --device "pixel_6"

# --- Dependency cache layer (rebuild only when build files change) ---
WORKDIR /app

COPY --chown=dev:dev build.gradle.kts settings.gradle.kts gradle.properties ./
COPY --chown=dev:dev gradle/ gradle/
COPY --chown=dev:dev gradlew ./
COPY --chown=dev:dev app/build.gradle.kts app/
COPY --chown=dev:dev app/src/main/AndroidManifest.xml app/src/main/AndroidManifest.xml

RUN chmod +x gradlew && \
    ./gradlew dependencies --no-daemon || true

# --- Source code (changes frequently) ---
COPY --chown=dev:dev . .
# .claude gets caught by the above COPY but belongs in home, not the workspace
RUN rm -rf /app/.claude

# --- Claude Code credentials (project-specific, never committed to git) ---
COPY --chown=dev:dev .claude/ /home/dev/.claude/

COPY --chown=dev:dev entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
