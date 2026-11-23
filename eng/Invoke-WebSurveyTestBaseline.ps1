[CmdletBinding()]
param(
    [string]$Root,
    [string]$NuGet,
    [string]$OutputDirectory,
    # Optional overrides so a separate Web Survey worktree can be tested without writing to shared artifacts.
    [string]$WebSurveyDirectory,
    [string]$BinaryDirectory
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Path $workspace -Parent }
if ([string]::IsNullOrWhiteSpace($NuGet)) { $NuGet = Join-Path $workspace 'scratch\nuget.exe' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $workspace 'artifacts\tests\WebSurvey' }

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

if ([string]::IsNullOrWhiteSpace($WebSurveyDirectory)) { $WebSurveyDirectory = Join-Path $Root 'Epi-Info-Web-Survey' }
if ([string]::IsNullOrWhiteSpace($BinaryDirectory)) { $BinaryDirectory = Join-Path $workspace 'artifacts\bin\WebSurveyTests\Release' }
$webSurveyDirectory = $WebSurveyDirectory
$solution = Join-Path $webSurveyDirectory 'Epi Info Web Survey.sln'
$project = Join-Path $webSurveyDirectory 'Epi.Web.Test\Epi.Web.Test.csproj'
$testPackagesConfig = Join-Path $webSurveyDirectory 'Epi.Web.Test\packages.config'
$packageDirectory = Join-Path $webSurveyDirectory 'packages'
$adapterPath = Join-Path $packageDirectory 'NUnit3TestAdapter.6.3.1\build\net462'
# MSBuild OutDir must end with a directory separator.
$binaryDirectory = $BinaryDirectory.TrimEnd('\', '/') + '\'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
# Every discovered test must run; a drop in this count means tests were silently lost.
# 56 controller/model tests + 27 display-mode tests + 19 static layout asset tests.
$expectedTotal = 102

foreach ($path in @($solution, $project, $testPackagesConfig)) {
    if (-not (Test-Path $path)) { throw "Required Web Survey test input does not exist: $path" }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $OutputDirectory "websurvey-solution-restore-$timestamp.log"
$testRestoreLog = Join-Path $OutputDirectory "websurvey-tests-restore-$timestamp.log"
$buildLog = Join-Path $OutputDirectory "websurvey-tests-build-$timestamp.log"
$buildConsoleLog = Join-Path $OutputDirectory "websurvey-tests-build-console-$timestamp.log"
$testLog = Join-Path $OutputDirectory "websurvey-tests-vstest-$timestamp.log"
$trx = Join-Path $OutputDirectory "websurvey-tests-$timestamp.trx"
$resultPath = Join-Path $OutputDirectory "websurvey-tests-result-$timestamp.json"

Write-Output '=== Restoring Web Survey solution packages ==='
& $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Web Survey solution package restore failed. See $solutionRestoreLog" }

Write-Output '=== Restoring Web Survey test packages ==='
& $NuGet restore $testPackagesConfig -NonInteractive -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $testRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Web Survey test package restore failed. See $testRestoreLog" }
if (-not (Test-Path (Join-Path $adapterPath 'NUnit3.TestAdapter.dll'))) { throw "NUnit adapter was not restored: $adapterPath" }

Write-Output '=== Building Epi.Web.Test (Release, AnyCPU) ==='
New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
$frameworkTargets = Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets'
& $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=AnyCPU "/p:OutDir=$binaryDirectory" /p:RestorePackages=false /p:Disable_CopyWebApplication=true "/p:CustomAfterMicrosoftCommonTargets=$frameworkTargets" /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
if ($LASTEXITCODE -ne 0) { throw "Web Survey test build failed. See $buildLog and $buildConsoleLog" }

$assembly = Join-Path $binaryDirectory 'Epi.Web.Test.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

# Not run here; each needs infrastructure this unit-test stage deliberately avoids.
$excludedTests = @(
    'Epi.Web.SurveyManager.Test (separate project): uses EntitySurveyInfoDao against a SQL database.',
    'HomeController POST Index (Begin Survey) and SurveyController GET/POST success paths: create or save responses through the survey service/repository (WCF) and execute check code over a live response hierarchy.',
    'Built-in MVC "Mobile" display mode under a browser-override cookie: needs ASP.NET browser-capability detection from a hosted AppDomain (custom Android/Opera Mobi/iPad modes are covered through DisplayModeConfig).',
    'Razor rendering, the real view engine, and browser runtime of layouts (script execution, CDN loads, CSS url() images): need an IIS-hosted application with a root Web.config and WCF/database services; layout assets are checked statically only.',
    'FinalController POST Index and email notification: send through the survey service and SMTP.'
)

Write-Output '=== Running Web Survey unit tests ==='
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
$status = if ($testExitCode -eq 0 -and $total -gt 0 -and $total -eq $expectedTotal -and $executed -eq $total -and $passed -eq $total -and $failed -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    TestProject = 'Epi-Info-Web-Survey/Epi.Web.Test'
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
    ExcludedTests = $excludedTests
    TRX = $trx
    RestoreLogs = @($solutionRestoreLog, $testRestoreLog)
    BuildLog = $buildLog
    VSTestLog = $testLog
}
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath

$result | Format-List TestProject, Configuration, Platform, ExpectedTotal, Total, Executed, Passed, Failed, VSTestExitCode, Status, TRX
if ($total -eq 0) { throw "VSTest discovered no Web Survey tests. See $testLog" }
if ($status -ne 'Passed') { throw "Web Survey unit tests failed. See $testLog and $trx" }
