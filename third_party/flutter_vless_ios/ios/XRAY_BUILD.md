# Build XRay.xcframework

The iOS plugin uses `XRay.xcframework`, generated with `gomobile bind` from `github.com/EbrahimTahernejad/xray-mobile`.

Current target Xray-core version: `v26.6.1`.
Release commit used by the script: `94ffd50060f1cfd5d7482ec90a23a92bdefdff68`.

Requirements:

- Full Xcode with iOS SDK installed and selected with `xcode-select`.
- Go installed.
- `gomobile` installed, or let the script install it into `$HOME/go/bin`.

Build:

```bash
cd ios
./build_xray_ios.sh
```

If `xcode-select -p` points to Command Line Tools, either switch Xcode globally:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

or run only this build with Xcode selected:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./ios/build_xray_ios.sh
```

Useful overrides:

```bash
XRAY_CORE_REF=94ffd50060f1cfd5d7482ec90a23a92bdefdff68 IOS_VERSION=15.0 ./build_xray_ios.sh
```

Note: Xcode Command Line Tools are not enough because `gomobile bind -target=ios` needs the `iphoneos` and `iphonesimulator` SDKs.
