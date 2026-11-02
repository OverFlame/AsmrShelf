@echo off
rem AsmrShelf Windows 构建（薄包装：真正逻辑在 build_windows.ps1）
rem 用法：scripts\build_windows.bat [release^|debug^|profile]
setlocal
set MODE=%~1
if "%MODE%"=="" set MODE=release

where pwsh >nul 2>nul
if errorlevel 1 (
  echo 找不到 pwsh（PowerShell 7+）。可改用系统自带 powershell：
  echo   powershell -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" -Mode %MODE%
  exit /b 1
)

pwsh -NoLogo -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" -Mode %MODE%
exit /b %errorlevel%
