#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/workspace/toolchains/android-sdk}}"
CMDLINE_TOOLS_DIR="$SDK_ROOT/cmdline-tools/latest"
SDKMANAGER="$CMDLINE_TOOLS_DIR/bin/sdkmanager"
ANDROID_USER_HOME="${ANDROID_USER_HOME:-$SDK_ROOT/.android-user}"
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_USER_HOME

# Pinned from Google's official Android repository metadata at:
# https://dl.google.com/android/repository/repository2-1.xml
TOOLS_ARCHIVE="commandlinetools-linux-16111833_latest.zip"
TOOLS_SHA1="e025545c62a8e64c7559119566a569fb1dec5f60"

if [[ ! -x "$SDKMANAGER" ]]; then
  if [[ -e "$CMDLINE_TOOLS_DIR" ]]; then
    echo "Refusing to replace incomplete command-line tools at $CMDLINE_TOOLS_DIR" >&2
    exit 1
  fi
  command -v curl >/dev/null
  command -v sha1sum >/dev/null
  command -v unzip >/dev/null
  mkdir -p "$SDK_ROOT/cmdline-tools"
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 \
    "https://dl.google.com/android/repository/$TOOLS_ARCHIVE" \
    -o "$temp_dir/$TOOLS_ARCHIVE"
  printf '%s  %s\n' "$TOOLS_SHA1" "$temp_dir/$TOOLS_ARCHIVE" | sha1sum --check
  mkdir "$temp_dir/extracted"
  unzip -q "$temp_dir/$TOOLS_ARCHIVE" -d "$temp_dir/extracted"
  mv "$temp_dir/extracted/cmdline-tools" "$CMDLINE_TOOLS_DIR"
fi

"$SDKMANAGER" --sdk_root="$SDK_ROOT" --install \
  'platforms;android-36' \
  'platforms;android-35' \
  'build-tools;36.0.0' \
  'build-tools;35.0.0' \
  'cmake;3.22.1' \
  'ndk;27.0.12077973' \
  'platform-tools'

version="$("$SDKMANAGER" --version 2>/dev/null | tail -n 1)"
packages="$("$SDKMANAGER" --sdk_root="$SDK_ROOT" --list_installed 2>/dev/null)"
for package in 'platforms/android-36' 'platforms/android-35' 'build-tools/36.0.0' 'build-tools/35.0.0' 'cmake/3.22.1' 'ndk/27.0.12077973' 'platform-tools'; do
  if ! grep -Fq "$package" <<<"$packages"; then
    echo "Expected SDK package is missing: $package" >&2
    exit 1
  fi
done
printf 'Android SDK ready at %s (sdkmanager %s)\n' "$SDK_ROOT" "$version"
