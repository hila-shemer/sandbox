#!/bin/bash
set -e

CF_BUILD="${CF_BUILD:-aosp-android-latest-release/aosp_cf_x86_64_only_phone-userdebug}"
CF_DIR="/root/cf_images"

# Start the orchestration services (original entrypoint)
/root/run_services.sh &

echo "Fetching Android images ($CF_BUILD)..."
cvd fetch --default_build="$CF_BUILD" --target_directory="$CF_DIR"

echo "Creating Cuttlefish device..."
cvd create --host_path="$CF_DIR" --product_path="$CF_DIR"

# Connect ADB so healthchecks (and other clients) can reach the device
"$CF_DIR/bin/adb" connect 0.0.0.0:6520

echo "Cuttlefish device ready, ADB on port 6520"

# Keep container alive
wait
