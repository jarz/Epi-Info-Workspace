# Building the Epi Info workspace

## Scope

These are **compilation/restore baselines**, not certified deployment packages or passing end-to-end tests. Existing checked-in vendor/application binaries still participate in some legacy references. A fully source-only, clean-agent build remains a modernization milestone.

The workspace repository is checked out next to the six independent product repositories and tracks only shared tooling and documentation. Its scripts find the products in the workspace's parent directory (override with `-Root`). The scripts do not commit changes, install SQL Server, run database scripts or publish anything.

## Prerequisites

Use Windows and PowerShell. Modern `dotnet build` alone is insufficient for the legacy ASP.NET/SSDT projects.

With explicit approval, Visual Studio Build Tools **2022 17.14.45** was installed on this machine with:

- `Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools`
- `Microsoft.VisualStudio.Workload.WebBuildTools`
- `Microsoft.Net.Component.4.8.TargetingPack`
- `Microsoft.VisualStudio.Wcf.BuildTools.ComponentGroup`
- `Microsoft.VisualStudio.Component.TestTools.BuildTools`
- `Microsoft.VisualStudio.Component.SQL.SSDTBuildSku`
- `Microsoft.VisualStudio.Component.Azure.Waverton.BuildTools`

The installation completed without a requested reboot. Use the [Microsoft component reference](https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools?view=vs-2022) to reproduce the workload selection. Installation is machine-wide and should be approved on shared hosts.

Bootstrap workspace-local tools:

```powershell
Set-Location C:\ei\Epi-Info-Workspace
.\eng\Initialize-Build.ps1
```

This downloads NuGet CLI **6.14.0** if missing, checks its Microsoft Authenticode signature/version, and restores Microsoft's framework-reference packages **1.0.3** for 4.0, 4.5, 4.5.1, 4.5.2, 4.6 and 4.6.1 beneath `scratch\framework-packages`. The import hook uses the official package targets without installing old runtimes or modifying machine reference directories. An installed 4.8 targeting pack covers the main desktop/survey projects.

## Commands

Build the five application/database solutions without Cloud:

```powershell
.\eng\Invoke-Build.ps1 -Repository Desktop,WebSurvey,WebEnter,SurveyApi,Database
```

Build all six primary solutions:

```powershell
.\eng\Invoke-Build.ps1
```

Targeted validation:

```powershell
.\eng\Invoke-Build.ps1 -Repository WebSurvey,WebEnter -Rebuild
.\eng\Invoke-Build.ps1 -Repository WebSurvey -Configuration Debug
```

The runner finds full-framework MSBuild through vswhere, restores exact existing application package declarations using NuGet v3, disables the obsolete in-build restore, and uses bounded MSBuild parallelism. It records both restore and compile exit codes, continues to inspect other solutions after a failure, and throws if any requested solution fails.

It explicitly sets the standard `Disable_CopyWebApplication=true` property: redirecting OutDir would otherwise also attempt legacy website-content packaging. That packaging was attempted and failed because both web products omit root Web.config and Web Survey also references a missing `PublishReportResponse3.datasource` file. Those failures are retained in [content-packaging logs](artifacts/build/content-packaging/); they are not treated as deployment success. Each new result records `RestoreAndCompilationOnly`.

`-SkipRestore` is only for a previously restored workspace; result JSON explicitly records it. `-OutputDirectory` changes the **log/result** directory, not the binary directory.

Default outputs:

- Logs and per-repository JSON: [artifacts/build](artifacts/build/).
- Isolated compiled outputs: [artifacts/bin](artifacts/bin/), under repository/configuration subdirectories.
- Initial baseline and recovery logs are retained separately from [final Release verification logs](artifacts/build/final/) and [Debug verification logs](artifacts/build/verified-debug/).

SSDT also has its own project output conventions; the database DACPAC can be found beneath the database project's `bin\Release` directory. Building a DACPAC never invokes Publish here.

## Verified matrix

| Primary solution | Release restore / compilation | Qualification |
| --- | --- | --- |
| Desktop | Passed | Installer not selected by normal Release configuration; Silverlight and out-of-solution tests not certified |
| Web Survey | Passed after reference repairs | Root web.config is absent; Razor views/runtime hosting, database and WCF connectivity not validated |
| Web Enter | Passed after reference repairs | Authentication, browser assets, database and service connectivity not validated |
| Survey API | Passed | Still has old compiler packages and bin/cross-checkout dependencies |
| Database | Passed; DACPAC produced | Schema provider is SQL Server 2012; deployment/data migration not validated |
| Cloud Contact Tracing | Passed | Release compilation succeeds with Azure Cloud Services 2.9 build tools installed; no Azure deployment was attempted |

All six Release solutions were rerun together; see the [final verification logs](artifacts/build/final/). The changed Web Survey and Web Enter graphs also passed **Debug Rebuild** with restore, using [Debug verification logs](artifacts/build/verified-debug/). The five application entrypoint assemblies and database DACPAC were checked for existence and nonzero length in their isolated output directories.

Cloud compilation blockers found during recovery are resolved:

- Azure Cloud Services 2.9 targets are now provided by the installed Waverton build-tools component.
- Stale bin-folder references were replaced with source project references, and the MVC 4 / Newtonsoft references now point to declared NuGet packages.
- The packaged `Unity.Mvc3` 1.2 binary expects Unity 2.x and does not provide the `RegisterControllers` extension used by the app. The bootstrapper now registers controllers using the existing Unity 4 convention API and the matching MVC integration package.

No fake Azure targets, missing-service stubs, or success-shaped skips were added. A successful build validates compilation, not a deployable Azure Cloud Services package, hosted service configuration, credentials, or runtime connectivity.

## Tests and operational validation

The focused Desktop numerical baseline restores the Desktop solution and test packages, builds `Epi.UnitTests` against the current source projects, and runs the 5,000-row binomial fixture, 100 2x2 reference tables, 100 linear-regression cases, and 100 logistic-regression cases under MSTest:

```powershell
.\eng\Invoke-DesktopNumericalBaseline.ps1
```

Run `eng\Initialize-Build.ps1` first if the workspace toolchain or private legacy targeting assemblies are not ready. The runner writes timestamped restore/build/VSTest logs, a TRX file, and a JSON summary under `artifacts\tests\Desktop\`. The numerical tests read fixtures directly and do not require the dashboard loader, Jet, or legacy configuration. Existing numeric tolerances are preserved, including the binomial upper-confidence-limit tolerance of one.

The broader Desktop unit baseline runs those four numerical methods plus 23 check-code and form-metadata tests:

```powershell
.\eng\Invoke-DesktopUnitBaseline.ps1
```

The check-code tests parse documented Epi Info 7 User Guide (chapter 13) examples and every check-code block in the checked-in templates with the compiled Enter grammar, assert grammar-grounded rejections, and run documented examples (arithmetic precedence, BMI, concatenation, IF/ELSE with HIDE/UNHIDE, CLEAR/GOTO, DEFINE) through the real Enter interpreter with a recording host. The form-metadata tests compare a new project document with the checked-in XML `.prj` samples and check that the checked-in templates satisfy the MakeView template loader. These tests need no Jet/ACE, UI or machine configuration. The runner fails on zero discovery, any failure, a missing numerical test, or a selected class with no tests. Date-literal check code (locale-dependent), GLOBAL/PERMANENT variables (machine configuration) and full `.prj` loads (Jet metadata) are not covered.

These are focused tests, not certification of the entire legacy test project. Other tests still depend on dashboard/data-loading behavior, Jet and legacy configuration paths. Before shipping, isolate and repair those tests, add synthetic-data integration coverage, and run the complete supported suite. See [the modernization plan](MODERNIZATION.md).

The Cloud metadata test project also has a focused, reproducible subset:

```powershell
.\eng\Invoke-CloudMetadataBaseline.ps1
```

It builds the test project with web packaging disabled and runs 17 metadata/model/controller tests that use local objects and fakes. It explicitly excludes tests requiring absent `C:\junk` JSON fixtures or a live metadata service, four property-count tests whose pinned counts disagree with the current API types, and a DAO test with no active assertions. These exclusions are recorded in the JSON result; the subset is not a claim that the full Cloud test project passes.

The Cloud resource tests run independently:

```powershell
.\eng\Invoke-CloudResourceBaseline.ps1
```

This verifies both the direct resource-manager lookup and the product resource-provider lookup.
`ResourceTests` is the first packages.config-to-PackageReference migration and keeps its two MSTest versions unchanged in `Cloud Enter\Directory.Packages.props`. In Community Edition, the existing `Epi.Data.EpiWeb` Newtonsoft.Json PackageReference is also centrally versioned, with its version unchanged at 13.0.2 in the repository-level `Directory.Packages.props`. Both projects restored and built; the Desktop numerical baseline passed 4/4 after its centralization.

The Cloud Cosmos project has a local wildcard-comparison test that can be run without a Cosmos account:

```powershell
.\eng\Invoke-CloudCosmosBaseline.ps1
```

It intentionally runs only the one test compiled into that project. The separate Cloud WebJob tests call Service Bus and SQL, and the publish/republish test controls a remote WebJob; those integration tests were not run.

The Web Survey MVC unit tests now run on .NET Framework 4.8:

```powershell
.\eng\Invoke-WebSurveyTestBaseline.ps1
```

`Epi.Web.Test` uses NuGet NUnit 5.0.0 and NUnit3TestAdapter 6.3.1 instead of an absent machine-installed NUnit 2, with hand-written fakes for the current `ISurveyFacade` and HTTP context. Its 56 tests characterize current Home/Final/Survey/ViewSwitcher controller behavior, mobile user-agent detection, the browser-override cookie, form rendering (including server-emitted jQuery Mobile and validationEngine markup), validation, and response JSON. The obsolete `SurveyController.Notify` test was rewritten rather than restoring the removed action. The runner fails on zero discovery, a change from 56 tests, or any failure. Excluded and recorded: `Epi.Web.SurveyManager.Test` (database), response creation/save and check-code success paths (survey service), `Global.asax` display-mode registration (inline in `Application_Start`; extracting a method would be a reviewed production change), and email notification. `Epi.Web.Test` is not part of the solution, so the solution build does not compile it.

The Desktop MongoDB round-trip is opt-in and requires an **authorized, disposable** server:

```powershell
.\eng\Invoke-DesktopMongoRoundTrip.ps1 -BuildOnly
.\eng\Invoke-DesktopMongoRoundTrip.ps1 -ConnectionString '<uri>' -ConfirmDisposableServer
```

The probe runs as x86 under the `EpiInfo.exe.config` binding redirects. It has no default server, passes the URI via a process-only environment variable, redacts credentials, creates only an `epiinfo_roundtrip_<guid>` database, refuses an existing name and drops only that database. It round-trips synthetic documents with no compression, snappy, zlib and zstd, treats compression as proven only when the server's compression counters increase, and exercises the `Epi.Data.MongoDB` adapter. Results go to `artifacts\tests\DesktopMongo\`. The evidence run used a local Docker `mongo:6.0` container (server 6.0.28) bound to 127.0.0.1 with no volume and `--networkMessageCompressors=snappy,zstd,zlib`; see [PRIORITIES.md](PRIORITIES.md) for its two product findings.

### Remaining test-project triage

| Repository / project | Current classification |
| --- | --- |
| Community Edition `Epi.UnitTests` | Four focused numerical methods and 23 check-code/form-metadata tests pass. The two means tests have expected-result CSVs but lack `MeansTestData.csv`; matched-logistic input data exists, but its four expected-result CSVs are absent. The missing fixtures were not found in any local ref, reflog or unreachable object, upstream branch/tag/release, the 12 public forks, GitHub code search, other Epi-Info repositories or CDC documentation; see [means evidence issue #1](https://github.com/jarz/Epi-Info-Community-Edition/issues/1) and [matched-logistic evidence issue #2](https://github.com/jarz/Epi-Info-Community-Edition/issues/2). |
| Community Edition `Tests` | `CreateMapImage` depends on a machine-specific `C:\_CODE\...chi.map7` path; not run. |
| Cloud `MetadataTests` | Seventeen local tests pass, including a Service Bus controller test using an injected local fake. Missing-file, live-service, four stale property-count tests, and a DAO test without assertions remain excluded and recorded. |
| Cloud `ResourceTests` | Two local tests pass; initial centrally managed PackageReference pilot. |
| Cloud `CosmosDBTests` | One wildcard-comparison test passes. The separate tree-construction source is not compiled into this project and has no assertions. |
| Cloud `Epi.Cloud.MetadataUnitTests` | Placeholder project; no active assertions to baseline. |
| Cloud `WebJobTest` | Both tests interact with Service Bus and SQL; integration environment/mocks required. |
| Cloud `PublishAndRepublishTest` | One test is empty; the other controls a remote WebJob. Do not run locally. |
| Cloud nested `Epi.Web.UnitTests\Epi.Web.Test` | Copied legacy NUnit MVC tests with stale test doubles and the obsolete `SurveyController.Notify` call; not yet a baseline. |
| Cloud nested `Epi.Web.UnitTests\Epi.Web.SurveyManager.Test` | Publisher/DAO-oriented tests; require a local database-backed contract fixture before execution. |
| Web Survey `Epi.Web.Test` | 56 tests pass on net48 with NuGet NUnit 5; service, database, IIS and SMTP paths excluded and recorded. |
| Web Survey `Epi.Web.SurveyManager.Test` | Publisher tests use `EntitySurveyInfoDao`; isolate a local persistence contract before execution. |
| Web Enter `Epi.Web.Test` | Copied NUnit MVC suite has the same legacy target/dependency and mock drift; contains an obsolete controller-action call. |
| Web Enter `Epi.Web.SurveyManager.Test` | Publisher tests use `EntitySurveyInfoDao`; isolate a local persistence contract before execution. |

No separate test projects were found in the Survey API or Database repositories. External-service and database tests stay gated until they can run against synthetic data in an authorized environment.

### Cloud property-count drift

Four excluded tests compare only `GetProperties().Count()`, not property names, types, or serialized payloads:

| Tested type | Expected / current properties | Observed role |
| --- | ---: | --- |
| [OrganizationDTO](<https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing/blob/master/Cloud Enter/Epi.Cloud.Common/DTO/OrganizationDTO.cs>) | 4 / 5 | Organization data is carried in [OrganizationResponse](<https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing/blob/master/Cloud Enter/Epi.Cloud.Common/Message.WebEnter/OrganizationResponse.cs>). |
| [OrgAdminInfoModel](<https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing/blob/master/Cloud Enter/Epi.Cloud.MVC.Common/Models/OrgAdminInfoModel.cs>) | 8 / 9 | MVC organization form model, used for view rendering and POST binding; not established as a public JSON contract. |
| [SurveyAnswerDTO](<https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing/blob/master/Cloud Enter/Epi.Common.Core/DTO/SurveyAnswerDTO.cs>) | 35 / 51 | A request/response data object that wraps `ResponseDetail` and exposes aliases such as `SurveyId`/`FormId`. |
| [SurveyResponseBO](<https://github.com/jarz/Epi-Info-Cloud-Contact-Tracing/blob/master/Cloud Enter/Epi.DataPersistence/Epi.DataPersistence.Common/BusinessObjects/SurveyResponseBO.cs>) | 29 / 43 | Business object used in the data-entry/persistence path and mapped to/from `SurveyAnswerDTO`; direct external serialization is not established. |

A same-count rename would pass these tests, while a harmless extra internal property could fail them. A serializer may also include fields or apply settings and attributes that reflection counts do not represent. Some production model files changed after the old tests, suggesting staleness but not proving the intended compatibility contract.

Before changing the expectations or model members, identify actual consumers and serializers, obtain approved historical or synthetic/redacted payloads, and define the required names, types, nesting, defaults, and compatibility policy. Add serialization, form-binding, and mapping tests at the boundaries actually used. Do not copy real survey data into tests or assume every one of these models crosses a network boundary.

The build runner redirects final assembly output away from tracked application bin folders. Some legacy targets still write intermediates inside their project directories, and some repositories track those intermediates. Inspect Git status after building; do not commit generated DLL/PDB/cache diffs as source changes.

### CI proposal

**On hold at the user's request:** do not create or enable CI workflows until the user resumes this work. When resumed, keep CI workflows and release lanes independent in each repository. Shared workflow hosting, permissions, and ownership have not been established, so no remote workflows or deployment jobs are assumed here.

- Use a Windows runner with the documented Visual Studio Build Tools components and workspace-local NuGet/reference-assembly bootstrap.
- Treat `eng\Invoke-Build.ps1` as the canonical workspace build command and run the Desktop unit, Web Survey unit and Cloud metadata/resource/Cosmos baselines as separate test steps. Keep the MongoDB round-trip out of standard CI unless a disposable service container is explicitly provisioned. For hosted per-repository CI, pin or host this shared logic only after its location and permissions are agreed.
- Publish restore/build logs, result JSON, TRX files, and build outputs as CI artifacts; fail if selected test discovery is zero or any selected test fails.
- Keep the stale Web Enter NUnit project and external-service/database tests excluded until their local test seams and contracts are ready; never invoke publishing or remote WebJob controls in standard CI.
