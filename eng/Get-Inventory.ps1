[CmdletBinding()]
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\inventory')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$repositories = @()
$projects = @()
$packages = @()
$references = @()
$solutions = @()
$sources = @()
$inventoryErrors = @()

$workspace = Split-Path $PSScriptRoot -Parent
foreach ($repository in Get-ChildItem $Root -Directory | Where-Object { $_.FullName -ne $workspace -and (Test-Path (Join-Path $_.FullName '.git')) }) {
    $files = @(git -C $repository.FullName ls-files --cached --others --exclude-standard | Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0) { throw "Cannot list tracked files in $($repository.Name)." }
    $commit = git -C $repository.FullName log -1 --format='%H|%cs'
    if ($LASTEXITCODE -ne 0) { throw "Cannot read commit in $($repository.Name)." }
    $state = @(git -C $repository.FullName status --short)
    if ($LASTEXITCODE -ne 0) { throw "Cannot read status in $($repository.Name)." }
    $projectCount = 0
    $packageCount = 0
    $binaryCount = @($files | Where-Object { $_ -match '\.(dll|exe|nupkg)$' }).Count

    foreach ($file in $files) {
        $path = Join-Path $repository.FullName ($file.Replace('/', '\'))
        if ($file -match '\.(csproj|vbproj|sqlproj|ccproj|pssproj|vdproj)$') {
            $projectCount++
            if ($file -match '\.vdproj$') {
                $projects += [pscustomobject]@{ Repository = $repository.Name; Project = $file; Framework = ''; Assembly = ''; SdkStyle = ''; Kind = 'vdproj' }
                continue
            }
            $xml = [xml]::new()
            try {
                $xml.Load($path)
            } catch [System.Xml.XmlException] {
                Write-Warning "Invalid project XML: $($repository.Name)\$file"
                $inventoryErrors += [pscustomobject]@{ Repository = $repository.Name; File = $file; Error = $_.Exception.Message }
                $projects += [pscustomobject]@{ Repository = $repository.Name; Project = $file; Framework = ''; Assembly = ''; SdkStyle = ''; Kind = [IO.Path]::GetExtension($file).TrimStart('.') }
                continue
            }
            $framework = $xml.SelectSingleNode("//*[local-name()='TargetFrameworkVersion' or local-name()='TargetFramework']")
            $assembly = $xml.SelectSingleNode("//*[local-name()='AssemblyName']")
            $projects += [pscustomobject]@{
                Repository = $repository.Name
                Project = $file
                Framework = if ($framework) { $framework.InnerText } else { '' }
                Assembly = if ($assembly) { $assembly.InnerText } else { '' }
                SdkStyle = $xml.DocumentElement.HasAttribute('Sdk')
                Kind = [IO.Path]::GetExtension($file).TrimStart('.')
            }
            $centralPackageVersions = @{}
            $searchDirectory = Split-Path $path -Parent
            while ($searchDirectory.StartsWith($repository.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                $centralPackagesPath = Join-Path $searchDirectory 'Directory.Packages.props'
                if (Test-Path -LiteralPath $centralPackagesPath) {
                    [xml]$centralPackagesXml = Get-Content -LiteralPath $centralPackagesPath -Raw
                    $manageVersions = $centralPackagesXml.SelectSingleNode("//*[local-name()='ManagePackageVersionsCentrally']")
                    if ($manageVersions -and $manageVersions.InnerText.Trim() -eq 'true') {
                        foreach ($centralPackage in $centralPackagesXml.SelectNodes("//*[local-name()='PackageVersion']")) {
                            $packageId = $centralPackage.GetAttribute('Include')
                            if (-not $packageId) { $packageId = $centralPackage.GetAttribute('Update') }
                            $versionNode = $centralPackage.SelectSingleNode("*[local-name()='Version']")
                            $version = if ($versionNode) { $versionNode.InnerText } else { $centralPackage.GetAttribute('Version') }
                            if ($packageId -and $version) { $centralPackageVersions[$packageId] = $version }
                        }
                    }
                    break
                }
                if ($searchDirectory.Equals($repository.FullName, [StringComparison]::OrdinalIgnoreCase)) { break }
                $searchDirectory = Split-Path $searchDirectory -Parent
            }
            foreach ($package in $xml.SelectNodes("//*[local-name()='PackageReference']")) {
                $versionOverrideNode = $package.SelectSingleNode("*[local-name()='VersionOverride']")
                $versionNode = $package.SelectSingleNode("*[local-name()='Version']")
                $packageId = $package.GetAttribute('Include')
                if (-not $packageId) { $packageId = $package.GetAttribute('Update') }
                $version = if ($versionOverrideNode) { $versionOverrideNode.InnerText } elseif ($versionNode) { $versionNode.InnerText } else { $package.GetAttribute('Version') }
                if (-not $version -and $packageId -and $centralPackageVersions.ContainsKey($packageId)) { $version = $centralPackageVersions[$packageId] }
                $packages += [pscustomobject]@{
                    Repository = $repository.Name
                    Manifest = $file
                    Kind = 'PackageReference'
                    Id = $packageId
                    Version = $version
                    Framework = if ($framework) { $framework.InnerText } else { '' }
                }
            }
            foreach ($node in $xml.SelectNodes("//*[local-name()='Reference' or local-name()='ProjectReference' or local-name()='COMReference']")) {
                $hint = $node.SelectSingleNode("*[local-name()='HintPath']")
                $relative = if ($node.LocalName -eq 'ProjectReference') { $node.GetAttribute('Include') } elseif ($hint) { $hint.InnerText } else { '' }
                $resolved = if ($relative -and $relative -notmatch '\$\(') { [IO.Path]::GetFullPath((Join-Path (Split-Path $path -Parent) $relative)) } else { '' }
                $references += [pscustomobject]@{
                    Repository = $repository.Name
                    Project = $file
                    Kind = $node.LocalName
                    Name = $node.GetAttribute('Include')
                    HintPath = $relative
                    Exists = if ($resolved) { Test-Path -LiteralPath $resolved } else { '' }
                    OutsideRepository = if ($resolved) { -not $resolved.StartsWith($repository.FullName + '\', [StringComparison]::OrdinalIgnoreCase) } else { '' }
                }
            }
        } elseif ($file -match '(^|/)packages\.config$') {
            $packageCount++
            [xml]$xml = Get-Content -LiteralPath $path -Raw
            foreach ($package in $xml.packages.package) {
                $packages += [pscustomobject]@{
                    Repository = $repository.Name
                    Manifest = $file
                    Kind = 'packages.config'
                    Id = $package.id
                    Version = $package.version
                    Framework = $package.targetFramework
                }
            }
        } elseif ($file -match '\.sln$') {
            foreach ($line in Get-Content -LiteralPath $path) {
                if ($line -match '^Project\("[^"]+"\) = "([^"]+)", "([^"]+\.(?:csproj|vbproj|sqlproj|vdproj|ccproj|pssproj))"') {
                    $name = $Matches[1]
                    $relative = $Matches[2]
                    $solutions += [pscustomobject]@{
                        Repository = $repository.Name
                        Solution = $file
                        Name = $name
                        Project = $relative
                        Exists = Test-Path -LiteralPath (Join-Path (Split-Path $path -Parent) $relative)
                    }
                }
            }
        } elseif ($file -match '\.(cs|vb)$' -and $file -notmatch '(^|/)(packages|bin|obj)/') {
            $sources += [pscustomobject]@{
                Repository = $repository.Name
                File = $file
                Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
        }
    }
    $repositories += [pscustomobject]@{
        Repository = $repository.Name
        Commit = $commit.Split('|')[0]
        CommitDate = $commit.Split('|')[1]
        InventoryFiles = $files.Count
        Projects = $projectCount
        PackageManifests = $packageCount
        TrackedBinaries = $binaryCount
        DirtyEntries = $state.Count
    }
}

$duplicates = @($sources | Group-Object Hash | Where-Object {
    @($_.Group.Repository | Sort-Object -Unique).Count -gt 1
} | ForEach-Object { $_.Group })

$repositories | Export-Csv (Join-Path $OutputDirectory 'repositories.csv') -NoTypeInformation
$projects | Export-Csv (Join-Path $OutputDirectory 'projects.csv') -NoTypeInformation
$packages | Export-Csv (Join-Path $OutputDirectory 'packages.csv') -NoTypeInformation
$references | Export-Csv (Join-Path $OutputDirectory 'references.csv') -NoTypeInformation
$solutions | Export-Csv (Join-Path $OutputDirectory 'solutions.csv') -NoTypeInformation
$duplicates | Export-Csv (Join-Path $OutputDirectory 'duplicate-sources.csv') -NoTypeInformation
$inventoryErrors | Export-Csv (Join-Path $OutputDirectory 'inventory-errors.csv') -NoTypeInformation
$repositories | Format-Table -AutoSize
Write-Output "Projects: $($projects.Count); package entries: $($packages.Count); cross-repository identical source groups: $(@($duplicates | Group-Object Hash).Count)"
Write-Output "Inventory written to $OutputDirectory"
if ($inventoryErrors.Count) { Write-Warning "$($inventoryErrors.Count) invalid project files recorded in inventory-errors.csv." }
