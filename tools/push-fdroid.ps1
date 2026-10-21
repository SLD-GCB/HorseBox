param([string]$Apk, [string]$VersionCode)
$ErrorActionPreference = "Stop"
$repo = "https://github.com/SLD-GCB/SLD-GCB_f-droid.git"
$work = Join-Path $env:TEMP "fdroid_push"
if (-not (Test-Path $Apk)) { Write-Host "[f-droid] APK not found: $Apk"; exit 1 }
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
git clone --depth 1 -b actions $repo $work
$name = "HorseBox-" + $VersionCode + ".apk"
Copy-Item $Apk (Join-Path $work ("apk/" + $name))
Push-Location $work
git add -f ("apk/" + $name)
git -c user.name="SLD-GCB" -c user.email="hdhdkc54748448@gmail.com" commit -m ("add HorseBox " + $VersionCode)
git push origin actions
Pop-Location
Write-Host "[f-droid] pushed $VersionCode"
