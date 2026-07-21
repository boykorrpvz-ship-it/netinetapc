#!/bin/bash
set -euo pipefail

XRAY_MOBILE_REPO="${XRAY_MOBILE_REPO:-https://github.com/EbrahimTahernejad/xray-mobile}"
XRAY_MOBILE_REF="${XRAY_MOBILE_REF:-1.8.1}"
XRAY_CORE_VERSION="${XRAY_CORE_VERSION:-v26.6.1}"
XRAY_CORE_REF="${XRAY_CORE_REF:-94ffd50060f1cfd5d7482ec90a23a92bdefdff68}"
IOS_VERSION="${IOS_VERSION:-15.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build_xray_ios}"
OUTPUT_XCFRAMEWORK="${OUTPUT_XCFRAMEWORK:-$SCRIPT_DIR/XRay.xcframework}"

if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go is required."
    exit 1
fi

if ! command -v gomobile >/dev/null 2>&1; then
    echo "gomobile not found, installing it with go install..."
    go install golang.org/x/mobile/cmd/gomobile@latest
    go install golang.org/x/mobile/cmd/gobind@latest
    export PATH="$HOME/go/bin:$PATH"
    gomobile init
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "Error: full Xcode with iOS SDK is required. Command Line Tools are not enough."
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

git clone --depth 1 --branch "$XRAY_MOBILE_REF" "$XRAY_MOBILE_REPO" "$BUILD_DIR/xray-mobile"
cd "$BUILD_DIR/xray-mobile"

# Xray-core uses calendar release tags but keeps the original module path.
# Pin by the release commit so Go resolves it to the matching v1.YYMMDD.0 module version.
go get "github.com/xtls/xray-core@$XRAY_CORE_REF"
go get -tool golang.org/x/mobile/cmd/gobind
go mod tidy

cat >> xray-mobile.go <<'GOEOF'

func GetVersion() string {
	return core.Version()
}

func MeasureDelay(url string) (int64, error) {
	return MeasureOutboundDelay("", url)
}

func MeasureOutboundDelay(ConfigureFileContent string, url string) (int64, error) {
	return 0, nil
}
GOEOF

gomobile bind \
    -a \
    -ldflags="-s -w -extldflags -lresolv" \
    -target=ios \
    -iosversion="$IOS_VERSION" \
    -o "$OUTPUT_XCFRAMEWORK" \
    github.com/EbrahimTahernejad/xray-mobile

echo "Created $OUTPUT_XCFRAMEWORK"
