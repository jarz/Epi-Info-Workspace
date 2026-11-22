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
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $workspace 'artifacts\tests\CloudCosmos' }

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
$project = Join-Path $cloudDirectory 'CosmosDBTests\CosmosDBTests.csproj'
$testPackagesConfig = Join-Path $cloudDirectory 'CosmosDBTests\packages.config'
$packageDirectory = Join-Path $cloudDirectory 'packages'
$adapterPath = Join-Path $packageDirectory 'MSTest.TestAdapter.1.4.0\build\_common'
$binaryDirectory = Join-Path $workspace 'artifacts\bin\CloudCosmosTests\Release\'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'

foreach ($path in @($solution, $project, $testPackagesConfig)) {
    if (-not (Test-Path $path)) { throw "Required Cloud local test input does not exist: $path" }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $OutputDirectory "cloud-solution-restore-$timestamp.log"
$testRestoreLog = Join-Path $OutputDirectory "cloud-cosmos-restore-$timestamp.log"
$buildLog = Join-Path $OutputDirectory "cloud-cosmos-build-$timestamp.log"
$buildConsoleLog = Join-Path $OutputDirectory "cloud-cosmos-build-console-$timestamp.log"
$testLog = Join-Path $OutputDirectory "cloud-cosmos-vstest-$timestamp.log"
$trx = Join-Path $OutputDirectory "cloud-cosmos-$timestamp.trx"
$resultPath = Join-Path $OutputDirectory "cloud-cosmos-result-$timestamp.json"

Write-Output '=== Restoring Cloud solution packages ==='
& $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Cloud solution package restore failed. See $solutionRestoreLog" }

Write-Output '=== Restoring Cloud Cosmos test packages ==='
& $NuGet restore $testPackagesConfig -NonInteractive -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $testRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Cloud Cosmos test package restore failed. See $testRestoreLog" }
if (-not (Test-Path $adapterPath)) { throw "MSTest adapter was not restored: $adapterPath" }

Write-Output '=== Building Cloud Cosmos tests (Release, AnyCPU) ==='
New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
$frameworkTargets = Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets'
& $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=AnyCPU "/p:OutDir=$binaryDirectory" /p:RestorePackages=false /p:Disable_CopyWebApplication=true "/p:CustomAfterMicrosoftCommonTargets=$frameworkTargets" /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
if ($LASTEXITCODE -ne 0) { throw "Cloud Cosmos test build failed. See $buildLog and $buildConsoleLog" }

$assembly = Join-Path $binaryDirectory 'CosmosDBTests.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

Write-Output '=== Running Cloud local wildcard test ==='
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
$status = if ($testExitCode -eq 0 -and $total -eq 1 -and $executed -eq 1 -and $passed -eq 1 -and $failed -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    TestProject = 'Cloud Enter/CosmosDBTests'
    Configuration = 'Release'
    Platform = 'AnyCPU'
    Total = $total
    Executed = $executed
    Passed = $passed
    Failed = $failed
    VSTestExitCode = $testExitCode
    Status = $status
    TRX = $trx
    RestoreLogs = @($solutionRestoreLog, $testRestoreLog)
    BuildLog = $buildLog
    VSTestLog = $testLog
}
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath

$result | Format-List TestProject, Configuration, Platform, Total, Executed, Passed, Failed, VSTestExitCode, Status, TRX
if ($status -ne 'Passed') { throw "Cloud Cosmos local tests failed. See $testLog and $trx" }
