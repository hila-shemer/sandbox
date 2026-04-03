FROM ghcr.io/hila-shemer/android-dev:latest

# Create AVD (project-specific: API 34, pixel_6 profile)
RUN echo "no" | avdmanager create avd \
    -n wcd_test \
    -k "system-images;android-34;google_apis;x86_64" \
    --device "pixel_6"

WORKDIR /app

# Copy only build files first (dependency cache layer)
COPY build.gradle.kts settings.gradle.kts gradle.properties ./
COPY gradle/ gradle/
COPY gradlew ./
COPY app/build.gradle.kts app/
COPY app/src/main/AndroidManifest.xml app/src/main/AndroidManifest.xml

# Download dependencies (cached unless build files change)
RUN chmod +x gradlew && \
    ./gradlew dependencies --no-daemon || true

# Source code (changes frequently)
COPY . .

CMD ["/bin/bash"]
