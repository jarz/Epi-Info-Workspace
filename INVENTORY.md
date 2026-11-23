# Epi Info workspace inventory

Snapshot: 2026-11-21. This is an inventory of the six local checkouts, not a claim about the latest upstream state. All six working trees were clean before this investigation. The workspace repository tracks shared tooling and documentation, not the six independent product checkouts.

## Repositories

| Repository | Responsibility | Local HEAD / date | Project files | Main technologies |
| --- | --- | --- | ---: | --- |
| [Community Edition](https://github.com/jarz/Epi-Info-Community-Edition) | Windows form designer, data entry, analysis, statistics, mapping, database adapters | `4cd353c6`, 2025-04-09 | 46 | C#, VB, WinForms, WPF; mostly .NET Framework 4.8; ADODB; native SQLite; legacy chart/map controls |
| [Web Survey](https://github.com/jarz/Epi-Info-Web-Survey) | Anonymous survey publishing and response collection | `8e8f74c8`, 2024-11-29 | 13 | .NET Framework 4.8 production projects; ASP.NET MVC 4, WCF, EF 5, jQuery Mobile |
| [Web Enter](https://github.com/jarz/Epi-Info-Web-Enter) | Authenticated, organizational web data capture | `261aafab`, 2021-04-13 | 12 | Mostly .NET Framework 4.5.1; MVC, WCF, EF 5; pre-release ASP.NET authentication dependencies |
| [Survey API](https://github.com/jarz/Epi-Info-Survey-API) | Survey API and console client | `289b065`, 2018-11-19 | 2 | .NET Framework 4.5/4.5.2; MVC/Web API, EF 6, Unity, old Roslyn/CodeDOM packages |
| [Cloud Contact Tracing](https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing) | Azure-oriented contact tracing/data capture, metadata, persistence and workers | `580aee0`, 2018-08-13 | 57 | Mostly .NET Framework 4.5.2; MVC/WCF; DocumentDB/Cosmos, Redis, Service Bus, WebJobs; Azure Cloud Services 2.9 |
| [Database Web](https://github.com/jarz/Epi-Info-Database-Web) | Shared SQL schema for web/cloud products | `bdfe8ae`, 2017-10-30 | 1 | SSDT SQL project; SQL Server 2012 schema provider |

There are **131 project files**: 125 C# projects, one VB project, one SQL project, two Azure cloud projects, one PowerShell project and one installer project. One C# project is malformed. There are seven solutions, including the Cloud compatibility sub-solution. Project-file counts include projects outside the primary solutions.

None of the projects use SDK-style project format. The Cloud `ResourceTests` project is the initial packages.config-to-PackageReference migration and centrally retains both MSTest versions. In Community Edition, the existing Newtonsoft.Json `PackageReference` in [Epi.Data.EpiWeb](https://github.com/jarz/Epi-Info-Community-Edition/blob/master/Epi.Data.EpiWeb/Epi.Data.EpiWeb.csproj) is centrally managed at its unchanged 13.0.2 version. Neither pilot changes a runtime package version; SDK-style conversion is not a prerequisite for Central Package Management.

## Dependency evidence

- After the build repairs and package-management pilots: **57 packages.config manifests** with **518 entries**, plus **three PackageReference declarations** (two MSTest dependencies in Cloud ResourceTests and Newtonsoft.Json in Community Edition's Epi.Data.EpiWeb), for **521 package declarations** total. All three PackageReferences are centrally versioned across the two repositories; declarations span **169 package IDs** and are not a runtime SBOM.
- Tracked `.dll`, `.exe` and `.nupkg` files at baseline: Desktop 109, Web Survey 114, Web Enter 32, Survey API 245, Cloud 9, Database 0.
- **374 byte-identical cross-repository source groups**, comprising **900 source-file instances**. This excludes package/build folders and proves duplication, not behavioral equivalence between all clones.
- **16 missing ProjectReference paths** in the snapshot, mostly Cloud compatibility/test projects and the old DocumentDB project name.
- Assemblies such as `Epi.Web.BLL`, `Epi.Web.EF`, `Epi.Web.DynamicForms`, `Epi.Web.MVC` and `EpiInfo.Plugin` are independently defined in multiple repositories. Do not merge projects by assembly name alone.
- Framework targets range from 4.0 through 4.8, plus Silverlight 5. The `v5.0` project is **Silverlight**, not modern .NET 5.
- Desktop has a Visual Studio installer `.vdproj`. The normal Release solution does **not** build it. Cloud also has a `.pssproj` with an empty Build target; success there would not validate deployment.
- [Epi.Web_Bad.csproj](https://github.com/jarz/Epi-Info-Web-Survey/blob/master/Epi.Web/Epi.Web_Bad.csproj) contains invalid XML. It is not in the primary solution and was recorded, not silently ignored or deleted.

### Representative version drift

| Family | Declared versions / issue |
| --- | --- |
| Newtonsoft.Json | 6.0.4, 6.0.6, 6.0.8, 8.0.3, 9.0.1, 11.0.2, 13.0.1, 13.0.2, 13.0.3 |
| EntityFramework | 5.0.0-rc, 5.0.0, 6.1.3, 6.4.4 |
| MVC / Razor / WebPages | Mixed MVC 4/5 and Razor/WebPages 2/3; some references point to application bin folders or another developer's checkout |
| Unity | 2.1.505.0, 2.1.505.2, 4.0.1, 5.8.1; namespace/API changes prevent blind alignment |
| Browser libraries | jQuery 1.x/2.x/3.x, Bootstrap 3.x, old jQuery UI/Mobile/validation; managed through NuGet/copied assets, not package.json |
| Azure clients | Legacy WindowsAzure.Storage, DocumentDB, WindowsAzure.ServiceBus, Redis and WebJobs packages |
| Test infrastructure | NUnit 2, legacy Visual Studio MSTest and MSTest 1.1.18; several tests excluded from production solutions |

Manifest versions do not necessarily match loaded assets. For example, Web Survey declares jQuery 3.5.0, but [BundleConfig](https://github.com/jarz/Epi-Info-Web-Survey/blob/master/Epi.Web/App_Start/BundleConfig.cs) selects `jquery-1.*`. NuGet restore does not rewrite these bundles or install-script-managed browser assets.

Restore reported dependency advisories, including high severity for [Snappier 1.0.0](https://github.com/advisories/GHSA-pggp-6c3x-2xmx) and moderate severity for [SharpCompress 0.32.2](https://github.com/advisories/GHSA-6c8g-7p36-r338), plus numerous old browser/Azure/JSON dependencies. These are package-feed warnings, not an application exploitability assessment.

## Build status and limits

See [BUILDING.md](BUILDING.md) for commands, outputs and the verified build matrix.

The changes restore build plumbing; they do not upgrade the application stack. In particular:

- Web Survey now explicitly restores its Common project's existing EPPlus and JSON dependencies and builds BLL/WCF against the current interfaces source.
- Web Enter now builds DynamicForms against its check-code source and the web application against its Common source. Two Debug output paths no longer traverse outside the checkout.
- Cloud now compiles with explicit source/package references, the installed Azure Cloud Services 2.9 targets and a Unity 4-compatible MVC registration API. This does not establish that the legacy hosted service remains deployable.
- Legacy targeting assemblies are restored privately from Microsoft packages. No obsolete framework runtimes were installed.
- Survey API now ignores newly generated bin/obj files; already tracked binaries remain tracked.
- No database was created, connected to, altered or deployed. No application or Azure resource was deployed.
- Isolated website-content packaging was also attempted and failed on missing Web.config/datasource content. The final runner explicitly validates compilation only, not packaging.

## Machine-readable inventory

Run:

```powershell
.\eng\Get-Inventory.ps1
```

The [inventory directory](artifacts/inventory/) contains:

- `repositories.csv`: local HEAD, counts and working-tree state.
- `projects.csv`: project kind, framework, assembly name and SDK-style status.
- `packages.csv`: package declarations, including PackageReference.
- `references.csv`: assembly/project references, hint-path existence and paths outside each repository.
- `solutions.csv`: declared solution membership and file existence.
- `duplicate-sources.csv`: cross-repository SHA-256-identical source files.
- `inventory-errors.csv`: malformed project XML.

The script includes tracked files and non-ignored untracked files, so new manifests are visible before commit. Framework/GAC references without a HintPath have unknown disk-path status, not a claimed failure. Missing hint paths are evidence to investigate: GAC, registry, transitively copied or checked-in binaries can sometimes still satisfy them.
