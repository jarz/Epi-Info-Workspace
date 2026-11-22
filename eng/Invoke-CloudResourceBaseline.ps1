[CmdletBinding()]
param(
    [string]$Root,
    [string]$NuGet,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Path $workspace -Parent }
if ([string]::IsNullOrWhiteSpace($NuGet)) { $NuGet = Join-Path $workspace 'scratch\nuget.exe' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $workspace 'artifacts\tests\CloudResource' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Install Visual Studio Build Tools with managed desktop, web, and test tools first.' }
$installationPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.TestTools.BuildTools -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installationPath) { throw 'Visual Studio Test Platform was not found.' }

$msbuild = Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe'
$testRunner = Join-Path $installationPath 'Common7\IDE\Extensions\TestPlatform\vstest.console.exe'
if (-not (Test-Path $msbuild)) { throw "Visual Studio MSBuild was not found: $msbuild" }
if (-not (Test-Path $testRunner)) { throw "VSTest console was not found: $testRunner" }
if (-not (Test-Path $NuGet)) { throw "NuGet CLI is missing: $NuGet. Run eng\Initialize-Build.ps1 first." }
if (-not (Test-Path (Join-Path $workspace 'scratch\framework-packages\Microsoft.NETFramework.ReferenceAssemblies.net452.1.0.3\build\Microsoft.NETFramework.ReferenceAssemblies.net452.targets'))) {
    throw 'Run eng\Initialize-Build.ps1 first to restore private legacy targeting assemblies.'
}

$cloudDirectory = Join-Path $Root 'Epi-Info-Cloud-Contact-Tracing\Cloud Enter'
$solution = Join-Path $cloudDirectory 'Epi Info Cloud Enter.sln'
$project = Join-Path $cloudDirectory 'ResourceTests\ResourceTests.csproj'
$centralVersionsFile = Join-Path $cloudDirectory 'Directory.Packages.props'
$packageDirectory = Join-Path $cloudDirectory 'packages'
$globalPackagesDirectory = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget\packages' }
$adapterPath = Join-Path $globalPackagesDirectory 'mstest.testadapter\1.4.0\build\_common'
$projectAssetsFile = Join-Path (Split-Path $project -Parent) 'obj\project.assets.json'
$binaryDirectory = Join-Path $workspace 'artifacts\bin\CloudResourceTests\Release\'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'

foreach ($path in @($solution, $project, $centralVersionsFile)) {
    if (-not (Test-Path $path)) { throw "Required Cloud resource test input does not exist: $path" }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $OutputDirectory "cloud-solution-restore-$timestamp.log"
$buildLog = Join-Path $OutputDirectory "cloud-resource-build-$timestamp.log"
$buildConsoleLog = Join-Path $OutputDirectory "cloud-resource-build-console-$timestamp.log"
$testLog = Join-Path $OutputDirectory "cloud-resource-vstest-$timestamp.log"
$trx = Join-Path $OutputDirectory "cloud-resource-$timestamp.trx"
$resultPath = Join-Path $OutputDirectory "cloud-resource-result-$timestamp.json"

Write-Output '=== Restoring Cloud solution packages ==='
& $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Cloud solution package restore failed. See $solutionRestoreLog" }

if (-not (Test-Path $projectAssetsFile)) { throw "PackageReference restore assets were not produced: $projectAssetsFile" }
[xml]$centralVersions = Get-Content -LiteralPath $centralVersionsFile -Raw
$resolvedAssets = Get-Content -LiteralPath $projectAssetsFile -Raw | ConvertFrom-Json
$packageDependencyMigration = @()
foreach ($packageId in @('MSTest.TestAdapter', 'MSTest.TestFramework')) {
    $centralPackage = $centralVersions.SelectSingleNode("//*[local-name()='PackageVersion' and @Include='$packageId']")
    if (-not $centralPackage) { throw "Central package version is missing for $packageId." }
    $centralVersion = $centralPackage.GetAttribute('Version')
    if ($centralVersion -ne '1.4.0') { throw "Unexpected centrally managed version for ${packageId}: $centralVersion" }
    $resolvedPackage = $resolvedAssets.libraries.PSObject.Properties.Name | Where-Object { $_ -ieq "$packageId/1.4.0" }
    if (-not $resolvedPackage) { throw "PackageReference restore did not resolve $packageId/1.4.0" }
    $packageDependencyMigration += [pscustomobject]@{
        PackageId = $packageId
        BeforeVersion = '1.4.0'
        AfterVersion = '1.4.0'
    }
}

if (-not (Test-Path $adapterPath)) { throw "MSTest adapter was not restored: $adapterPath" }

Write-Output '=== Building Cloud resource tests (Release, AnyCPU) ==='
New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
$frameworkTargets = Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets'
& $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=AnyCPU "/p:OutDir=$binaryDirectory" /p:RestorePackages=false /p:Disable_CopyWebApplication=true "/p:CustomAfterMicrosoftCommonTargets=$frameworkTargets" /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
if ($LASTEXITCODE -ne 0) { throw "Cloud resource test build failed. See $buildLog and $buildConsoleLog" }

$assembly = Join-Path $binaryDirectory 'ResourceTests.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

Write-Output '=== Running Cloud resource tests ==='
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & $testRunner $assembly "/TestAdapterPath:$adapterPath" "/Logger:trx;LogFileName=$trx" *> $testLog
    $testExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if (-not (Test-Path $trx)) { throw "VSTest did not write the TRX result. See $testLog" }

[xml]$testResults = Get-Content -LiteralPath $trx -Raw
$counters = $testResults.SelectSingleNode("//*[local-name()='Counters']")
if (-not $counters) { throw "VSTest TRX has no test counters: $trx" }

$total = [int]$counters.GetAttribute('total')
$executed = [int]$counters.GetAttribute('executed')
$passed = [int]$counters.GetAttribute('passed')
$failed = [int]$counters.GetAttribute('failed')
$status = if ($testExitCode -eq 0 -and $total -eq 2 -and $executed -eq 2 -and $passed -eq 2 -and $failed -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    TestProject = 'Cloud Enter/ResourceTests'
    Configuration = 'Release'
    Platform = 'AnyCPU'
    Total = $total
    Executed = $executed
    Passed = $passed
    Failed = $failed
    VSTestExitCode = $testExitCode
    Status = $status
    TRX = $trx
    RestoreLogs = @($solutionRestoreLog)
    PackageDependencyMigration = $packageDependencyMigration
    BuildLog = $buildLog
    VSTestLog = $testLog
}
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath

$result | Format-List TestProject, Configuration, Platform, Total, Executed, Passed, Failed, VSTestExitCode, Status, TRX
if ($status -ne 'Passed') { throw "Cloud resource tests failed. See $testLog and $trx" }
