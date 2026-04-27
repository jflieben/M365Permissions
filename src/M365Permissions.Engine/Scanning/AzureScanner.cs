using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans Azure RBAC role assignments across subscriptions.
/// Uses the Azure Resource Manager REST API (management.azure.com).
/// </summary>
public sealed class AzureScanner : IScanProvider
{
    public string Category => "Azure";

    private readonly DelegatedAuth _auth;
    private readonly HttpClient _http;

    public AzureScanner(DelegatedAuth auth)
    {
        _auth = auth;
        _http = new HttpClient();
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Enumerating Azure subscriptions...", 3);

        // Get all accessible subscriptions
        var subscriptions = new List<(string Id, string Name)>();
        try
        {
            var token = await _auth.GetAccessTokenAsync("azure", ct);
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://management.azure.com/subscriptions?api-version=2022-12-01");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var resp = await _http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode)
            {
                context.ReportProgress($"Cannot access Azure Management API (HTTP {(int)resp.StatusCode}). Ensure the user has Reader access to subscriptions.", 2);
                yield break;
            }

            var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
            {
                foreach (var sub in val.EnumerateArray())
                {
                    var subId = sub.TryGetProperty("subscriptionId", out var sid) ? sid.GetString() ?? "" : "";
                    var displayName = sub.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                    if (!string.IsNullOrEmpty(subId))
                        subscriptions.Add((subId, displayName));
                }
            }
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Failed to enumerate Azure subscriptions: {ex.Message}", 2);
            yield break;
        }

        if (subscriptions.Count == 0)
        {
            context.ReportProgress("No Azure subscriptions found (or no access).", 3);
            yield break;
        }

        context.SetTotalTargets(subscriptions.Count);
        context.ReportProgress($"Found {subscriptions.Count} Azure subscription(s).", 3);

        // Cache role definitions to avoid repeated lookups
        var roleCache = new Dictionary<string, string>();
        var allEntries = new List<PermissionEntry>();

        foreach (var (subId, subName) in subscriptions)
        {
            ct.ThrowIfCancellationRequested();
            context.ReportProgress($"Scanning subscription: {subName}...", 4);

            // Get role assignments for this subscription
            var assignments = new List<JsonElement>();
            try
            {
                var token = await _auth.GetAccessTokenAsync("azure", ct);
                var url = $"https://management.azure.com/subscriptions/{subId}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&$filter=atScope()";

                while (url != null)
                {
                    ct.ThrowIfCancellationRequested();
                    using var req = new HttpRequestMessage(HttpMethod.Get, url);
                    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

                    var resp = await _http.SendAsync(req, ct);
                    if (!resp.IsSuccessStatusCode) break;

                    var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
                    if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var a in val.EnumerateArray())
                            assignments.Add(a.Clone());
                    }

                    url = doc.RootElement.TryGetProperty("nextLink", out var nl) ? nl.GetString() : null;
                }
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Error scanning subscription {subName}: {ex.Message}", 2);
                context.FailTarget();
                continue;
            }

            // Resolve role definitions for this subscription
            if (roleCache.Count == 0)
            {
                try
                {
                    await LoadRoleDefinitionsAsync(subId, roleCache, ct);
                }
                catch { /* continue with raw role IDs */ }
            }

            foreach (var assignment in assignments)
            {
                if (!assignment.TryGetProperty("properties", out var props)) continue;

                var roleDefId = props.TryGetProperty("roleDefinitionId", out var rdi) ? rdi.GetString() ?? "" : "";
                var principalId = props.TryGetProperty("principalId", out var pid) ? pid.GetString() ?? "" : "";
                var principalType = props.TryGetProperty("principalType", out var pt) ? pt.GetString() ?? "" : "";
                var scope = props.TryGetProperty("scope", out var sc) ? sc.GetString() ?? "" : "";

                var roleName = ResolveRoleName(roleDefId, roleCache);

                allEntries.Add(new PermissionEntry
                {
                    TargetPath = $"Azure/{subName}{FormatScope(scope, subId)}",
                    TargetType = DetermineTargetType(scope),
                    TargetId = scope,
                    PrincipalEntraId = principalId,
                    PrincipalType = MapPrincipalType(principalType),
                    PrincipalRole = roleName,
                    Through = "AzureRBAC",
                    AccessType = "Allow",
                    Tenure = "Permanent"
                });
            }

            context.CompleteTarget();
            context.ReportProgress($"Found {assignments.Count} role assignments in '{subName}'.", 4);
        }

        // Resolve principal display names via Graph API
        if (allEntries.Count > 0)
        {
            context.ReportProgress($"Resolving {allEntries.Count} principal display names via Graph...", 3);
            var principalIds = allEntries
                .Where(e => !string.IsNullOrEmpty(e.PrincipalEntraId))
                .Select(e => e.PrincipalEntraId!)
                .Distinct()
                .ToList();
            var nameCache = await ResolvePrincipalNamesAsync(principalIds, ct);
            foreach (var entry in allEntries)
            {
                if (!string.IsNullOrEmpty(entry.PrincipalEntraId) &&
                    nameCache.TryGetValue(entry.PrincipalEntraId, out var displayName))
                {
                    entry.PrincipalSysName = displayName;
                }
                else if (string.IsNullOrEmpty(entry.PrincipalSysName))
                {
                    entry.PrincipalSysName = entry.PrincipalEntraId ?? "";
                }
            }
        }

        foreach (var entry in allEntries)
            yield return entry;

        context.ReportProgress("Completed Azure RBAC scan.", 3);
    }

    private async Task LoadRoleDefinitionsAsync(string subscriptionId, Dictionary<string, string> cache, CancellationToken ct)
    {
        var token = await _auth.GetAccessTokenAsync("azure", ct);
        using var req = new HttpRequestMessage(HttpMethod.Get,
            $"https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var resp = await _http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) return;

        var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
        if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
        {
            foreach (var rd in val.EnumerateArray())
            {
                var id = rd.TryGetProperty("id", out var rid) ? rid.GetString() ?? "" : "";
                var name = "";
                if (rd.TryGetProperty("properties", out var rdp) && rdp.TryGetProperty("roleName", out var rn))
                    name = rn.GetString() ?? "";
                if (!string.IsNullOrEmpty(id) && !string.IsNullOrEmpty(name))
                    cache[id] = name;
            }
        }
    }

    private static string ResolveRoleName(string roleDefinitionId, Dictionary<string, string> cache)
    {
        if (cache.TryGetValue(roleDefinitionId, out var name))
            return name;

        // Extract the role definition GUID from the full resource ID
        var parts = roleDefinitionId.Split('/');
        var guid = parts.Length > 0 ? parts[^1] : roleDefinitionId;

        // Check by GUID suffix too
        foreach (var (key, val) in cache)
        {
            if (key.EndsWith(guid, StringComparison.OrdinalIgnoreCase))
                return val;
        }

        return guid; // Return GUID if we can't resolve
    }

    private static string MapPrincipalType(string? azureType) => azureType switch
    {
        "User" => "User",
        "Group" => "SecurityGroup",
        "ServicePrincipal" => "Application",
        "ForeignGroup" => "External Group",
        "Device" => "Device",
        _ => azureType ?? "Unknown"
    };

    private static string DetermineTargetType(string scope)
    {
        if (string.IsNullOrEmpty(scope)) return "Unknown";
        if (scope.Contains("/resourceGroups/", StringComparison.OrdinalIgnoreCase))
        {
            if (scope.Contains("/providers/", StringComparison.OrdinalIgnoreCase))
                return "Resource";
            return "ResourceGroup";
        }
        if (scope.Contains("/managementGroups/", StringComparison.OrdinalIgnoreCase))
            return "ManagementGroup";
        return "Subscription";
    }

    private static string FormatScope(string scope, string subscriptionId)
    {
        // Strip the leading /subscriptions/{id} to make it shorter
        var prefix = $"/subscriptions/{subscriptionId}";
        if (scope.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            var remainder = scope[prefix.Length..];
            return string.IsNullOrEmpty(remainder) ? "" : remainder;
        }
        return scope;
    }

    /// <summary>
    /// Resolve principal GUIDs to display names via Graph /directoryObjects/getByIds (up to 1000 per call).
    /// </summary>
    private async Task<Dictionary<string, string>> ResolvePrincipalNamesAsync(
        List<string> principalIds, CancellationToken ct)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (principalIds.Count == 0) return result;

        string token;
        try
        {
            token = await _auth.GetAccessTokenAsync("graph", ct);
        }
        catch
        {
            return result; // Can't resolve without Graph token — fall back to GUIDs
        }

        // Process in chunks of 1000 (Graph API limit for getByIds)
        for (int i = 0; i < principalIds.Count; i += 1000)
        {
            ct.ThrowIfCancellationRequested();
            var chunk = principalIds.Skip(i).Take(1000).ToList();

            try
            {
                var body = JsonSerializer.Serialize(new
                {
                    ids = chunk,
                    types = new[] { "user", "group", "servicePrincipal" }
                });

                using var req = new HttpRequestMessage(HttpMethod.Post,
                    "https://graph.microsoft.com/v1.0/directoryObjects/getByIds");
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                req.Content = new StringContent(body, Encoding.UTF8, "application/json");

                var resp = await _http.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) continue;

                var doc = await JsonDocument.ParseAsync(
                    await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
                if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
                {
                    foreach (var obj in val.EnumerateArray())
                    {
                        var id = obj.TryGetProperty("id", out var oid) ? oid.GetString() ?? "" : "";
                        var displayName = obj.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                        var upn = obj.TryGetProperty("userPrincipalName", out var u) ? u.GetString() ?? "" : "";

                        if (!string.IsNullOrEmpty(id))
                        {
                            // Prefer "displayName (UPN)" for users, just displayName for groups/SPs
                            var name = !string.IsNullOrEmpty(upn) && !string.IsNullOrEmpty(displayName)
                                ? $"{displayName} ({upn})"
                                : !string.IsNullOrEmpty(displayName) ? displayName
                                : upn;
                            if (!string.IsNullOrEmpty(name))
                                result[id] = name;
                        }
                    }
                }
            }
            catch { /* continue with remaining chunks */ }
        }

        return result;
    }
}
