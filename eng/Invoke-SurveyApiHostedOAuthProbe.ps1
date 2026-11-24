[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\(localdb\)\\EpiSurveyApiTest_[0-9a-fA-F]{12}$')]
    [string]$Server,

    [Parameter(Mandatory)]
    [ValidatePattern('^EpiSurveyApiSynthetic_[0-9a-fA-F]{12}$')]
    [string]$Database,

    [Parameter(Mandatory)]
    [string]$ProbeConfigPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CertificateThumbprint,

    [ValidateRange(1024, 65535)]
    [int]$HttpsPort = 44300
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this script with Windows PowerShell (powershell.exe), not PowerShell Core.'
}

$workspace = Split-Path $PSScriptRoot -Parent
$repositoryRoot = Split-Path $workspace -Parent
$apiSource = Join-Path $repositoryRoot 'Epi-Info-Survey-API\Epi.Web.SurveyAPI'
$binary = Join-Path $workspace 'artifacts\bin\SurveyApi\Release'
$roslynDirectory = Join-Path $binary '_PublishedWebsites\Epi.Web.SurveyAPI\bin\roslyn'
$iis = 'C:\Program Files\IIS Express\iisexpress.exe'
$applicationHostTemplate = 'C:\Program Files\IIS Express\config\templates\PersonalWebServer\applicationhost.config'
$probeConfig = (Resolve-Path -LiteralPath $ProbeConfigPath).Path
$thumbprint = $CertificateThumbprint.ToUpperInvariant()
$identityDatabase = 'EpiSurveyApiIdentitySynthetic_' + [guid]::NewGuid().ToString('N')
$identityConnectionString = "Data Source=$Server;Initial Catalog=$identityDatabase;Integrated Security=True;Connect Timeout=10"
$databaseConnectionString = "Data Source=$Server;Initial Catalog=$Database;Integrated Security=True;Connect Timeout=10"
$testId = [guid]::NewGuid().ToString('N')
$work = Join-Path $workspace "artifacts\tests\SurveyApiHosted\$testId"
$site = Join-Path $work 'site'
$siteBin = Join-Path $site 'bin'
$process = $null
$previousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
$identityDatabaseMayExist = $false

foreach ($path in @(
    $probeConfig,
    (Join-Path $apiSource 'Global.asax'),
    (Join-Path $apiSource 'Web.config'),
    (Join-Path $apiSource 'App_Data\XMLDocument.xml'),
    (Join-Path $binary 'Epi.Web.SurveyAPI.dll'),
    (Join-Path $binary 'System.Web.Http.dll'),
    (Join-Path $roslynDirectory 'csc.exe'),
    $iis,
    $applicationHostTemplate
)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required hosted probe input not found: $path. Build SurveyApi in Release first."
    }
}

$fixture = New-Object System.Xml.XmlDocument
$fixture.Load($probeConfig)
$apiKeyNode = $fixture.SelectSingleNode("/configuration/appSettings/add[@key='SurveyApiSharedKey']")
if (-not $apiKeyNode) { throw 'Synthetic probe configuration has no SurveyApiSharedKey.' }
$apiKey = $apiKeyNode.GetAttribute('value')
if ($apiKey -notmatch '^[0-9a-fA-F]{64}$') { throw 'Synthetic probe configuration has an invalid API key.' }

[void][Reflection.Assembly]::LoadFrom((Join-Path $binary 'Epi.Web.SurveyAPI.dll'))
$passphraseNode = $fixture.SelectSingleNode("/configuration/appSettings/add[@key='KeyForConnectionStringPassphrase']")
$saltNode = $fixture.SelectSingleNode("/configuration/appSettings/add[@key='KeyForConnectionStringSalt']")
$vectorNode = $fixture.SelectSingleNode("/configuration/appSettings/add[@key='KeyForConnectionStringVector']")
if (-not $passphraseNode -or -not $saltNode -or -not $vectorNode) {
    throw 'Synthetic probe configuration is missing the connection-string encryption keys.'
}
$keys = [Epi.Web.SurveyAPI.Web.Common.Security.KeyMaterial]::new(
    $passphraseNode.GetAttribute('value'),
    $saltNode.GetAttribute('value'),
    $vectorNode.GetAttribute('value')
)
$entityNode = $fixture.SelectSingleNode("/configuration/connectionStrings/add[@name='SurveyAPIEntities']")
$adoNode = $fixture.SelectSingleNode("/configuration/connectionStrings/add[@name='EIWSADO']")
if (-not $entityNode -or -not $adoNode) { throw 'Synthetic probe configuration is missing API database connection strings.' }
$entityString = [Epi.Web.SurveyAPI.Web.Common.Security.Cryptography]::Decrypt($entityNode.GetAttribute('connectionString'), $keys)
$providerMatch = [regex]::Match($entityString, 'provider connection string\s*=\s*"([^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (-not $providerMatch.Success) { throw 'Could not extract the synthetic Entity Framework provider connection string.' }
$entityDatabase = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($providerMatch.Groups[1].Value)
$adoDatabase = [System.Data.SqlClient.SqlConnectionStringBuilder]::new(
    [Epi.Web.SurveyAPI.Web.Common.Security.Cryptography]::Decrypt($adoNode.GetAttribute('connectionString'), $keys)
)
foreach ($configuredDatabase in @($entityDatabase, $adoDatabase)) {
    if (-not [string]::Equals($configuredDatabase.DataSource, $Server, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($configuredDatabase.InitialCatalog, $Database, [StringComparison]::OrdinalIgnoreCase) -or
        -not $configuredDatabase.IntegratedSecurity -or $configuredDatabase.UserID -or $configuredDatabase.Password) {
        throw 'Probe configuration must use Windows authentication and the explicitly supplied synthetic LocalDB database.'
    }
}

$connection = New-Object System.Data.SqlClient.SqlConnection $databaseConnectionString
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = "SELECT TOP (1) SurveyId FROM dbo.SurveyMetaData WHERE SurveyName = 'Synthetic survey'"
    $surveyId = [guid]$command.ExecuteScalar()
    if ($surveyId -eq [guid]::Empty) { throw 'The supplied database has no synthetic survey.' }
}
finally {
    $connection.Dispose()
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools are required to compile the temporary OAuth probe controller.' }
$vs = & $vswhere -latest -products '*' -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'Visual Studio Build Tools were not found.' }
$compiler = Join-Path $vs 'MSBuild\Current\Bin\Roslyn\csc.exe'
$frameworkReferences = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'

New-Item -ItemType Directory -Path $siteBin -Force | Out-Null
try {
    Copy-Item (Join-Path $apiSource 'Global.asax') $site
    New-Item -ItemType Directory -Path (Join-Path $site 'App_Data') | Out-Null
    Copy-Item (Join-Path $apiSource 'App_Data\XMLDocument.xml') (Join-Path $site 'App_Data')
    Copy-Item (Join-Path $apiSource 'Scripts') $site -Recurse
    Copy-Item (Join-Path $apiSource 'Content') $site -Recurse
    Get-ChildItem -LiteralPath $binary -Filter '*.dll' | Where-Object {
        $_.Name -notlike 'Microsoft.AI.*' -and $_.Name -ne 'Microsoft.ApplicationInsights.dll'
    } | Copy-Item -Destination $siteBin
    New-Item -ItemType Junction -Path (Join-Path $siteBin 'roslyn') -Target $roslynDirectory | Out-Null

    $controllerSource = @'
using System.Web.Http;

namespace Epi.Web.SurveyAPI.Controllers
{
    [Authorize]
    [RoutePrefix("api/OAuthProbe")]
    public sealed class OAuthProbeController : ApiController
    {
        [HttpPost]
        [Route("Identity")]
        public IHttpActionResult GetIdentity()
        {
            return Ok(User.Identity.Name);
        }
    }
}
'@
    $controllerSourcePath = Join-Path $work 'OAuthProbeController.cs'
    $controllerAssemblyPath = Join-Path $siteBin 'Epi.Web.SurveyAPI.OAuthProbe.dll'
    [IO.File]::WriteAllText($controllerSourcePath, $controllerSource, [Text.UTF8Encoding]::new($false))
    $references = @(
        (Join-Path $frameworkReferences 'mscorlib.dll'),
        (Join-Path $frameworkReferences 'System.dll'),
        (Join-Path $frameworkReferences 'System.Core.dll'),
        (Join-Path $frameworkReferences 'System.Net.Http.dll'),
        (Join-Path $siteBin 'System.Web.Http.dll'),
        (Join-Path $siteBin 'System.Net.Http.Formatting.dll')
    )
    foreach ($reference in $references) {
        if (-not (Test-Path -LiteralPath $reference)) { throw "Required compiler reference not found: $reference" }
    }
    if (-not (Test-Path -LiteralPath $compiler)) { throw "C# compiler not found: $compiler" }
    $compilerArguments = @('/nologo', '/target:library', "/out:$controllerAssemblyPath")
    $compilerArguments += $references | ForEach-Object { "/reference:$_" }
    $compilerArguments += $controllerSourcePath
    & $compiler @compilerArguments
    if ($LASTEXITCODE -ne 0) { throw "Temporary OAuth probe controller compilation failed ($LASTEXITCODE)." }

    $config = New-Object System.Xml.XmlDocument
    $config.Load((Join-Path $apiSource 'Web.config'))
    foreach ($node in $fixture.SelectNodes('/configuration/connectionStrings/add')) {
        $target = $config.SelectSingleNode("/configuration/connectionStrings/add[@name='$($node.GetAttribute('name'))']")
        if (-not $target) { throw "Web.config has no connection named $($node.GetAttribute('name'))." }
        $target.SetAttribute('connectionString', $node.GetAttribute('connectionString'))
    }
    foreach ($node in $fixture.SelectNodes('/configuration/appSettings/add')) {
        $target = $config.SelectSingleNode("/configuration/appSettings/add[@key='$($node.GetAttribute('key'))']")
        if (-not $target) { throw "Web.config has no appSetting named $($node.GetAttribute('key'))." }
        $target.SetAttribute('value', $node.GetAttribute('value'))
    }
    $identityNode = $config.SelectSingleNode("/configuration/connectionStrings/add[@name='DefaultConnection']")
    if (-not $identityNode) {
        $identityNode = $config.CreateElement('add')
        $identityNode.SetAttribute('name', 'DefaultConnection')
        $identityNode.SetAttribute('providerName', 'System.Data.SqlClient')
        [void]$config.SelectSingleNode('/configuration/connectionStrings').AppendChild($identityNode)
    }
    $identityNode.SetAttribute('connectionString', $identityConnectionString)
    $config.Save((Join-Path $site 'Web.config'))
    if (Get-ChildItem -LiteralPath $siteBin -Filter 'Microsoft.AI*.dll') {
        throw 'Telemetry assemblies must not be present in the isolated hosted test.'
    }

    if (Get-NetTCPConnection -LocalPort $HttpsPort -State Listen -ErrorAction SilentlyContinue) {
        throw "HTTPS port $HttpsPort is already in use."
    }
    $listener = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $listener.Start()
    $httpPort = $listener.LocalEndpoint.Port
    $listener.Stop()

    $apphost = New-Object System.Xml.XmlDocument
    $apphost.Load($applicationHostTemplate)
    $siteNode = $apphost.SelectSingleNode('/configuration/system.applicationHost/sites/site')
    if (-not $siteNode) { throw 'IIS Express applicationHost template contains no site node.' }
    $siteNode.SetAttribute('name', 'SyntheticSurveyApi')
    $siteNode.SelectSingleNode('application/virtualDirectory').SetAttribute('physicalPath', $site)
    $bindings = $siteNode.SelectSingleNode('bindings')
    $bindings.RemoveAll()
    foreach ($binding in @(@('http', $httpPort), @('https', $HttpsPort))) {
        $node = $apphost.CreateElement('binding')
        $node.SetAttribute('protocol', $binding[0])
        $node.SetAttribute('bindingInformation', ":$($binding[1]):localhost")
        [void]$bindings.AppendChild($node)
    }
    $hostPath = Join-Path $work 'applicationhost.config'
    $apphost.Save($hostPath)
    $stdout = Join-Path $work 'iis.stdout.log'
    $stderr = Join-Path $work 'iis.stderr.log'
    $process = Start-Process -FilePath $iis -ArgumentList @("/config:$hostPath", '/site:SyntheticSurveyApi', '/systray:false', '/trace:error') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $pinTypeName = 'LocalIisCertificatePin' + $testId
    $validatorSource = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class $pinTypeName {
    public static RemoteCertificateValidationCallback Callback { get { return Validate; } }
    public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
        var request = sender as HttpWebRequest;
        return request != null && request.RequestUri.Host == "localhost" && certificate != null
            && String.Equals(certificate.GetCertHashString(), "$thumbprint", StringComparison.OrdinalIgnoreCase);
    }
}
"@
    $validatorType = Add-Type -TypeDefinition $validatorSource -PassThru
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $validatorType.GetProperty('Callback').GetValue($null, $null)

    function Invoke-HostedRequest(
        [string]$Url,
        [string]$Body,
        [string]$ContentType,
        [string]$Key,
        [guid]$Survey,
        [string]$BearerToken = ''
    ) {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Proxy = $null
        $request.Timeout = 30000
        $request.Method = 'POST'
        $request.ContentType = $ContentType
        if ($Key) { $request.Headers.Add('X-Epi-Info-API-Key', $Key) }
        if ($Survey -ne [guid]::Empty) { $request.Headers.Add('SurveyId', $Survey.ToString()) }
        if ($BearerToken) { $request.Headers.Add('Authorization', "Bearer $BearerToken") }
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $request.ContentLength = $bytes.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        try { $response = $request.GetResponse() }
        catch [Net.WebException] {
            if (-not $_.Exception.Response) { throw }
            $response = $_.Exception.Response
        }
        try {
            $reader = New-Object IO.StreamReader $response.GetResponseStream()
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $text }
        }
        finally {
            $response.Dispose()
        }
    }

    $wrongKey = $(if ($apiKey[0] -eq '0') { '1' } else { '0' }) + $apiKey.Substring(1)
    $base = "https://localhost:$HttpsPort"
    $http = "http://localhost:$httpPort"
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    $ready = $null
    do {
        if ($process.HasExited) { throw "IIS Express exited; see $stdout and $stderr." }
        try {
            $ready = Invoke-HostedRequest "$base/api/SurveyResponse" '{}' 'application/json' $wrongKey $surveyId
        }
        catch [Net.WebException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
        }
        if (-not $ready) { Start-Sleep -Milliseconds 250 }
    } while (-not $ready -and [DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw "IIS Express did not become ready; see $stdout and $stderr." }
    if ($ready.Status -ne 401) { throw "HTTPS readiness expected 401, got $($ready.Status): $($ready.Body)" }

    $responseId = [guid]::NewGuid()
    $payload = @{ responseid = $responseId.ToString(); Question1 = 'hosted database answer' } | ConvertTo-Json -Compress
    $httpResult = Invoke-HostedRequest "$http/api/SurveyResponse" $payload 'application/json' $apiKey $surveyId
    if ($httpResult.Status -ne 400) { throw "HTTP API expected 400, got $($httpResult.Status)." }
    Write-Output 'PASS: hosted API rejects HTTP'

    $invalidResult = Invoke-HostedRequest "$base/api/SurveyResponse" $payload 'application/json' $wrongKey $surveyId
    if ($invalidResult.Status -ne 401) { throw "Wrong key expected 401, got $($invalidResult.Status)." }
    Write-Output 'PASS: hosted API rejects an incorrect key'

    $unknownResult = Invoke-HostedRequest "$base/api/SurveyResponse" $payload 'application/json' $apiKey ([guid]::NewGuid())
    if ($unknownResult.Status -ne 401) { throw "Unknown survey expected 401, got $($unknownResult.Status)." }
    Write-Output 'PASS: hosted API rejects an unknown survey'

    $submission = Invoke-HostedRequest "$base/api/SurveyResponse" $payload 'application/json' $apiKey $surveyId
    if ($submission.Status -ne 201) { throw "HTTPS submission expected 201, got $($submission.Status): $($submission.Body)" }
    $submissionJson = $submission.Body | ConvertFrom-Json
    if ($submissionJson.Status -ne 'Success' -or [guid]$submissionJson.SurveyResponseID -ne $responseId) {
        throw 'Hosted API returned an unexpected response.'
    }
    $connection = New-Object System.Data.SqlClient.SqlConnection $databaseConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT CAST(ResponseXML AS nvarchar(max)) FROM dbo.SurveyResponse WHERE ResponseId = @id AND SurveyId = @survey'
        [void]$command.Parameters.AddWithValue('@id', $responseId)
        [void]$command.Parameters.AddWithValue('@survey', $surveyId)
        $xml = $command.ExecuteScalar()
        if (-not $xml -or -not $xml.Contains('hosted database answer')) { throw 'Hosted response was not persisted.' }
    }
    finally {
        $connection.Dispose()
    }
    Write-Output 'PASS: HTTPS hosted API returns 201 and persists the synthetic answer'

    $insecureToken = Invoke-HostedRequest "$http/Token" 'grant_type=client_credentials' 'application/x-www-form-urlencoded' '' ([guid]::Empty)
    if ($insecureToken.Status -ne 404) { throw "HTTP token endpoint expected 404, got $($insecureToken.Status)." }
    Write-Output 'PASS: OAuth token endpoint rejects HTTP'

    $unauthorizedToken = Invoke-HostedRequest "$base/Token" 'grant_type=client_credentials' 'application/x-www-form-urlencoded' '' ([guid]::Empty)
    if ($unauthorizedToken.Status -ne 400 -or $unauthorizedToken.Body -notmatch 'unauthorized_client') {
        throw "Unauthorized client expected 400/unauthorized_client, got $($unauthorizedToken.Status): $($unauthorizedToken.Body)"
    }
    Write-Output 'PASS: OAuth token endpoint rejects an unauthorized client'

    $email = 'synthetic-' + [guid]::NewGuid().ToString('N') + '@example.test'
    $password = 'Synthetic!Test42'
    $unknownForm = 'grant_type=password&username=' + [uri]::EscapeDataString($email) + '&password=' + [uri]::EscapeDataString($password)
    $identityDatabaseMayExist = $true
    $unknownPassword = Invoke-HostedRequest "$base/Token" $unknownForm 'application/x-www-form-urlencoded' '' ([guid]::Empty)
    if ($unknownPassword.Status -ne 400 -or $unknownPassword.Body -notmatch 'invalid_grant') {
        throw "Unknown user expected 400/invalid_grant, got $($unknownPassword.Status): $($unknownPassword.Body)"
    }

    $identityAssembly = [Reflection.Assembly]::LoadFrom((Join-Path $binary 'Microsoft.AspNet.Identity.Core.dll'))
    $hasherType = $identityAssembly.GetType('Microsoft.AspNet.Identity.PasswordHasher', $true)
    $passwordHash = ([Activator]::CreateInstance($hasherType)).HashPassword($password)
    $connection = New-Object System.Data.SqlClient.SqlConnection $identityConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'INSERT dbo.AspNetUsers (Id, Email, EmailConfirmed, PasswordHash, SecurityStamp, PhoneNumber, PhoneNumberConfirmed, TwoFactorEnabled, LockoutEnabled, AccessFailedCount, UserName) VALUES (@id, @email, 0, @hash, @stamp, NULL, 0, 0, 0, 0, @email)'
        [void]$command.Parameters.AddWithValue('@id', [guid]::NewGuid().ToString())
        [void]$command.Parameters.AddWithValue('@email', $email)
        [void]$command.Parameters.AddWithValue('@hash', $passwordHash)
        [void]$command.Parameters.AddWithValue('@stamp', [guid]::NewGuid().ToString())
        [void]$command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
    Write-Output 'PASS: isolated Identity database seeded with a synthetic user'

    $form = 'grant_type=password&username=' + [uri]::EscapeDataString($email) + '&password=' + [uri]::EscapeDataString($password)
    $passwordToken = Invoke-HostedRequest "$base/Token" $form 'application/x-www-form-urlencoded' '' ([guid]::Empty)
    if ($passwordToken.Status -ne 200) { throw "OAuth password grant expected 200, got $($passwordToken.Status): $($passwordToken.Body)" }
    $tokenJson = $passwordToken.Body | ConvertFrom-Json
    if (-not $tokenJson.access_token -or $tokenJson.token_type -ne 'bearer' -or $tokenJson.userName -ne $email) {
        throw 'OAuth password grant returned an unexpected token response.'
    }
    Write-Output 'PASS: OAuth password grant issues a synthetic bearer token'

    $wrongPassword = 'grant_type=password&username=' + [uri]::EscapeDataString($email) + '&password=Wrong!Pass42'
    $badToken = Invoke-HostedRequest "$base/Token" $wrongPassword 'application/x-www-form-urlencoded' '' ([guid]::Empty)
    if ($badToken.Status -ne 400 -or $badToken.Body -notmatch 'invalid_grant') {
        throw "Wrong password expected 400/invalid_grant, got $($badToken.Status): $($badToken.Body)"
    }
    Write-Output 'PASS: OAuth password grant rejects an incorrect password'

    $unauthorizedProbe = Invoke-HostedRequest "$base/api/OAuthProbe/Identity" '{}' 'application/json' $apiKey $surveyId
    if ($unauthorizedProbe.Status -ne 401) { throw "Protected probe route expected 401 without a bearer token, got $($unauthorizedProbe.Status)." }
    $authorizedProbe = Invoke-HostedRequest "$base/api/OAuthProbe/Identity" '{}' 'application/json' $apiKey $surveyId $tokenJson.access_token
    if ($authorizedProbe.Status -ne 200 -or ($authorizedProbe.Body | ConvertFrom-Json) -ne $email) {
        throw "Bearer token did not authenticate the protected probe route: $($authorizedProbe.Status): $($authorizedProbe.Body)"
    }
    Write-Output 'PASS: issued bearer token authenticates a protected Web API route'
    Write-Output "Hosted OAuth probe passed for $Server / $Database."
}
catch {
    Write-Output ("Hosted probe error: " + $_.Exception.Message)
    if ($stdout -and (Test-Path -LiteralPath $stdout)) { Get-Content -LiteralPath $stdout }
    if ($stderr -and (Test-Path -LiteralPath $stderr)) { Get-Content -LiteralPath $stderr }
    throw
}
finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    try {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id
            $process.WaitForExit()
        }
    }
    finally {
        [System.Data.SqlClient.SqlConnection]::ClearAllPools()
        try {
            if ($identityDatabaseMayExist) {
                $masterConnection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Server;Initial Catalog=master;Integrated Security=True"
                try {
                    $masterConnection.Open()
                    $command = $masterConnection.CreateCommand()
                    $command.CommandText = "IF DB_ID(@name) IS NOT NULL BEGIN ALTER DATABASE [$identityDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$identityDatabase]; END"
                    [void]$command.Parameters.AddWithValue('@name', $identityDatabase)
                    [void]$command.ExecuteNonQuery()
                }
                finally {
                    $masterConnection.Dispose()
                }
            }
        }
        finally {
            $roslynJunction = Join-Path $siteBin 'roslyn'
            if (Test-Path -LiteralPath $roslynJunction) {
                [IO.Directory]::Delete($roslynJunction, $false)
            }
            if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        }
    }
}
