param([string]$BuildRoot = (Join-Path $env:USERPROFILE '.cache\count-tools-runtime\android-workspace'))
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildPath = [IO.Path]::GetFullPath($BuildRoot)
if ($buildPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or $buildPath -eq [IO.Path]::GetPathRoot($buildPath)) { throw 'Build workspace must be a separate, non-root directory.' }
$marker = Join-Path $buildPath '.count-tools-workspace'
if ((Test-Path -LiteralPath $buildPath) -and -not (Test-Path -LiteralPath $marker)) { throw 'Existing directory is not a managed CountTools workspace.' }
if ((Test-Path -LiteralPath $marker) -and ([IO.File]::ReadAllText($marker).Trim() -ne $repoRoot)) { throw 'Workspace belongs to another repository.' }
# The Windows native sqlite DLL is held by flutter_tester while tests run.
# Reject a second prepare/build before touching copied sources or cached files.
$activeTesters = @(Get-CimInstance Win32_Process -Filter "Name='flutter_tester.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($buildPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($activeTesters.Count) { throw 'A Flutter test is using this managed workspace. Wait for it to finish before preparing or building.' }
New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
$repoRoot | Set-Content -LiteralPath $marker -Encoding utf8NoBOM
foreach ($name in @('lib','test','android','assets','pubspec.yaml','pubspec.lock','analysis_options.yaml')) {
    $source = Join-Path $repoRoot $name
    if (-not (Test-Path -LiteralPath $source)) { continue }
    $target = Join-Path $buildPath $name
    # Only these copied source directories are replaced; cached build output remains.
    if (Test-Path -LiteralPath $target) {
        $resolved = [IO.Path]::GetFullPath($target)
        if (-not $resolved.StartsWith($buildPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Copy target outside managed workspace.' }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $target -Recurse
}
Write-Output $buildPath
