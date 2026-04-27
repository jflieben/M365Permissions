using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using M365Permissions.Engine.Auth;

namespace M365Permissions.Engine.Graph;

/// <summary>
/// HTTP client for Microsoft Graph API with automatic pagination, retry, throttling, and batch support.
/// Modeled after V1's new-GraphQuery.ps1 / new-GraphBatchQuery.ps1 patterns.
/// </summary>
public sealed class GraphClient
{
    private readonly DelegatedAuth _auth;
    private readonly HttpClient _http;
    private readonly AdaptiveThrottleManager _throttle;

    private const int DefaultMaxRetries = 5;
    private const int BatchSize = 20;
    private const string GraphBaseUrl = "https://graph.microsoft.com";

    public AdaptiveThrottleManager ThrottleManager => _throttle;

    public GraphClient(DelegatedAuth auth, int maxConcurrency = 5)
    {
        _auth = auth;
        _http = new HttpClient();
        _throttle = new AdaptiveThrottleManager(maxConcurrency, maxConcurrency * 2);
    }

    /// <summary>
    /// Execute a paginated GET query. Returns all pages of results.
    /// Handles @odata.nextLink pagination, 429 throttling with Retry-After, and exponential backoff.
    /// </summary>
    public async IAsyncEnumerable<JsonElement> GetPaginatedAsync(
        string url,
        string? version = "v1.0",
        bool eventualConsistency = false,
        int maxRetries = DefaultMaxRetries,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        var currentUrl = url.StartsWith("http", StringComparison.OrdinalIgnoreCase)
            ? url
            : $"{GraphBaseUrl}/{version}/{url.TrimStart('/')}";

        while (currentUrl != null)
        {
            ct.ThrowIfCancellationRequested();

            var (json, nextLink) = await ExecuteWithRetry(currentUrl, eventualConsistency, maxRetries, ct);
            if (json == null) yield break;

            if (json.Value.TryGetProperty("value", out var valueArray) && valueArray.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in valueArray.EnumerateArray())
                    yield return item;
            }
            else
            {
                yield return json.Value;
            }

            currentUrl = nextLink;
        }
    }

    /// <summary>
    /// Execute a single GET request and return the full response JSON.
    /// </summary>
    public async Task<JsonElement?> GetAsync(string url, string? version = "v1.0",
        bool eventualConsistency = false,
        int maxRetries = DefaultMaxRetries, CancellationToken ct = default)
    {
        var fullUrl = url.StartsWith("http", StringComparison.OrdinalIgnoreCase)
            ? url
            : $"{GraphBaseUrl}/{version}/{url.TrimStart('/')}";

        var (json, _) = await ExecuteWithRetry(fullUrl, eventualConsistency, maxRetries, ct);
        return json;
    }

    /// <summary>
    /// Execute a batch of requests (up to 20 per batch, per Graph API limits).
    /// Returns responses indexed by the request ID.
    /// </summary>
    public async Task<Dictionary<string, JsonElement>> BatchAsync(
        List<BatchRequest> requests,
        string? version = "v1.0",
        CancellationToken ct = default)
    {
        var results = new Dictionary<string, JsonElement>();
        var batchUrl = $"{GraphBaseUrl}/{version}/$batch";

        // Process in chunks of BatchSize
        for (int i = 0; i < requests.Count; i += BatchSize)
        {
            ct.ThrowIfCancellationRequested();

            var chunk = requests.Skip(i).Take(BatchSize).ToList();
            var batchBody = new
            {
                requests = chunk.Select((r, idx) => new
                {
                    id = r.Id ?? (i + idx).ToString(),
                    method = r.Method,
                    url = r.RelativeUrl,
                    headers = r.Headers
                }).ToArray()
            };

            var token = await _auth.GetAccessTokenAsync("graph", ct);
            using var request = new HttpRequestMessage(HttpMethod.Post, batchUrl);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Content = new StringContent(
                JsonSerializer.Serialize(batchBody),
                Encoding.UTF8, "application/json");

            await _throttle.WaitAsync(ct);
            try
            {
                _throttle.RecordRequest();
                var response = await _http.SendAsync(request, ct);
                var responseJson = await JsonDocument.ParseAsync(
                    await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);

                if (responseJson.RootElement.TryGetProperty("responses", out var responses))
                {
                    foreach (var resp in responses.EnumerateArray())
                    {
                        var id = resp.GetProperty("id").GetString()!;
                        var status = resp.GetProperty("status").GetInt32();
                        if (status >= 200 && status < 300 && resp.TryGetProperty("body", out var body))
                        {
                            results[id] = body.Clone();
                        }
                        // Failed items can be retried individually by the caller
                    }
                }
            }
            finally
            {
                _throttle.Release();
            }
        }

        return results;
    }

    private async Task<(JsonElement? json, string? nextLink)> ExecuteWithRetry(
        string url, bool eventualConsistency, int maxRetries, CancellationToken ct)
    {
        for (int attempt = 0; attempt < maxRetries; attempt++)
        {
            ct.ThrowIfCancellationRequested();

            await _throttle.WaitAsync(ct);
            try
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

                if (eventualConsistency)
                {
                    request.Headers.Add("ConsistencyLevel", "eventual");
                    // Append $count=true if not already in URL
                    if (!url.Contains("$count", StringComparison.OrdinalIgnoreCase))
                    {
                        var separator = url.Contains('?') ? "&" : "?";
                        request.RequestUri = new Uri($"{url}{separator}$count=true");
                    }
                }

                _throttle.RecordRequest();
                var response = await _http.SendAsync(request, ct);

                if (response.StatusCode == (HttpStatusCode)429)
                {
                    _throttle.ReportThrottle();
                    var retryAfter = response.Headers.RetryAfter?.Delta
                        ?? TimeSpan.FromSeconds(Math.Pow(5, attempt + 1));
                    await Task.Delay(retryAfter, ct);
                    continue;
                }

                if (response.StatusCode == HttpStatusCode.NotFound)
                    return (null, null);

                if (!response.IsSuccessStatusCode)
                {
                    var errorBody = await response.Content.ReadAsStringAsync(ct);
                    throw new HttpRequestException(
                        $"HTTP {(int)response.StatusCode} {response.ReasonPhrase}: {Truncate(errorBody, 500)}",
                        null, response.StatusCode);
                }

                _throttle.ReportSuccess();

                var doc = await JsonDocument.ParseAsync(
                    await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
                var root = doc.RootElement;

                string? nextLink = null;
                if (root.TryGetProperty("@odata.nextLink", out var nl))
                    nextLink = nl.GetString();
                else if (root.TryGetProperty("odata.nextLink", out var nl2))
                    nextLink = nl2.GetString();

                return (root.Clone(), nextLink);
            }
            catch (HttpRequestException ex) when (attempt < maxRetries - 1 && IsTransientError(ex))
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt + 1)), ct);
            }
            finally
            {
                _throttle.Release();
            }
        }

        return (null, null);
    }

    private static bool IsTransientError(HttpRequestException ex)
    {
        // Only retry on server errors (5xx) and network failures (no status code).
        // Client errors (4xx) like 400, 403, etc. are permanent and should not be retried.
        return ex.StatusCode == null || (int)ex.StatusCode >= 500;
    }

    private static string Truncate(string s, int max)
        => s.Length <= max ? s : s[..max] + "...";
}

public sealed class BatchRequest
{
    public string? Id { get; set; }
    public string Method { get; set; } = "GET";
    public string RelativeUrl { get; set; } = string.Empty;
    public Dictionary<string, string>? Headers { get; set; }
}
