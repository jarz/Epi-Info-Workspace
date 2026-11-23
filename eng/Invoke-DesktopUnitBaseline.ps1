[CmdletBinding()]
param(
    [string]$Root,
    [string]$NuGet,
    [string]$OutputDirectory,
    [switch]$SkipBuild
)

# Builds Epi.UnitTests (Release, x86) and runs the Desktop numerical baselines plus the evidence-based
# check-code and form-metadata tests. Fails on zero discovery, a missing expected test, or any failure.

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

# Numerical baselines (see Invoke-DesktopNumericalBaseline.ps1) must always be present and pass.
$requiredTests = @(
    'Epi.UnitTests.StatCalcTests.BinomialTest',
    'Epi.UnitTests.AnalysisTest.TwoByTwoTest',
    'Epi.UnitTests.AdvancedAnalysisTests.LinearRegressionTest',
    'Epi.UnitTests.AdvancedAnalysisTests.LogisticRegressionTest'
)
# Whole test classes that need no Jet/ACE, OLE DB, UI or EpiInfo.Config.xml.
$requiredClasses = @(
    'Epi.UnitTests.CheckCode.CheckCodeGrammarTests',
    'Epi.UnitTests.CheckCode.CheckCodeExecutionTests',
    'Epi.UnitTests.FormMetadata.FormMetadataTests'
)
$filter = (@($requiredTests | ForEach-Object { "FullyQualifiedName=$_" }) + @($requiredClasses | ForEach-Object { "FullyQualifiedName~$_." })) -join '|'

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $OutputDirectory "desktop-unit-solution-restore-$timestamp.log"
$testRestoreLog = Join-Path $OutputDirectory "desktop-unit-restore-$timestamp.log"
$buildLog = Join-Path $OutputDirectory "desktop-unit-build-$timestamp.log"
$buildConsoleLog = Join-Path $OutputDirectory "desktop-unit-build-console-$timestamp.log"
$testLog = Join-Path $OutputDirectory "desktop-unit-vstest-$timestamp.log"
$trx = Join-Path $OutputDirectory "desktop-unit-$timestamp.trx"
$resultPath = Join-Path $OutputDirectory "desktop-unit-result-$timestamp.json"

if (-not $SkipBuild) {
    if (-not (Test-Path $NuGet)) { throw "NuGet CLI is missing: $NuGet. Run eng\Initialize-Build.ps1 first." }
    if (-not (Test-Path (Join-Path $workspace 'scratch\framework-packages\Microsoft.NETFramework.ReferenceAssemblies.net452.1.0.3\build\Microsoft.NETFramework.ReferenceAssemblies.net452.targets'))) {
        throw 'Run eng\Initialize-Build.ps1 first to restore private legacy targeting assemblies.'
    }

    Write-Output '=== Restoring Desktop solution packages ==='
    & $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
    if ($LASTEXITCODE -ne 0) { throw "Desktop solution package restore failed. See $solutionRestoreLog" }

    Write-Output '=== Restoring Desktop test packages ==='
    & $NuGet restore $project -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $testRestoreLog
    if ($LASTEXITCODE -ne 0) { throw "Desktop test package restore failed. See $testRestoreLog" }

    Write-Output '=== Building Desktop tests (Release, x86) ==='
    New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
    & $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=x86 "/p:OutDir=$binaryDirectory" /p:RestorePackages=false "/p:CustomAfterMicrosoftCommonTargets=$(Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets')" /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
    if ($LASTEXITCODE -ne 0) { throw "Desktop test build failed. See $buildLog and $buildConsoleLog" }
}
if (-not (Test-Path $adapterPath)) { throw "MSTest adapter was not restored: $adapterPath" }

$assembly = Join-Path $binaryDirectory 'Epi.UnitTests.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

Write-Output '=== Running Desktop numerical, check-code and form-metadata tests ==='
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & $testRunner $assembly "/TestAdapterPath:$adapterPath" /Platform:x86 "/TestCaseFilter:$filter" "/Logger:trx;LogFileName=$trx" *> $testLog
    $testExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if (-not (Test-Path $trx)) { throw "VSTest did not write the TRX result (no tests discovered?). See $testLog" }

[xml]$testResults = Get-Content -LiteralPath $trx -Raw
$counters = $testResults.SelectSingleNode("//*[local-name()='Counters']")
if (-not $counters) { throw "VSTest TRX has no test counters: $trx" }

$total = [int]$counters.GetAttribute('total')
$executed = [int]$counters.GetAttribute('executed')
$passed = [int]$counters.GetAttribute('passed')
$failed = [int]$counters.GetAttribute('failed')

$definitions = @{}
foreach ($definition in $testResults.SelectNodes("//*[local-name()='UnitTest']")) {
    $method = $definition.SelectSingleNode("*[local-name()='TestMethod']")
    $definitions[$definition.GetAttribute('id')] = "$($method.GetAttribute('className')).$($method.GetAttribute('name'))"
}
$outcomes = @(foreach ($unitTestResult in $testResults.SelectNodes("//*[local-name()='UnitTestResult']")) {
    [pscustomobject]@{ Name = $definitions[$unitTestResult.GetAttribute('testId')]; Outcome = $unitTestResult.GetAttribute('outcome') }
}) | Sort-Object Name

$problems = New-Object System.Collections.Generic.List[string]
if ($total -eq 0) { $problems.Add('No tests were discovered.') }
if ($testExitCode -ne 0) { $problems.Add("VSTest exited with $testExitCode.") }
if ($executed -ne $total -or $passed -ne $total -or $failed -ne 0) { $problems.Add("Counters: total=$total executed=$executed passed=$passed failed=$failed.") }
foreach ($name in $requiredTests) {
    if (-not ($outcomes | Where-Object { $_.Name -eq $name -and $_.Outcome -eq 'Passed' })) { $problems.Add("Required test did not pass: $name") }
}
foreach ($class in $requiredClasses) {
    if (-not ($outcomes | Where-Object { $_.Name -like "$class.*" })) { $problems.Add("No tests discovered for class $class") }
}
$status = if ($problems.Count -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    Filter = $filter
    Configuration = 'Release'
    Platform = 'x86'
    Total = $total
    Executed = $executed
    Passed = $passed
    Failed = $failed
    VSTestExitCode = $testExitCode
    Status = $status
    Problems = @($problems)
    Results = $outcomes
    TRX = $trx
    RestoreLogs = @($solutionRestoreLog, $testRestoreLog)
    BuildLog = $buildLog
    VSTestLog = $testLog
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultPath

$result | Format-List Configuration, Platform, Total, Executed, Passed, Failed, VSTestExitCode, Status, Problems, TRX
Write-Output "JSON summary: $resultPath"
if ($status -ne 'Passed') { throw "Desktop unit baseline failed. See $testLog and $trx" }
