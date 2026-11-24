# Building the Epi Info workspace

## Scope

These are **compilation/restore baselines**, not certified deployment packages or passing end-to-end tests. Existing checked-in vendor/application binaries still participate in some legacy references. A fully source-only, clean-agent build remains a modernization milestone.

The workspace repository is checked out next to the six independent product repositories and tracks only shared tooling and documentation. Its scripts find the products in the workspace's parent directory (override with `-Root`). Build scripts do not commit changes, install SQL Server, run database scripts or publish anything. The separately invoked Survey API database probe publishes a DACPAC only to its own newly created LocalDB instance.

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
.\eng\Invoke-SurveyApiTestBaseline.ps1
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
| Survey API | Passed | Targets .NET Framework 4.8; EPPlus still uses a local bin assembly. Isolated IIS Express tests exercised Razor and an HTTPS response submission backed by LocalDB. Production hosting and other response workflows remain unvalidated |
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

The broader Desktop unit baseline runs those four numerical methods plus 23 check-code and form-metadata tests and three MongoDB date tests:

```powershell
.\eng\Invoke-DesktopUnitBaseline.ps1
```

The check-code tests parse documented Epi Info 7 User Guide (chapter 13) examples and every check-code block in the checked-in templates with the compiled Enter grammar, assert grammar-grounded rejections, and run documented examples (arithmetic precedence, BMI, concatenation, IF/ELSE with HIDE/UNHIDE, CLEAR/GOTO, DEFINE) through the real Enter interpreter with a recording host. The form-metadata tests compare a new project document with the checked-in XML `.prj` samples and check that the checked-in templates satisfy the MakeView template loader. The MongoDB date tests read in-memory BSON documents through the `Epi.Data.MongoDB` wrapper in fixed time zones, so they need no server and still detect the date shift on a UTC machine. They also pin the cross-zone behavior: a US Eastern midnight read in US Pacific is 21:00 the previous day. These tests need no Jet/ACE, UI, MongoDB server or machine configuration. The runner fails on zero discovery, any failure, a missing numerical test, or a selected class with no tests. Date-literal check code (locale-dependent), GLOBAL/PERMANENT variables (machine configuration) and full `.prj` loads (Jet metadata) are not covered.

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

`Epi.Web.Test` uses NuGet NUnit 5.0.0 and NUnit3TestAdapter 6.3.1 instead of an absent machine-installed NUnit 2, with hand-written fakes for the current `ISurveyFacade` and HTTP context. Its 151 tests characterize controller behavior, form rendering and response JSON, display-mode selection and static layout asset references, and cover deployment key material, the admin key, key rotation and fail-closed WCF service authentication (49 security tests; see [Web key material](#web-key-material)). Display-mode registration was extracted without changing its order or behavior. The obsolete `SurveyController.Notify` test was rewritten rather than restoring the removed action. The runner fails on zero discovery, a change from 151 tests, or any failure. Excluded and recorded: database and hosted service paths, email, the built-in mobile mode with a browser override, and hosted Razor/browser behavior. The asset tests inspect source rather than executing Razor or JavaScript; see [the browser inventory](WEB-SURVEY-BROWSER-ASSETS.md) for remaining gates. `Epi.Web.Test` is not part of the solution, so the solution build does not compile it.

The Web Enter MVC unit tests also run on .NET Framework 4.8:

```powershell
.\eng\Invoke-WebEnterTestBaseline.ps1 -IncludeSolutionBuild
```

`-IncludeSolutionBuild` first rebuilds `Epi Info Web Enter.sln` in Release as a build baseline; omit it to build only the test project and its project references. `-WebEnterDirectory` selects a checkout other than the sibling `Epi-Info-Web-Enter`, and `-ArtifactsDirectory` (default `artifacts`) relocates all output. Packages restore from nuget.org into the checkout's ignored `packages` folder. Binaries go to `artifacts\bin\WebEnter\` and `artifacts\bin\WebEnterTests\`; [IsolatedIntermediates.targets](eng/IsolatedIntermediates.targets) redirects every project's `obj\` to `artifacts\obj\`, so the source checkout receives no build output. Logs, the TRX and a JSON result (including the exclusion list) go to `artifacts\tests\WebEnter\`.

Like Web Survey, `Epi.Web.Test` uses NuGet NUnit 5.0.0 and NUnit3TestAdapter 6.3.1 with hand-written fakes for `ISurveyFacade` and the HTTP context, uses synthetic data only, and is not part of the solution. Its 141 tests include 79 that characterize current behavior of the Home controller (landing page and organization selection, response listing with saved sort/search, delete, unlock and concurrency checks), the Final, Report, Response, Post (`UnescapeCodes`) and ViewSwitcher controllers, `SurveyHelper` (mobile detection, GUID/passcode helpers, response XML merging and user-id encryption), and `FormProvider` desktop/mobile form building, validation and HTML. Another 62 tests cover deployment key material, the admin key, the password salt and its sign-in migration, the key rotation tool and data-service authentication (see [Web key material](#web-key-material)). The two obsolete tests for removed Home actions were deleted rather than restoring those actions. The runner fails on zero discovery, a change from 141 tests, or any failure, and lists each failed test with its message. Excluded and recorded:

- `Epi.Web.SurveyManager.Test` (SQL data layer; separate stale project outside the solution).
- Survey-service (WCF) and check-code paths: Home POST `Index`/`Edit` and `GetSettings`/`SaveSettings`, `SurveyController`, `FormResponseController`, Final POST and `EIWSTController`.
- Service, Active Directory and OIDC sign-in: `AdminOrganizationController`, `AdminUserController` and `LoginController`.
- SMTP: the Home, EIWST and Post `Notify` actions.
- `FormsAuthentication` paths that need an IIS-hosted request: all LogOut/SignOut actions and the invalid-user-id branch of `SurveyHelper.GetDecryptUserId`.
- `Epi.Web.SurveyManager.Client` (interactive WCF client) and `Global.asax` Unity/WCF startup.

The suite records current behavior, including the `Erorr` token returned by a failed response unlock. Known product issues not covered: `PostController.UnescapeCodes` passes a position where `Substring` expects a length, corrupting input with two or more escapes; the solution's Newtonsoft.Json 6.0.6 reports advisory NU1903.

Survey API now has a focused NUnit baseline:

```powershell
.\eng\Invoke-SurveyApiTestBaseline.ps1
```

The 15 tests cover API-key format and matching, HTTPS enforcement, missing/malformed credentials, and the authenticated `SurveyId` requirement. They use only synthetic keys and local `HttpMessageHandler` requests. MVC, Razor, and WebPages resolve consistently from the declared NuGet packages. Survey API and its console client use Newtonsoft.Json 13.0.4; the API uses Microsoft.Owin 4.2.3, ASP.NET Identity 2.2.4, Bootstrap 3.4.1, jQuery 3.7.1, and jQuery Validation 1.21.0 to replace versions flagged by NuGet advisories. The latest restore reports no NU190x advisories for this solution. The API targets .NET Framework 4.8 and uses CodeDom 4.1.0. An earlier one-off IIS Express/browser smoke test with synthetic keys rendered the Home Page, loaded jQuery 3.7.1 and Bootstrap, and confirmed the jQuery Validation required rule rejects an empty value; this UI check is not covered by the reusable hosted API runner below. One Application Insights telemetry request returned HTTP 400; telemetry configuration was outside this test and is not covered by the runner.

The database probe requires Windows PowerShell, SQL Server LocalDB, Visual Studio's SqlPackage, and Release builds of SurveyApi and Database:

```powershell
.\eng\Invoke-Build.ps1 -Repository @('SurveyApi','Database') -Configuration Release -SkipRestore -Rebuild
.\eng\Invoke-SurveyApiDatabaseProbe.ps1
# To retain a new, isolated synthetic database for inspection:
.\eng\Invoke-SurveyApiDatabaseProbe.ps1 -KeepDatabase
```

Each run creates a uniquely named LocalDB instance and deploys the complete Database project's DACPAC, with generated synthetic keys and rows. It tests repository lookup and organization-key decryption, authenticated handler lookup and rejection, missing surveys, surfaced data and database connection errors, Entity Framework response insert/read/update, and a synthetic answer sent through the real in-process Web API routing/controller/DAO pipeline. It does not host IIS or exercise OAuth. By default the probe drops only its own database and removes its own instance; `-KeepDatabase` retains both after success and prints their names and the synthetic configuration location. Connect using Windows authentication and the printed `(localdb)\...` server and database names. No existing instance or database is reused. Logs and synthetic configuration are under `artifacts\tests\SurveyApiDatabase`; never use these generated keys in production.

To repeat the hosted check, first retain a synthetic database with `Invoke-SurveyApiDatabaseProbe.ps1 -KeepDatabase`, then pass the 12-character suffix printed in its LocalDB names and configuration directory, plus the thumbprint of the localhost certificate already bound to the HTTPS port:

```powershell
$testId = '<12-character ID printed by the database probe>'
.\eng\Invoke-SurveyApiHostedOAuthProbe.ps1 `
    -Server "(localdb)\EpiSurveyApiTest_$testId" `
    -Database "EpiSurveyApiSynthetic_$testId" `
    -ProbeConfigPath ".\artifacts\tests\SurveyApiDatabase\$testId\SurveyApiDatabaseProbe.exe.config" `
    -CertificateThumbprint '<40-character certificate thumbprint>'
```

The hosted runner requires Windows PowerShell, IIS Express, Visual Studio's C# compiler, a Release Survey API build, and the existing localhost HTTPS certificate binding (port 44300 by default); it does not change machine-level HTTPS bindings. It accepted a synthetic HTTPS response with HTTP 201 and persisted the answer, and rejected HTTP API requests, an incorrect API key, and an unknown survey. The OAuth token endpoint rejected HTTP and an unauthorized client; with an explicitly configured, isolated `DefaultConnection` and a synthetic Identity user, its password grant issued a bearer token over HTTPS and rejected an incorrect password with `invalid_grant`. A temporary protected Web API probe confirmed that the issued token authenticates through the host's bearer middleware. The runner removes its temporary Identity database and hosted site, but leaves the retained synthetic API database for inspection. The checked-in host configuration does not define `DefaultConnection`, although `ApplicationDbContext` uses that name, so production Identity database configuration remains unverified. Account-management actions in `AccountController` are commented out; the synthetic user was seeded directly, and no production account endpoint was exercised. Telemetry assemblies were excluded from the temporary site. No production IIS configuration or external services were exercised.

The Desktop MongoDB round-trip is opt-in and requires an **authorized, disposable** server:

```powershell
.\eng\Invoke-DesktopMongoRoundTrip.ps1 -BuildOnly
.\eng\Invoke-DesktopMongoRoundTrip.ps1 -ConnectionString '<uri>' -ConfirmDisposableServer
# Or start a throwaway local container, run the probe and remove the container:
.\eng\Invoke-DisposableMongoRoundTrip.ps1 -Image mongo:8.0 [-DesktopBinDirectory <app folder>]
```

The probe runs as x86 under the `EpiInfo.exe.config` binding redirects and checks the MongoDB.Driver/Bson 3.14.1, Snappier 1.3.1, SharpCompress 0.48.1 and ZstdSharp 0.7.3 runtime versions. It has no default server, passes the URI via a process-only environment variable, redacts credentials, creates only an `epiinfo_roundtrip_<guid>` database, refuses an existing name and drops only that database. It round-trips synthetic documents with no compression, snappy, zlib and zstd, treats compression as proven only when the server's compression counters increase, and exercises the `Epi.Data.MongoDB` adapter. Results go to `artifacts\tests\DesktopMongo\`.

`Invoke-DisposableMongoRoundTrip.ps1` requires a running Docker engine. It starts the image with authentication and all three network compressors enabled, tmpfs data directories, a loopback-only port and a generated password passed only through the process environment. It fails unless an unauthenticated command is rejected, and it always removes the container. For Community Edition `5c159148`, the extracted MSI layout passed every check except the then-known date shift against MongoDB 4.4.30, 7.0.48, 8.0.38, 8.2.12 and 9.0.8; an earlier non-MSI run passed against 6.0.28. After the date fix in `673af43f`, the rebuilt Release application folder passed every check, including `adapter.dateTimeRoundTrip`, against 4.4.30, 6.0.28, 7.0.48, 8.0.38, 8.2.12 and 9.0.8. For `bddc9f4f`, the rebuilt Release folder passed every check against 4.4.30, 7.0.48, 8.0.38 and 9.0.8, and the administratively extracted, rebuilt MSI passed against 4.4.30, 8.0.38 and 9.0.8. MongoDB 4.4 is the supported minimum, which is driver 3.14.1's minimum; see [PRIORITIES.md](PRIORITIES.md) for the server policy. Cross-version testing confirmed that legacy subtype-3 and standard subtype-4 GUID data remain readable across driver 2.19 and 3.14.1. An application folder with an adapter that predates the fix still fails `adapter.dateTimeRoundTrip`, and the probe exits non-zero.

The Desktop installer is built separately from `Epi Info 7.sln`, using Microsoft Visual Studio Installer Projects in Visual Studio:

1. Copy a Desktop Release output to the gitignored `Epi-Info-Community-Edition\build\Epi Info 7` folder. Remove a stale `MongoDB.Driver.Core.dll` if an older build left one there.
2. Build a solution that contains only `Setup\Setup.vdproj`: `devenv.com <SetupOnly.sln> /Build "Release|Default"`. The MSI goes to `Setup\Release\Setup\EI7_Setup.msi`.
3. Inspect the payload without installing: `msiexec /a <msi> /qn TARGETDIR=<scratch folder>`.

Community Edition `bddc9f4f` builds this way without scratch-generated files. It excludes the Windows `PortableDeviceApi.dll` and `PortableDeviceTypes.dll` system files that `5c159148` still packaged. Setup reports 65 unique pre-existing warnings, including unresolved EPPlus and System.Net.Http 4.2.0.0 dependencies; the only change from `5c159148`'s 67 is the removal of the two system-file warnings. The extracted payload omits both system files and the stale `MongoDB.Driver.Core.dll`, includes `PortableDevices.dll` and both interop assemblies, and has an empty SelfReg table. Under 32-bit PowerShell, the extracted `PortableDevices.dll` loads, resolves both interop assemblies and reaches the application's "no devices" path through the Windows COM components.

A launch smoke test of that pre-fix MSI started EpiInfo, MakeView, Enter, Analysis, AnalysisDashboard, StatCalc and Mapping one at a time. Each displayed its main window and kept responding until stopped, with no Application Error (1000) or .NET Runtime (1026) events. The EpiInfo launcher's host window has no title, so title-based window detection waits for its timeout even though the tile menu renders. Mapping starts, but its OpenStreetMap base map shows only "Access blocked" tiles; see [PRIORITIES.md](PRIORITIES.md#desktop-runtime-findings). No form, data-entry, analysis or real-device workflow was exercised, and the MSI was not installed or upgraded.

The subsequent OpenStreetMap fix was built and run from the isolated Desktop Release output. Mapping rendered real tiles from the standard HTTPS tile endpoint with the app-identifying User-Agent and visible linked attribution. It cached 48 viewport tiles; a repeat launch used the cache, and forcing one cached tile stale caused an `If-None-Match` request and an HTTP 304 response. This verifies tile loading and cache revalidation, not zone buffering, Dashboard maps, offline use, or a full user workflow. The cache is per-user under `%LOCALAPPDATA%\EpiInfo\OpenStreetMapTiles\v1`; offline prefetch is not supported.

### Remaining test-project triage

| Repository / project | Current classification |
| --- | --- |
| Community Edition `Epi.UnitTests` | Four focused numerical methods, 23 check-code/form-metadata tests and three MongoDB date tests pass. The two means tests have expected-result CSVs but lack `MeansTestData.csv`; matched-logistic input data exists, but its four expected-result CSVs are absent. The missing fixtures were not found in any local ref, reflog or unreachable object, upstream branch/tag/release, the 12 public forks, GitHub code search, other Epi-Info repositories or CDC documentation; see [means evidence issue #1](https://github.com/jarz/Epi-Info-Community-Edition/issues/1) and [matched-logistic evidence issue #2](https://github.com/jarz/Epi-Info-Community-Edition/issues/2). |
| Community Edition `Tests` | `CreateMapImage` depends on a machine-specific `C:\_CODE\...chi.map7` path; not run. |
| Cloud `MetadataTests` | Seventeen local tests pass, including a Service Bus controller test using an injected local fake. Missing-file, live-service, four stale property-count tests, and a DAO test without assertions remain excluded and recorded. |
| Cloud `ResourceTests` | Two local tests pass; initial centrally managed PackageReference pilot. |
| Cloud `CosmosDBTests` | One wildcard-comparison test passes. The separate tree-construction source is not compiled into this project and has no assertions. |
| Cloud `Epi.Cloud.MetadataUnitTests` | Placeholder project; no active assertions to baseline. |
| Cloud `WebJobTest` | Both tests interact with Service Bus and SQL; integration environment/mocks required. |
| Cloud `PublishAndRepublishTest` | One test is empty; the other controls a remote WebJob. Do not run locally. |
| Cloud nested `Epi.Web.UnitTests\Epi.Web.Test` | Copied legacy NUnit MVC tests with stale test doubles and the obsolete `SurveyController.Notify` call; not yet a baseline. |
| Cloud nested `Epi.Web.UnitTests\Epi.Web.SurveyManager.Test` | Publisher/DAO-oriented tests; require a local database-backed contract fixture before execution. |
| Web Survey `Epi.Web.Test` | 151 tests pass on net48 with NuGet NUnit 5; hosted WCF, database, hosted rendering and SMTP paths excluded and recorded. |
| Web Survey `Epi.Web.SurveyManager.Test` | Publisher tests use `EntitySurveyInfoDao`; isolate a local persistence contract before execution. |
| Web Enter `Epi.Web.Test` | 141 tests pass on net48 with NuGet NUnit 5; database, directory/OIDC, IIS and SMTP paths excluded and recorded. |
| Web Enter `Epi.Web.SurveyManager.Test` | Publisher tests use `EntitySurveyInfoDao`; isolate a local persistence contract before execution. |
| Survey API `Epi.Web.SurveyAPI.Tests` | 15 tests pass on net48 with NuGet NUnit 5; the separate LocalDB probe covers database lookup and response DAO writes. The hosted runner also verifies synthetic HTTPS submission, OAuth password-grant issuance, wrong-password rejection, and bearer authentication. Production Identity configuration and account endpoints remain unverified. |

No separate test project was found in the Database repository. External-service and other database tests stay gated until they can run against synthetic data in an authorized environment.

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

### Web key material

Web Survey, Survey API and Web Enter previously shipped one shared set of key material: the connection-string encryption keys, the admin key and Web Enter's password salt. Those values are public in the repositories' history, and Web Enter's admin check accepted any key. The forks now require each deployment to supply its own values in `appSettings`. Each web application and WCF host calls `Cryptography.ValidateConfiguration()` first in `Application_Start` and refuses to start when a value is missing, malformed or publicly known. Web Enter's `Utility.ValidateAdmin` compares the caller's key with the configured `AdminKey` again. The encryption algorithm is unchanged, so data that a deployment encrypted with its own keys still decrypts.

`Epi.Web.KeyRotation` in Web Survey and Web Enter generates a key file. It then rotates each configuration file and the encrypted `dbo.Organization.OrganizationKey` column: it re-encrypts, verifies and keeps a backup. It is a dry run unless `--apply` is given and never prints secret values. It refuses an encrypted connection string or row that neither key set decrypts. When a configuration already holds the new keys, `--database` checks that every row uses them and asks for the previous keys if any does not. Follow [the Web Survey guide](https://github.com/jarz/Epi-Info-Web-Survey/blob/master/Epi.Web.KeyRotation/README.md), which also covers Survey API configuration files, or [the Web Enter guide](https://github.com/jarz/Epi-Info-Web-Enter/blob/master/Epi.Web.KeyRotation/README.md). For Web Enter, the tool moves a publicly known password salt to `LegacyKeyForUserPasswordSalt`; each user is re-hashed with the new salt at their next sign-in. Remove the legacy setting once users have signed in; anyone who has not signed in by then must use "Forgot password".

Web Survey's DataService and ManagerService WCF versions now require a 64-character hexadecimal `DataServiceSharedKey` on every SOAP request and HTTPS transport. Configure the same deployment-specific value in the WCF host, the external-mode web caller and the Survey Manager desktop client's protected configuration; do not commit it. All endpoint URLs must use HTTPS and trusted certificates. The publish-host template leaves the key empty, which denies requests until configured. Web Survey's in-process integrated mode does not use this SOAP credential.

The Web Enter `EWEDataService` WCF endpoint also requires a 64-character hexadecimal `DataServiceSharedKey` on every SOAP request and HTTPS transport. Configure the same deployment-specific value in the `Epi.Web` caller and WCF host's protected configuration; do not commit it. The external-mode `ENDPOINT_USED` URL must use HTTPS. The publish-host template leaves the key empty, which denies requests until configured. The in-process integrated mode does not use this SOAP credential.

Survey API response endpoints now require a separate deployment-specific 64-character hexadecimal `SurveyApiSharedKey` in the `X-Epi-Info-API-Key` header, in addition to the `SurveyId` header, and reject HTTP requests. Its OAuth token endpoint also rejects insecure HTTP. Set the same secret in the API host and every client; the checked-in host and console-client templates leave it blank and therefore reject requests. The only caller found in the repository is the console test client; update any external clients before deployment. The shared API key is an application-level gate, not individual-user authentication, and must not be embedded in distributable clients. The former hardcoded source value is considered compromised and must not be reused.

Generate a key with a cryptographic random-number generator and keep it out of source control:

```powershell
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 32
$rng.GetBytes($bytes)
$surveyApiSharedKey = -join ($bytes | ForEach-Object { $_.ToString('x2') })
$rng.Dispose()
```

Configure it in the API host's protected `Web.config` and the console client's protected `App.config`. Production IIS/API validation remains outstanding.

Validation: 49 Web Survey and 62 Web Enter unit tests, plus LocalDB end-to-end runs of both tools with synthetic keys and rows. Each run covered dry run, apply, row verification, a no-op second run, recovery from a restored backup, catching up a row left under the old keys after a configuration-only rotation, and a scan of the tool output for secrets. The service-auth tests exercise credential validation and client endpoint requirements; hosted IIS/WCF behavior still requires deployment validation. Survey API's 15 focused tests, LocalDB lookup/response DAO probe, and reusable hosted submission/OAuth password-grant/bearer probe pass with synthetic fixtures; production Identity configuration and account endpoints remain unverified. Clients that send the admin key must use the deployment's new `AdminKey` GUID.

Not addressed: tracked configuration files in all three repositories still contain plaintext connection strings with credentials for the original operator's database servers. Only that operator can revoke them; Git history was not rewritten.

### CI proposal

**On hold at the user's request:** do not create or enable CI workflows until the user resumes this work. When resumed, keep CI workflows and release lanes independent in each repository. Shared workflow hosting, permissions, and ownership have not been established, so no remote workflows or deployment jobs are assumed here.

- Use a Windows runner with the documented Visual Studio Build Tools components and workspace-local NuGet/reference-assembly bootstrap.
- Treat `eng\Invoke-Build.ps1` as the canonical workspace build command and run the Desktop unit, Web Survey unit, Web Enter unit and Cloud metadata/resource/Cosmos baselines as separate test steps. Keep the MongoDB round-trip out of standard CI unless a disposable service container is explicitly provisioned. For hosted per-repository CI, pin or host this shared logic only after its location and permissions are agreed.
- Publish restore/build logs, result JSON, TRX files, and build outputs as CI artifacts; fail if selected test discovery is zero or any selected test fails.
- Keep external-service/database tests and the stale Cloud nested NUnit projects excluded until their local test seams and contracts are ready; never invoke publishing or remote WebJob controls in standard CI.
