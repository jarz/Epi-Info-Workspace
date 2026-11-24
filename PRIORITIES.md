# Epi Info project priorities

Assessment as of 2026-11-23. This is a work-order recommendation, not a
commitment to upgrade or deploy. No product or deployment owner is available
to confirm active use, so Desktop work proceeds against documented
compatibility minimums and tests; Cloud migration remains deferred.

## Recommended order

1. **Contain exposed credentials and key material.** Historical Cloud
   configuration in the public repository contains Azure credential values.
   The referenced resource names no longer resolve, but that does not verify
   that credentials were revoked or rule out use of a different resource.
   Have the relevant owner or security administrator verify and revoke or
   rotate any still-active credentials. Do not copy credential values into
   issues or reports. Treat removing secrets from Git history as a separate,
   coordinated operation; the current assessment did not rewrite history.
   No such owner is currently reachable: CDC ended product development and
   has not engaged, so revocation cannot be confirmed from the forks. Treat
   every credential in the public history as compromised.

   **Web key material (fixed in the forks):** Web Survey, Survey API and Web
   Enter shared one publicly known set of connection-string encryption keys,
   admin key and (Web Enter) password salt, and Web Enter accepted any admin
   key. The forks now refuse to start without deployment-specific values,
   check the admin key again, and provide `Epi.Web.KeyRotation` to move an
   existing deployment and its encrypted organization keys onto new keys.
   See [Web key material](BUILDING.md#web-key-material). Tracked
   configuration files also contain plaintext database credentials for the
   original operator's servers; only that operator can revoke them.
2. **Remediate the Desktop MongoDB dependency cohort.** Community Edition is
   the highest priority product to keep usable: CDC says Desktop remains
   operational, and its MongoDB dependency set includes packages with
   published advisories for [Snappier](https://github.com/advisories/GHSA-pggp-6c3x-2xmx)
   and [SharpCompress](https://github.com/advisories/GHSA-6c8g-7p36-r338).
   The fork now uses MongoDB.Driver/Bson 3.14.1, Snappier 1.3.1,
   SharpCompress 0.48.1 and ZstdSharp 0.7.3. Driver 3.14.1 is built against
   the patched compression libraries; this also resolves the zlib break that
   occurred when patched SharpCompress was forced under driver 2.19.

   **Validation:** the Desktop Release rebuild and 30 focused tests pass.
   A clean Setup build of `5c159148` produced `EI7_Setup.msi` without
   scratch files. Its administratively extracted application folder passed
   x86 synthetic CRUD with no compression, snappy, zlib and zstd against
   disposable, authenticated MongoDB 4.4.30, 7.0.48, 8.0.38, 8.2.12 and 9.0.8
   servers; server counters confirmed compression negotiation. Earlier
   non-MSI runs also passed against 6.0.28. Legacy subtype-3 and standard
   subtype-4 GUID values were cross-read across driver 2.19 and 3.14.1, and
   the adapter's GUID-as-string behavior remained unchanged. The MSI has not
   been installed or tested as an upgrade.

   **Server policy:** MongoDB server 4.4 is the supported minimum because it
   is driver 3.14.1's minimum. There is no deployment owner to confirm
   installed server versions, so the fork proceeds on that basis. Older
   servers are not a reason to keep the vulnerable 2.x driver: MongoDB 4.2
   and earlier are end of life and have no vendor fix for the unauthenticated
   zlib heap-read vulnerability
   [CVE-2025-14847](https://www.cve.org/CVERecord?id=CVE-2025-14847).
   Users on those servers must upgrade the server before using this build.
   MongoDB 4.4, 5.0 and 6.0 are also past end of life
   ([lifecycle](https://www.mongodb.com/legal/support-policy/lifecycles)).
   Recommend a supported, patched server: 7.0.28 or later, 8.0.17 or later,
   8.2.3 or later, or 9.0.

   **Other compatibility limits:** driver 3.x requires TLS 1.2 or later and
   no longer supports MONGODB-CR authentication. The upgrade removes old AWS
   authentication and client-side encryption dependencies; no corresponding
   use was found in the repository source. Reassess those capabilities if a
   consumer relies on them.

   **Fixed date shift:** `InsertBulkRows` stores local wall-clock values as
   UTC instants, but reads showed the UTC wall-clock time, so dates moved by
   the local UTC offset (US Eastern 13:45 read back as 18:45). Community
   Edition `673af43f` converts stored dates to the reader's local time zone.
   Stored data is unchanged, so no migration is needed and records written
   by earlier builds display correctly. Readers in another time zone see
   their own local time; a date-only value written at midnight shows as the
   previous day to a reader west of the writer. Three unit tests pin this
   behavior. The rebuilt Release application folder passed every check,
   including `adapter.dateTimeRoundTrip`, against disposable MongoDB 4.4.30,
   6.0.28, 7.0.48, 8.0.38, 8.2.12 and 9.0.8; the pre-fix adapter still fails
   that check against 8.0.38. The MSI rebuilt from Community Edition
   `bddc9f4f` passed every check, including the date check, against 4.4.30,
   8.0.38 and 9.0.8 after administrative extraction.

   **Unchanged product defects:** `InsertBulkRows` does not await its writes,
   and `DeleteTable` reports success without deleting. These are separate
   fixes.

   **Fixed installer gap:** the checked-in `PortableDevices.dll` needs
   `Interop.PortableDeviceApiLib.dll` and `Interop.PortableDeviceTypesLib.dll`
   at runtime, but MakeView embedded those interop types, so the build never
   produced them. As a result, the Portable Device (MTP) path used by Copy to
   Android and phone import threw `FileNotFoundException`; Copy to Android
   silently swallows it, so connected Android devices were never found. A
   clean Setup build also could not find the files.
   Community Edition `5c159148` stops embedding them. The build output and MSI
   now include both files, and the extracted MSI reaches the application's
   existing "no devices" path. Community Edition `bddc9f4f` also stops Setup
   from packaging copies of the Windows `PortableDeviceApi.dll` and
   `PortableDeviceTypes.dll` system files. The rebuilt MSI omits them, its two
   system-file warnings are gone, and the extracted `PortableDevices.dll`
   still reaches the "no devices" path using the Windows COM components. No
   real Android device was tested.
   Runtime evidence is recorded in closed
   [fork issue #3](https://github.com/jarz/Epi-Info-Community-Edition/issues/3)
   and the date-shift fix in closed
   [fork issue #4](https://github.com/jarz/Epi-Info-Community-Edition/issues/4);
   MSI install/upgrade validation is tracked in
   [fork issue #5](https://github.com/jarz/Epi-Info-Community-Edition/issues/5).
3. **Inventory and update Web Survey browser assets.** The inventory found
   that [`packages.config`](https://github.com/jarz/Epi-Info-Web-Survey/blob/master/Epi.Web/packages.config)
   declares jQuery 3.5.0, while the primary
   [layout](https://github.com/jarz/Epi-Info-Web-Survey/blob/master/Epi.Web/Views/Shared/_Layout.cshtml)
   directly loads jQuery 1.7.1. The report layout loads jQuery 1.12.4 from a
   CDN. The mobile layout loads both jQuery 1.6.3 and 1.7.1 before jQuery Mobile
   1.1.1; `Global.asax.cs` registers that mobile display mode for Android,
   Opera Mobile and iPad, with a browser override. The
   [jquery bundle](https://github.com/jarz/Epi-Info-Web-Survey/blob/master/Epi.Web/App_Start/BundleConfig.cs)
   has a `jquery-1.*` wildcard, but no `Scripts.Render` call was found in the
   views. Do not just update the package manifest. The
   [browser asset inventory](WEB-SURVEY-BROWSER-ASSETS.md) confirms that none
   of the declared jQuery 3.5.0, Bootstrap 3.4.1 or validation 1.19.4 files
   are on disk or served, that SurveyManager's Bootstrap 4.2.1 JavaScript
   refuses to initialize on jQuery 1.7.1, and that jQuery Mobile 1.1.1 only
   supports jQuery 1.6.4/1.7.1. It proposes a test-gated sequence: one jQuery
   per layout, jQuery Migrate as a diagnostic stage, replacing jQuery Mobile
   and its plugins, then jQuery 3.7.1 and jQuery UI/Bootstrap updates.
   Display-mode and static layout-asset characterization are now in the test
   baseline; hosted browser behavior and other seams remain open.
4. **Retarget maintained web projects to .NET Framework 4.8.** Treat this as a
   compatibility stage, not a migration to a new architecture. Start with
   products confirmed to be maintained or deployed; validate hosting,
   authentication, session, WCF and database behavior before release.
5. **Modernize the web test harness.** Web Survey and Web Enter now run 141
   tests each on net48 with NuGet NUnit 5. Their runners fail on zero discovery;
   database, hosted IIS/WCF and SMTP paths remain excluded.
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

## Desktop runtime findings

A launch smoke test of the administratively extracted `bddc9f4f` MSI started
EpiInfo, MakeView, Enter, Analysis, AnalysisDashboard, StatCalc and Mapping.
Each displayed its main window and kept responding, with no Application Error
or .NET Runtime crash events. It did not exercise form design, data entry,
analysis, MongoDB through the user interface, or MSI install/upgrade.

The smoke test and follow-up checks found pre-existing map-service failures,
tracked in [fork issue #6](https://github.com/jarz/Epi-Info-Community-Edition/issues/6):

- **OpenStreetMap base map fixed and verified.** Mapping now uses the standard
  HTTPS tile URL, an identifying User-Agent, a per-user disk cache that
  observes response freshness headers and revalidates expired tiles, and
  visible linked attribution. A live Mapping run rendered real tiles; a
  repeat launch used the cache, and a forced stale tile returned HTTP 304.
  The implementation follows the
  [tile usage policy](https://operations.osmfoundation.org/policies/tiles/);
  it requests only the interactive viewport and has no offline/prefetch mode.
- **Zone buffers use a retired ESRI sample server.** `ZoneProvider` and the
  Dashboard `MapControl` buffer points through
  `sampleserver3.arcgisonline.com`, which did not resolve on 2026-11-23. The
  user-interface behavior was not exercised.
- **Bing Maps key and service.** The Dashboard map and Enter's `GEOCODE`
  default to a Bing Maps key embedded in source. Microsoft retired free Bing
  Maps for Enterprise accounts on 2025-06-30, and Enterprise accounts end
  2028-06-30. The key was not tested because it belongs to CDC. Plan a
  replacement with a configured key.

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
