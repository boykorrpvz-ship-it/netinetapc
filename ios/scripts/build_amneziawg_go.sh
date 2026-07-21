#!/bin/sh
set -eu

PACKAGE_DIR="${SRCROOT}/Packages/AmneziaWGKit"
GO_DIR="${PACKAGE_DIR}/Sources/WireGuardKitGo"
OUTPUT_DIR="${GO_DIR}/out"
TEMP_DIR="${PROJECT_TEMP_DIR}/amneziawg-go"

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go is required to build the AmneziaWG iOS core."
  echo "Install it with: brew install go"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${TEMP_DIR}"
rm -f "${OUTPUT_DIR}/libwg-go.a"

make -C "${GO_DIR}" \
  PLATFORM_NAME="${PLATFORM_NAME}" \
  ARCHS="${ARCHS}" \
  SDKROOT="${SDKROOT}" \
  CONFIGURATION_BUILD_DIR="${OUTPUT_DIR}" \
  CONFIGURATION_TEMP_DIR="${TEMP_DIR}" \
  build
