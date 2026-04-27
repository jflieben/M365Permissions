using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using M365Permissions.Engine.Auth;

namespace M365Permissions.Engine.Graph;

/// <summary>
/// REST client for Exchange Online admin API.
/// Uses the InvokeCommand pattern (POST to /adminapi/beta/{org}/InvokeCommand)
/// matching V1's new-ExOQuery.ps1.
/// </summary>
public sealed class ExchangeRestClient
{
    private readonly DelegatedAuth _auth;
    private readonly HttpClient _http;
    private readonly string _baseUrl = "https://outlook.office365.com";

    private const int MaxRetries = 3;
    private const int MaxPageSize = 1000;

    // Exchange Online transient error codes that should be retried even on HTTP 400
    private static readonly string[] TransientErrorCodes = new[]
    {
        "CmdletProxyNotAvailableFailure",
        "ServerBusyException",
        "TransientException",
        "BackendCommunicationException"
    };

    public ExchangeRestClient(DelegatedAuth auth)
    {
        _auth = auth;
        _http = new HttpClient();
    }

    /// <summary>
    /// Execute an Exchange cmdlet via REST API.
    /// Returns all pages of results.
    /// </summary>
    public async Task<List<JsonElement>> InvokeCommandAsync(
        string organization,
        string cmdletName,
        Dictionary<string, object>? parameters = null,
        CancellationToken ct = default)
    {
        var results = new List<JsonElement>();
        string? nextLink = null;
        var url = $"{_baseUrl}/adminapi/beta/{organization}/InvokeCommand";

        for (int attempt = 0; attempt < MaxRetries; attempt++)
        {
            try
            {
                var currentUrl = nextLink ?? url;

                do
                {
                    ct.ThrowIfCancellationRequested();

                    var body = new Dictionary<string, object>
                    {
                        ["CmdletInput"] = new
                        {
                            CmdletName = cmdletName,
                            Parameters = parameters ?? new Dictionary<string, object>()
                        }
                    };

                    var token = await _auth.GetAccessTokenAsync("exchange", ct);
                    using var request = new HttpRequestMessage(HttpMethod.Post, currentUrl);
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    request.Headers.Add("X-CmdletName", cmdletName);
                    request.Headers.Add("Prefer", $"odata.maxpagesize={MaxPageSize}");
                    request.Headers.Add("X-SerializationLevel", "Partial");
                    request.Content = new StringContent(
                        JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

                    var response = await _http.SendAsync(request, ct);

                    if (!response.IsSuccessStatusCode)
                    {
                        var errorBody = await response.Content.ReadAsStringAsync(ct);

                        // Check if this is a known transient Exchange error (even on HTTP 400)
                        var isTransient = TransientErrorCodes.Any(code =>
                            errorBody.Contains(code, StringComparison.OrdinalIgnoreCase));

                        if (isTransient && attempt < MaxRetries - 1)
                        {
                            await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt + 1)), ct);
                            break; // Break inner pagination loop to retry from scratch
                        }

                        throw new HttpRequestException(
                            $"EXO {(int)response.StatusCode} {response.ReasonPhrase} [{cmdletName}]: {Truncate(errorBody, 500)}",
                            null, response.StatusCode);
                    }

                    var doc = await JsonDocument.ParseAsync(
                        await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);

                    var root = doc.RootElement;

                    if (root.TryGetProperty("value", out var valueArray) && valueArray.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in valueArray.EnumerateArray())
                            results.Add(item.Clone());
                    }

                    // Check for pagination
                    nextLink = null;
                    if (root.TryGetProperty("@odata.nextLink", out var nl))
                        nextLink = nl.GetString();
                    else if (root.TryGetProperty("odata.nextLink", out var nl2))
                        nextLink = nl2.GetString();

                    currentUrl = nextLink;

                } while (currentUrl != null);

                return results; // Success, exit retry loop

            }
            catch (HttpRequestException ex) when (
                attempt < MaxRetries - 1 &&
                (ex.StatusCode == null || (int)ex.StatusCode >= 500 ||
                 (ex.Message != null && TransientErrorCodes.Any(code => ex.Message.Contains(code, StringComparison.OrdinalIgnoreCase)))))
            {
                results.Clear(); // Reset partial results before retry
                await Task.Delay(TimeSpan.FromSeconds((attempt + 1) * 2), ct);
            }
        }

        return results;
    }

    private static string Truncate(string s, int max)
        => s.Length <= max ? s : s[..max] + "...";

    /// <summary>Get all mailboxes in the tenant.</summary>
    public Task<List<JsonElement>> GetMailboxesAsync(string organization, CancellationToken ct = default)
    {
        return InvokeCommandAsync(organization, "Get-Mailbox",
            new Dictionary<string, object>
            {
                ["ResultSize"] = "Unlimited"
            }, ct);
    }

    /// <summary>Get mailbox permissions for a specific mailbox.</summary>
    public Task<List<JsonElement>> GetMailboxPermissionsAsync(string organization, string identity, CancellationToken ct = default)
    {
        return InvokeCommandAsync(organization, "Get-MailboxPermission",
            new Dictionary<string, object>
            {
                ["Identity"] = identity
            }, ct);
    }

    /// <summary>Get recipient permissions (SendAs).</summary>
    public Task<List<JsonElement>> GetRecipientPermissionsAsync(string organization, string identity, CancellationToken ct = default)
    {
        return InvokeCommandAsync(organization, "Get-RecipientPermission",
            new Dictionary<string, object>
            {
                ["Identity"] = identity
            }, ct);
    }

    /// <summary>Get mailbox folder statistics to enumerate all folders.</summary>
    public Task<List<JsonElement>> GetMailboxFolderStatisticsAsync(string organization, string identity, CancellationToken ct = default)
    {
        return InvokeCommandAsync(organization, "Get-MailboxFolderStatistics",
            new Dictionary<string, object>
            {
                ["Identity"] = identity
            }, ct);
    }

    /// <summary>Get folder-level permissions for a specific mailbox folder.</summary>
    public Task<List<JsonElement>> GetMailboxFolderPermissionsAsync(string organization, string folderIdentity, CancellationToken ct = default)
    {
        return InvokeCommandAsync(organization, "Get-MailboxFolderPermission",
            new Dictionary<string, object>
            {
                ["Identity"] = folderIdentity
            }, ct);
    }
}
