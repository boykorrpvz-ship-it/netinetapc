$ErrorActionPreference = "Stop"

$project = Resolve-Path (Join-Path $PSScriptRoot "..")
$dev = Join-Path $env:USERPROFILE "dev"
$sdk = Join-Path $dev "android-sdk"
$env:JAVA_HOME = Join-Path $dev "jdk-17"
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:Path = @(
    (Join-Path $env:JAVA_HOME "bin"),
    (Join-Path $dev "flutter\bin"),
    (Join-Path $sdk "cmdline-tools\latest\bin"),
    (Join-Path $sdk "platform-tools"),
    (Join-Path $sdk "emulator"),
    $env:Path
) -join ";"

& (Join-Path $PSScriptRoot "start_emulator.ps1")

$serial = ((adb devices | Select-String -Pattern "^(emulator-\d+)\s+device").Matches[0].Groups[1].Value)
Push-Location $project
try {
    flutter build apk --debug
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build failed with exit code $LASTEXITCODE"
    }
    $apk = Join-Path $project "build\app\outputs\flutter-apk\app-debug.apk"
    adb -s $serial install -r $apk
    if ($LASTEXITCODE -ne 0) {
        throw "adb install failed with exit code $LASTEXITCODE"
    }
    adb -s $serial shell monkey -p shop.ironvpn.app -c android.intent.category.LAUNCHER 1
    Write-Host "IronVPN launched on $serial"
}
finally {
    Pop-Location
}
