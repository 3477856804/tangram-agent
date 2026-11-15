# 稳健安装 Flutter SDK（Windows CI 专用）。
# 修 2026-11-15 build-all-platforms 下载失败：
#   1) 官方源 storage.googleapis.com 优先（GitHub runner 在境外），国内镜像兜底
#   2) 不用断点续传（镜像 range 不稳定会 curl 33），一次下完 -> 校验 -> 解压
#   3) 解压成功即视为校验通过（损坏的 zip Expand-Archive 会抛异常）
#
# 用法: powershell -File scripts/install_flutter.ps1 -Dest C:\flutter
param(
  [string]$Dest = 'C:\flutter',
  [string]$Version = '3.50.0'
)

$ErrorActionPreference = 'Stop'
$fname = "flutter_windows_${Version}-stable.zip"
$official = "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/$fname"
$mirror = "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/$fname"

if ($env:FLUTTER_MIRROR_FIRST -eq '1') {
  $urls = @($mirror, $official)
} else {
  $urls = @($official, $mirror)
}

$tmp = Join-Path $env:TEMP $fname
$ok = $false
foreach ($url in $urls) {
  Write-Host "==> 下载 Flutter $Version (windows): $url"
  if (Test-Path $tmp) { Remove-Item -Force $tmp }
  curl.exe -fL --retry 4 --retry-all-errors --retry-delay 2 `
    --connect-timeout 30 --speed-time 90 --speed-limit 20480 `
    -o $tmp $url
  if ($LASTEXITCODE -ne 0) {
    Write-Host "!! 下载失败，换下一个源" -WarningAction Continue
    continue
  }
  Write-Host "==> 解压并校验: $tmp"
  try {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    # Expand-Archive 遇到损坏/半截 zip 会抛异常，即校验
    Expand-Archive -Path $tmp -DestinationPath 'C:\' -Force
    $ok = $true
    break
  } catch {
    Write-Host "!! 解压校验失败，换下一个源重下: $_" -WarningAction Continue
  }
}

if (-not $ok) {
  Write-Error "所有源均失败，无法安装 Flutter $Version"
  exit 1
}

$flutterBin = Join-Path $Dest 'bin\flutter.bat'
& $flutterBin --version
Write-Host "==> Flutter 安装完成: $flutterBin"
