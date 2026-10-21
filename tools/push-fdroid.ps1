param([string]$Apk, [string]$VersionCode)
$ErrorActionPreference = "Stop"
$repo = "https://github.com/SLD-GCB/SLD-GCB_f-droid.git"
$work = Join-Path $env:TEMP "fdroid_push"
if (-not (Test-Path $Apk)) { Write-Host "[f-droid] 找不到 APK: $Apk"; exit 1 }
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
git clone --depth 1 -b actions $repo $work
Copy-Item $Apk (Join-Path $work ("apk/HorseBox-" + $VersionCode + ".apk"))
Push-Location $work
git add -f ("apk/HorseBox-" + $VersionCode + ".apk")
git -c user.name="SLD-GCB" -c user.email="hdhdkc54748448@gmail.com" commit -m ("添加 HorseBox " + $VersionCode + " 的 APK")
git push origin actions
Pop-Location
Write-Host "[f-droid] 已推送 $VersionCode，CI 会自动发布"
