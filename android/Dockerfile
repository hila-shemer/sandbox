FROM ghcr.io/hila-shemer/android-dev:latest

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
