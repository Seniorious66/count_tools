param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')][string]$VersionName,
    [Parameter(Mandatory=$true)][ValidateRange(11000,2100000000)][int]$VersionCode,
    [string]$SigningProperties = 'E:\OneDrive\Code\artifacts\count-tools-signing\personal-20261011\count-tools-signing.properties'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'use-dev-env.ps1')
$signingFile = (Resolve-Path -LiteralPath $SigningProperties).Path
if ($signingFile.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Signing configuration must stay outside Git.' }
$outputDir = Join-Path $repoRoot 'local-artifacts\android'
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$ledgerFile = Join-Path $outputDir 'candidate-ledger.json'
$ledger = @()
if (Test-Path -LiteralPath $ledgerFile) { $ledger = @(Get-Content -LiteralPath $ledgerFile -Raw | ConvertFrom-Json) }
if ($ledger.Count -and $VersionCode -le ($ledger.versionCode | Measure-Object -Maximum).Maximum) { throw 'VersionCode must exceed every previously built personal candidate.' }
$destination = Join-Path $outputDir "cheki-$VersionName-$VersionCode.apk"
if (Test-Path -LiteralPath $destination) { throw 'Refusing to overwrite a candidate APK.' }
$env:COUNT_TOOLS_SIGNING_PROPERTIES = $signingFile
$workspace = & (Join-Path $PSScriptRoot 'prepare-local-workspace.ps1')
Push-Location $workspace
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Locked dependency check failed.' }
    & flutter build apk --release --no-pub "--build-name=$VersionName" "--build-number=$VersionCode" "--dart-define=APP_VERSION_NAME=$VersionName" "--dart-define=APP_VERSION_CODE=$VersionCode"
    if ($LASTEXITCODE -ne 0) { throw 'Personal release build failed.' }
    $source = Join-Path $workspace 'build\app\outputs\flutter-apk\app-release.apk'
    $apksigner = Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\apksigner.bat'
    $signature = & $apksigner verify --verbose --print-certs $source 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $certLine = $signature | Select-String 'Signer #1 certificate SHA-256 digest:' | Select-Object -First 1
    if (-not $certLine) { throw 'APK signing certificate unavailable.' }
    $cert = ($certLine.Line -split ':',2)[1].Trim()
    if ($ledger.Count -and @($ledger | Where-Object { $_.certificateDigest -ne $cert }).Count) { throw 'Candidate signing identity changed.' }
    $badging = & (Join-Path $env:ANDROID_HOME 'build-tools\36.0.0\aapt2.exe') dump badging $source
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect APK identity.' }
    $package = $badging | Select-String '^package:' | Select-Object -First 1
    if ($package.Line -notmatch "name='com.seniorious66.counttools'" -or $package.Line -notmatch "versionCode='$VersionCode'" -or $package.Line -notmatch "versionName='$VersionName'") { throw 'APK package or version does not match the candidate.' }
    if (-not ($badging | Select-String "^application-label:'Cheki账本'")) { throw 'APK display name differs.' }
    Copy-Item -LiteralPath $source -Destination $destination
    $ledger += [pscustomobject]@{versionName=$VersionName;versionCode=$VersionCode;applicationId='com.seniorious66.counttools';certificateDigest=$cert;date=(Get-Date).ToString('o');apk=$destination}
    ConvertTo-Json -InputObject @($ledger) -Depth 5 | Set-Content -LiteralPath $ledgerFile -Encoding utf8NoBOM
    Write-Output "Personal signed candidate verified: $VersionName / $VersionCode. No installation or publishing."
} finally { Pop-Location; Remove-Item Env:COUNT_TOOLS_SIGNING_PROPERTIES -ErrorAction SilentlyContinue }
