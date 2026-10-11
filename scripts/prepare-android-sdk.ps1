param(
    [string]$Source = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$Destination = (Join-Path $env:USERPROFILE '.cache\count-tools-runtime\android-sdk')
)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $Source).Path
$destinationRoot = [IO.Path]::GetFullPath($Destination)
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if ($destinationRoot -eq [IO.Path]::GetPathRoot($destinationRoot) -or
    $destinationRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $destinationRoot.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $sourceRoot.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SDK copy must be a separate external directory.'
}
$marker = Join-Path $destinationRoot '.count-tools-sdk'
if (Test-Path -LiteralPath $destinationRoot) {
    if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker).Trim() -ne $repoRoot) {
        throw 'Existing SDK destination is not owned by this project; refusing to change it.'
    }
    foreach ($required in @('platforms\android-36\android.jar','build-tools\36.0.0\aapt2.exe','platform-tools\adb.exe','cmdline-tools\latest\bin\sdkmanager.bat','licenses\android-sdk-license')) {
        if (-not (Test-Path -LiteralPath (Join-Path $destinationRoot $required))) { throw 'Managed SDK copy is incomplete; inspect it before replacing components.' }
    }
    Write-Output 'Existing managed SDK copy retained; source SDK untouched.'
    return
}
foreach ($component in @('platforms','build-tools','platform-tools','licenses','cmdline-tools')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $component))) { throw "Source SDK component missing: $component" }
}
New-Item -ItemType Directory -Path $destinationRoot | Out-Null
[IO.File]::WriteAllText($marker, $repoRoot)
foreach ($component in @('platforms','build-tools','platform-tools','licenses','cmdline-tools')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $component) -Destination $destinationRoot -Recurse
}
Write-Output 'SDK tools copied to the managed external directory; source SDK untouched.'
