#!/usr/bin/env bash
set -euo pipefail

TOOLCHAINS_ROOT="${FIELDLENS_TOOLCHAINS_ROOT:-/workspace/toolchains}"
JDK_HOME="$TOOLCHAINS_ROOT/jdk"
RELEASE_TAG='jdk-21.0.12.1+1'
ASSET='OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz'
EXPECTED_SHA256='ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94'
RELEASE_BASE="https://github.com/adoptium/temurin21-binaries/releases/download/${RELEASE_TAG//+/\%2B}"
REPOSITORY='https://github.com/adoptium/temurin21-binaries.git'

if [[ -x "$JDK_HOME/bin/java" && -x "$JDK_HOME/bin/javac" ]]; then
  "$JDK_HOME/bin/java" -version
  "$JDK_HOME/bin/javac" -version
  exit 0
fi
if [[ -e "$JDK_HOME" ]]; then
  echo "Refusing to replace incomplete JDK installation at $JDK_HOME" >&2
  exit 1
fi

command -v curl >/dev/null
command -v git >/dev/null
command -v sha256sum >/dev/null
command -v tar >/dev/null
mkdir -p "$TOOLCHAINS_ROOT"
temp_dir="$(mktemp -d "$TOOLCHAINS_ROOT/.jdk-install.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

# Ensure the pinned release tag exists in the official Adoptium repository.
git ls-remote --exit-code --tags "$REPOSITORY" "refs/tags/$RELEASE_TAG" >/dev/null
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
  "$RELEASE_BASE/$ASSET.sha256.txt" -o "$temp_dir/$ASSET.sha256.txt"
published_sha256="$(awk '{print $1}' "$temp_dir/$ASSET.sha256.txt")"
if [[ "$published_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "Adoptium checksum metadata does not match the pinned JDK release." >&2
  exit 1
fi
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
  "$RELEASE_BASE/$ASSET" -o "$temp_dir/$ASSET"
printf '%s  %s\n' "$EXPECTED_SHA256" "$temp_dir/$ASSET" | sha256sum --check
mkdir "$temp_dir/extracted"
tar -xzf "$temp_dir/$ASSET" --strip-components=1 -C "$temp_dir/extracted"
test -x "$temp_dir/extracted/bin/java"
test -x "$temp_dir/extracted/bin/javac"
printf '%s\n%s\n' "$RELEASE_TAG" "$EXPECTED_SHA256" > "$temp_dir/extracted/.fieldlens-source"
mv "$temp_dir/extracted" "$JDK_HOME"
"$JDK_HOME/bin/java" -version
"$JDK_HOME/bin/javac" -version
