param(
    [string]$FlutterRoot = $env:COUNT_TOOLS_FLUTTER_ROOT,
    [string]$JdkRoot = $env:COUNT_TOOLS_JDK_ROOT,
    [string]$AndroidSdk = $env:COUNT_TOOLS_ANDROID_SDK,
    [switch]$Inspect
)
$ErrorActionPreference = 'Stop'
if (-not $FlutterRoot) { $FlutterRoot = Join-Path $env:USERPROFILE '.cache\count-tools-runtime\flutter-3.47.5' }
if (-not $JdkRoot) { $JdkRoot = Join-Path $env:USERPROFILE '.cache\salaryflow-runtime\jdk-21' }
if (-not $AndroidSdk) {
    $isolatedSdk = Join-Path $env:USERPROFILE '.cache\count-tools-runtime\android-sdk'
    $AndroidSdk = if (Test-Path -LiteralPath $isolatedSdk) { $isolatedSdk } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
}
$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $FlutterRoot -and $flutterCommand) { $FlutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source) }
$checks = [ordered]@{
    Flutter = ($FlutterRoot -and (Test-Path -LiteralPath (Join-Path $FlutterRoot 'bin\flutter.bat')))
    JDK = ($JdkRoot -and (Test-Path -LiteralPath (Join-Path $JdkRoot 'bin\javac.exe')))
    AndroidSDK = (Test-Path -LiteralPath (Join-Path $AndroidSdk 'platform-tools\adb.exe'))
}
if ($Inspect) {
    foreach ($name in $checks.Keys) { Write-Output "$name : $(if ($checks[$name]) {'available'} else {'missing / not pinned'})" }
    Write-Output 'Diagnostic only; no SDK download, device connection or APK build.'
    return
}
foreach ($name in $checks.Keys) { if (-not $checks[$name]) { throw "$name missing or not pinned. Configure explicit external runtimes; see docs/DEVELOPMENT_GUIDE.md." } }
$env:JAVA_HOME = [IO.Path]::GetFullPath($JdkRoot)
$env:ANDROID_HOME = [IO.Path]::GetFullPath($AndroidSdk)
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:GRADLE_USER_HOME = Join-Path $env:USERPROFILE '.cache\count-tools-runtime\gradle-home'
$env:PATH = @((Join-Path $FlutterRoot 'bin'), (Join-Path $JdkRoot 'bin'), (Join-Path $AndroidSdk 'platform-tools'), $env:PATH) -join ';'
$pinned = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
$sdkInfo = (& flutter --version --machine | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $sdkInfo.frameworkVersion -ne $pinned.flutter -or $sdkInfo.dartSdkVersion -notlike ($pinned.dart + '*')) { throw 'Flutter/Dart differ from the pinned toolchain.' }
$javacVersion = & (Join-Path $JdkRoot 'bin\javac.exe') -version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $javacVersion.Trim() -ne ('javac ' + $pinned.jdk)) { throw 'JDK differs from the pinned toolchain version.' }
Write-Output 'Pinned Flutter/Dart/JDK configured; no device connection.'
