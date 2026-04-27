using System.Net.Http.Headers;
using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans Power BI workspaces for access permissions.
/// Uses the Power BI REST API via Graph proxy (users can access via delegated Graph token).
/// </summary>
public sealed class PowerBIScanner : IScanProvider
{
    public string Category => "PowerBI";

    private readonly DelegatedAuth _auth;
    private readonly HttpClient _http;

    public PowerBIScanner(DelegatedAuth auth)
    {
        _auth = auth;
        _http = new HttpClient();
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Enumerating Power BI workspaces...", 3);

        // Try the Power BI admin API first for full workspace enumeration
        var pbiWorkspaces = new List<JsonElement>();
        try
        {
            var token = await _auth.GetAccessTokenAsync("powerbi", ct);
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.powerbi.com/v1.0/myorg/admin/groups?$top=5000&$expand=users");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var resp = await _http.SendAsync(req, ct);
            if (resp.IsSuccessStatusCode)
            {
                var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
                if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
                {
                    foreach (var ws in val.EnumerateArray())
                        pbiWorkspaces.Add(ws.Clone());
                }
            }
            else
            {
                context.ReportProgress("Power BI Admin API not available (may need Power BI admin role). Falling back to user-scoped enumeration.", 3);
            }
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Power BI Admin API failed: {ex.Message}. Falling back to user-scoped.", 3);
        }

        if (pbiWorkspaces.Count > 0)
        {
            context.SetTotalTargets(pbiWorkspaces.Count);
            context.ReportProgress($"Found {pbiWorkspaces.Count} Power BI workspaces via Admin API.", 3);

            foreach (var ws in pbiWorkspaces)
            {
                ct.ThrowIfCancellationRequested();

                var wsId = ws.TryGetProperty("id", out var wid) ? wid.GetString() ?? "" : "";
                var wsName = ws.TryGetProperty("name", out var wn) ? wn.GetString() ?? "" : "";

                if (ws.TryGetProperty("users", out var users) && users.ValueKind == JsonValueKind.Array)
                {
                    foreach (var user in users.EnumerateArray())
                    {
                        var entry = MapPbiWorkspaceUser(user, wsName, wsId);
                        if (entry != null) yield return entry;
                    }
                }

                context.CompleteTarget();
            }
        }
        else
        {
            // Fallback: enumerate user's own workspaces (non-admin)
            var fallbackEntries = new List<PermissionEntry>();
            try
            {
                var token = await _auth.GetAccessTokenAsync("powerbi", ct);
                using var req = new HttpRequestMessage(HttpMethod.Get,
                    "https://api.powerbi.com/v1.0/myorg/groups?$expand=users");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

                var resp = await _http.SendAsync(req, ct);
                if (resp.IsSuccessStatusCode)
                {
                    var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
                    if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
                    {
                        context.SetTotalTargets(val.GetArrayLength());
                        foreach (var ws in val.EnumerateArray())
                        {
                            var wsId = ws.TryGetProperty("id", out var wid) ? wid.GetString() ?? "" : "";
                            var wsName = ws.TryGetProperty("name", out var wn) ? wn.GetString() ?? "" : "";

                            if (ws.TryGetProperty("users", out var users) && users.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var user in users.EnumerateArray())
                                {
                                    var entry = MapPbiWorkspaceUser(user, wsName, wsId);
                                    if (entry != null) fallbackEntries.Add(entry);
                                }
                            }

                            context.CompleteTarget();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Failed to enumerate user Power BI workspaces: {ex.Message}", 2);
            }

            foreach (var e in fallbackEntries) yield return e;
        }

        context.ReportProgress("Completed Power BI scan.", 3);
    }

    private static PermissionEntry? MapPbiWorkspaceUser(JsonElement user, string workspaceName, string workspaceId)
    {
        var email = user.TryGetProperty("emailAddress", out var e) ? e.GetString() ?? "" : "";
        var displayName = user.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
        var role = user.TryGetProperty("groupUserAccessRight", out var r) ? r.GetString() ?? "" : "";
        var principalType = user.TryGetProperty("principalType", out var pt) ? pt.GetString() ?? "" : "";
        var identifier = user.TryGetProperty("identifier", out var id) ? id.GetString() ?? "" : "";

        if (string.IsNullOrEmpty(email) && string.IsNullOrEmpty(displayName) && string.IsNullOrEmpty(identifier))
            return null;

        return new PermissionEntry
        {
            TargetPath = $"PowerBI/{workspaceName}",
            TargetType = "Workspace",
            TargetId = workspaceId,
            PrincipalEntraUpn = email,
            PrincipalEntraId = identifier,
            PrincipalSysName = displayName,
            PrincipalType = MapPrincipalType(principalType),
            PrincipalRole = role,
            Through = "WorkspaceAccess",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    private static string MapPrincipalType(string pbiType) => pbiType?.ToLower() switch
    {
        "user" => "User",
        "group" => "SecurityGroup",
        "app" => "Application",
        _ => "User"
    };
}
