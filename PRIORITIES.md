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
   published advisories. Choose a compatible driver and compression set
   together, then validate restore, binding redirects, architecture-specific
   assets, compression and synthetic database operations.
3. **Inventory and update Web Survey browser assets.** Determine which
   JavaScript files are actually served before changing manifests. The checked
   in bundle configuration selects `jquery-1.*`, despite a newer manifest
   declaration. Update the deployed assets and validate survey entry,
   validation, mobile rendering and accessibility.
4. **Retarget maintained web projects to .NET Framework 4.8.** Treat this as a
   compatibility stage, not a migration to a new architecture. Start with
   products confirmed to be maintained or deployed; validate hosting,
   authentication, session, WCF and database behavior before release.
5. **Modernize the web test harness.** Replace machine-installed NUnit 2
   dependencies with a supported NuGet-based framework and adapter, and
   rewrite obsolete tests to assert current behavior. Require nonzero test
   discovery so stale tests cannot silently disappear.
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
