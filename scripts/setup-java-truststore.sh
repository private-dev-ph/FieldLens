#!/usr/bin/env bash
set -euo pipefail

JAVA_HOME="${JAVA_HOME:-/workspace/toolchains/jdk}"
KEYTOOL="$JAVA_HOME/bin/keytool"
SOURCE_CACERTS="$JAVA_HOME/lib/security/cacerts"
TRUSTSTORE="${FIELDLENS_JAVA_TRUSTSTORE:-/workspace/toolchains/java-truststore/cacerts}"
CERT_FILE="${CODEX_PROXY_CERT:-}"
ALIAS='fieldlens-proxy-ca'

if [[ -z "$CERT_FILE" ]]; then
  echo 'No environment-provided Java CA certificate is configured.' >&2
  exit 1
fi
if [[ ! -x "$KEYTOOL" || ! -r "$SOURCE_CACERTS" || ! -r "$CERT_FILE" ]]; then
  echo 'Java truststore setup requires a readable JDK cacerts and environment CA certificate.' >&2
  exit 1
fi
if [[ "$(python3 -c 'import os,sys; print(open(sys.argv[1], "rb").read().count(b"-----BEGIN CERTIFICATE-----"))' "$CERT_FILE")" != 1 ]]; then
  echo 'Expected exactly one PEM X.509 certificate in the environment CA file.' >&2
  exit 1
fi
openssl x509 -in "$CERT_FILE" -noout >/dev/null
openssl x509 -in "$CERT_FILE" -checkend 0 -noout >/dev/null

truststore_dir="$(dirname "$TRUSTSTORE")"
mkdir -p "$truststore_dir"
if [[ ! -f "$TRUSTSTORE" ]]; then
  cp "$SOURCE_CACERTS" "$TRUSTSTORE"
  chmod 600 "$TRUSTSTORE"
fi
source_fingerprint="$(openssl x509 -in "$CERT_FILE" -outform DER | sha256sum | awk '{print $1}')"
if "$KEYTOOL" -exportcert -alias "$ALIAS" -keystore "$TRUSTSTORE" \
    -storepass changeit 2>/dev/null | sha256sum | awk '{print $1}' | \
    grep -Fxq "$source_fingerprint"; then
  printf 'Java truststore already contains the configured CA: %s\n' "$TRUSTSTORE"
  exit 0
fi
if "$KEYTOOL" -list -keystore "$TRUSTSTORE" -storepass changeit \
    -alias "$ALIAS" >/dev/null 2>&1; then
  "$KEYTOOL" -delete -keystore "$TRUSTSTORE" -storepass changeit -alias "$ALIAS"
fi
"$KEYTOOL" -importcert -noprompt -trustcacerts -alias "$ALIAS" \
  -file "$CERT_FILE" -keystore "$TRUSTSTORE" -storepass changeit
chmod 600 "$TRUSTSTORE"
printf 'Java truststore prepared at %s with the configured CA.\n' "$TRUSTSTORE"
