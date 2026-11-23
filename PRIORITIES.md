# Epi Info project priorities

Assessment as of 2026-11-22. This is a work-order recommendation, not a
commitment to upgrade or deploy. Confirm product ownership and active use before
behavior-changing work.

## Recommended order

1. **Verify and revoke any exposed Cloud credentials.** Historical Cloud
   configuration in the public repository contains Azure credential values.
   The referenced resource names no longer resolve, but that does not verify
   that credentials were revoked or rule out use of a different resource.
   Have the relevant owner or security administrator verify and revoke or
   rotate any still-active credentials. Do not copy credential values into
   issues or reports. Treat removing secrets from Git history as a separate,
   coordinated operation; the current assessment did not rewrite history.
2. **Remediate the Desktop MongoDB dependency cohort.** Community Edition is
   the highest priority product to keep usable: CDC says Desktop remains
   operational, and its MongoDB dependency set includes packages with
   published advisories for [Snappier](https://github.com/advisories/GHSA-pggp-6c3x-2xmx)
   and [SharpCompress](https://github.com/advisories/GHSA-6c8g-7p36-r338).
   The remediation updates Snappier to 1.3.1 and SharpCompress to 0.48.1,
   aligns shared .NET Framework dependencies, and adds host-level redirects to
   all 16 Desktop executable configurations. The Desktop Release rebuild and
   focused regression tests pass, and an x86 probe under the `EpiInfo.exe`
   redirects loads the remediated assemblies (Snappier 1.3.1, SharpCompress
   0.48.1, ZstdSharp 0.6.7) with driver 2.19.0.

   A live round-trip against an authorized, disposable local `mongo:6.0`
   container (server 6.0.28) passed for no compression, snappy and zstd,
   with server-side counters proving negotiation. It found two product
   defects that need a decision:

   - **zlib is broken by the SharpCompress update.** Driver 2.19's zlib
     compressor uses `SharpCompress.IO.NonDisposingStream`, which
     SharpCompress removed in 0.41.0. The server negotiates zlib, then the
     first operation throws `TypeLoadException`, so any user whose connection
     string requests only `compressors=zlib` cannot work. Connections without
     compressors are unaffected. Pinning SharpCompress below 0.41 would
     reopen the advisory. The coherent fix is MongoDB.Driver 3.x:
     3.14.1 targets .NET Framework 4.7.2 and itself depends on SharpCompress
     0.48.1 and Snappier 1.3.1. That is a major upgrade (removed legacy APIs,
     changed GUID representation defaults that affect stored data, a higher
     minimum server version), so it needs the deployed server versions and a
     GUID compatibility check first. Until then, document zlib as unsupported.
   - **The adapter shifts date/time values by the local UTC offset.**
     `MongoDBDatabase.cs` writes `new BsonDateTime((DateTime)value)`, which
     treats the value as local time and stores UTC; `MongoDBWrapper.cs`
     returns the UTC value unconverted. On a UTC-5 machine a stored
     13:45 reads back as 18:45. This predates the dependency update.

   The probe also recorded existing adapter gaps: the factory does not
   pass the connection string, `InsertBulkRows` does not await its writes,
   and `DeleteTable` reports success without deleting.
3. **Inventory and update Web Survey browser assets.** The inventory found
   that [`packages.config`](https://github.com/jarz/Epi-Info-Web-Survey/blob/copilot/build-and-test-baseline/Epi.Web/packages.config)
   declares jQuery 3.5.0, while the primary
   [layout](https://github.com/jarz/Epi-Info-Web-Survey/blob/copilot/build-and-test-baseline/Epi.Web/Views/Shared/_Layout.cshtml)
   directly loads jQuery 1.7.1. The report layout loads jQuery 1.12.4 from a
   CDN. The mobile layout loads both jQuery 1.6.3 and 1.7.1 before jQuery Mobile
   1.1.1; `Global.asax.cs` registers that mobile display mode for Android,
   Opera Mobile and iPad, with a browser override. The
   [jquery bundle](https://github.com/jarz/Epi-Info-Web-Survey/blob/copilot/build-and-test-baseline/Epi.Web/App_Start/BundleConfig.cs)
   has a `jquery-1.*` wildcard, but no `Scripts.Render` call was found in the
   views. Do not just update the package manifest. The
   [browser asset inventory](WEB-SURVEY-BROWSER-ASSETS.md) confirms that none
   of the declared jQuery 3.5.0, Bootstrap 3.4.1 or validation 1.19.4 files
   are on disk or served, that SurveyManager's Bootstrap 4.2.1 JavaScript
   refuses to initialize on jQuery 1.7.1, and that jQuery Mobile 1.1.1 only
   supports jQuery 1.6.4/1.7.1. It proposes a test-gated sequence: one jQuery
   per layout, jQuery Migrate as a diagnostic stage, replacing jQuery Mobile
   and its plugins, then jQuery 3.7.1 and jQuery UI/Bootstrap updates.
   Implementation waits for the characterization seams listed there.
4. **Retarget maintained web projects to .NET Framework 4.8.** Treat this as a
   compatibility stage, not a migration to a new architecture. Start with
   products confirmed to be maintained or deployed; validate hosting,
   authentication, session, WCF and database behavior before release.
5. **Modernize the web test harness.** Web Survey `Epi.Web.Test` now runs 56
   tests on net48 with NuGet NUnit 5 and a runner that fails on zero
   discovery. Apply the same approach to Web Enter's copied NUnit suite.
6. **Upgrade web dependency families in coordinated steps.** After focused
   tests exist, address MVC/Web API/Razor/WebPages together, then EF 5 to EF 6.
   Treat JSON alignment as lower urgency because the current Newtonsoft
   versions are past the cited known vulnerability. Review EPPlus licensing
   before considering an upgrade.
7. **Defer Cloud Service Bus and DocumentDB migrations unless an active
   deployment is confirmed.** The checked-in Cloud endpoints are dev/QA, and
   the endpoint names found in the repository no longer resolve. If an owner
   identifies an active deployment using alternate endpoints, prioritize
   migration from the retired Service Bus SDK/protocol and DocumentDB SDK,
   validating message behavior and Cosmos queries with authorized synthetic
   data. Otherwise, treat Cloud as reference code and consider an explicit
   archive or maintenance disposition.
8. **Defer broad architectural modernization.** Keep the product repositories
   separate. Adopt SDK-style projects, wider Central Package Management, .NET
   10 and ASP.NET Core incrementally, beginning with isolated, tested leaf
   libraries only after owners and compatibility boundaries are clear.

## Deployment evidence and limits

- The upstream Cloud repository was last pushed in 2018 and has no GitHub
  issues, pull requests or releases. Four of its five forks have no later
  changes; the remaining fork's `master` is identical to upstream, and its
  2023 changes are automated dependency-fix branches.
- The repository's Azure web, Cosmos DB, Redis, Service Bus and SQL hostnames
  were checked on 2026-11-22. The configured service endpoint names did not
  resolve through the local resolver or public Google and Cloudflare DNS
  resolvers.
- Public web searches found no organization reporting a live Cloud Contact
  Tracing deployment. CDC's [Epi Info page](https://www.cdc.gov/epiinfo/index.html)
  says product development and technical assistance ended in September 2025
  and identifies Desktop as still operational.

This evidence makes a currently live deployment unlikely, but it does not
prove that no installation exists. A private fork, offline installation,
custom domain, or deployment configured outside this repository would not
necessarily appear in these checks. Before abandoning Cloud, ask the former
product or deployment owner to confirm whether a system remains in use.
