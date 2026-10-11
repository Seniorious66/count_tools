param(
    [string]$FlutterRoot = $env:COUNT_TOOLS_FLUTTER_ROOT,
    [string]$JdkRoot = $env:COUNT_TOOLS_JDK_ROOT,
    [string]$AndroidSdk = $env:COUNT_TOOLS_ANDROID_SDK,
    [switch]$Inspect
)
$ErrorActionPreference = 'Stop'
if (-not $AndroidSdk) { $AndroidSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
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
$env:PATH = @((Join-Path $FlutterRoot 'bin'), (Join-Path $JdkRoot 'bin'), (Join-Path $AndroidSdk 'platform-tools'), $env:PATH) -join ';'
Write-Output 'Explicit environment configured. Compatibility requires local validation.'
