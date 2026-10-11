param([string]$Message, [string[]]$Paths, [switch]$PushOnly)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    $hooksPath = & git config --get core.hooksPath
    if ($hooksPath -ne '.githooks') { throw 'Enable repository hooks before committing: git config --local core.hooksPath .githooks' }
    $tracePython = & git config --get counttools.python
    if (-not $tracePython) { $tracePython = 'python' }
    if ($PushOnly) {
        & $tracePython scripts/git-trace.py push
        if ($LASTEXITCODE -ne 0) { throw 'Push failed or upload unverified; local commit is retained.' }
    } else {
        if (-not $Message) { throw 'A commit message is required.' }
        if ($Paths) {
            & git add -- @Paths
            if ($LASTEXITCODE -ne 0) { throw 'Staging failed.' }
        }
        $commitOutput = & git commit -m $Message 2>&1
        if ($LASTEXITCODE -ne 0) { $commitOutput | Write-Output; throw 'Commit checks failed; inspect staged changes.' }
        Write-Output 'Local commit created; automatic post-commit upload attempted.'
    }
    # A post-commit hook cannot undo an existing commit; verify upload explicitly.
    & $tracePython scripts/git-trace.py verify
    if ($LASTEXITCODE -ne 0) { throw 'Local commit exists but remote upload is unverified. Use -PushOnly.' }
} finally { Pop-Location }
