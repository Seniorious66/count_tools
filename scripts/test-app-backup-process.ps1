param([Parameter(Mandatory=$true)][string]$ProofRoot)
$ErrorActionPreference='Stop'
$resolved=[IO.Path]::GetFullPath($ProofRoot)
$allowed=[IO.Path]::GetFullPath('E:\OneDrive\Code\artifacts\count-tools-ui')
if(-not $resolved.StartsWith($allowed+'\',[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath (Join-Path $resolved '.cheki-ui-evidence'))) {throw 'Marked synthetic proof directory required.'}
. (Join-Path $PSScriptRoot 'use-dev-env.ps1')
$workspace=Join-Path $env:USERPROFILE '.cache\count-tools-runtime\android-workspace'
if(-not(Test-Path -LiteralPath (Join-Path $workspace '.count-tools-workspace'))) {throw 'Prepare managed source copy first.'}
Push-Location $workspace
try {
    foreach($phase in @('old-moved','new-installed','settings-written','committed')) {
        $root=Join-Path $resolved ('app-interruption-'+$phase)
        if(Test-Path -LiteralPath $root){throw 'Refusing to overwrite prior interruption evidence.'}
        $env:CHEKI_BACKUP_PROCESS_ROOT=$root
        $env:CHEKI_BACKUP_CRASH_PHASE=$phase
        & flutter test --no-pub test/backup_test.dart --reporter expanded *> (Join-Path $resolved ('crash-'+$phase+'.txt'))
        $crashExit=$LASTEXITCODE
        if($crashExit -eq 0 -or -not(Test-Path -LiteralPath (Join-Path $root 'crash-phase')) -or (Get-Content -LiteralPath (Join-Path $root 'crash-phase') -Raw) -ne $phase -or -not(Test-Path -LiteralPath (Join-Path $root 'live.cheki-recovery\transaction.json'))) {throw 'Child did not interrupt at the required durable phase.'}
        Remove-Item Env:CHEKI_BACKUP_CRASH_PHASE
        $env:CHEKI_BACKUP_EXPECT_COMMITTED=if($phase -eq 'committed'){'1'}else{'0'}
        & flutter test --no-pub test/backup_test.dart --reporter expanded *> (Join-Path $resolved ('recover-'+$phase+'.txt'))
        if($LASTEXITCODE -ne 0){throw 'Fresh Flutter process recovery failed.'}
        Write-Output ('Actual process interruption and fresh recovery verified: '+$phase)
    }
} finally {
    foreach($name in @('CHEKI_BACKUP_PROCESS_ROOT','CHEKI_BACKUP_CRASH_PHASE','CHEKI_BACKUP_EXPECT_COMMITTED')){Remove-Item -LiteralPath ('Env:'+ $name) -ErrorAction SilentlyContinue}
    Pop-Location
}
