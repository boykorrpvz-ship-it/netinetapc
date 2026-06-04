$ErrorActionPreference = "Stop"

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

$avdName = "IronVPN_Pixel_8_API_36"
$running = adb devices | Select-String -Pattern "^emulator-\d+\s+device"

if (-not $running) {
    Start-Process -FilePath (Join-Path $sdk "emulator\emulator.exe") -ArgumentList @(
        "-avd", $avdName,
        "-netdelay", "none",
        "-netspeed", "full"
    )
}

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 3
    $deviceLine = adb devices | Select-String -Pattern "^(emulator-\d+)\s+device"
    if ($deviceLine) {
        $serial = $deviceLine.Matches[0].Groups[1].Value
        $boot = (adb -s $serial shell getprop sys.boot_completed 2>$null | Select-Object -First 1).Trim()
        if ($boot -eq "1") {
            Write-Host "Emulator is ready: $serial"
            exit 0
        }
    }
} while ((Get-Date) -lt $deadline)

throw "Emulator did not finish booting in 5 minutes."
