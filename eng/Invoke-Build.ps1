[CmdletBinding()]
param(
    [ValidateSet('Desktop', 'WebSurvey', 'WebEnter', 'SurveyApi', 'Cloud', 'Database')]
    [string[]]$Repository = @('Desktop', 'WebSurvey', 'WebEnter', 'SurveyApi', 'Cloud', 'Database'),
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$NuGet = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scratch\nuget.exe'),
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\build'),
    [switch]$SkipRestore,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Install Visual Studio Build Tools with managed desktop and web build workloads first.' }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\Current\Bin\MSBuild.exe'
if ($LASTEXITCODE -ne 0 -or -not $msbuild) { throw 'Visual Studio MSBuild was not found.' }
if (-not $SkipRestore -and -not (Test-Path $NuGet)) { throw "NuGet CLI is missing: $NuGet. See BUILDING.md for the pinned download." }
if (-not (Test-Path (Join-Path $PSScriptRoot '..\scratch\framework-packages\Microsoft.NETFramework.ReferenceAssemblies.net452.1.0.3\build\Microsoft.NETFramework.ReferenceAssemblies.net452.targets'))) {
    throw 'Run eng\Initialize-Build.ps1 first to restore private legacy targeting assemblies.'
}

$solutions = @{
    Desktop = 'Epi-Info-Community-Edition\Epi Info 7.sln'
    WebSurvey = 'Epi-Info-Web-Survey\Epi Info Web Survey.sln'
    WebEnter = 'Epi-Info-Web-Enter\Epi Info Web Enter.sln'
    SurveyApi = 'Epi-Info-Survey-API\Epi.Web.SurveyAPI.sln'
    Cloud = 'Epi-Info-Cloud-Contact-Tracing\Cloud Enter\Epi Info Cloud Enter.sln'
    Database = 'Epi-Info-Database-Web\EpiInfo.Database.EIWeb\EpiInfo.Database.EIWeb.sln'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$results = @()
Write-Output 'Validation scope: restore and compilation only. Website-content packaging is disabled; deployment prerequisites are not validated.'
foreach ($name in $Repository) {
    $solution = Join-Path $Root $solutions[$name]
    if (-not (Test-Path $solution)) { throw "Solution does not exist: $solution" }
    $started = Get-Date
    $restoreExit = $null
    $buildExit = $null
    $restoreLog = Join-Path $OutputDirectory "$name-restore.log"
    $buildLog = Join-Path $OutputDirectory "$name-build.log"
    $binaryDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "artifacts\bin\$name\$Configuration\"
    Write-Output "=== $name ($Configuration) ==="

    if (-not $SkipRestore -and $name -ne 'Database') {
        & $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory (Join-Path (Split-Path $solution -Parent) 'packages') -Source 'https://api.nuget.org/v3/index.json' -Verbosity normal *> $restoreLog
        $restoreExit = $LASTEXITCODE
        if ($restoreExit -ne 0) { Write-Warning "$name restore failed ($restoreExit). See $restoreLog" }
    }

    # Attempt compilation even after failed restore to inventory independent blockers.
    $target = if ($Rebuild) { 'Rebuild' } else { 'Build' }
    & $msbuild $solution /nologo /m:2 /nr:false "/t:$target" "/p:Configuration=$Configuration" "/p:OutDir=$binaryDirectory" /p:Disable_CopyWebApplication=true /p:RestorePackages=false "/p:CustomAfterMicrosoftCommonTargets=$PSScriptRoot\LegacyFrameworkReferences.targets" /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> (Join-Path $OutputDirectory "$name-console.log")
    $buildExit = $LASTEXITCODE
    $status = if ($buildExit -eq 0 -and ($null -eq $restoreExit -or $restoreExit -eq 0)) { 'Passed' } else { 'Failed' }
    $result = [pscustomobject]@{
        Repository = $name
        Solution = $solutions[$name]
        Configuration = $Configuration
        ValidationScope = 'RestoreAndCompilationOnly'
        RestoreSkipped = [bool]$SkipRestore
        RestoreExitCode = $restoreExit
        BuildExitCode = $buildExit
        Status = $status
        StartedAt = $started.ToString('o')
        FinishedAt = (Get-Date).ToString('o')
        BuildLog = $buildLog
        BinaryDirectory = $binaryDirectory
    }
    $results += $result
    $result | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory "$name-result.json")
    Write-Output "$name : $status (build exit $buildExit). Log: $buildLog"
}

$results | Format-Table Repository, Configuration, RestoreExitCode, BuildExitCode, Status -AutoSize
if (@($results | Where-Object Status -eq 'Failed').Count) { throw 'One or more solutions failed. Consult the per-repository logs and BUILDING.md.' }
