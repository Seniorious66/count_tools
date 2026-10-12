param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [string]$NativeGraph = '',
    [string]$Workspace = (Join-Path $env:USERPROFILE '.cache\count-tools-runtime\android-workspace')
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'use-dev-env.ps1')
$marker = Join-Path $Workspace '.count-tools-workspace'
if (-not (Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw).Trim() -ne $repoRoot) { throw 'Managed CountTools dependency workspace required' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath (Join-Path $output 'audit.json')) { throw 'Refusing to overwrite dependency audit evidence' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
Push-Location -LiteralPath $Workspace
try { $graphText = & dart pub deps --json; if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve locked production dependency graph' }; $graph = $graphText | ConvertFrom-Json } finally { Pop-Location }
$byName=@{};foreach($p in $graph.packages){$byName[$p.name]=$p}
$queue=[Collections.Generic.Queue[string]]::new();foreach($p in $graph.packages | Where-Object kind -eq 'direct'){$queue.Enqueue($p.name)}
$seen=[Collections.Generic.HashSet[string]]::new()
while($queue.Count){$name=$queue.Dequeue();if(-not $seen.Add($name)){continue};if(-not $byName.ContainsKey($name)){throw 'Missing dependency graph node'};foreach($dep in $byName[$name].dependencies){$queue.Enqueue($dep)}}
$packages=@();$excluded=@()
foreach($name in $seen){$p=$byName[$name];if($p.source -eq 'hosted'){$packages+=@{ecosystem='Pub';name=$p.name;version=$p.version}}else{$excluded+=@{name=$p.name;source=$p.source;reason='SDK/path/git source needs separate verification'}}}
if($NativeGraph){
    $nativeText=Get-Content -LiteralPath $NativeGraph -Raw
    if($nativeText -notmatch 'BUILD SUCCESSFUL' -or $nativeText -match '\(FAILED\)| FAILED|Could not resolve'){throw 'Incomplete Android release dependency resolution'}
    $nativeSeen=[Collections.Generic.HashSet[string]]::new()
    foreach($match in [regex]::Matches($nativeText,'(?m)^[|+\\\s-]*([\w.\-]+):([\w.\-]+):([^\s]+)(?: -> ([^\s]+))?')){
        $name=$match.Groups[1].Value+':'+$match.Groups[2].Value;$version=$match.Groups[3].Value
        if($match.Groups[4].Success){$version=$match.Groups[4].Value;if($version.Contains(':')){throw 'Relocated Maven coordinate requires review'}}
        if($name.StartsWith('io.flutter:')){$excluded+=@{name=$name;source='Flutter engine';reason='SDK engine artifact requires separate verification'};continue}
        if($version -match '[\[\],+()]'){throw 'Unresolved Maven version constraint'}
        if($nativeSeen.Add($name+'@'+$version)){$packages+=@{ecosystem='Maven';name=$name;version=$version}}
    }
    if(-not $nativeSeen.Count){throw 'No Android release Maven dependencies found'}
}
$packages=@($packages | Sort-Object ecosystem,name)
$queries=@($packages | ForEach-Object { @{package=@{name=$_.name;ecosystem=$_.ecosystem};version=$_.version} })
$queryBody=@{queries=$queries}|ConvertTo-Json -Depth 5
# Send only public package coordinates and versions, never source or app data.
$response=Invoke-RestMethod -Method Post -Uri 'https://api.osv.dev/v1/querybatch' -ContentType 'application/json' -Body $queryBody -TimeoutSec 45
if(@($response.results).Count -ne $packages.Count){throw 'Dependency advisory response incomplete'}
$findings=@();for($i=0;$i -lt $packages.Count;$i++){
    $result=$response.results[$i]
    if($result.next_page_token){throw 'Paginated advisory response needs follow-up; not a completed audit'}
    foreach($v in $result.vulns){$findings+=@{package=$packages[$i];advisory=$v.id}}
}
$report=@{date=(Get-Date).ToString('o');source='https://api.osv.dev/v1/querybatch';scope='Locked direct production Pub packages plus their transitive closure; resolved Android release Maven coordinates when provided';pubCount=@($packages|Where-Object ecosystem -eq 'Pub').Count;mavenCount=@($packages|Where-Object ecosystem -eq 'Maven').Count;packages=$packages;excluded=$excluded;findings=$findings;limitations='Known advisory lookup only; Flutter SDK/engine, device OS, build tooling and platform-native binaries are outside this query. Empty findings is not a guarantee of no vulnerabilities.'}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $output 'audit.json') -Encoding utf8NoBOM
Write-Output "Production advisory lookup: $($report.pubCount) Pub / $($report.mavenCount) Maven packages; $($findings.Count) findings. SDK/native limitations recorded."
if($findings.Count){throw 'Known production dependency advisories require review'}
