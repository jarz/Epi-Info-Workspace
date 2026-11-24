[CmdletBinding()]
param(
    [string]$Root,
    [string]$SurveyApiDirectory,
    [string]$NuGet,
    [string]$ArtifactsDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Path $workspace -Parent }
if ([string]::IsNullOrWhiteSpace($SurveyApiDirectory)) { $SurveyApiDirectory = Join-Path $Root 'Epi-Info-Survey-API' }
if ([string]::IsNullOrWhiteSpace($NuGet)) { $NuGet = Join-Path $workspace 'scratch\nuget.exe' }
if ([string]::IsNullOrWhiteSpace($ArtifactsDirectory)) { $ArtifactsDirectory = Join-Path $workspace 'artifacts' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Install Visual Studio Build Tools with managed desktop, web, and test tools first.' }
$installationPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.TestTools.BuildTools -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installationPath) { throw 'Visual Studio Test Platform was not found.' }

$msbuild = Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe'
$testRunner = Join-Path $installationPath 'Common7\IDE\Extensions\TestPlatform\vstest.console.exe'
if (-not (Test-Path $msbuild)) { throw "Visual Studio MSBuild was not found: $msbuild" }
if (-not (Test-Path $testRunner)) { throw "VSTest console was not found: $testRunner" }
if (-not (Test-Path $NuGet)) { throw "NuGet CLI is missing: $NuGet. Run eng\Initialize-Build.ps1 first." }

$solution = Join-Path $SurveyApiDirectory 'Epi.Web.SurveyAPI.sln'
$project = Join-Path $SurveyApiDirectory 'Epi.Web.SurveyAPI.Tests\Epi.Web.SurveyAPI.Tests.csproj'
$testPackagesConfig = Join-Path $SurveyApiDirectory 'Epi.Web.SurveyAPI.Tests\packages.config'
$packageDirectory = Join-Path $SurveyApiDirectory 'packages'
$adapterPath = Join-Path $packageDirectory 'NUnit3TestAdapter.6.3.1\build\net462'
$outputDirectory = Join-Path $ArtifactsDirectory 'tests\SurveyApi'
$binaryDirectory = Join-Path $ArtifactsDirectory 'bin\SurveyApiTests\Release\'
$intermediateRoot = Join-Path $ArtifactsDirectory 'obj\SurveyApiTests\'
$frameworkTargets = Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets'
$isolationTargets = Join-Path $PSScriptRoot 'IsolatedIntermediates.targets'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$expectedTotal = 15

foreach ($path in @($solution, $project, $testPackagesConfig, $frameworkTargets, $isolationTargets)) {
    if (-not (Test-Path $path)) { throw "Required Survey API test input does not exist: $path" }
}

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $outputDirectory "surveyapi-solution-restore-$timestamp.log"
$testRestoreLog = Join-Path $outputDirectory "surveyapi-tests-restore-$timestamp.log"
$buildLog = Join-Path $outputDirectory "surveyapi-tests-build-$timestamp.log"
$buildConsoleLog = Join-Path $outputDirectory "surveyapi-tests-build-console-$timestamp.log"
$testLog = Join-Path $outputDirectory "surveyapi-tests-vstest-$timestamp.log"
$trx = Join-Path $outputDirectory "surveyapi-tests-$timestamp.trx"

Write-Output '=== Restoring Survey API solution packages ==='
& $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Survey API solution package restore failed. See $solutionRestoreLog" }

Write-Output '=== Restoring Survey API test packages ==='
& $NuGet restore $testPackagesConfig -NonInteractive -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $testRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Survey API test package restore failed. See $testRestoreLog" }
if (-not (Test-Path (Join-Path $adapterPath 'NUnit3.TestAdapter.dll'))) { throw "NUnit adapter was not restored: $adapterPath" }

Write-Output '=== Building Survey API tests (Release, AnyCPU) ==='
New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
$isolationArguments = @(
    '/p:RestorePackages=false',
    '/p:Disable_CopyWebApplication=true',
    "/p:CustomBeforeMicrosoftCommonTargets=$isolationTargets",
    "/p:CustomAfterMicrosoftCommonTargets=$frameworkTargets"
)
& $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=AnyCPU "/p:OutDir=$binaryDirectory" "/p:IsolatedIntermediateRoot=$intermediateRoot" @isolationArguments /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
if ($LASTEXITCODE -ne 0) { throw "Survey API test build failed. See $buildLog and $buildConsoleLog" }

$assembly = Join-Path $binaryDirectory 'Epi.Web.SurveyAPI.Tests.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

Write-Output '=== Running Survey API tests ==='
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
$failedTests = @($testResults.SelectNodes("//*[local-name()='UnitTestResult'][@outcome!='Passed']") | ForEach-Object {
    $message = $_.SelectSingleNode(".//*[local-name()='Message']")
    "$($_.GetAttribute('testName')) [$($_.GetAttribute('outcome'))]: $(if ($message) { $message.InnerText.Trim() })"
})
$status = if ($testExitCode -eq 0 -and $total -eq $expectedTotal -and $executed -eq $total -and $passed -eq $total -and $failed -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    TestProject = 'Epi-Info-Survey-API/Epi.Web.SurveyAPI.Tests'
    SourceDirectory = $SurveyApiDirectory
    Configuration = 'Release'
    Platform = 'AnyCPU'
    TestFramework = 'NUnit 5.0.0 / NUnit3TestAdapter 6.3.1 / VSTest (Build Tools)'
    ExpectedTotal = $expectedTotal
    Total = $total
    Executed = $executed
    Passed = $passed
    Failed = $failed
    VSTestExitCode = $testExitCode
    Status = $status
    FailedTests = $failedTests
    TRX = $trx
    RestoreLogs = @($solutionRestoreLog, $testRestoreLog)
    BuildLog = $buildLog
    VSTestLog = $testLog
}
$resultPath = Join-Path $outputDirectory "surveyapi-tests-result-$timestamp.json"
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath

$result | Format-List TestProject, Configuration, Platform, ExpectedTotal, Total, Executed, Passed, Failed, VSTestExitCode, Status, TRX
$failedTests | ForEach-Object { Write-Output "FAILED: $_" }
if ($total -eq 0) { throw "VSTest discovered no Survey API tests. See $testLog" }
if ($status -ne 'Passed') { throw "Survey API tests failed. See $testLog and $trx" }
