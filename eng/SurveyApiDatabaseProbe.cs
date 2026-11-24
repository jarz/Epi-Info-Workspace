using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Http;
using System.Web.Http.Dependencies;
using Epi.Web.SurveyAPI.EF;
using Epi.Web.SurveyAPI.Controllers;
using Epi.Web.SurveyAPI.MessageHandlers;
using Epi.Web.SurveyAPI.Models;
using Epi.Web.SurveyAPI.Repository;
using Epi.Web.SurveyAPI.Web.Common.BusinessObject;
using Epi.Web.SurveyAPI.Web.Common.Security;

internal static class SurveyApiDatabaseProbe
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
        Console.WriteLine("PASS: " + message);
    }

    private static void CheckSqlFailure(Action action, string message)
    {
        try { action(); }
        catch (Exception error)
        {
            for (Exception current = error; current != null; current = current.InnerException)
            {
                if (current is SqlException)
                {
                    Check(true, message);
                    return;
                }
            }
            throw;
        }
        throw new InvalidOperationException(message);
    }

    private static HttpStatusCode Send(SurveyResponseRepository repository, string key, Guid surveyId)
    {
        using (var configuration = new HttpConfiguration())
        using (var request = new HttpRequestMessage(HttpMethod.Post, "https://localhost/api/surveyResponse"))
        using (var handler = new APIKeyHandler { InnerHandler = new TerminalHandler() })
        using (var invoker = new HttpMessageInvoker(handler))
        {
            configuration.DependencyResolver = new Resolver(repository);
            request.SetConfiguration(configuration);
            request.Headers.Add(SurveyApiAuthentication.HeaderName, key);
            request.Headers.Add("SurveyId", surveyId.ToString());
            using (var response = invoker.SendAsync(request, CancellationToken.None).GetAwaiter().GetResult())
                return response.StatusCode;
        }
    }

    private static Tuple<HttpStatusCode, string> Post(
        SurveyResponseRepository repository, string key, Guid surveyId, Guid responseId)
    {
        using (var configuration = new HttpConfiguration())
        {
            configuration.DependencyResolver = new Resolver(repository);
            configuration.IncludeErrorDetailPolicy = IncludeErrorDetailPolicy.Always;
            configuration.Routes.MapHttpRoute(
                name: "DefaultApi",
                routeTemplate: "api/{controller}/{id}",
                defaults: new { id = RouteParameter.Optional });
            using (var server = new HttpServer(configuration))
            using (var handler = new APIKeyHandler { InnerHandler = server })
            using (var invoker = new HttpMessageInvoker(handler))
            using (var request = new HttpRequestMessage(HttpMethod.Post, "https://localhost/api/SurveyResponse"))
            {
                request.SetConfiguration(configuration);
                request.Headers.Add(SurveyApiAuthentication.HeaderName, key);
                request.Headers.Add("SurveyId", surveyId.ToString());
                request.Content = new StringContent(
                    "{\"responseid\":\"" + responseId + "\",\"Question1\":\"database answer\"}",
                    Encoding.UTF8, "application/json");
                using (var response = invoker.SendAsync(request, CancellationToken.None).GetAwaiter().GetResult())
                    return Tuple.Create(response.StatusCode,
                        response.Content.ReadAsStringAsync().GetAwaiter().GetResult());
            }
        }
    }

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 2 && args[0] == "--unavailable")
            {
                var missingDatabaseRepository = new SurveyResponseRepository();
                var id = Guid.Parse(args[1]);
                var key = Environment.GetEnvironmentVariable("EPI_SURVEY_TEST_API_KEY");
                CheckSqlFailure(() => missingDatabaseRepository.GetSurveyInfoById(id.ToString()),
                                "repository surfaces an unavailable database");
                CheckSqlFailure(() => Send(missingDatabaseRepository, key, id),
                                "authenticated handler surfaces an unavailable database");
                return 0;
            }
            var surveyId = Guid.Parse(args[0]);
            var publisherKey = Guid.Parse(args[1]);
            var organizationKey = Guid.Parse(args[2]);
            var responseId = Guid.Parse(args[3]);
            var apiKey = Environment.GetEnvironmentVariable("EPI_SURVEY_TEST_API_KEY");
            var repository = new SurveyResponseRepository();
            var info = repository.GetSurveyInfoById(surveyId.ToString());
            Check(info != null && info.SurveyId == surveyId.ToString() &&
                  info.UserPublishKey == publisherKey && info.OrganizationKey == organizationKey,
                  "repository reads survey and decrypts organization key");
            Check(repository.GetSurveyInfoById(Guid.NewGuid().ToString()) == null,
                  "missing survey returns no result");
            Check(Send(repository, apiKey, surveyId) == HttpStatusCode.OK &&
                  repository.SurveyId == surveyId && repository.PublisherKey == publisherKey &&
                  repository.OrgKey == organizationKey, "authenticated handler loads database-backed survey");
            Check(Send(repository, apiKey, Guid.NewGuid()) == HttpStatusCode.Unauthorized,
                  "authenticated handler rejects unknown survey");
            var wrongKey = (apiKey[0] == '0' ? "1" : "0") + apiKey.Substring(1);
            Check(Send(repository, wrongKey, surveyId) == HttpStatusCode.Unauthorized,
                  "handler rejects incorrect API key");
            var surveys = new EntitySurveyInfoDao().GetSurveyInfo(
                new List<string> { surveyId.ToString(), Guid.NewGuid().ToString() });
            Check(surveys.Count == 1 && surveys[0].SurveyId == surveyId.ToString(),
                  "survey lookup skips missing IDs without losing existing results");
            var authorizedSurveys = new EntitySurveyInfoDao().GetSurveyInfoByOrgKeyAndPublishKey(
                surveyId.ToString(), Cryptography.Encrypt(organizationKey.ToString()), publisherKey);
            Check(authorizedSurveys.Count == 1 && authorizedSurveys[0].SurveyId == surveyId.ToString(),
                  "survey publisher and organization keys authorize submission");
            var directSubmission = repository.SetSurveyAnswer(new SurveyAnswerModel
            {
                SurveyId = surveyId, OrgKey = organizationKey, PublisherKey = publisherKey,
                SurveyQuestionAnswerListField = new Dictionary<string, string>
                {
                    { "responseid", Guid.NewGuid().ToString() },
                    { "Question1", "database answer" }
                }
            });
            Check(directSubmission.SurveyResponseID != null,
                  "repository accepts a synthetic answer (status " + directSubmission.Status +
                  ", errors " + string.Join("; ", directSubmission.ErrorMessageList == null
                      ? new string[0]
                      : directSubmission.ErrorMessageList.Select(x => x.Key + "=" + x.Value)) + ")");

            var postResult = Post(repository, apiKey, surveyId, Guid.NewGuid());
            Check(postResult.Item1 == HttpStatusCode.Created &&
                  postResult.Item2.Contains("\"Status\":\"Success\""),
                  "real Web API POST accepts a synthetic survey answer (status " +
                  (int)postResult.Item1 + ", response " + postResult.Item2 + ")");
            var apiResponseId = new System.Text.RegularExpressions.Regex(
                "\"SurveyResponseID\":\"([^\"]+)\"").Match(postResult.Item2);
            Check(apiResponseId.Success, "API response includes the created response ID");
            var apiStored = new EntitySurveyResponseDao().GetSurveyResponse(
                new List<string> { apiResponseId.Groups[1].Value }, publisherKey);
            Check(apiStored.Count == 1 && apiStored[0].XML.Contains("database answer"),
                  "controller request persists its answer through Entity Framework");

            var dao = new EntitySurveyResponseDao();
            var response = new SurveyResponseBO
            {
                SurveyId = surveyId.ToString(), ResponseId = responseId.ToString(),
                XML = "<SurveyResponse><Page><Answer>initial</Answer></Page></SurveyResponse>",
                DateCreated = DateTime.UtcNow, DateUpdated = DateTime.UtcNow,
                Status = 1, RecordSourceId = 4, TemplateXMLSize = 70
            };
            dao.InsertSurveyResponse(response);
            var stored = dao.GetSurveyResponse(new List<string> { responseId.ToString() }, publisherKey);
            Check(stored.Count == 1 && stored[0].SurveyId == surveyId.ToString() &&
                  stored[0].XML.Contains("initial"), "Entity Framework inserts and reads synthetic response");
            response.XML = "<SurveyResponse><Page><Answer>updated</Answer></Page></SurveyResponse>";
            dao.UpdateSurveyResponse(response);
            stored = dao.GetSurveyResponse(new List<string> { responseId.ToString() }, publisherKey);
            Check(stored.Count == 1 && stored[0].XML.Contains("updated"),
                  "Entity Framework updates and reads synthetic response");

            using (var connection = new SqlConnection(DataObjectFactory._ADOConnectionString))
            {
                connection.Open();
                using (var command = connection.CreateCommand())
                {
                    command.CommandText = "SELECT OrganizationKey FROM dbo.Organization WHERE OrganizationId = @id";
                    command.Parameters.AddWithValue("@id", info.OrganizationId);
                    var originalKey = (string)command.ExecuteScalar();
                    command.CommandText = "UPDATE dbo.Organization SET OrganizationKey = @key WHERE OrganizationId = @id";
                    command.Parameters.AddWithValue("@key", "invalid-base64");
                    Check(command.ExecuteNonQuery() == 1, "corrupt synthetic organization key for failure test");
                    try
                    {
                        bool failed = false;
                        try { repository.GetSurveyInfoById(surveyId.ToString()); }
                        catch (FormatException) { failed = true; }
                        Check(failed, "database data errors are not mistaken for an unknown survey");
                        failed = false;
                        try { Send(repository, apiKey, surveyId); }
                        catch (FormatException) { failed = true; }
                        Check(failed, "authenticated handler surfaces database data errors");
                    }
                    finally
                    {
                        command.Parameters["@key"].Value = originalKey;
                        if (command.ExecuteNonQuery() != 1)
                            throw new InvalidOperationException("Failed to restore the synthetic organization key.");
                    }
                }
            }
            Console.WriteLine("Survey API database probe passed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private sealed class TerminalHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK));
        }
    }

    private sealed class Resolver : IDependencyResolver
    {
        private readonly SurveyResponseRepository repository;
        public Resolver(SurveyResponseRepository repository) { this.repository = repository; }
        public object GetService(Type type)
        {
            if (type == typeof(ISurveyResponseRepository)) return repository;
            if (type == typeof(SurveyResponseController)) return new SurveyResponseController(repository);
            return null;
        }
        public IEnumerable<object> GetServices(Type type) { return new object[0]; }
        public IDependencyScope BeginScope() { return this; }
        public void Dispose() { }
    }
}
