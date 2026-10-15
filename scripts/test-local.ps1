param([switch]$BuildDebug, [string]$Python = 'python', [string]$Baseline = '')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $planningArgs = @('scripts/verify-mastersheet.py')
    if ($Baseline) { $planningArgs += @('--baseline', $Baseline) }
    & $Python @planningArgs
    if ($LASTEXITCODE -ne 0) { throw 'Planning validation failed' }
    & $Python scripts/test-workflow.py
    if ($LASTEXITCODE -ne 0) { throw 'Workflow protection checks failed' }
    & $Python scripts/test-recovery.py
    if ($LASTEXITCODE -ne 0) { throw 'Isolated complete recovery checks failed' }
    . (Join-Path $PSScriptRoot 'use-dev-env.ps1')
    $workspace = & (Join-Path $PSScriptRoot 'prepare-local-workspace.ps1')
    Set-Location -LiteralPath $workspace
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    & flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    & flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed; template tests are not business acceptance' }
    if ($env:COUNT_TOOLS_CATALOG_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-catalog-recovery.py') --source $env:COUNT_TOOLS_CATALOG_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current catalog complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_IDENTITY_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-identity-recovery.py') --source $env:COUNT_TOOLS_IDENTITY_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current identity complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_NULLABLE_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-nullable-recovery.py') --source $env:COUNT_TOOLS_NULLABLE_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current nullable records complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_RECEIPT_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-receipt-recovery.py') --source $env:COUNT_TOOLS_RECEIPT_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current receipt records complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_NAMES_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-names-recovery.py') --source $env:COUNT_TOOLS_NAMES_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current record names complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_M1_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-m1-recovery.py') --source $env:COUNT_TOOLS_M1_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Combined M1 complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_TICKET_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-ticket-recovery.py') --source $env:COUNT_TOOLS_TICKET_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current ticket complete recovery checks failed' }
    }
    if ($env:COUNT_TOOLS_ENTRY_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-entry-recovery.py') --source $env:COUNT_TOOLS_ENTRY_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current linked entries complete recovery checks failed' }
    }
    if ($BuildDebug) {
        # Debug builds are optional and never installed by this runner.
        & flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { throw 'Android debug compilation failed' }
        Write-Output 'Debug APK only; no release signing or installation.'
    }
    if ($env:COUNT_TOOLS_TRANSFER_ACCEPTANCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-transfer-recovery.py') --source $env:COUNT_TOOLS_TRANSFER_ACCEPTANCE
        if ($LASTEXITCODE -ne 0) { throw 'Current transfer complete recovery checks failed' }
    }
    if ($env:CHEKI_TRANSPORT_EVIDENCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-transport-recovery.py') --source $env:CHEKI_TRANSPORT_EVIDENCE
        if ($LASTEXITCODE -ne 0) { throw 'Current structured transport complete recovery checks failed' }
    }
    if ($env:CHEKI_LEGACY_EVIDENCE) {
        & $Python (Join-Path $repoRoot 'scripts/test-legacy-mapping-recovery.py') --source $env:CHEKI_LEGACY_EVIDENCE
        if ($LASTEXITCODE -ne 0) { throw 'Current legacy mapping complete recovery checks failed' }
    }
    Write-Output 'Requested local checks passed; no device acceptance.'
} finally { Pop-Location }
