param([string]$FlutterRoot = (Join-Path $env:USERPROFILE '.cache\count-tools-runtime\flutter-3.47.5'))
$ErrorActionPreference = 'Stop'
$pinned = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath $FlutterRoot) { throw 'Existing SDK is retained; validate it with use-dev-env.ps1 rather than overwriting it.' }
$gitArgs = @()
if ($env:HTTPS_PROXY) { $gitArgs += @('-c', ('http.proxy=' + $env:HTTPS_PROXY)) }
$gitArgs += @('clone','--depth','1','--branch',$pinned.flutter,'https://github.com/flutter/flutter.git',$FlutterRoot)
& git @gitArgs
if ($LASTEXITCODE -ne 0) { throw 'Official fixed-tag SDK checkout failed; retain diagnostic files.' }
& (Join-Path $FlutterRoot 'bin\flutter.bat') --version
if ($LASTEXITCODE -ne 0) { throw 'Official SDK bootstrap failed; do not report the environment ready.' }
Write-Output 'SDK checkout and bootstrap complete; Android dependencies and project checks still require validation.'
