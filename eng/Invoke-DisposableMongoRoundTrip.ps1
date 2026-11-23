[CmdletBinding()]
param(
    # Docker image of the MongoDB server to test, for example mongo:8.0.
    [Parameter(Mandatory)][string]$Image,
    [string]$DesktopBinDirectory,
    [string]$OutputDirectory,
    [string]$ProbeDirectory
)

# Starts a throwaway, authenticated, compression-enabled local MongoDB container, runs
# Invoke-DesktopMongoRoundTrip.ps1 against it and always removes the container.
# Data directories are tmpfs, the generated password exists only in this process and the
# container's environment, and the port is bound to loopback.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Path $PSScriptRoot -Parent
$label = ($Image -replace '[^A-Za-z0-9.]', '-')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $workspace "artifacts\tests\DesktopMongo\$label" }
if ([string]::IsNullOrWhiteSpace($ProbeDirectory)) { $ProbeDirectory = Join-Path $workspace "artifacts\probes\DesktopMongo-$label" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Invoke-Docker { $o = & docker @args 2>&1; [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($o | Out-String).Trim() } }

if ((Invoke-Docker version --format '{{.Server.Version}}').Exit -ne 0) { throw 'Docker is not available or its engine is not running.' }

$name = 'epiinfo-mongo-roundtrip-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$bytes = New-Object byte[] 24
$rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
$password = [Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]', 'x'
$user = 'epiprobe'
$summary = [ordered]@{ image = $Image; container = $name; port = $port }

try {
    $env:MONGO_INITDB_ROOT_USERNAME = $user
    $env:MONGO_INITDB_ROOT_PASSWORD = $password
    $run = Invoke-Docker run -d --name $name -p "127.0.0.1:${port}:27017" --tmpfs /data/db --tmpfs /data/configdb -e MONGO_INITDB_ROOT_USERNAME -e MONGO_INITDB_ROOT_PASSWORD $Image '--networkMessageCompressors=snappy,zstd,zlib'
    Remove-Item Env:\MONGO_INITDB_ROOT_USERNAME, Env:\MONGO_INITDB_ROOT_PASSWORD
    if ($run.Exit -ne 0) { throw "docker run failed: $($run.Output)" }
    Write-Output "Started $name ($Image) on 127.0.0.1:$port"

    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 2
        $logs = (Invoke-Docker logs $name).Output
        $ready = $logs -match 'init process complete' -and ($logs -split 'init process complete')[-1] -match 'Waiting for connections'
    } until ($ready -or (Get-Date) -gt $deadline)
    if (-not $ready) {
        $logs.Replace($password, '[REDACTED]') | Set-Content -LiteralPath (Join-Path $OutputDirectory 'container-failed.log')
        throw 'MongoDB did not become ready; see container-failed.log.'
    }

    $shell = if ((Invoke-Docker exec $name sh -c 'command -v mongosh').Exit -eq 0) { 'mongosh' } else { 'mongo' }
    $summary.serverVersion = ((Invoke-Docker exec $name mongod --version).Output -split "`n" | Select-Object -First 1).Trim()
    $unauthenticated = Invoke-Docker exec $name $shell --quiet --eval 'try { printjson(db.adminCommand({listDatabases:1})) } catch (e) { print(e) }'
    $summary.authenticationEnforced = $unauthenticated.Output -match 'requires authentication|Unauthorized|not authorized'
    if (-not $summary.authenticationEnforced) { throw 'The container accepted an unauthenticated listDatabases command.' }

    $connectionString = "mongodb://${user}:${password}@127.0.0.1:${port}/?authSource=admin"
    $arguments = @{ ConnectionString = $connectionString; ConfirmDisposableServer = $true; OutputDirectory = $OutputDirectory; ProbeDirectory = $ProbeDirectory }
    if ($DesktopBinDirectory) { $arguments.DesktopBinDirectory = $DesktopBinDirectory }
    & (Join-Path $PSScriptRoot 'Invoke-DesktopMongoRoundTrip.ps1') @arguments 2>&1 | ForEach-Object { "$_".Replace($password, '[REDACTED]') }
    $summary.roundTripExitCode = $LASTEXITCODE
}
finally {
    Remove-Item Env:\MONGO_INITDB_ROOT_USERNAME, Env:\MONGO_INITDB_ROOT_PASSWORD -ErrorAction SilentlyContinue
    $removal = Invoke-Docker rm -f -v $name
    $remaining = (Invoke-Docker ps -a --filter "name=^/$name$" --format '{{.Names}}').Output
    $summary.containerRemoved = ($removal.Exit -eq 0 -and [string]::IsNullOrWhiteSpace($remaining))
    Remove-Variable password, connectionString -ErrorAction SilentlyContinue
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'container-summary.json')
    $summary | ConvertTo-Json
}
if ($summary.roundTripExitCode -ne 0) { exit 1 }
