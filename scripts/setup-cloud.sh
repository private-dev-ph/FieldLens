#!/usr/bin/env bash
set -euo pipefail

# Each task is already isolated. Reuse this checkout; do not create worktrees.
repo=/workspace/FieldLens
sdk=/workspace/toolchains/flutter
expected_commit=adc901062556672b4138e18a4dc62a4be8f4b3c2
export PUB_CACHE=/workspace/toolchains/pub-cache
export XDG_CONFIG_HOME=/workspace/toolchains/config
export ANALYZER_STATE_LOCATION_OVERRIDE=/workspace/toolchains/analyzer-state
export LD_LIBRARY_PATH="/workspace/toolchains/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
mkdir -p /workspace/toolchains
# sqlite3 on Linux loads libsqlite3.so; this machine already has the versioned
# runtime library. Provide its loader alias locally instead of changing /usr.
mkdir -p /workspace/toolchains/lib
if [ -f /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ]; then
  if [ ! -e /workspace/toolchains/lib/libsqlite3.so ] && [ ! -L /workspace/toolchains/lib/libsqlite3.so ]; then
    ln -s /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /workspace/toolchains/lib/libsqlite3.so
  fi
fi
if [ ! -d "$sdk" ]; then
  git clone --depth 1 --branch 3.35.7 https://github.com/flutter/flutter.git "$sdk"
fi
test "$(git -C "$sdk" rev-parse HEAD)" = "$expected_commit"
export PATH="$sdk/bin:$PATH"
flutter --version
cd "$repo/apps/mobile"
if [ -f pubspec.lock ]; then
  flutter pub get --enforce-lockfile
else
  # Initial dependency resolution; retain and review the resulting lockfile.
  flutter pub get
fi
dart run build_runner build

bash "$repo/scripts/setup-jdk.sh"
if [ -n "${CODEX_PROXY_CERT:-}" ]; then
  JAVA_HOME=/workspace/toolchains/jdk bash "$repo/scripts/setup-java-truststore.sh"
fi
source "$repo/scripts/cloud-env.sh"
if [ -n "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}" ]; then
  bash "$repo/scripts/setup-gradle-proxy.sh"
fi
bash "$repo/scripts/setup-android.sh"
