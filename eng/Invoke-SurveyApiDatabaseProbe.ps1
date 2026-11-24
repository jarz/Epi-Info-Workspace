[CmdletBinding()]
param(
    [switch]$KeepDatabase
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this script with Windows PowerShell (powershell.exe), not PowerShell Core.'
}
$workspace = Split-Path $PSScriptRoot -Parent
$bin = Join-Path $workspace 'artifacts\bin\SurveyApi\Release'
$dacpac = Join-Path $workspace 'artifacts\bin\Database\Release\EpiInfo.Database.EIWeb.dacpac'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products '*' -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'Visual Studio SSDT is required.' }
$sqlPackage = Join-Path $vs 'Common7\IDE\Extensions\Microsoft\SQLDB\DAC\SqlPackage.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
foreach ($path in @($dacpac, $sqlPackage, $compiler, (Join-Path $bin 'Epi.Web.SurveyAPI.dll'), (Join-Path $bin 'System.Web.Http.dll'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input not found: $path. Build SurveyApi and Database in Release first." }
}
if (-not (Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue)) { throw 'SQL Server LocalDB is required.' }

$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$instance = "EpiSurveyApiTest_$id"
$database = "EpiSurveyApiSynthetic_$id"
$server = "(localdb)\$instance"
$work = Join-Path $workspace "artifacts\tests\SurveyApiDatabase\$id"
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item -Path (Join-Path $bin '*.dll') -Destination $work
$exe = Join-Path $work 'SurveyApiDatabaseProbe.exe'
$source = Join-Path $PSScriptRoot 'SurveyApiDatabaseProbe.cs'
& $compiler /nologo /target:exe "/out:$exe" "/reference:$(Join-Path $work 'Epi.Web.SurveyAPI.dll')" "/reference:$(Join-Path $work 'System.Web.Http.dll')" /reference:System.dll /reference:System.Core.dll /reference:System.Data.dll /reference:System.Net.Http.dll $source
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the database probe.' }

[void][Reflection.Assembly]::LoadFrom((Join-Path $work 'Epi.Web.SurveyAPI.dll'))
$keys = [Epi.Web.SurveyAPI.Web.Common.Security.KeyMaterial]::Generate()
$crypto = [Epi.Web.SurveyAPI.Web.Common.Security.Cryptography]
$ado = "Data Source=$server;Initial Catalog=$database;Integrated Security=True"
$entity = 'metadata=res://*/EF.Epi.Web.Model.csdl|res://*/EF.Epi.Web.Model.ssdl|res://*/EF.Epi.Web.Model.msl;provider=System.Data.SqlClient;provider connection string="' + $ado + '"'
$apiKeyBytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($apiKeyBytes) } finally { $rng.Dispose() }
$apiKey = [BitConverter]::ToString($apiKeyBytes).Replace('-', '')

$config = New-Object System.Xml.XmlDocument
$config.LoadXml('<configuration><connectionStrings/><appSettings/></configuration>')
$webConfigPath = Join-Path (Split-Path $workspace -Parent) 'Epi-Info-Survey-API\Epi.Web.SurveyAPI\Web.config'
$webConfig = New-Object System.Xml.XmlDocument
$webConfig.Load($webConfigPath)
$runtime = $webConfig.SelectSingleNode('/configuration/runtime')
if (-not $runtime) { throw "Runtime binding redirects not found in $webConfigPath." }
[void]$config.DocumentElement.AppendChild($config.ImportNode($runtime, $true))
foreach ($item in @(
    @('SurveyAPIEntities', $crypto::Encrypt($entity, $keys)),
    @('EIWSADO', $crypto::Encrypt($ado, $keys))
)) {
    $node = $config.CreateElement('add')
    $node.SetAttribute('name', $item[0]); $node.SetAttribute('connectionString', $item[1])
    [void]$config.SelectSingleNode('/configuration/connectionStrings').AppendChild($node)
}
foreach ($item in @(
    @('KeyForConnectionStringPassphrase', $keys.Passphrase),
    @('KeyForConnectionStringSalt', $keys.Salt),
    @('KeyForConnectionStringVector', $keys.Vector),
    @('SurveyApiSharedKey', $apiKey)
)) {
    $node = $config.CreateElement('add')
    $node.SetAttribute('key', $item[0]); $node.SetAttribute('value', $item[1])
    [void]$config.SelectSingleNode('/configuration/appSettings').AppendChild($node)
}
$config.Save("$exe.config")

function Invoke-Sql([string]$connectionString, [string]$sql, [hashtable]$parameters = @{}) {
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        foreach ($name in $parameters.Keys) { [void]$command.Parameters.AddWithValue($name, $parameters[$name]) }
        [void]$command.ExecuteNonQuery()
    }
    finally { $connection.Dispose() }
}

function Invoke-Probe([string]$path, [string[]]$arguments, [string]$log) {
    try {
        $ErrorActionPreference = 'Continue'
        & $path @arguments *> $log
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = 'Stop' }
    Get-Content -LiteralPath $log
    if ($exitCode -ne 0) { throw "Survey API database probe failed. See $log" }
}

$created = $false
$succeeded = $false
try {
    $existing = @(& SqlLocalDB.exe info)
    if ($existing -contains $instance) { throw "Refusing to reuse existing LocalDB instance $instance." }
    & SqlLocalDB.exe create $instance
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated LocalDB instance.' }
    $created = $true
    & SqlLocalDB.exe start $instance
    if ($LASTEXITCODE -ne 0) { throw 'Could not start the isolated LocalDB instance.' }
    $publishLog = Join-Path $work 'publish.log'
    & $sqlPackage /Action:Publish "/SourceFile:$dacpac" "/TargetServerName:$server" "/TargetDatabaseName:$database" /TargetTrustServerCertificate:True /p:BlockOnPossibleDataLoss=True *> $publishLog
    if ($LASTEXITCODE -ne 0) { throw "Schema deployment failed. See $publishLog" }

    $surveyId = [guid]::NewGuid()
    $publisherKey = [guid]::NewGuid()
    $organizationKey = [guid]::NewGuid()
    $responseId = [guid]::NewGuid()
    $sql = @'
INSERT dbo.lk_SurveyType(SurveyTypeId, SurveyType) VALUES (1, 'Synthetic');
INSERT dbo.lk_Status(StatusId, Status) VALUES (1, 'Synthetic'), (3, 'Synthetic');
INSERT dbo.lk_RecordSource(RecordSourceId, RecordSource) VALUES (3, 'Synthetic'), (4, 'Synthetic');
INSERT dbo.Organization(OrganizationKey, Organization, IsEnabled) VALUES (@orgkey, 'Synthetic organization', 1);
DECLARE @orgid int = SCOPE_IDENTITY();
INSERT dbo.SurveyMetaData(SurveyId, SurveyTypeId, ClosingDate, SurveyName, TemplateXML, UserPublishKey, TemplateXMLSize, OrganizationId)
VALUES (@survey, 1, DATEADD(year, 1, GETDATE()), 'Synthetic survey',
        '<Template><Project><View Name="Synthetic"><Page PageId="1"><Field Name="Question1" FieldTypeId="1" Position="0" IsRequired="false" PromptText="Synthetic question" PageId="1" SourceTableName="" /></Page></View></Project></Template>',
        @publisher, 250, @orgid);
'@
    Invoke-Sql $ado $sql @{
        '@orgkey' = $crypto::Encrypt($organizationKey.ToString(), $keys)
        '@survey' = $surveyId
        '@publisher' = $publisherKey
    }
    $env:EPI_SURVEY_TEST_API_KEY = $apiKey
    Invoke-Probe $exe @($surveyId.ToString(), $publisherKey.ToString(), $organizationKey.ToString(), $responseId.ToString()) (Join-Path $work 'probe.log')

    $unavailableExe = Join-Path $work 'SurveyApiUnavailableProbe.exe'
    Copy-Item -LiteralPath $exe -Destination $unavailableExe
    $unavailableConfig = $config.Clone()
    $unavailableAdo = "Data Source=$server;Initial Catalog=${database}_missing;Integrated Security=True;Connect Timeout=5"
    $unavailableEntity = 'metadata=res://*/EF.Epi.Web.Model.csdl|res://*/EF.Epi.Web.Model.ssdl|res://*/EF.Epi.Web.Model.msl;provider=System.Data.SqlClient;provider connection string="' + $unavailableAdo + '"'
    $unavailableConfig.SelectSingleNode("/configuration/connectionStrings/add[@name='SurveyAPIEntities']").SetAttribute('connectionString', $crypto::Encrypt($unavailableEntity, $keys))
    $unavailableConfig.SelectSingleNode("/configuration/connectionStrings/add[@name='EIWSADO']").SetAttribute('connectionString', $crypto::Encrypt($unavailableAdo, $keys))
    $unavailableConfig.Save("$unavailableExe.config")
    Invoke-Probe $unavailableExe @('--unavailable', $surveyId.ToString()) (Join-Path $work 'unavailable-probe.log')
    $succeeded = $true
}
finally {
    Remove-Item Env:\EPI_SURVEY_TEST_API_KEY -ErrorAction SilentlyContinue
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    if ($created -and (-not $KeepDatabase -or -not $succeeded)) {
        $master = "Data Source=$server;Initial Catalog=master;Integrated Security=True"
        Invoke-Sql $master "IF DB_ID('$database') IS NOT NULL DROP DATABASE [$database]"
        & SqlLocalDB.exe stop $instance
        if ($LASTEXITCODE -ne 0) { throw "Could not stop test instance $instance." }
        & SqlLocalDB.exe delete $instance
        if ($LASTEXITCODE -ne 0) { throw "Could not delete test instance $instance." }
        Write-Output "Removed test database and instance $instance."
    }
}
if ($KeepDatabase -and $succeeded) {
    Write-Output "Synthetic database retained: $database on $server"
    Write-Output "Synthetic probe configuration and deployment log: $work"
}
