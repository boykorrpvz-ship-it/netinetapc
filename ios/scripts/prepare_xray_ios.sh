#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/../Packages/IronXrayTunnelSupport" && pwd)"
ARTIFACTS_DIR="$PACKAGE_DIR/Artifacts"
FRAMEWORK_DIR="$ARTIFACTS_DIR/XRay.xcframework"
ARCHIVE_PATH="$ARTIFACTS_DIR/XRay.xcframework.zip"
XRAY_URL="${FLUTTER_VLESS_XRAY_URL:-https://github.com/XIIIFOX/flutter_vless/releases/download/xray-ios-v26.6.1/XRay.xcframework.zip}"
XRAY_CHECKSUM="${FLUTTER_VLESS_XRAY_CHECKSUM:-13b512b31b394a701de95d1ea9ae7a8aad091d5b8d8db6d2e042374015254217}"

if [[ -d "$FRAMEWORK_DIR" ]]; then
  echo "XRay.xcframework is already prepared."
  exit 0
fi

mkdir -p "$ARTIFACTS_DIR"
curl --fail --location --retry 3 "$XRAY_URL" --output "$ARCHIVE_PATH"

ACTUAL_CHECKSUM="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_CHECKSUM" != "$XRAY_CHECKSUM" ]]; then
  echo "XRay archive checksum mismatch." >&2
  echo "Expected: $XRAY_CHECKSUM" >&2
  echo "Actual:   $ACTUAL_CHECKSUM" >&2
  rm -f "$ARCHIVE_PATH"
  exit 1
fi

unzip -q "$ARCHIVE_PATH" -d "$ARTIFACTS_DIR"
rm -f "$ARCHIVE_PATH"

if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  echo "XRay.xcframework was not found after extraction." >&2
  exit 1
fi

echo "Prepared $FRAMEWORK_DIR"
