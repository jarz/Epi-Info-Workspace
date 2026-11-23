[CmdletBinding()]
param(
    [string]$Root,
    [string]$WebEnterDirectory,
    [string]$NuGet,
    [string]$ArtifactsDirectory,
    # Also rebuild the whole Web Enter solution (Release) before the test project, as a build baseline.
    [switch]$IncludeSolutionBuild
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Path $workspace -Parent }
if ([string]::IsNullOrWhiteSpace($WebEnterDirectory)) { $WebEnterDirectory = Join-Path $Root 'Epi-Info-Web-Enter' }
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
$frameworkTargets = Join-Path $PSScriptRoot 'LegacyFrameworkReferences.targets'
$isolationTargets = Join-Path $PSScriptRoot 'IsolatedIntermediates.targets'
foreach ($path in @($frameworkTargets, $isolationTargets)) {
    if (-not (Test-Path $path)) { throw "Required MSBuild import does not exist: $path" }
}
if (-not (Test-Path (Join-Path $workspace 'scratch\framework-packages\Microsoft.NETFramework.ReferenceAssemblies.net452.1.0.3\build\Microsoft.NETFramework.ReferenceAssemblies.net452.targets'))) {
    throw 'Run eng\Initialize-Build.ps1 first to restore private legacy targeting assemblies.'
}

$solution = Join-Path $WebEnterDirectory 'Epi Info Web Enter.sln'
$project = Join-Path $WebEnterDirectory 'Epi.Web.Test\Epi.Web.Test.csproj'
$testPackagesConfig = Join-Path $WebEnterDirectory 'Epi.Web.Test\packages.config'
$packageDirectory = Join-Path $WebEnterDirectory 'packages'
$adapterPath = Join-Path $packageDirectory 'NUnit3TestAdapter.6.3.1\build\net462'
$OutputDirectory = Join-Path $ArtifactsDirectory 'tests\WebEnter'
$solutionBinaryDirectory = Join-Path $ArtifactsDirectory 'bin\WebEnter\Release\'
$binaryDirectory = Join-Path $ArtifactsDirectory 'bin\WebEnterTests\Release\'
$solutionIntermediateRoot = Join-Path $ArtifactsDirectory 'obj\WebEnter\'
$intermediateRoot = Join-Path $ArtifactsDirectory 'obj\WebEnterTests\'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
# Every discovered test must run; a drop in this count means tests were silently lost.
# 79 controller/helper/form tests + 52 key-material/admin-key/password-salt/sign-in/key-rotation security tests.
$expectedTotal = 131

foreach ($path in @($solution, $project, $testPackagesConfig)) {
    if (-not (Test-Path $path)) { throw "Required Web Enter test input does not exist: $path" }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$solutionRestoreLog = Join-Path $OutputDirectory "webenter-solution-restore-$timestamp.log"
$testRestoreLog = Join-Path $OutputDirectory "webenter-tests-restore-$timestamp.log"
$solutionBuildLog = Join-Path $OutputDirectory "webenter-solution-build-$timestamp.log"
$solutionBuildConsoleLog = Join-Path $OutputDirectory "webenter-solution-build-console-$timestamp.log"
$buildLog = Join-Path $OutputDirectory "webenter-tests-build-$timestamp.log"
$buildConsoleLog = Join-Path $OutputDirectory "webenter-tests-build-console-$timestamp.log"
$testLog = Join-Path $OutputDirectory "webenter-tests-vstest-$timestamp.log"
$trx = Join-Path $OutputDirectory "webenter-tests-$timestamp.trx"
$resultPath = Join-Path $OutputDirectory "webenter-tests-result-$timestamp.json"

# OutDir and obj\ are redirected so neither the source tree nor shared checkouts receive build output.
$isolationArguments = @(
    '/p:RestorePackages=false',
    '/p:Disable_CopyWebApplication=true',
    "/p:CustomBeforeMicrosoftCommonTargets=$isolationTargets",
    "/p:CustomAfterMicrosoftCommonTargets=$frameworkTargets"
)

Write-Output '=== Restoring Web Enter solution packages ==='
& $NuGet restore $solution -NonInteractive -MSBuildPath (Split-Path $msbuild -Parent) -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $solutionRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Web Enter solution package restore failed. See $solutionRestoreLog" }

Write-Output '=== Restoring Web Enter test packages ==='
& $NuGet restore $testPackagesConfig -NonInteractive -PackagesDirectory $packageDirectory -Source 'https://api.nuget.org/v3/index.json' -Verbosity quiet *> $testRestoreLog
if ($LASTEXITCODE -ne 0) { throw "Web Enter test package restore failed. See $testRestoreLog" }
if (-not (Test-Path (Join-Path $adapterPath 'NUnit3.TestAdapter.dll'))) { throw "NUnit adapter was not restored: $adapterPath" }

if ($IncludeSolutionBuild) {
    Write-Output '=== Building Web Enter solution (Release) ==='
    New-Item -ItemType Directory -Path $solutionBinaryDirectory -Force | Out-Null
    & $msbuild $solution /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release "/p:OutDir=$solutionBinaryDirectory" "/p:IsolatedIntermediateRoot=$solutionIntermediateRoot" @isolationArguments /v:minimal "/flp:logfile=$solutionBuildLog;verbosity=normal" *> $solutionBuildConsoleLog
    if ($LASTEXITCODE -ne 0) { throw "Web Enter solution build failed. See $solutionBuildLog and $solutionBuildConsoleLog" }
}

Write-Output '=== Building Epi.Web.Test (Release, AnyCPU) ==='
New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
& $msbuild $project /nologo /m:2 /nr:false /t:Rebuild /p:Configuration=Release /p:Platform=AnyCPU "/p:OutDir=$binaryDirectory" "/p:IsolatedIntermediateRoot=$intermediateRoot" @isolationArguments /v:minimal "/flp:logfile=$buildLog;verbosity=normal" *> $buildConsoleLog
if ($LASTEXITCODE -ne 0) { throw "Web Enter test build failed. See $buildLog and $buildConsoleLog" }

$assembly = Join-Path $binaryDirectory 'Epi.Web.Test.dll'
if (-not (Test-Path $assembly)) { throw "Test assembly was not produced: $assembly" }

# Not run here; each needs infrastructure this unit-test stage deliberately avoids.
$excludedTests = @(
    'Epi.Web.SurveyManager.Test\Epi.Web.BLL.Test.csproj (separate stale project, not in the solution): publisher tests use EntitySurveyInfoDao and other DAL types against a SQL database.',
    'HomeController POST Index/Edit, GetSettings/SaveSettings, SurveyController, FormResponseController, FinalController POST and EIWSTController: create, save, delete, or submit responses through the survey service (WCF) and execute check code over a live response hierarchy.',
    'AdminOrganizationController, AdminUserController and LoginController (including OIDC/AD sign-in and password reset): user/organization management through the service, Active Directory, OIDC, and email.',
    'HomeController.Notify, EIWSTController.Notify and PostController.Notify: send email through SMTP.',
    'LogOut/SignOut actions (Home, Survey, FormResponse, Post, Login) and the invalid-user-id branch of SurveyHelper.GetDecryptUserId: call FormsAuthentication, which needs an IIS-hosted HttpContext.',
    'Epi.Web.SurveyManager.Client: interactive WCF client application, not unit-testable.',
    'Global.asax.cs Application_Start display modes, Unity bootstrapping, and WCF proxies: need an IIS-hosted application; no testable seam without a production refactor.'
)

Write-Output '=== Running Web Enter unit tests ==='
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
$status = if ($testExitCode -eq 0 -and $total -gt 0 -and $total -eq $expectedTotal -and $executed -eq $total -and $passed -eq $total -and $failed -eq 0) { 'Passed' } else { 'Failed' }

$result = [pscustomobject]@{
    TestProject = 'Epi-Info-Web-Enter/Epi.Web.Test'
    SourceDirectory = $WebEnterDirectory
    Configuration = 'Release'
    Platform = 'AnyCPU'
    TestFramework = 'NUnit 5.0.0 / NUnit3TestAdapter 6.3.1 / VSTest (Build Tools)'
    SolutionBuilt = [bool]$IncludeSolutionBuild
    ExpectedTotal = $expectedTotal
    Total = $total
    Executed = $executed
    Passed = $passed
    Failed = $failed
    VSTestExitCode = $testExitCode
    Status = $status
    FailedTests = $failedTests
    ExcludedTests = $excludedTests
    TRX = $trx
    RestoreLogs = @($solutionRestoreLog, $testRestoreLog)
    SolutionBuildLog = if ($IncludeSolutionBuild) { $solutionBuildLog } else { $null }
    BuildLog = $buildLog
    VSTestLog = $testLog
}
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath

$result | Format-List TestProject, Configuration, Platform, SolutionBuilt, ExpectedTotal, Total, Executed, Passed, Failed, VSTestExitCode, Status, TRX
$failedTests | ForEach-Object { Write-Output "FAILED: $_" }
if ($total -eq 0) { throw "VSTest discovered no Web Enter tests. See $testLog" }
if ($status -ne 'Passed') { throw "Web Enter unit tests failed. See $testLog and $trx" }
