#!/bin/bash
# Build bridge.apk with the Android SDK's command-line tools (no Gradle).
#
#   android/bridge/build.sh [output.apk]
#
# Needs ANDROID_HOME (or ANDROID_SDK_ROOT) with a platform and build-tools, and a
# JDK 17+. GitHub's ubuntu-latest and macos runners have both. The version code
# comes from MSA_BRIDGE_VERSION in apple/Config/Base.xcconfig, so the app knows
# which bridge it ships.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
OUT="${1:-${ROOT}/build/payload/bridge.apk}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "${SDK}" ] || { echo "Set ANDROID_HOME to your Android SDK"; exit 1; }

# Newest stable build-tools and platform (skip previews such as -rc1 or -beta3).
newest() { local all stable; all="$(ls -d "$@" 2>/dev/null | sort -V)"; stable="$(grep -E '[-/][0-9.]+$' <<<"${all}" || true)"; tail -1 <<<"${stable:-${all}}"; }
BUILD_TOOLS="$(newest "${SDK}"/build-tools/*)"
PLATFORM="$(newest "${SDK}"/platforms/android-*)/android.jar"
VERSION="$(awk -F' *= *' '/^MSA_BRIDGE_VERSION/ {print $2}' "${ROOT}/apple/Config/Base.xcconfig")"
VERSION="${VERSION:-1}"
echo "Building bridge ${VERSION} with $(basename "${BUILD_TOOLS}") and $(basename "$(dirname "${PLATFORM}")")"

WORK="${ROOT}/build/bridge"
rm -rf "${WORK}"
mkdir -p "${WORK}/classes" "${WORK}/dex" "$(dirname "${OUT}")"

"${BUILD_TOOLS}/aapt2" compile --dir "${HERE}/res" -o "${WORK}/res.zip"
"${BUILD_TOOLS}/aapt2" link -o "${WORK}/base.apk" -I "${PLATFORM}" \
    --manifest "${HERE}/AndroidManifest.xml" "${WORK}/res.zip" \
    --min-sdk-version 30 --target-sdk-version 35 \
    --version-code "${VERSION}" --version-name "${VERSION}"

find "${HERE}/src" -name '*.java' > "${WORK}/sources.txt"
javac --release 11 -encoding UTF-8 -classpath "${PLATFORM}" -d "${WORK}/classes" @"${WORK}/sources.txt"

"${BUILD_TOOLS}/d8" --release --min-api 30 --lib "${PLATFORM}" --output "${WORK}/dex" \
    $(find "${WORK}/classes" -name '*.class')

cp "${WORK}/base.apk" "${WORK}/unsigned.apk"
(cd "${WORK}/dex" && zip -q "${WORK}/unsigned.apk" classes.dex)
"${BUILD_TOOLS}/zipalign" -f 4 "${WORK}/unsigned.apk" "${WORK}/aligned.apk"

# The signing key only has to stay the same between versions (Android refuses
# updates signed by a different key). Use BRIDGE_KEYSTORE to keep one; otherwise
# a key is made in build/ and reused.
KEYSTORE="${BRIDGE_KEYSTORE:-${ROOT}/build/bridge.keystore}"
if [ ! -f "${KEYSTORE}" ]; then
    keytool -genkeypair -keystore "${KEYSTORE}" -storepass android -keypass android \
        -alias bridge -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Mac Android Subsystem bridge" >/dev/null
fi
"${BUILD_TOOLS}/apksigner" sign --ks "${KEYSTORE}" --ks-pass pass:"${BRIDGE_KEYSTORE_PASSWORD:-android}" \
    --ks-key-alias bridge --out "${OUT}" "${WORK}/aligned.apk"
echo "Wrote ${OUT}"
