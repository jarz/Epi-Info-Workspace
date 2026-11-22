[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# LegacyFrameworkReferences.targets imports from eng\..\scratch, so scratch must stay in this workspace.
$scratch = Join-Path (Split-Path $PSScriptRoot -Parent) 'scratch'
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$nuget = Join-Path $scratch 'nuget.exe'
if (-not (Test-Path $nuget)) {
    Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/v6.14.0/nuget.exe' -OutFile $nuget
}
$signature = Get-AuthenticodeSignature $nuget
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
    throw 'NuGet CLI must have a valid Microsoft Authenticode signature.'
}
$version = (Get-Item $nuget).VersionInfo.ProductVersion
if ($version -notlike '6.14.0*') { throw "Expected NuGet 6.14.0; found $version." }

& $nuget restore (Join-Path $PSScriptRoot 'packages.config') -PackagesDirectory (Join-Path $scratch 'framework-packages') -Source 'https://api.nuget.org/v3/index.json' -NonInteractive -Verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'Legacy framework reference assembly restore failed.' }
Write-Output 'NuGet and private legacy framework reference assemblies are ready. Visual Studio Build Tools is installed separately.'
