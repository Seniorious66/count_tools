param([switch]$BuildDebug, [string]$Python = 'python', [string]$Baseline = '')
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    $planningArgs = @('scripts/verify-mastersheet.py')
    if ($Baseline) { $planningArgs += @('--baseline', $Baseline) }
    & $Python @planningArgs
    if ($LASTEXITCODE -ne 0) { throw 'Planning validation failed' }
    & $Python scripts/test-workflow.py
    if ($LASTEXITCODE -ne 0) { throw 'Workflow protection checks failed' }
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw 'Flutter SDK unavailable; configure scripts/use-dev-env.ps1 first.' }
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    & flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    & flutter test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed; template tests are not business acceptance' }
    if ($BuildDebug) {
        & flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw 'Android debug compilation failed' }
        Write-Output 'Debug APK only; no release signing or installation.'
    }
    Write-Output 'Requested local checks passed; no device acceptance.'
} finally { Pop-Location }
