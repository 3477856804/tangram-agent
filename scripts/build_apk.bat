@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================================
echo  TGA tangram-agent 一键打包 (Windows)
echo  产物: 仓库根目录\tangram-agent.apk
echo ============================================================
echo.

where flutter >nul 2>nul
if errorlevel 1 (
  echo [X] 未找到 flutter 命令。请先安装 Flutter 3.50 ^(或 >=3.41^) 并加入 PATH。
  pause
  exit /b 1
)

echo [1/6] 工具链版本
call flutter --version
echo.

set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

if not exist "frontend\pubspec.yaml" (
  echo [X] 未找到 frontend\pubspec.yaml，请在仓库根目录运行本脚本。
  pause
  exit /b 1
)

echo [2/6] 清理旧产物与增量缓存
pushd frontend
call flutter clean >nul 2>nul
popd
if exist "tangram-agent.apk" del /f /q "tangram-agent.apk"

echo [3/6] flutter pub get
pushd frontend
call flutter pub get
if errorlevel 1 (
  echo [X] flutter pub get 失败。
  popd
  pause
  exit /b 1
)

echo.
echo [4/6] flutter build apk --release  ^(首次构建约 10-25 分钟^)
call flutter build apk --release
set "RC=%ERRORLEVEL%"
popd

echo.
echo [5/6] 收集 APK
set "OUT="
for /f "delims=" %%F in ('dir /b /s /o-d "frontend\build\app\outputs\flutter-apk\*.apk" 2^>nul') do if not defined OUT set "OUT=%%F"
if not defined OUT for /f "delims=" %%F in ('dir /b /s /o-d "frontend\android\app\build\outputs\flutter-apk\*.apk" 2^>nul') do if not defined OUT set "OUT=%%F"
if not defined OUT for /f "delims=" %%F in ('dir /b /s /o-d "frontend\build\app\outputs\apk\release\*.apk" 2^>nul') do if not defined OUT set "OUT=%%F"

if not defined OUT (
  echo [X] 未找到 APK 产物 ^(flutter 退出码 !RC!^)。请把上面的报错发给张宇。
  pause
  exit /b 1
)

copy /y "!OUT!" "tangram-agent.apk" >nul
if errorlevel 1 (
  echo [X] 拷贝 APK 失败: !OUT!
  pause
  exit /b 1
)

echo [6/6] 完成
for %%A in ("tangram-agent.apk") do echo 产物: %CD%\tangram-agent.apk  大小: %%~zA 字节
echo.
echo 下一步: 把 tangram-agent.apk 传到手机安装 ^(需允许「未知来源」^)。
start "" "%CD%"
pause
exit /b 0
