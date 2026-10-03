#!/usr/bin/env bash
set -euo pipefail

GRADLE_USER_HOME="${GRADLE_USER_HOME:-/workspace/toolchains/gradle}"
mkdir -p "$GRADLE_USER_HOME"
export GRADLE_USER_HOME
python3 <<'PY'
import os
import pathlib
import tempfile
from urllib.parse import urlsplit

proxy_url = next((os.environ.get(key) for key in
                  ('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')
                  if os.environ.get(key)), '')
if not proxy_url:
    raise SystemExit('No HTTP(S) proxy is configured; no Gradle proxy settings were written.')

try:
    parsed = urlsplit(proxy_url if '://' in proxy_url else 'http://' + proxy_url)
    host = parsed.hostname or ''
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
except ValueError:
    raise SystemExit('Proxy configuration is invalid; no Gradle proxy settings were written.')
if not host or parsed.username is not None or parsed.password is not None:
    raise SystemExit('Proxy configuration is missing a host or contains credentials; refusing to save it in plaintext Gradle properties.')
if parsed.scheme not in ('http', 'https'):
    raise SystemExit('Unsupported proxy scheme; expected HTTP or HTTPS.')
if ':' in host and not host.startswith('['):
    host = f'[{host}]'

non_proxy_hosts = ['localhost', '127.*', '[::1]']
for entry in os.environ.get('NO_PROXY', os.environ.get('no_proxy', '')).split(','):
    entry = entry.strip()
    if not entry:
        continue
    if entry.startswith('.'):
        entry = '*' + entry
    if entry not in non_proxy_hosts:
        non_proxy_hosts.append(entry)

user_home = pathlib.Path(os.environ['GRADLE_USER_HOME'])
properties_file = user_home / 'gradle.properties'
marker_begin = '# BEGIN cloud Gradle proxy settings'
marker_end = '# END cloud Gradle proxy settings'
existing = properties_file.read_text(encoding='utf-8') if properties_file.exists() else ''
lines = existing.splitlines()
if lines.count(marker_begin) != lines.count(marker_end) or lines.count(marker_begin) > 1:
    raise SystemExit(f'Existing managed Gradle proxy block is malformed in {properties_file}; leaving it unchanged.')
if marker_begin in lines:
    start = lines.index(marker_begin)
    end = lines.index(marker_end, start + 1)
    del lines[start:end + 1]

block = [
    marker_begin,
    f'systemProp.http.proxyHost={host}',
    f'systemProp.http.proxyPort={port}',
    f'systemProp.https.proxyHost={host}',
    f'systemProp.https.proxyPort={port}',
    f"systemProp.http.nonProxyHosts={'|'.join(non_proxy_hosts)}",
]
truststore = pathlib.Path(os.environ.get(
    'FIELDLENS_JAVA_TRUSTSTORE', '/workspace/toolchains/java-truststore/cacerts'))
if truststore.is_file():
    block.extend([
        f'systemProp.javax.net.ssl.trustStore={truststore}',
        'systemProp.javax.net.ssl.trustStorePassword=changeit',
    ])
block.append(marker_end)
while lines and not lines[-1].strip():
    lines.pop()
output = '\n'.join(lines + ([''] if lines else []) + block) + '\n'
fd, temp_name = tempfile.mkstemp(prefix='gradle.properties.', dir=user_home)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as temp_file:
        temp_file.write(output)
    os.chmod(temp_name, 0o600)
    os.replace(temp_name, properties_file)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)
print(f'Gradle proxy configured at {host}:{port} in {properties_file}; proxy credentials were not stored.')
PY
