param(
    [string]$PrimaryDirectory = 'E:\OneDrive\Code\artifacts\count-tools-signing\personal-20261011',
    [string]$BackupDirectory = '\\192.168.31.101\nas-hdd\Code\artifacts\count-tools-signing\personal-20261011',
    [string]$JdkRoot = 'C:\Users\Aphoe\.cache\salaryflow-runtime\jdk-21'
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$primary = [IO.Path]::GetFullPath($PrimaryDirectory)
$backup = [IO.Path]::GetFullPath($BackupDirectory)
if ($primary -eq $backup) { throw 'Signing copies must use independent locations.' }
foreach ($target in @($primary, $backup)) {
    if ($target.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $target -eq $repoRoot) { throw 'Signing material must remain outside the repository.' }
    if (Test-Path -LiteralPath $target) { throw 'Refusing to overwrite an existing signing directory.' }
}
$keytool = Join-Path $JdkRoot 'bin\keytool.exe'
if (-not (Test-Path -LiteralPath $keytool)) { throw 'A complete external JDK is required.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $backup))) { New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null }
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$env:COUNT_TOOLS_KEY_PASSWORD = [Convert]::ToBase64String($bytes)
try {
    New-Item -ItemType Directory -Path $primary | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $primary /inheritance:r /grant:r "${identity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict local signing directory permissions.' }
    $keystore = Join-Path $primary 'count-tools-release.p12'
    & $keytool -genkeypair -noprompt -storetype PKCS12 -keystore $keystore -alias count-tools-personal -keyalg RSA -keysize 4096 -validity 10000 -storepass:env COUNT_TOOLS_KEY_PASSWORD -keypass:env COUNT_TOOLS_KEY_PASSWORD -dname 'CN=seniorious66 Cheki,OU=Personal,O=seniorious66,C=CN' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Dedicated signing key generation failed; retain files for inspection.' }
    @(
        ('storeFile=' + $keystore.Replace('\', '/')),
        ('storePassword=' + $env:COUNT_TOOLS_KEY_PASSWORD),
        'keyAlias=count-tools-personal',
        ('keyPassword=' + $env:COUNT_TOOLS_KEY_PASSWORD)
    ) | Set-Content -LiteralPath (Join-Path $primary 'count-tools-signing.properties') -Encoding utf8NoBOM
    @('Dedicated to com.seniorious66.counttools. Keep this bundle private.',
      'The properties file contains the recovery password. Preserve both files together.',
      'After moving the bundle, update storeFile to the restored keystore location.',
      'Do not regenerate this key for future candidates or borrow another app key.') | Set-Content -LiteralPath (Join-Path $primary 'README.txt') -Encoding utf8NoBOM
    New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($entry in Get-ChildItem -LiteralPath $primary -File) {
        $destination = Join-Path $backup $entry.Name
        Copy-Item -LiteralPath $entry.FullName -Destination $destination
        if ((Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) { throw 'Signing backup verification failed; retain both copies.' }
    }
    & $keytool -list -keystore $keystore -storepass:env COUNT_TOOLS_KEY_PASSWORD -alias count-tools-personal 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Generated key cannot be reopened.' }
    Write-Output 'Dedicated permanent signing key created; E and NAS copies verified; recovery bundle reopened.'
} finally { Remove-Item Env:COUNT_TOOLS_KEY_PASSWORD -ErrorAction SilentlyContinue }
