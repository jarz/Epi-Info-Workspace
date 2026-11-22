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
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $workspace 'artifacts\tests\Desktop' }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Install Visual Studio Build Tools with managed desktop and test tools first.' }
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

$desktopDirectory = Join-Path $Root 'Epi-Info-Community-Edition'
$solution = Join-Path $desktopDirectory 'Epi Info 7.sln'
$project = Join-Path $desktopDirectory 'Epi.UnitTests\Epi.UnitTests.csproj'
$packageDirectory = Join-Path $desktopDirectory 'packages'
$adapterPath = Join-Path $packageDirectory 'MSTest.TestAdapter.2.2.10\build\_common'
$binaryDirectory = Join-Path $workspace 'artifacts\bin\DesktopTests\Release\'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'

foreach ($path in @($solution, $project)) {
    if (-not (Test-Path $path)) { throw "Required Desktop test input does not exist: $path" }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $OutputDirectory "desktop-solution-restore-$timestamp.log"
$testRestoreLog = Join-Path $OutputDirectory "desktop-tests-restore-$timestamp.log"
$buildLog = Join-Path $OutputDirectory "desktop-tests-build-$timestamp.log"
$buildConsoleLog = Join-Path $OutputDirectory "desktop-tests-build-console-$timestamp.log"
$testLog = Join-Path $OutputDirectory "desktop-numerical-vstest-$timestamp.log"
$trx = Join-Path $OutputDirectory "desktop-numerical-$timestamp.trx"
$resultPath = Join-Path $OutputDirectory "desktop-numerical-result-$timestamp.json"

Write-Output '=== Restoring Desktop solution packages ==='
& $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Desktop solution package restore failed. See $solutionRestoreLog" }

Write-Output '=== Restoring Desktop test packages ==='
& $NuGet restore $project -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $testRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Desktop test package restore failed. See $testRestoreLog" }
if (-not (Test-Path $adapterPath)) { throw "MSTest adapter was not restored: $adapterPath" }

Write-Output '=== Building Desktop tests (Release, x86) ==='
New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
& $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=x86 "/p:OutDir=$binaryDirectory" /p:RestorePackages=false "/p:CustomAfterMicrosoftCommonTargets=$(Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets')" /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
if ($LASTEXITCODE -ne 0) { throw "Desktop test build failed. See $buildLog and $buildConsoleLog" }

$assembly = Join-Path $binaryDirectory 'Epi.UnitTests.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

Write-Output '=== Running Desktop numerical baselines ==='
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & $testRunner $assembly "/TestAdapterPath:$adapterPath" /Platform:x86 '/TestCaseFilter:FullyQualifiedName~Epi.UnitTests.StatCalcTests.BinomialTest|FullyQualifiedName~Epi.UnitTests.AnalysisTest.TwoByTwoTest|FullyQualifiedName~Epi.UnitTests.AdvancedAnalysisTests.LinearRegressionTest|FullyQualifiedName~Epi.UnitTests.AdvancedAnalysisTests.LogisticRegressionTest' "/Logger:trx;LogFileName=$trx" *> $testLog
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
$status = if ($testExitCode -eq 0 -and $total -eq 4 -and $executed -eq 4 -and $passed -eq 4 -and $failed -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    Tests = @('Epi.UnitTests.StatCalcTests.BinomialTest', 'Epi.UnitTests.AnalysisTest.TwoByTwoTest', 'Epi.UnitTests.AdvancedAnalysisTests.LinearRegressionTest', 'Epi.UnitTests.AdvancedAnalysisTests.LogisticRegressionTest')
    Configuration = 'Release'
    Platform = 'x86'
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

$result | Format-List Tests, Configuration, Platform, Total, Executed, Passed, Failed, VSTestExitCode, Status, TRX
if ($status -ne 'Passed') { throw "Desktop numerical baseline failed. See $testLog and $trx" }
