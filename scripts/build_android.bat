@echo off
rem ============================================================
rem  AsmrShelf Android build script (Windows)
rem  Requires: Flutter in PATH, JDK 17+, Android SDK installed
rem ============================================================
setlocal
cd /d "%~dp0.."

rem China mirrors
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

rem Android SDK path: use env var if set, else default D:\Android\sdk
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=D:\Android\sdk"
set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

echo ==^> flutter pub get
call flutter --no-version-check --suppress-analytics pub get
if errorlevel 1 goto :err

echo ==^> flutter build apk --release
call flutter --no-version-check --suppress-analytics build apk --release
if errorlevel 1 goto :err

echo.
echo Build done: build\app\outputs\flutter-apk\app-release.apk
goto :eof

:err
echo Build failed (exit code %errorlevel%)
exit /b 1
