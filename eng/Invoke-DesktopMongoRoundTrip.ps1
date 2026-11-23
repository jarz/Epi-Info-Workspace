[CmdletBinding()]
param(
    # MongoDB URI of an authorized, disposable server. Required; there is deliberately no default.
    [string]$ConnectionString,
    # Required acknowledgement that the server is disposable and that writes/drops of a throwaway database are allowed.
    [switch]$ConfirmDisposableServer,
    [string]$DesktopBinDirectory,
    [string]$OutputDirectory,
    [switch]$SkipAdapter,
    # Compile and stage the probe only; no connection string or server is needed.
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Path $PSScriptRoot -Parent

if (-not $BuildOnly) {
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        throw 'Refusing to run: -ConnectionString is required and has no default. Supply the URI of an authorized, disposable MongoDB server (use -BuildOnly to compile without connecting).'
    }
    if (-not $ConfirmDisposableServer) {
        throw 'Refusing to run: -ConfirmDisposableServer was not supplied. The probe creates and drops a throwaway database (epiinfo_roundtrip_<guid>) and must only target an authorized, disposable server.'
    }
}

if ([string]::IsNullOrWhiteSpace($DesktopBinDirectory)) { $DesktopBinDirectory = Join-Path $workspace 'artifacts\bin\Desktop\Release' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $workspace 'artifacts\tests\DesktopMongo' }
$DesktopBinDirectory = [IO.Path]::GetFullPath($DesktopBinDirectory)

$hostConfig = Join-Path $DesktopBinDirectory 'EpiInfo.exe.config'
foreach ($required in @('Epi.Core.dll', 'Epi.Data.MongoDB.dll', 'MongoDB.Driver.dll', 'MongoDB.Driver.Core.dll', 'MongoDB.Bson.dll', 'Snappier.dll', 'SharpCompress.dll', 'ZstdSharp.dll', 'EpiInfo.exe.config')) {
    if (-not (Test-Path -LiteralPath (Join-Path $DesktopBinDirectory $required))) {
        throw "Desktop Release output is missing $required in $DesktopBinDirectory. Build Desktop Release (eng\Invoke-Build.ps1) or pass -DesktopBinDirectory."
    }
}
$hostConfigText = Get-Content -LiteralPath $hostConfig -Raw
foreach ($redirect in @('name="Snappier"', 'name="SharpCompress"', 'name="ZstdSharp"')) {
    if ($hostConfigText -notmatch [regex]::Escape($redirect)) { throw "EpiInfo.exe.config has no binding redirect for $redirect; the probe must run under the Desktop host redirects." }
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'Install Visual Studio Build Tools (managed desktop workload) first.' }
$installationPath = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installationPath) { throw 'Visual Studio MSBuild was not found.' }
$csc = Join-Path $installationPath 'MSBuild\Current\Bin\Roslyn\csc.exe'
if (-not (Test-Path $csc)) { throw "Roslyn compiler was not found: $csc" }
$referenceDirectory = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"
if (-not (Test-Path (Join-Path $referenceDirectory 'mscorlib.dll'))) { throw ".NET Framework 4.8 targeting pack was not found: $referenceDirectory" }

$probeSource = Join-Path $PSScriptRoot 'probes\MongoRoundTrip\Program.cs'
$probeDirectory = Join-Path $workspace 'artifacts\probes\DesktopMongoRoundTrip'
$probeExe = Join-Path $probeDirectory 'Epi.MongoRoundTripProbe.exe'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
New-Item -ItemType Directory -Path $probeDirectory, $OutputDirectory -Force | Out-Null

Write-Output '=== Staging Desktop Release assemblies beside the probe ==='
# The probe must resolve dependencies exactly as EpiInfo.exe does: same application base, same binding redirects.
$copied = 0
foreach ($file in Get-ChildItem -LiteralPath $DesktopBinDirectory -Filter '*.dll' -File) {
    $target = Join-Path $probeDirectory $file.Name
    $existing = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
    if (-not $existing -or $existing.Length -ne $file.Length -or $existing.LastWriteTimeUtc -ne $file.LastWriteTimeUtc) {
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $copied++
    }
}
Copy-Item -LiteralPath $hostConfig -Destination "$probeExe.config" -Force
Write-Output "Copied $copied changed assemblies; host config: EpiInfo.exe.config -> $(Split-Path "$probeExe.config" -Leaf)"

Write-Output '=== Compiling probe (x86, .NET Framework 4.8) ==='
$references = @('mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Data.dll', 'System.Xml.dll', 'Facades\System.Runtime.dll', 'Facades\netstandard.dll') |
    ForEach-Object { '/reference:' + (Join-Path $referenceDirectory $_) }
$references += @('MongoDB.Bson.dll', 'MongoDB.Driver.dll', 'MongoDB.Driver.Core.dll', 'Epi.Core.dll') |
    ForEach-Object { '/reference:' + (Join-Path $probeDirectory $_) }
$compileLog = Join-Path $OutputDirectory "desktop-mongo-probe-compile-$timestamp.log"
& $csc /nologo /noconfig /nostdlib+ /target:exe /platform:x86 /optimize+ /langversion:7.3 /warn:4 "/out:$probeExe" @references $probeSource *> $compileLog
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $compileLog | Write-Output
    throw "Probe compilation failed. See $compileLog"
}
Write-Output "Probe: $probeExe"

if ($BuildOnly) {
    Write-Output 'Build only: the probe was not run.'
    return
}

$resultPath = Join-Path $OutputDirectory "desktop-mongo-roundtrip-$timestamp.json"
$runLog = Join-Path $OutputDirectory "desktop-mongo-roundtrip-$timestamp.log"
$probeArguments = @('--confirm-disposable-server', '--output', $resultPath)
if ($SkipAdapter) { $probeArguments += '--skip-adapter' }

Write-Output '=== Running MongoDB round-trip probe ==='
# Hand the connection string over through a process-scoped environment variable so it never appears on a command line or in logs.
$variable = 'EPIINFO_MONGO_ROUNDTRIP_CONNECTION_STRING'
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    [Environment]::SetEnvironmentVariable($variable, $ConnectionString, 'Process')
    & $probeExe @probeArguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $runLog
    $probeExitCode = $LASTEXITCODE
}
finally {
    [Environment]::SetEnvironmentVariable($variable, $null, 'Process')
    $ErrorActionPreference = $previousErrorActionPreference
}

if (-not (Test-Path -LiteralPath $resultPath)) { throw "The probe did not write a result (exit code $probeExitCode). See $runLog" }
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
$result.checks | ForEach-Object { [pscustomobject]@{ Check = $_.name; Status = $_.status } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
[pscustomobject]@{
    Status = $result.status
    ServerVersion = if ($result.server) { $result.server.version } else { $null }
    MongoDBDriver = $result.assemblies.'MongoDB.Driver'.identity
    Snappier = $result.assemblies.Snappier.identity
    SharpCompress = $result.assemblies.SharpCompress.identity
    ZstdSharp = $result.assemblies.ZstdSharp.identity
    ProbeExitCode = $probeExitCode
    Result = $resultPath
    Log = $runLog
} | Format-List | Out-String -Width 200 | Write-Output

if ($probeExitCode -ne 0) {
    Write-Error "Desktop MongoDB round-trip failed (probe exit code $probeExitCode). See $resultPath" -ErrorAction Continue
    exit $probeExitCode
}
