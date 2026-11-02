<#
AsmrShelf — Windows 构建脚本

用法：
  pwsh -File scripts\build_windows.ps1 [选项]

选项：
  -Mode <release|debug|profile>   构建模式，默认 release
  -Clean                          构建前执行 flutter clean
  -NoPub                          跳过 flutter pub get
  -FlutterBin <路径>              指定 flutter 可执行文件

产物：build\windows\<架构>\runner\<模式>\asmrshelf.exe
日志：<应用根>\logs\build_windows_<时间戳>.log（可用环境变量 APP_LOG_DIR 覆盖）

环境变量覆盖：FLUTTER_BIN、APP_LOG_DIR、FLUTTER_STORAGE_BASE_URL、PUB_HOSTED_URL

前提：Flutter SDK + Visual Studio（含「使用 C++ 的桌面开发」工作负载）。
Flutter 不支持在 Linux 上交叉编译 Windows，本脚本必须在 Windows 上运行；
从 WSL/Linux 一键触发请用 scripts/build_windows_remote.sh。

关于 sqlite3：pubspec.yaml 的 hooks 段写成
  sqlite3:
    source: system
    name_windows: winsqlite3
即 Windows 上改用系统自带的 winsqlite3.dll（Win10+），构建过程不访问 GitHub。
本脚本会核对这段配置，缺失时直接失败并给出处置建议。
#>

[CmdletBinding()]
param(
    [ValidateSet('release', 'debug', 'profile')][string]$Mode = 'release',
    [switch]$Clean,
    [switch]$NoPub,
    [string]$FlutterBin = $env:FLUTTER_BIN
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Module = 'build_windows'
$ScriptDir = $PSScriptRoot
$AppRoot = Split-Path -Parent $ScriptDir
$ExeName = 'asmrshelf'
$script:Flutter = $null
$script:LogFile = $null
$pushedLocation = $false

$LogDir = if ([string]::IsNullOrWhiteSpace($env:APP_LOG_DIR)) { Join-Path $AppRoot 'logs' } else { $env:APP_LOG_DIR }
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$script:LogFile = Join-Path $LogDir ("build_windows_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[{0}] [{1,-5}] [{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Module, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
}

function Invoke-Step {
    param([string]$Label, [scriptblock]$Action)
    Write-Log 'INFO' "运行：$Label"
    & $Action 2>&1 | Tee-Object -FilePath $script:LogFile -Append
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'ERROR' "命令失败（退出码 $LASTEXITCODE）：$Label"
        exit $LASTEXITCODE
    }
}

function Get-Flutter {
    if (-not [string]::IsNullOrWhiteSpace($FlutterBin)) {
        if (-not (Test-Path -LiteralPath $FlutterBin)) {
            Write-Log 'ERROR' "指定的 flutter 不存在：$FlutterBin"
            exit 4
        }
        return (Resolve-Path -LiteralPath $FlutterBin).Path
    }
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        Write-Log 'ERROR' '找不到 flutter，可用 -FlutterBin <路径> 或环境变量 FLUTTER_BIN 指定。'
        exit 4
    }
    return $cmd.Source
}

try {
    Push-Location $AppRoot
    $pushedLocation = $true

    Write-Log 'INFO' "构建模式：$Mode"

    # sqlite3 配置核对：Windows 必须命中 winsqlite3.dll
    $pubspecPath = Join-Path $AppRoot 'pubspec.yaml'
    $pubspec = Get-Content -LiteralPath $pubspecPath -Raw
    if ($pubspec -notmatch 'name_windows\s*:\s*winsqlite3') {
        Write-Log 'ERROR' 'pubspec.yaml 的 hooks 段没有 name_windows: winsqlite3。'
        Write-Log 'ERROR' '处置：把 hooks.user_defines.sqlite3 写成 source: system 加 name_windows: winsqlite3，避免构建时去 GitHub 下载 sqlite3.dll。'
        exit 3
    }
    Write-Log 'INFO' 'sqlite3：使用系统 winsqlite3.dll'

    if ([string]::IsNullOrWhiteSpace($env:FLUTTER_STORAGE_BASE_URL)) {
        $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    }
    if ([string]::IsNullOrWhiteSpace($env:PUB_HOSTED_URL)) {
        $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    }

    $script:Flutter = Get-Flutter
    Write-Log 'INFO' "flutter：$($script:Flutter)"

    if ($Clean) {
        Invoke-Step "$($script:Flutter) clean" { & $script:Flutter clean }
    }
    if (-not $NoPub) {
        Invoke-Step "$($script:Flutter) pub get" {
            & $script:Flutter --no-version-check --suppress-analytics pub get
        }
    }

    $modeFlag = "--$Mode"
    Invoke-Step "$($script:Flutter) build windows $modeFlag" {
        & $script:Flutter --no-version-check --suppress-analytics build windows $modeFlag
    }

    $bundle = Get-ChildItem -Path (Join-Path $AppRoot 'build\windows') -Directory -Recurse -Depth 2 -Filter 'runner' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$ExeName.exe") } |
        Select-Object -First 1
    if ($null -eq $bundle) {
        Write-Log 'ERROR' "没找到 $ExeName.exe，构建产物缺失。"
        exit 5
    }

    Write-Log 'INFO' "构建完成：$(Join-Path $bundle.FullName "$ExeName.exe")"
    Write-Log 'INFO' "日志：$script:LogFile"
    Write-Host ''
    Write-Host "✅ 构建完成：$($bundle.FullName)"
    exit 0
}
finally {
    if ($pushedLocation) { Pop-Location }
}
