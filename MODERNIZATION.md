# Epi Info dependency and repository modernization plan

As of 2026-11-22. Based on the [local inventory](INVENTORY.md), actual build attempts and Microsoft/NuGet metadata.

## Recommendation

**Retain the six independent repositories and standardize dependency governance and CI across them.** The workspace-level inventory/build/test scripts provide a shared engineering layer without merging Git histories or release boundaries. Central package management is scoped to eligible PackageReference projects inside each repository; shared code should be published as independently versioned packages only after compatibility is proven.

Do not force all 131 projects into one build graph or deployment. Keep product solutions and release/version policies independent, and avoid consolidating same-named assemblies while cloned implementations coexist. Use reusable workflows only when their hosting and permissions are explicit; otherwise keep repository-specific workflows calling the same validated build/test conventions.

A monorepo is not the selected strategy. The workspace repository tracks shared tooling and documentation only; the six product repositories are separate sibling checkouts that keep their own histories and release boundaries. Reconsider a monorepo only if product owners later agree on ownership, release policies, and a history-preserving migration.

**CI is on hold at the user's request.** The steps below describe local work and future gates; do not create or enable hosted workflows until the user resumes CI work.

## Proposed next dependency and framework work

This is a plan, not an instruction to upgrade packages or deploy. Confirm the product owner and active deployments before each product-specific migration.

1. **Establish evidence and owners.** Preserve the 103 passing selected tests (27 Desktop, 56 Web Survey, 20 Cloud) and their explicit exclusions. Recover the means input and independent matched-logistic reference results through [fork issue #1](https://github.com/jarz/Epi-Info-Community-Edition/issues/1) and [fork issue #2](https://github.com/jarz/Epi-Info-Community-Edition/issues/2). For Cloud, identify real consumers, serialization settings, and approved synthetic or redacted contract examples before changing the four property-count tests. Assign an owner to each blocked contract or fixture.
2. **Triage active Cloud dependencies immediately.** The code declares `WindowsAzure.ServiceBus` 3.3.2. Microsoft retired this library and the default SBMP protocol on 2026-09-30; the library can still use AMQP if explicitly configured, but it no longer receives support or updates. The local Service Bus code does not explicitly select a transport; the deployment's connection configuration could override that. Ask the deployment owner to check the active protocol and usage privately, without sharing credentials. For maintained deployments, plan migration to `Azure.Messaging.ServiceBus` and compare message bodies/properties, acknowledgements, retry/idempotency and error behavior with synthetic data in an authorized environment. The local fake is not a service integration test. The repository also declares `Microsoft.Azure.DocumentDB` 1.10.0; assess its supported migration path to the Cosmos DB v3 SDK and preserve query, partition, consistency and serialization behavior. Do not assume a live deployment exists.
3. **Remediate the Desktop MongoDB dependency cohort.** [Epi.Data.MongoDB](https://github.com/jarz/Epi-Info-Community-Edition/blob/master/Epi.Data.MongoDB/packages.config) originally declared MongoDB driver/Bson/Core 2.19.0, Snappier 1.0.0 and SharpCompress 0.32.2. Recheck advisories and actual affected usage; [Snappier's advisory](https://github.com/advisories/GHSA-pggp-6c3x-2xmx) lists 1.3.1 as patched and [SharpCompress's advisory](https://github.com/advisories/GHSA-6c8g-7p36-r338) lists 0.48.0. These are candidate minimum fixes for those advisories, not proven safe dependency combinations. Select a mutually compatible driver/compression set, then validate restore, binding redirects, x86/x64/native assets, compression and synthetic database operations. Status: Snappier 1.3.1 and SharpCompress 0.48.1 are in place with host redirects; a disposable-container round-trip passes for none/snappy/zstd but zlib fails because driver 2.19 uses a type SharpCompress removed in 0.41. MongoDB.Driver 3.x (3.14.1 targets net472 with the same compression packages) is the coherent fix, gated on deployed server versions and GUID-representation compatibility; see [PRIORITIES.md](PRIORITIES.md). Package presence alone does not establish application exploitability.
4. **Modernize the web test harness first.** Both legacy MVC test projects target .NET Framework 4.0, reference machine-installed NUnit 2 and `System.Web`, and contain obsolete fakes/actions. Move the tests to `net48` as a compatibility stage, use a supported NuGet-based NUnit and test adapter, and rewrite affected tests for current behavior. NUnit 5.0.0 and NUnit3TestAdapter 6.3.1 advertise `net462` compatibility, but are candidates requiring validation; the modern adapter does not run NUnit 2 tests unchanged. Run the tests on Windows, require nonzero discovery, and never restore a removed action merely to pass a stale test. Status: done for Web Survey (56 tests, NUnit 5.0.0 / adapter 6.3.1 validated on net48); Web Enter remains.
5. **Pilot one bounded JSON upgrade.** Web Survey currently declares Newtonsoft.Json 13.0.1 in its web and Common manifests. After adding focused synthetic serialization/form tests, select a currently supported compatible patch, update the related references and redirects together, and verify dates, nulls, numeric values, persisted shapes and both projects' builds. Other repositories move independently, not through a workspace-wide version bump.
6. **Move hosts and other families in stages.** For new modern services and isolated portable libraries, target a patched .NET 10 LTS; retain `net48` where the existing Windows desktop or ASP.NET Framework code still requires it. Extract or multi-target a small, well-tested leaf library first; `Epi.Statistics` itself depends on `Epi.Core` and R/native binaries and is not yet a safe drop-in first project. Migrate ASP.NET MVC routes to ASP.NET Core incrementally with explicit authentication, session, form and WCF compatibility. Handle EF, MVC/Razor/WebPages, Azure SDKs, browser assets and vendor controls as separate compatibility families rather than a single upgrade. The existing Visual Studio 2022 toolchain does not officially target `net10.0` in the IDE; plan a supported Visual Studio 18+ or suitable standalone .NET 10 toolchain without replacing the legacy build tools prematurely.

For every candidate: capture before/after dependency graphs, check license and advisory status, run relevant regression/contract tests and builds, document untested integrations, and maintain a rollback. When a contract, fixture, service environment, or owner is missing, record the blocker instead of inventing compatibility.

## Phase 0: Finish build recovery and establish trustworthy baselines

**Priority: immediate.** Owner: build/release maintainer with desktop, web and cloud representatives.

1. Keep all six primary Release builds green using [the build runner](eng/Invoke-Build.ps1). Record tool versions, restore logs and artifact hashes on a fresh Windows agent.
2. Cloud's application and full solution compile after stale Common/Interfaces references were replaced with project references, MVC/JSON dependencies were made explicit and its Unity 4 MVC integration was corrected. Verify the Cloud build on a clean agent and confirm that the legacy Azure 2.9 hosted-service packaging is still required before investing further in it.
3. Decide whether to retain or replace Azure Cloud Services packaging after checking for active deployments; a local compile is not a deployment or service-availability test. Only preserve an old packaging VM if an actual maintained deployment still requires it.
4. Obtain lawful provenance and required licenses for parser/chart/map/interop binaries. Do not manufacture license resources or fetch arbitrary replacement DLLs. Classify each as restorable package, owned source, licensed artifact, or replacement work.
5. Move generated artifacts out of source control only after verifying builds without them. Retain genuine vendor inputs in a documented artifact feed or narrowly scoped vendor directory.
6. Repair test runners before making behavior-changing upgrades. The Desktop binomial, 2x2, linear-regression and logistic-regression fixtures now run through a focused x86 MSTest runner, checking all 5,000 binomial rows, 100 2x2 tables and 100 datasets for each regression. Focused Cloud metadata, resource and local wildcard runners pass 20 selected tests; keep external-service, missing-fixture and API-shape checks visible rather than silently skipping them. The means input CSV and matched-logistic expected-result CSVs are absent from local history, upstream refs and releases, all public forks and CDC documentation; restore canonical fixtures before adding those baselines. Continue with matched logistic, survival and complex-sample fixtures, preserving published numerical tolerances and detecting dropped tests. Twenty-three check-code grammar/interpreter and form-metadata tests grounded in the User Guide and checked-in samples now run in the Desktop unit baseline; extend them to date-literal, GLOBAL/PERMANENT and Jet-backed metadata once those seams have fixtures.
7. Supply non-secret configuration templates, recover missing datasource/content metadata, and create synthetic development data. Isolated website-content packaging currently fails on omitted root Web.config files and a missing Survey datasource file. Never use production public-health records for CI; do not enable deployment scripts during baseline validation.

**Exit gate:** all maintained application build lanes restore/compile on a clean agent; each excluded installer/cloud/Silverlight component has an explicit owner/disposition; selected existing regression tests run with nonzero discovered test counts; no hidden reliance on developers' GACs, checkout paths or stale application DLLs.

Current status: all six primary Release solutions compile locally, the changed web solutions also pass Debug Rebuild, and 103 focused tests pass (27 Desktop numerical/check-code/form-metadata tests, 56 Web Survey MVC tests and 20 Cloud metadata/resource/wildcard tests) with exclusions documented. An opt-in MongoDB round-trip ran against a disposable local container. Cloud ResourceTests is the first packages.config-to-PackageReference pilot; a second Central Package Management check now governs the existing `Epi.Data.EpiWeb` Newtonsoft.Json reference without changing its 13.0.2 version. The Desktop Release build and four numerical tests pass with that change. A local fake now exercises the Cloud Service Bus API controller without contacting Service Bus. CI workflow hosting/ownership, clean-agent reproducibility, remaining legacy tests, API-shape drift review and deployed/runtime validation remain outstanding. This phase is not complete.

## Phase 1: Reduce dependency risk without changing architecture

Owner: component maintainers. Work in small dependency-family changes, each reversible.

### Candidate upgrades

Versions below were checked against public NuGet metadata on 2026-11-21. They are **candidates, not validated upgrades**. Recheck advisories, framework compatibility and package/license terms when implementing.

| Family | Short-term approach | Validation required |
| --- | --- | --- |
| Newtonsoft.Json | Align compatible applications toward 13.0.4; Web Survey build repair only aligned Common with its already-declared 13.0.1 | Survey/check-code JSON round trips, null/date/enum behavior, polymorphism settings, assembly redirects |
| EF 5 / EF 6 | Move EF 5 to EF 6 deliberately; consider 6.5.2 for the EF6 stabilization lane | EDMX/generated code, provider config, query results, transactions and schema-diff review; no automatic production migrations |
| MVC/Web API/Razor/WebPages | Treat MVC/Web API 5.3.0 with Razor/WebPages 3.3.0 as a coordinated classic-ASP.NET migration, not independent patch bumps from MVC 4 | Routing, model binding, authentication/authorization, Razor compilation, WCF integration and redirects |
| Desktop MongoDB / compression | Remediate reported Snappier/SharpCompress advisories through a compatible driver/dependency set | Database operations, compression interoperability, native dependency packaging; don't independently force transitive versions |
| Bootstrap/jQuery/UI/validation | Inventory actually served files and bundles first; NuGet currently lists jQuery 3.7.1 and Bootstrap 5.3.9 | Browser publishing/entry flows, mobile forms, validation, accessibility; Bootstrap 3 -> 5 is a markup/plugin migration |
| jQuery Mobile / obsolete plugins | Plan replacement rather than perpetuating abandoned plugins | Date/number controls, conditional fields, touch/mobile rendering and check-code behavior |
| EPPlus 4.0.5 | Evaluate maintained alternatives or a deliberately licensed upgrade | Spreadsheet fidelity, dates/formulas/cell types, export performance and license review; do not blindly upgrade to a different license model |
| Unity / ServiceLocator | First make versions/references coherent within each product; replace composition roots later | DI resolution/lifetimes, WCF service construction and container-specific APIs |
| Roslyn/CodeDOM | Retire bundled Microsoft.Net.Compilers 1.x and obsolete CodeDOM packages separately | Build compiler selection plus runtime ASP.NET compilation; updating one does not validate the other |
| Native/interop/database/map controls | Explicitly inventory ADODB, Jet/ACE, SQLite x86/x64, Npgsql 2.x, ESRI and ComponentArt | Architecture-specific packaging, provider behavior, chart/map equivalence and vendor rights |

Retarget maintained .NET Framework projects toward 4.8 as a **compatibility staging baseline**; consider 4.8.1 only after choosing supported Windows/Server versions. Old reference assemblies enable compilation, not supported deployment of 4.5.x applications.

For every upgrade: capture before/after dependency graphs, update actual asset references and configuration/binding redirects, run focused unit/contract/browser tests, build deployable packages, and exercise them with synthetic data. Do not silence restore advisories to obtain a green build.

**Exit gate:** maintained runtime dependency set has no unexplained critical/high advisories, no unintended pre-release dependencies, and upgrades preserve required outputs within existing tolerances. Document justified exceptions with owner and expiry.

## Phase 2: Standardize package management across repositories

Owner: build/release maintainer. Depends on Phase 0 baselines; can proceed product-by-product alongside Phase 1.

1. Keep each repository's history and release boundary independent; do not import histories into a new monorepo.
2. The Cloud `ResourceTests` project provides a test-only **packages.config -> PackageReference** and Central Package Management pilot without changing production runtime dependencies. Community Edition's existing `Epi.Data.EpiWeb` Newtonsoft.Json PackageReference is now centrally versioned at the same 13.0.2 version. A separate packages.config-to-PackageReference migration in a production library still requires install-asset and ownership review. Legacy CSPROJ can use PackageReference; SDK-style conversion is a separate step.
3. Introduce `Directory.Packages.props` only for eligible PackageReference projects. Central Package Management does **not** govern packages.config. Use deliberate family/target-specific exceptions during transition; do not impose one version on incompatible clones.
4. Inspect install.ps1/content/transforms/build/native assets before each conversion. Classic ASP.NET migration is not supported by the automatic NuGet migrator; retain packages.config in those projects until the assets/runtime compilation have a verified alternative.
5. Add narrowly scoped shared build properties, a released/pinned SDK for modern projects, explicit NuGet feeds/source mapping, lock files where supported, and locked-mode restores for modern CI lanes. Avoid parent-level properties that accidentally retarget legacy projects.
6. Add dependency-update automation and package advisory/SBOM reporting with accountable ownership. Keep related MVC/Razor/WebPages, Azure SDK and native-provider updates grouped.
7. Separate Windows legacy lanes from cross-platform modern lanes. Publish one artifact per application, with installer/database/deployment jobs clearly separated and approvals for actual environment changes.

**Exit gate:** central versions actually drive eligible restores; a deliberate mismatch fails CI; packages.config exceptions are visible; reproducible restore/release artifacts work within each repository; each repository has owners and release policies.

## Phase 3: Extract shared contracts and pure domain code

Owner: desktop/web domain maintainers. Depends on baseline contract tests and clear ownership.

Start with form metadata/serialization, check-code contracts and numerical routines, not MVC controllers or entire EF layers.

- Use the 374 duplicate-source groups as candidates, not instructions to merge.
- Compare wire schemas, namespaces, assembly identities and differences between Desktop, Survey, Enter and Cloud variants.
- Create golden synthetic fixtures for desktop -> publish -> enter -> response -> export round trips, including related forms and versioned WCF/JSON/XML contracts.
- Separate pure statistics/check-code logic from WinForms/WPF, ADODB, System.Web, EF and service access. Preserve numerical algorithms and tolerances; do not combine refactoring with algorithm changes.
- Where needed, use netstandard2.0 contracts to bridge net48 and modern consumers, or multi-target shared libraries. Test both target frameworks.
- Replace clone copies one consumer at a time; retain adapters for existing clients and rollback paths.

**Exit gate:** one shared implementation for each intentionally unified component, source/project/package references rather than bin-folder coupling, and cross-product contract tests prove compatibility.

## Phase 4: Move maintained hosts to current platforms

Owner: application/platform teams. Incremental replacement, not a whole-system rewrite.

- Target a **released, patched .NET 10 LTS** toolchain for new modern services and eligible libraries. Do not pin the currently installed preview SDK. Microsoft lists .NET 10 support through 2028-11-14; .NET 8 and 9 are already out of support at this snapshot.
- Migrate web endpoints toward ASP.NET Core behind adapters/routes. `System.Web` and WCF hosting are not drop-in modern-.NET conversions. Decide whether legacy SOAP contracts require CoreWCF or a compatibility host before replacing them with HTTP APIs.
- Replace DocumentDB, WindowsAzure.Storage and legacy Service Bus clients with maintained Azure SDKs; test message formats, retry/idempotency, cache behavior, consistency and serialization. Separate infrastructure changes from data migrations.
- Replace Azure Cloud Services packaging with a supported hosting/deployment model selected for the actual operational requirements. **Do not adopt Cloud Services extended support as a long-term target:** it is deprecated and scheduled to retire on 2027-03-31.
- Evaluate modern Windows .NET for WPF/WinForms after vendor-control/native-provider feasibility work. Keeping a supported net48 desktop lane is preferable to a forced UI rewrite with lost epidemiologic functionality.
- Consider an SDK-style `Microsoft.Build.Sql` database project after validating model/DACPAC equivalence. Select a supported database compatibility target based on actual deployments; never silently change it during build recovery.
- Replace unsupported Silverlight, chart/map and installer tooling explicitly, with accessible UI and artifact-parity tests.

**Exit gate:** supported runtime/hosting/dependency stack, upgrade/rollback procedures, synthetic-data operational tests, verified numerical/contract/UI parity, and a documented retirement date for each remaining legacy lane.

## First actionable backlog

1. Determine whether Cloud deployments are active, review their Service Bus protocol, and decide the disposition of Azure 2.9 packaging.
2. Recover the missing numerical evidence and modernize the statistics/check-code test runners and fixtures.
3. On hold: create clean Windows CI only after the user resumes that work; separately identify which checked-in binaries are real inputs.
4. Remediate high-severity compression/driver advisories and align JSON within compatible products.
5. Fix browser dependency inventory: compare served bundles/assets with declarations.
6. After package install-asset and ownership review, pilot packages.config-to-PackageReference in one suitable production library; the test-project migration and existing-reference centralization are already verified.
7. On hold: define repository-specific CI ownership and reusable-workflow hosting when CI work resumes; keep release boundaries independent.

No schedule estimate is assigned until maintainers identify which products/deployments remain active, supported client OS/database versions, and the required legacy-client compatibility window.

## References

- [NuGet Central Package Management](https://learn.microsoft.com/en-us/nuget/consume-packages/central-package-management)
- [NuGet migration limitations](https://learn.microsoft.com/en-us/nuget/consume-packages/migrate-packages-config-to-package-reference)
- [.NET support policy](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core)
- [.NET SDK and Visual Studio compatibility](https://learn.microsoft.com/en-us/dotnet/core/porting/versioning-sdk-msbuild-vs)
- [Incremental ASP.NET to ASP.NET Core migration](https://learn.microsoft.com/en-us/aspnet/core/migration/fx-to-core/start?view=aspnetcore-10.0)
- [NUnit test adapter compatibility](https://docs.nunit.org/articles/vs-test-adapter/Index.html)
- [Retired Service Bus SDKs and AMQP compatibility](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-amqp-dotnet)
- [Cosmos DB .NET SDK v2 retirement](https://learn.microsoft.com/en-us/azure/cosmos-db/sdk-dotnet-v2)
- [Older .NET Framework retirement](https://learn.microsoft.com/en-us/lifecycle/announcements/sha-1-signed-content-retired)
- [Azure Cloud Services extended-support retirement](https://learn.microsoft.com/en-us/azure/cloud-services-extended-support/overview)
- [SQL database projects](https://learn.microsoft.com/en-us/sql/tools/sql-database-projects/sql-database-projects)
- [NuGet JSON candidate](https://www.nuget.org/packages/Newtonsoft.Json/13.0.4), [EF candidate](https://www.nuget.org/packages/EntityFramework/6.5.2), [MVC candidate](https://www.nuget.org/packages/Microsoft.AspNet.Mvc/5.3.0)
