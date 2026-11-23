// Opt-in MongoDB round-trip probe for the Epi Info Desktop MongoDB dependency cohort.
// Built and launched by eng\Invoke-DesktopMongoRoundTrip.ps1 as an x86 .NET Framework 4.8 console
// application that runs beside the Desktop Release binaries under the EpiInfo.exe.config binding redirects.
// The connection string is only accepted through an environment variable so it never appears on a command line.
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.Common;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using MongoDB.Bson;
using MongoDB.Bson.IO;
using MongoDB.Driver;
using MongoDB.Driver.Core.Compression;
using MongoDB.Driver.Core.Configuration;

namespace Epi.Tools.MongoRoundTrip
{
    internal static class Program
    {
        internal const string ConnectionStringVariable = "EPIINFO_MONGO_ROUNDTRIP_CONNECTION_STRING";
        private const string DatabasePrefix = "epiinfo_roundtrip_";
        private static readonly Regex OwnedDatabaseName = new Regex("^" + DatabasePrefix + "[0-9a-f]{32}$", RegexOptions.CultureInvariant);

        private static readonly string[] ReportedAssemblies =
        {
            "MongoDB.Driver", "MongoDB.Driver.Core", "MongoDB.Bson", "MongoDB.Libmongocrypt", "Snappier", "SharpCompress", "ZstdSharp",
            "DnsClient", "System.Memory", "System.Buffers", "System.Runtime.CompilerServices.Unsafe", "System.Numerics.Vectors",
            "Microsoft.Extensions.Logging.Abstractions", "AWSSDK.Core", "Epi.Core", "Epi.Data.MongoDB"
        };

        private static readonly CompressorType[] LiveCompressors = { CompressorType.Snappy, CompressorType.Zlib, CompressorType.ZStandard };

        private static Report report;
        private static readonly Redactor redactor = new Redactor();
        private static string outputPath;

        private static int Main(string[] args)
        {
            bool confirmed = false;
            bool skipAdapter = false;
            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                if (arg == "--confirm-disposable-server") { confirmed = true; }
                else if (arg == "--skip-adapter") { skipAdapter = true; }
                else if (arg == "--output" && i + 1 < args.Length) { outputPath = args[++i]; }
                else
                {
                    Console.Error.WriteLine("Unknown or incomplete argument: " + arg);
                    return 2;
                }
            }

            if (string.IsNullOrWhiteSpace(outputPath))
            {
                Console.Error.WriteLine("--output <result.json> is required.");
                return 2;
            }

            string connectionString = Environment.GetEnvironmentVariable(ConnectionStringVariable);
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                Console.Error.WriteLine("Refusing to run: no connection string was supplied (expected via " + ConnectionStringVariable + "). There is no default server.");
                return 2;
            }

            if (!confirmed)
            {
                Console.Error.WriteLine("Refusing to run: --confirm-disposable-server was not supplied. Only run against an authorized, disposable MongoDB server.");
                return 2;
            }

            redactor.AddSecret(connectionString);
            report = new Report(redactor);
            AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;

            try
            {
                Run(connectionString, skipAdapter);
            }
            catch (Exception ex)
            {
                report.Add("probe.unexpectedException", Status.Failed, null, ex);
            }

            report.Root["loadedAssembliesAtExit"] = DescribeLoadedAssemblies();
            report.Write(outputPath);
            Console.WriteLine("Result: " + report.OverallStatus + " -> " + outputPath);
            return report.OverallStatus == Status.Passed ? 0 : 1;
        }

        private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
        {
            try
            {
                report.Add("probe.unhandledException", Status.Failed, new BsonDocument("note", "An unobserved exception terminated the probe (for example from the adapter's async void MongoDBWrapper.Insert)."), e.ExceptionObject as Exception);
                report.Root["loadedAssembliesAtExit"] = DescribeLoadedAssemblies();
                report.Write(outputPath);
                Console.Error.WriteLine("Result: Failed (unhandled exception) -> " + outputPath);
            }
            catch
            {
            }
        }

        private static void Run(string connectionString, bool skipAdapter)
        {
            report.Root["environment"] = new BsonDocument
            {
                { "is64BitProcess", Environment.Is64BitProcess },
                { "pointerSize", IntPtr.Size },
                { "clrVersion", Environment.Version.ToString() },
                { "osVersion", Environment.OSVersion.VersionString },
                { "baseDirectory", AppDomain.CurrentDomain.BaseDirectory },
                { "configurationFile", AppDomain.CurrentDomain.SetupInformation.ConfigurationFile }
            };
            report.Add("environment.x86", IntPtr.Size == 4 ? Status.Passed : Status.Failed, new BsonDocument("pointerSize", IntPtr.Size));

            MongoUrl url;
            try
            {
                url = new MongoUrl(connectionString);
            }
            catch (Exception ex)
            {
                report.Add("connectionString.parse", Status.Failed, null, ex);
                return;
            }

            // Very short passwords are covered by the URI user-info scrub instead, so they cannot corrupt the JSON.
            if (!string.IsNullOrEmpty(url.Password) && url.Password.Length >= 4)
            {
                redactor.AddSecret(url.Password);
            }

            report.Add("connectionString.parse", Status.Passed, new BsonDocument
            {
                { "scheme", url.Scheme.ToString() },
                { "hosts", new BsonArray(url.Servers.Select(s => s.ToString())) },
                { "hasCredentials", !string.IsNullOrEmpty(url.Username) },
                { "useTls", url.UseTls },
                { "replicaSet", (BsonValue)url.ReplicaSetName ?? BsonNull.Value },
                { "uriCompressors", new BsonArray(url.Compressors.Select(c => c.Type.ToString())) },
                { "note", "The raw connection string and credentials are never written; per-check compressors override uriCompressors." }
            });

            CheckAssemblyBinding();
            CheckCodecs();
            object adapterFactory = skipAdapter ? null : LoadAdapterFactory(connectionString);

            string databaseName = DatabasePrefix + Guid.NewGuid().ToString("N");
            report.Root["database"] = databaseName;
            MongoClient baseClient = new MongoClient(CreateSettings(url, null));
            bool ownsDatabase = false;
            try
            {
                ownsDatabase = Preflight(baseClient, databaseName);
                if (!ownsDatabase)
                {
                    report.Add("roundTrip", Status.Skipped, new BsonDocument("reason", "Preflight did not establish a reachable server with a fresh throwaway database."));
                    if (!skipAdapter) { report.Add("adapter.live", Status.Skipped, new BsonDocument("reason", "Preflight failed.")); }
                    return;
                }

                RoundTrip(url, baseClient, databaseName, null);
                foreach (CompressorType compressor in LiveCompressors)
                {
                    RoundTrip(url, baseClient, databaseName, compressor);
                }

                if (skipAdapter)
                {
                    report.Add("adapter.live", Status.Skipped, new BsonDocument("reason", "--skip-adapter"));
                }
                else if (adapterFactory != null)
                {
                    AdapterRoundTrip(adapterFactory, connectionString, baseClient, databaseName);
                }
                else
                {
                    report.Add("adapter.live", Status.Skipped, new BsonDocument("reason", "Adapter factory did not load."));
                }
            }
            finally
            {
                if (ownsDatabase)
                {
                    Cleanup(baseClient, databaseName);
                }
            }
        }

        private static MongoClientSettings CreateSettings(MongoUrl url, CompressorType? compressor)
        {
            MongoClientSettings settings = MongoClientSettings.FromUrl(url);
            settings.ApplicationName = "EpiInfoMongoRoundTripProbe";
            settings.Compressors = compressor.HasValue
                ? new[] { new CompressorConfiguration(compressor.Value) }
                : new CompressorConfiguration[0];
            return settings;
        }

        private static void CheckAssemblyBinding()
        {
            // Resolve each dependency by the exact identity the MongoDB and Epi assemblies were compiled against,
            // so the result shows what the host binding redirects actually deliver.
            BsonArray resolutions = new BsonArray();
            bool allResolved = true;
            // MongoDB.Driver.Core was merged into MongoDB.Driver in 3.0; only probe it for a 2.x cohort.
            string[] roots = typeof(MongoClient).Assembly.GetName().Version.Major < 3
                ? new[] { "MongoDB.Driver", "MongoDB.Driver.Core", "MongoDB.Bson", "Epi.Data.MongoDB" }
                : new[] { "MongoDB.Driver", "MongoDB.Bson", "Epi.Data.MongoDB" };
            foreach (string root in roots)
            {
                Assembly rootAssembly;
                try
                {
                    rootAssembly = Assembly.Load(root);
                }
                catch (Exception ex)
                {
                    allResolved = false;
                    resolutions.Add(new BsonDocument { { "referencedBy", "probe" }, { "requested", root }, { "error", redactor.Scrub(ex.GetType().Name + ": " + ex.Message) } });
                    continue;
                }

                foreach (AssemblyName reference in rootAssembly.GetReferencedAssemblies())
                {
                    if (!ReportedAssemblies.Contains(reference.Name, StringComparer.OrdinalIgnoreCase)) { continue; }
                    BsonDocument entry = new BsonDocument { { "referencedBy", root }, { "requested", reference.FullName } };
                    try
                    {
                        Assembly loaded = Assembly.Load(reference);
                        entry["loaded"] = loaded.FullName;
                        entry["location"] = loaded.Location;
                        entry["fileVersion"] = FileVersion(loaded);
                    }
                    catch (Exception ex)
                    {
                        allResolved = false;
                        entry["error"] = redactor.Scrub(ex.GetType().Name + ": " + ex.Message);
                    }

                    resolutions.Add(entry);
                }
            }

            report.Add("assemblies.bindingRedirects", allResolved ? Status.Passed : Status.Failed, new BsonDocument("resolutions", resolutions));

            BsonDocument identities = new BsonDocument();
            foreach (string name in ReportedAssemblies)
            {
                try
                {
                    Assembly assembly = Assembly.Load(name);
                    identities[name] = new BsonDocument { { "identity", assembly.FullName }, { "location", assembly.Location }, { "fileVersion", FileVersion(assembly) }, { "informationalVersion", InformationalVersion(assembly) } };
                }
                catch (Exception ex)
                {
                    identities[name] = new BsonDocument("error", redactor.Scrub(ex.GetType().Name + ": " + ex.Message));
                }
            }

            report.Root["assemblies"] = identities;

            Version snappier = VersionOf("Snappier");
            Version sharpCompress = VersionOf("SharpCompress");
            Version driver = VersionOf("MongoDB.Driver");
            Version bson = VersionOf("MongoDB.Bson");
            Version zstd = VersionOf("ZstdSharp");
            bool expected = snappier == new Version(1, 3, 1, 0) && sharpCompress == new Version(0, 48, 1, 0)
                && zstd == new Version(0, 7, 3, 0) && driver == new Version(3, 14, 1, 0) && bson == new Version(3, 14, 1, 0);
            report.Add("assemblies.remediatedVersions", expected ? Status.Passed : Status.Failed, new BsonDocument
            {
                { "MongoDB.Driver", Str(driver) }, { "MongoDB.Bson", Str(bson) }, { "Snappier", Str(snappier) }, { "SharpCompress", Str(sharpCompress) }, { "ZstdSharp", Str(zstd) },
                { "expected", "MongoDB.Driver 3.14.1.0, MongoDB.Bson 3.14.1.0, Snappier 1.3.1.0, SharpCompress 0.48.1.0, ZstdSharp 0.7.3.0" }
            });
        }

        private static void CheckCodecs()
        {
            // Offline self-test through the driver's own (internal) CompressorSource, which the wire protocol uses
            // after negotiation. Proves each codec's managed dependency loads and round-trips under x86 with the redirects.
            Type sourceType = typeof(CompressorConfiguration).Assembly.GetType("MongoDB.Driver.Core.Compression.CompressorSource", false);
            byte[] payload = SyntheticPayload(1 << 20, 7);
            foreach (CompressorType type in LiveCompressors)
            {
                string name = "codec." + ServerName(type);
                if (sourceType == null)
                {
                    report.Add(name, Status.Failed, new BsonDocument("error", "MongoDB.Driver.Core.Compression.CompressorSource was not found."));
                    continue;
                }

                try
                {
                    IReadOnlyList<CompressorConfiguration> allowed = new List<CompressorConfiguration> { new CompressorConfiguration(type) };
                    ICompressorSource source = (ICompressorSource)Activator.CreateInstance(sourceType, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic, null, new object[] { allowed }, null);
                    ICompressor compressor = source.Get(type);
                    HashSet<string> loadedBefore = new HashSet<string>(AppDomain.CurrentDomain.GetAssemblies().Select(a => a.FullName));
                    byte[] compressed;
                    using (MemoryStream input = new MemoryStream(payload))
                    using (MemoryStream output = new MemoryStream())
                    {
                        compressor.Compress(input, output);
                        compressed = output.ToArray();
                    }

                    byte[] roundTripped;
                    using (MemoryStream input = new MemoryStream(compressed))
                    using (MemoryStream output = new MemoryStream())
                    {
                        compressor.Decompress(input, output);
                        roundTripped = output.ToArray();
                    }

                    bool equal = roundTripped.SequenceEqual(payload);
                    bool smaller = compressed.Length < payload.Length;
                    report.Add(name, equal && smaller ? Status.Passed : Status.Failed, new BsonDocument
                    {
                        { "compressorType", compressor.GetType().FullName },
                        { "originalBytes", payload.Length },
                        { "compressedBytes", compressed.Length },
                        { "roundTripEqual", equal },
                        { "assembliesLoadedByCodec", new BsonArray(AppDomain.CurrentDomain.GetAssemblies().Select(a => a.FullName).Where(n => !loadedBefore.Contains(n))) }
                    });
                }
                catch (Exception ex)
                {
                    report.Add(name, Status.Failed, null, ex);
                }
            }
        }

        private static object LoadAdapterFactory(string connectionString)
        {
            // Same mechanism Epi Info uses: DbDriverFactoryCreator resolves the factory named by SharedStrings.MONGODB_DATABASE_INFO.
            try
            {
                string driverType = Epi.SharedStrings.MONGODB_DATABASE_INFO;
                Epi.Data.IDbDriverFactory factory = Epi.Data.DbDriverFactoryCreator.GetDbDriverFactory(driverType);
                if (factory == null)
                {
                    report.Add("adapter.factory", Status.Failed, new BsonDocument("error", "DbDriverFactoryCreator returned null."));
                    return null;
                }

                bool claims = factory.CanClaimConnectionString(connectionString);
                report.Add("adapter.factory", claims ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "requestedType", driverType },
                    { "factoryType", factory.GetType().AssemblyQualifiedName },
                    { "location", factory.GetType().Assembly.Location },
                    { "canClaimConnectionString", claims }
                });
                return factory;
            }
            catch (Exception ex)
            {
                report.Add("adapter.factory", Status.Failed, null, ex);
                return null;
            }
        }

        private static bool Preflight(MongoClient client, string databaseName)
        {
            IMongoDatabase admin = client.GetDatabase("admin");
            try
            {
                BsonDocument buildInfo = admin.RunCommand<BsonDocument>(new BsonDocument("buildInfo", 1));
                BsonDocument hello = RunHello(admin, null);
                List<string> databases = client.ListDatabaseNames().ToList();
                BsonDocument server = new BsonDocument
                {
                    { "version", buildInfo.GetValue("version", BsonNull.Value) },
                    { "gitVersion", buildInfo.GetValue("gitVersion", BsonNull.Value) },
                    { "modules", buildInfo.GetValue("modules", new BsonArray()) },
                    { "maxWireVersion", hello.GetValue("maxWireVersion", BsonNull.Value) },
                    { "setName", hello.GetValue("setName", BsonNull.Value) },
                    { "isMongos", hello.GetValue("msg", "").ToString() == "isdbgrid" },
                    { "clusterType", client.Cluster.Description.Type.ToString() }
                };
                report.Root["server"] = server;
                if (databases.Contains(databaseName))
                {
                    report.Add("preflight", Status.Failed, new BsonDocument("error", "Throwaway database name already exists; refusing to touch it."));
                    return false;
                }

                if (!OwnedDatabaseName.IsMatch(databaseName))
                {
                    report.Add("preflight", Status.Failed, new BsonDocument("error", "Generated database name failed the ownership pattern."));
                    return false;
                }

                report.Add("preflight", Status.Passed, new BsonDocument { { "serverVersion", server["version"] }, { "throwawayDatabaseAbsent", true } });
                return true;
            }
            catch (Exception ex)
            {
                report.Add("preflight", Status.Failed, null, ex);
                return false;
            }
        }

        private static BsonDocument RunHello(IMongoDatabase admin, CompressorType? compressor)
        {
            foreach (string command in new[] { "hello", "isMaster" })
            {
                BsonDocument request = new BsonDocument(command, 1);
                if (compressor.HasValue) { request["compression"] = new BsonArray { ServerName(compressor.Value) }; }
                try
                {
                    return admin.RunCommand<BsonDocument>(request);
                }
                catch (MongoCommandException) when (command == "hello")
                {
                }
            }

            return new BsonDocument();
        }

        private static void RoundTrip(MongoUrl url, MongoClient baseClient, string databaseName, CompressorType? compressor)
        {
            string label = compressor.HasValue ? ServerName(compressor.Value) : "none";
            string prefix = "roundTrip." + label;
            IMongoDatabase admin = baseClient.GetDatabase("admin");
            BsonDocument before = CompressionCounters(admin);
            MongoClient client = new MongoClient(CreateSettings(url, compressor));
            IMongoDatabase database = client.GetDatabase(databaseName);
            IMongoCollection<BsonDocument> collection = database.GetCollection<BsonDocument>("rt_" + label);

            try
            {
                BsonDocument hello = RunHello(client.GetDatabase("admin"), compressor);
                report.Add(prefix + ".helloCompression", Status.Info, new BsonDocument
                {
                    { "requested", compressor.HasValue ? (BsonValue)ServerName(compressor.Value) : BsonNull.Value },
                    { "serverReply", hello.GetValue("compression", BsonNull.Value) },
                    { "note", "Informational: hello on an established connection only echoes server support; the serverStatus counter deltas are the negotiation evidence." }
                });

                List<BsonDocument> expected = Enumerable.Range(0, 10).Select(i => SyntheticDocument(i, label)).ToList();
                collection.InsertMany(expected.Select(d => d.DeepClone().AsBsonDocument));
                List<BsonDocument> actual = collection.Find(FilterDefinition<BsonDocument>.Empty).Sort(new BsonDocument("seq", 1)).ToList();
                BsonArray mismatches;
                bool insertedEqual = Compare(expected, actual, out mismatches);
                report.Add(prefix + ".insertRead", insertedEqual ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "inserted", expected.Count }, { "read", actual.Count }, { "mismatches", mismatches },
                    { "fieldsCompared", new BsonArray(expected[0].Names) },
                    { "binaryBytesPerDocument", expected[0]["blob"].AsBsonBinaryData.Bytes.Length }
                });

                const string updatedStatus = "updated \u2713 \u00e9t\u00e9";
                UpdateResult update = collection.UpdateMany(
                    new BsonDocument("seq", new BsonDocument("$lt", 5)),
                    new BsonDocument { { "$set", new BsonDocument("status", updatedStatus) }, { "$inc", new BsonDocument("counter", 1L) } });
                foreach (BsonDocument d in expected.Where(d => d["seq"].AsInt32 < 5))
                {
                    d["status"] = updatedStatus;
                    d["counter"] = d["counter"].AsInt64 + 1;
                }

                actual = collection.Find(FilterDefinition<BsonDocument>.Empty).Sort(new BsonDocument("seq", 1)).ToList();
                bool updatedEqual = Compare(expected, actual, out mismatches);
                report.Add(prefix + ".update", update.ModifiedCount == 5 && updatedEqual ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "matched", update.MatchedCount }, { "modified", update.ModifiedCount }, { "mismatches", mismatches }
                });

                DeleteResult partial = collection.DeleteMany(new BsonDocument("seq", new BsonDocument("$gte", 5)));
                long remaining = collection.CountDocuments(FilterDefinition<BsonDocument>.Empty);
                DeleteResult rest = collection.DeleteMany(FilterDefinition<BsonDocument>.Empty);
                long final = collection.CountDocuments(FilterDefinition<BsonDocument>.Empty);
                report.Add(prefix + ".delete", partial.DeletedCount == 5 && remaining == 5 && rest.DeletedCount == 5 && final == 0 ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "deletedFirst", partial.DeletedCount }, { "remainingAfterFirst", remaining }, { "deletedSecond", rest.DeletedCount }, { "final", final }
                });
            }
            catch (Exception ex)
            {
                report.Add(prefix + ".exception", Status.Failed, null, ex);

                // Show whether the failure poisons the live client: run a trivial compressed command on the same client.
                try
                {
                    client.GetDatabase("admin").RunCommand<BsonDocument>(new BsonDocument("ping", 1));
                    report.Add(prefix + ".pingAfterFailure", Status.Info, new BsonDocument("ping", "ok"));
                }
                catch (Exception pingEx)
                {
                    report.Add(prefix + ".pingAfterFailure", Status.Info, new BsonDocument("ping", "failed"), pingEx);
                }
            }

            if (compressor.HasValue)
            {
                BsonDocument after = CompressionCounters(admin);
                string name = ServerName(compressor.Value);
                long decompressedIn = Delta(before, after, name, "decompressor", "bytesIn");
                long compressedIn = Delta(before, after, name, "compressor", "bytesIn");
                bool countersPresent = after.Contains(name);
                report.Add(prefix + ".negotiated", countersPresent && decompressedIn > 0 && compressedIn > 0 ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "evidence", "serverStatus.network.compression." + name + " byte counter deltas across this compressor's workload" },
                    { "serverCountersPresent", countersPresent },
                    { "serverDecompressorBytesInDelta", decompressedIn },
                    { "serverDecompressorBytesOutDelta", Delta(before, after, name, "decompressor", "bytesOut") },
                    { "serverCompressorBytesInDelta", compressedIn },
                    { "serverCompressorBytesOutDelta", Delta(before, after, name, "compressor", "bytesOut") },
                    { "otherCompressorsDecompressorBytesInDelta", new BsonDocument(LiveCompressors.Select(ServerName).Where(n => n != name).Select(n => new BsonElement(n, Delta(before, after, n, "decompressor", "bytesIn")))) }
                });
            }
        }

        private static void AdapterRoundTrip(object factoryObject, string connectionString, MongoClient baseClient, string databaseName)
        {
            const string table = "adapter_rows";
            Epi.Data.IDbDriverFactory factory = (Epi.Data.IDbDriverFactory)factoryObject;
            if (connectionString.Contains("~"))
            {
                report.Add("adapter.live", Status.Skipped, new BsonDocument("reason", "Connection string contains '~', which the adapter uses as its database separator."));
                return;
            }

            // The adapter format is "<mongodb uri>~<database>" (MongoDBConnectionStringBuilder.ToString()).
            // If the URI selects no compressors, request all three so the Epi path also exercises negotiation.
            string adapterUri = connectionString;
            bool addedCompressors = connectionString.IndexOf("compressors=", StringComparison.OrdinalIgnoreCase) < 0;
            if (addedCompressors)
            {
                string afterScheme = connectionString.Substring(connectionString.IndexOf("://", StringComparison.Ordinal) + 3);
                string separator = connectionString.Contains("?") ? "&" : afterScheme.Contains("/") ? "?" : "/?";
                adapterUri += separator + "compressors=zstd,snappy,zlib";
            }

            string adapterConnectionString = adapterUri + "~" + databaseName;
            redactor.AddSecret(adapterConnectionString);
            redactor.AddSecret(adapterUri);
            IMongoDatabase admin = baseClient.GetDatabase("admin");
            BsonDocument before = CompressionCounters(admin);

            Epi.Data.IDbDriver driver;
            try
            {
                Type builderType = factory.GetType().Assembly.GetType("Epi.Data.MongoDB.MongoDBConnectionStringBuilder", true);
                DbConnectionStringBuilder builder = (DbConnectionStringBuilder)Activator.CreateInstance(builderType, adapterConnectionString);
                driver = factory.CreateDatabaseObject(builder);
                bool connectionStringPropagated = driver.ConnectionString == adapterConnectionString;
                if (!connectionStringPropagated)
                {
                    driver.ConnectionString = builder.ToString();
                }

                report.Add("adapter.createDatabaseObject", driver.DbName == databaseName ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "driverType", driver.GetType().FullName },
                    { "connectionStringPropagatedByFactory", connectionStringPropagated },
                    { "note", connectionStringPropagated ? "" : "CreateDatabaseObject reads the base DbConnectionStringBuilder.ConnectionString, which MongoDBConnectionStringBuilder hides with a new property; the probe assigned builder.ToString() to IDbDriver.ConnectionString." },
                    { "dbName", driver.DbName ?? "" },
                    { "identifyDatabase", Safe(() => driver.IdentifyDatabase()) }
                });
            }
            catch (Exception ex)
            {
                report.Add("adapter.createDatabaseObject", Status.Failed, null, ex);
                return;
            }

            try
            {
                report.Add("adapter.testConnection", driver.TestConnection() ? Status.Passed : Status.Failed, null);

                DataTable source = new DataTable(table);
                source.Columns.Add("RecordId", typeof(int));
                source.Columns.Add("Name", typeof(string));
                source.Columns.Add("Score", typeof(double));
                source.Columns.Add("Active", typeof(bool));
                source.Columns.Add("Visited", typeof(DateTime));
                source.Columns.Add("Notes", typeof(string));
                DateTime baseDate = new DateTime(2024, 2, 29, 13, 45, 30, 123, DateTimeKind.Utc);
                for (int i = 0; i < 5; i++)
                {
                    source.Rows.Add(i + 1, "Synthetic \u00fcnic\u00f6de \u65e5\u672c " + i, i * 1.25 + 0.5, i % 2 == 0, baseDate.AddDays(i), new string('x', 2048) + i);
                }

                // InsertBulkRows hands each row to MongoDBWrapper.Insert, an async void method, so it returns before
                // the writes complete; poll the collection through the plain driver until they land.
                bool inserted;
                using (DataTableReader reader = source.CreateDataReader())
                {
                    inserted = driver.InsertBulkRows(table, reader);
                }

                IMongoCollection<BsonDocument> collection = baseClient.GetDatabase(databaseName).GetCollection<BsonDocument>(table);
                Stopwatch wait = Stopwatch.StartNew();
                long count = 0;
                while (wait.Elapsed < TimeSpan.FromSeconds(30))
                {
                    count = collection.CountDocuments(FilterDefinition<BsonDocument>.Empty);
                    if (count >= source.Rows.Count) { break; }
                    Thread.Sleep(250);
                }

                report.Add("adapter.insertBulkRows", inserted && count == source.Rows.Count ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "returned", inserted }, { "documentsObserved", count }, { "expected", source.Rows.Count }, { "waitedMs", wait.ElapsedMilliseconds }
                });

                bool tableExists = driver.TableExists(table);
                List<string> tableNames = driver.GetTableNames() ?? new List<string>();
                long scalar = Convert.ToInt64(driver.ExecuteScalar(driver.CreateQuery("SELECT COUNT(*) FROM " + table)));
                report.Add("adapter.metadata", tableExists && tableNames.Contains(table) && scalar == source.Rows.Count ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "tableExists", tableExists }, { "tableNames", new BsonArray(tableNames) }, { "countScalar", scalar }
                });

                DataTable read = driver.GetTableData(table);
                BsonArray mismatches = new BsonArray();
                BsonArray dateMismatches = new BsonArray();
                bool allDateShiftsAreLocalOffset = true;
                Dictionary<int, DataRow> byId = new Dictionary<int, DataRow>();
                foreach (DataRow row in read.Rows) { byId[Convert.ToInt32(row["RecordId"])] = row; }
                foreach (DataRow expected in source.Rows)
                {
                    int id = (int)expected["RecordId"];
                    DataRow actual;
                    if (!byId.TryGetValue(id, out actual)) { mismatches.Add("missing RecordId " + id); continue; }
                    if ((string)expected["Name"] != Convert.ToString(actual["Name"])) { mismatches.Add(id + ".Name"); }
                    if ((double)expected["Score"] != Convert.ToDouble(actual["Score"])) { mismatches.Add(id + ".Score"); }
                    if ((bool)expected["Active"] != bool.Parse(Convert.ToString(actual["Active"]))) { mismatches.Add(id + ".Active"); }
                    if ((string)expected["Notes"] != Convert.ToString(actual["Notes"])) { mismatches.Add(id + ".Notes"); }

                    // Epi DataTables use the default DataColumn.DateTimeMode (UnspecifiedLocal), so values carry Kind=Unspecified
                    // wall-clock times; a faithful round trip returns the same wall-clock value.
                    DateTime expectedVisited = (DateTime)expected["Visited"];
                    DateTime actualVisited = Convert.ToDateTime(actual["Visited"]);
                    if (expectedVisited != actualVisited)
                    {
                        BsonDocument storedDoc = collection.Find(FilterDefinition<BsonDocument>.Empty).ToList().FirstOrDefault(d => d.Contains("RecordId") && Convert.ToInt32(BsonTypeMapper.MapToDotNetValue(d["RecordId"])) == id);
                        DateTime stored = storedDoc != null && storedDoc.Contains("Visited") && storedDoc["Visited"].IsValidDateTime ? storedDoc["Visited"].ToUniversalTime() : DateTime.MinValue;
                        DateTime localAsUtc = DateTime.SpecifyKind(expectedVisited, DateTimeKind.Local).ToUniversalTime();
                        allDateShiftsAreLocalOffset &= actualVisited.Ticks == localAsUtc.Ticks && stored == localAsUtc;
                        dateMismatches.Add(new BsonDocument
                        {
                            { "recordId", id },
                            { "written", expectedVisited.ToString("o") + " (" + expectedVisited.Kind + ")" },
                            { "storedBsonUtc", stored.ToString("o") },
                            { "readBack", actualVisited.ToString("o") + " (" + actualVisited.Kind + ")" },
                            { "shiftHours", (actualVisited - expectedVisited).TotalHours }
                        });
                    }
                }

                report.Add("adapter.getTableData", read.Rows.Count == source.Rows.Count && mismatches.Count == 0 ? Status.Passed : Status.Failed, new BsonDocument
                {
                    { "rows", read.Rows.Count }, { "columns", new BsonArray(read.Columns.Cast<DataColumn>().Select(c => c.ColumnName + ":" + c.DataType.Name)) },
                    { "fieldsCompared", "RecordId, Name, Score, Active, Notes (DateTime checked separately in adapter.dateTimeRoundTrip)" }, { "mismatches", mismatches }
                });

                BsonDocument dateDetails = new BsonDocument
                {
                    { "localUtcOffsetHours", TimeZoneInfo.Local.GetUtcOffset(baseDate).TotalHours },
                    { "mismatches", dateMismatches }
                };
                if (dateMismatches.Count == 0)
                {
                    report.Add("adapter.dateTimeRoundTrip", Status.Passed, dateDetails);
                }
                else if (allDateShiftsAreLocalOffset)
                {
                    dateDetails["classification"] = "ProductDefect (Epi.Data.MongoDB), not a probe or dependency-cohort issue";
                    dateDetails["finding"] =
                        "Epi.Data.MongoDB shifts DateTime values by the local UTC offset on a write/read round trip. Write: MongoDBDatabase.InsertBulkRows (Epi.Data.MongoDB\\MongoDBDatabase.cs:1583) builds new BsonDateTime((DateTime)reader[y]), which treats Kind=Unspecified as local time and stores it converted to UTC. Read: MongoDBWrapper.SetValue (Epi.Data.MongoDB\\Wrappers\\MongoDBWrapper.cs:206) assigns the BsonDateTime to a DateTime column (type from GetDataType, MongoDBWrapper.cs:250-253), which yields the UTC value without converting back to local.                         Invisible on machines whose local offset is zero.";
                                            report.Add("adapter.dateTimeRoundTrip", Status.Failed, dateDetails);
                }
                else
                {
                    report.Add("adapter.dateTimeRoundTrip", Status.Failed, dateDetails);
                }

                bool deleteReported = driver.DeleteTable(table);
                long afterDelete = collection.CountDocuments(FilterDefinition<BsonDocument>.Empty);
                report.Add("adapter.updateDelete", Status.Info, new BsonDocument
                {
                    { "deleteTableReturned", deleteReported },
                    { "documentsAfterDeleteTable", afterDelete },
                    { "note", "MongoDBDatabase.ExecuteNonQuery is a stub returning 1, so DeleteTable reports success without deleting; Insert_1_Row/Update_1_Row throw NotImplementedException. Update/delete are verified only through the plain driver checks." }
                });
            }
            catch (Exception ex)
            {
                report.Add("adapter.exception", Status.Failed, null, ex);
            }

            BsonDocument after = CompressionCounters(admin);
            BsonDocument deltas = new BsonDocument(LiveCompressors.Select(ServerName).Select(n => new BsonElement(n, Delta(before, after, n, "decompressor", "bytesIn"))));
            bool anyNegotiated = deltas.Elements.Any(e => e.Value.ToInt64() > 0);
            report.Add("adapter.compressionNegotiated", addedCompressors ? (anyNegotiated ? Status.Passed : Status.Failed) : Status.Info, new BsonDocument
            {
                { "adapterRequestedCompressors", addedCompressors ? "zstd,snappy,zlib (added by probe)" : "as specified in the supplied URI" },
                { "serverDecompressorBytesInDelta", deltas }
            });
        }

        private static void Cleanup(MongoClient client, string databaseName)
        {
            try
            {
                if (!OwnedDatabaseName.IsMatch(databaseName)) { throw new InvalidOperationException("Refusing to drop a database the probe did not name."); }
                client.DropDatabase(databaseName);
                bool gone = !client.ListDatabaseNames().ToList().Contains(databaseName);
                report.Add("cleanup.dropThrowawayDatabase", gone ? Status.Passed : Status.Failed, new BsonDocument("database", databaseName));
            }
            catch (Exception ex)
            {
                report.Add("cleanup.dropThrowawayDatabase", Status.Failed, new BsonDocument("database", databaseName), ex);
            }
        }

        private static BsonDocument CompressionCounters(IMongoDatabase admin)
        {
            try
            {
                BsonDocument status = admin.RunCommand<BsonDocument>(new BsonDocument("serverStatus", 1));
                BsonValue network;
                BsonValue compression;
                if (status.TryGetValue("network", out network) && network.IsBsonDocument && network.AsBsonDocument.TryGetValue("compression", out compression) && compression.IsBsonDocument)
                {
                    return compression.AsBsonDocument;
                }
            }
            catch (MongoException)
            {
            }

            return new BsonDocument();
        }

        private static long Delta(BsonDocument before, BsonDocument after, string compressor, string direction, string counter)
        {
            return Counter(after, compressor, direction, counter) - Counter(before, compressor, direction, counter);
        }

        private static long Counter(BsonDocument counters, string compressor, string direction, string counter)
        {
            BsonValue a, b, c;
            if (counters.TryGetValue(compressor, out a) && a.IsBsonDocument && a.AsBsonDocument.TryGetValue(direction, out b) && b.IsBsonDocument && b.AsBsonDocument.TryGetValue(counter, out c) && c.IsNumeric)
            {
                return c.ToInt64();
            }

            return 0;
        }

        private static BsonDocument SyntheticDocument(int seq, string label)
        {
            return new BsonDocument
            {
                { "_id", ObjectId.GenerateNewId() },
                { "seq", seq },
                { "label", label },
                { "text", "Synthetic record " + seq + " \u2013 \u00e9\u00e8\u00ea \u00fc\u00f1\u00ee\u00e7\u00f8d\u00e9 \u65e5\u672c\u8a9e \u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u0939\u093f\u0928\u094d\u0926\u0940 \ud83d\ude00" },
                { "int32", int.MaxValue - seq },
                { "int32Negative", int.MinValue + seq },
                { "int64", 9007199254740993L + seq },
                { "double", Math.PI * (seq + 1) },
                // 34 significant digits: the Decimal128 maximum precision.
                { "decimal128", new BsonDecimal128(Decimal128.Parse("1234567890123456789.01234567890123" + seq)) },
                { "dateUtc", new BsonDateTime(new DateTime(2025, 1, 15, 8, 30, 45, 678, DateTimeKind.Utc).AddMinutes(seq)) },
                { "nullValue", BsonNull.Value },
                { "flag", seq % 2 == 0 },
                { "status", "new" },
                { "counter", (long)seq },
                { "nested", new BsonDocument { { "level", 1 }, { "inner", new BsonDocument { { "level", 2 }, { "values", new BsonArray { 1, 2.5, "three" } } } } } },
                { "array", new BsonArray { seq, "item-" + seq, BsonNull.Value, new BsonDocument("k", seq), new BsonArray { true, false } } },
                // Preserve legacy subtype 3 alongside standard subtype 4 during driver-major compatibility checks.
                { "uuid", new BsonBinaryData(new Guid(seq + 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11), GuidRepresentation.CSharpLegacy) },
                { "uuidStandard", new BsonBinaryData(new Guid(seq + 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11), GuidRepresentation.Standard) },
                { "blob", new BsonBinaryData(SyntheticPayload(128 * 1024, seq)) }
            };
        }

        private static byte[] SyntheticPayload(int length, int seed)
        {
            // Mostly repetitive text with a sprinkle of pseudo-random bytes, so every codec has something to compress.
            byte[] pattern = Encoding.UTF8.GetBytes("Epi Info synthetic payload; no real data. 0123456789 ");
            byte[] bytes = new byte[length];
            Random random = new Random(seed);
            for (int i = 0; i < length; i++)
            {
                bytes[i] = i % 97 == 0 ? (byte)random.Next(256) : pattern[i % pattern.Length];
            }

            return bytes;
        }

        // Compare what the server stores (subtype and bytes); driver 2.x BsonBinaryData.Equals also compared a client-side tag.
        private static bool BinaryEquals(BsonBinaryData expected, BsonBinaryData actual)
        {
            return expected.SubType == actual.SubType && expected.Bytes.SequenceEqual(actual.Bytes);
        }

        private static string Describe(BsonValue value)
        {
            if (value.IsBsonBinaryData && value.AsBsonBinaryData.Bytes.Length <= 32)
            {
                BsonBinaryData b = value.AsBsonBinaryData;
                return "Binary(subtype " + b.SubType + ", " + BitConverter.ToString(b.Bytes).Replace("-", "") + ")";
            }
            return value.BsonType.ToString();
        }

        private static bool Compare(List<BsonDocument> expected, List<BsonDocument> actual, out BsonArray mismatches)
        {
            mismatches = new BsonArray();
            if (expected.Count != actual.Count)
            {
                mismatches.Add("count expected " + expected.Count + " actual " + actual.Count);
                return false;
            }

            for (int i = 0; i < expected.Count; i++)
            {
                foreach (BsonElement element in expected[i])
                {
                    BsonValue value;
                    if (!actual[i].TryGetValue(element.Name, out value))
                    {
                        mismatches.Add("seq " + i + " missing " + element.Name);
                    }
                    else if (value.BsonType != element.Value.BsonType || !(element.Value.IsBsonBinaryData ? BinaryEquals(element.Value.AsBsonBinaryData, value.AsBsonBinaryData) : value.Equals(element.Value)))
                    {
                        mismatches.Add("seq " + i + " field " + element.Name + " expected " + Describe(element.Value) + " got " + Describe(value));
                    }
                }

                if (actual[i].ElementCount != expected[i].ElementCount)
                {
                    mismatches.Add("seq " + i + " element count expected " + expected[i].ElementCount + " got " + actual[i].ElementCount);
                }
            }

            return mismatches.Count == 0;
        }

        private static BsonArray DescribeLoadedAssemblies()
        {
            return new BsonArray(AppDomain.CurrentDomain.GetAssemblies()
                .Where(a => ReportedAssemblies.Contains(a.GetName().Name, StringComparer.OrdinalIgnoreCase))
                .OrderBy(a => a.GetName().Name)
                .Select(a => new BsonDocument { { "identity", a.FullName }, { "location", a.IsDynamic ? "" : a.Location } }));
        }

        private static string ServerName(CompressorType type)
        {
            switch (type)
            {
                case CompressorType.Snappy: return "snappy";
                case CompressorType.Zlib: return "zlib";
                case CompressorType.ZStandard: return "zstd";
                default: return type.ToString().ToLowerInvariant();
            }
        }

        private static Version VersionOf(string name)
        {
            try { return Assembly.Load(name).GetName().Version; } catch { return null; }
        }

        private static BsonValue Str(Version version)
        {
            return version == null ? (BsonValue)BsonNull.Value : version.ToString();
        }

        private static string FileVersion(Assembly assembly)
        {
            try { return FileVersionInfo.GetVersionInfo(assembly.Location).FileVersion ?? ""; } catch { return ""; }
        }

        private static string InformationalVersion(Assembly assembly)
        {
            AssemblyInformationalVersionAttribute attribute = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>();
            return attribute == null ? "" : attribute.InformationalVersion;
        }

        private static BsonValue Safe(Func<string> action)
        {
            try { return action() ?? ""; } catch (Exception ex) { return "error: " + ex.GetType().Name; }
        }
    }

    internal enum Status
    {
        Passed,
        Failed,
        Skipped,
        Info
    }

    internal sealed class Report
    {
        private readonly Redactor redactor;
        private readonly BsonArray checks = new BsonArray();
        private readonly object gate = new object();
        private readonly Stopwatch clock = Stopwatch.StartNew();

        public Report(Redactor redactor)
        {
            this.redactor = redactor;
            Root = new BsonDocument
            {
                { "schema", "epiinfo.desktop.mongodb.roundtrip/1" },
                { "timestampUtc", DateTime.UtcNow.ToString("o") },
                { "machine", Environment.MachineName },
                { "status", "Running" }
            };
        }

        public BsonDocument Root { get; private set; }

        // Skipped live checks count as failure: the harness only passes with real server evidence.
        public Status OverallStatus
        {
            get
            {
                lock (gate)
                {
                    return checks.Any(c => c["status"] == "Failed" || c["status"] == "Skipped") ? Status.Failed : Status.Passed;
                }
            }
        }

        public void Add(string name, Status status, BsonDocument details, Exception error = null)
        {
            BsonDocument check = new BsonDocument { { "name", name }, { "status", status.ToString() }, { "elapsedMs", clock.ElapsedMilliseconds } };
            if (details != null) { check["details"] = details; }
            if (error != null)
            {
                Exception root = error;
                while (root.InnerException != null && (root is AggregateException || root is TargetInvocationException || root is TypeInitializationException)) { root = root.InnerException; }
                check["error"] = new BsonDocument
                {
                    { "type", root.GetType().FullName },
                    { "message", redactor.Scrub(root.Message) },
                    { "detail", redactor.Scrub(error.ToString()) }
                };
            }

            lock (gate) { checks.Add(check); }
            Console.WriteLine("[{0}] {1}{2}", status, name, error == null ? "" : " - " + redactor.Scrub(error.GetType().Name + ": " + FirstLine(error.Message)));
        }

        public void Write(string path)
        {
            lock (gate)
            {
                Root["checks"] = checks;
                Root["status"] = OverallStatus == Status.Passed ? "Passed" : "Failed";
                Root["completedUtc"] = DateTime.UtcNow.ToString("o");
                string json = redactor.Scrub(Root.ToJson(new JsonWriterSettings { Indent = true, OutputMode = JsonOutputMode.RelaxedExtendedJson }));
                string directory = Path.GetDirectoryName(Path.GetFullPath(path));
                if (!string.IsNullOrEmpty(directory)) { Directory.CreateDirectory(directory); }
                File.WriteAllText(path, json, new UTF8Encoding(false));
            }
        }

        private static string FirstLine(string text)
        {
            if (text == null) { return ""; }
            int index = text.IndexOfAny(new[] { '\r', '\n' });
            return index < 0 ? text : text.Substring(0, index);
        }
    }

    internal sealed class Redactor
    {
        private static readonly Regex UserInfo = new Regex(@"(mongodb(?:\+srv)?://)[^@/\s]+@", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private readonly List<string> secrets = new List<string>();

        public void AddSecret(string secret)
        {
            if (string.IsNullOrEmpty(secret)) { return; }
            lock (secrets)
            {
                if (!secrets.Contains(secret)) { secrets.Add(secret); }
                secrets.Sort((a, b) => b.Length.CompareTo(a.Length));
            }
        }

        public string Scrub(string text)
        {
            if (string.IsNullOrEmpty(text)) { return text ?? ""; }
            lock (secrets)
            {
                foreach (string secret in secrets)
                {
                    text = text.Replace(secret, "***");
                    string escaped = Uri.EscapeDataString(secret);
                    if (escaped != secret) { text = text.Replace(escaped, "***"); }
                }
            }

            return UserInfo.Replace(text, "$1***@");
        }
    }
}
