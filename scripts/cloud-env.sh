# Source this file in each new shell after running scripts/setup-cloud.sh.
export PATH="/workspace/toolchains/flutter/bin:$PATH"
export PUB_CACHE=/workspace/toolchains/pub-cache
export XDG_CONFIG_HOME=/workspace/toolchains/config
export ANALYZER_STATE_LOCATION_OVERRIDE=/workspace/toolchains/analyzer-state
export LD_LIBRARY_PATH="/workspace/toolchains/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export ANDROID_HOME=/workspace/toolchains/android-sdk
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$ANDROID_HOME/.android-user"
export GRADLE_USER_HOME=/workspace/toolchains/gradle
if [ -x /workspace/toolchains/jdk/bin/javac ]; then
  export JAVA_HOME=/workspace/toolchains/jdk
  export PATH="$JAVA_HOME/bin:$PATH"
fi
if [ -f /workspace/toolchains/java-truststore/cacerts ]; then
  case "${JAVA_TOOL_OPTIONS:-}" in
    *-Djavax.net.ssl.trustStore=*) ;;
    *) export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djavax.net.ssl.trustStore=/workspace/toolchains/java-truststore/cacerts -Djavax.net.ssl.trustStorePassword=changeit" ;;
  esac
fi
