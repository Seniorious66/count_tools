param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [string]$AndroidSdk = $env:COUNT_TOOLS_ANDROID_SDK
)
$ErrorActionPreference = 'Stop'
if (-not $AndroidSdk) { $AndroidSdk = Join-Path $env:USERPROFILE '.cache\count-tools-runtime\android-sdk' }
$pinned = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
if ($pinned.ndk -ne '28.2.13676358') { throw 'Update the official archive validation before installing a different NDK.' }
$sdkRoot = [IO.Path]::GetFullPath($AndroidSdk)
$ndkRoot = Join-Path $sdkRoot 'ndk'
$target = Join-Path $ndkRoot $pinned.ndk
if (Test-Path -LiteralPath $target) {
    $properties = Join-Path $target 'source.properties'
    if (-not (Test-Path -LiteralPath $properties) -or
        -not (Select-String -LiteralPath $properties -Pattern '^Pkg.Revision = 28\.2\.13676358$' -Quiet)) {
        throw 'Existing NDK directory is incomplete or differs; refusing to overwrite it.'
    }
    Write-Output 'Pinned NDK already available; no installation needed.'
    return
}
$zipPath = (Resolve-Path -LiteralPath $Archive).Path
# Official Android NDK r28c Windows archive, linked by android/ndk Unsupported-Downloads.
if ((Get-Item -LiteralPath $zipPath).Length -ne 748118221 -or
    (Get-FileHash -LiteralPath $zipPath -Algorithm SHA1).Hash -ne '086BBA43FF2F5EB0E387B15C8278BB4E0D89BA1D') {
    throw 'Official NDK archive validation failed; nothing installed.'
}
$stage = Join-Path ([IO.Path]::GetDirectoryName($zipPath)) ('ndk-extract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    foreach ($entry in $zip.Entries) {
        $resolved = [IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
        if (-not $resolved.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Archive entry escapes extraction directory.'
        }
    }
} finally { $zip.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stage)
$extracted = Join-Path $stage 'android-ndk-r28c'
if (-not (Select-String -LiteralPath (Join-Path $extracted 'source.properties') -Pattern '^Pkg.Revision = 28\.2\.13676358$' -Quiet)) {
    throw 'Extracted NDK revision differs; staging preserved.'
}
[IO.Directory]::CreateDirectory($ndkRoot) | Out-Null
if (-not ([IO.Path]::GetFullPath($target)).StartsWith($sdkRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'NDK target escapes the SDK directory.'
}
[IO.Directory]::Move($extracted, $target)
Remove-Item -LiteralPath $stage
Write-Output 'Official pinned NDK installed in its own version directory; other SDK versions retained.'
