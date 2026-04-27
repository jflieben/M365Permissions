using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans Microsoft Purview / Security &amp; Compliance Center role groups and their members.
/// Uses the compliance-specific endpoint (ps.compliance.protection.outlook.com) with regional discovery,
/// matching the Connect-IPPSSession pattern from ExchangeOnlineManagement.
/// </summary>
public sealed class PurviewScanner : IScanProvider
{
    public string Category => "Purview";

    private readonly DelegatedAuth _auth;
    private readonly HttpClient _http;

    private const string ComplianceBaseHost = "ps.compliance.protection.outlook.com";
    private const int MaxRetries = 3;

    // Cache the discovered regional compliance URL prefix
    private string? _regionalPrefix;
    private string? _resolvedTenantId;

    public PurviewScanner(DelegatedAuth auth)
    {
        _auth = auth;
        _http = new HttpClient(new HttpClientHandler
        {
            AllowAutoRedirect = false
        });
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Scanning Purview compliance role groups...", 3);

        // Step 1: Discover regional compliance endpoint via redirect
        var complianceUrl = await DiscoverComplianceEndpointAsync(context, ct);
        if (complianceUrl == null)
        {
            context.ReportProgress("Cannot discover Purview compliance endpoint. Skipping Purview scan.", 2);
            yield break;
        }

        // Step 2: Get all role groups from the compliance center
        var roleGroups = new List<ComplianceRoleGroup>();
        await GetRoleGroupsAsync(context, complianceUrl, roleGroups, ct);

        if (roleGroups.Count == 0)
        {
            context.ReportProgress("No Compliance role groups found.", 3);
            yield break;
        }

        context.SetTotalTargets(roleGroups.Count);
        context.ReportProgress($"Found {roleGroups.Count} Compliance role group(s). Enumerating members...", 3);

        // Step 3: For each role group, get its members
        var allEntries = new List<PermissionEntry>();

        foreach (var group in roleGroups)
        {
            ct.ThrowIfCancellationRequested();
            context.ReportProgress($"Scanning role group: {group.Name}...", 4);

            try
            {
                await GetRoleGroupMembersAsync(context, complianceUrl, group, allEntries, ct);
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Failed to enumerate members of '{group.Name}': {ex.Message}", 2);
                context.FailTarget();
                continue;
            }

            context.CompleteTarget();
        }

        foreach (var entry in allEntries)
            yield return entry;

        context.ReportProgress($"Completed Purview scan. Found {allEntries.Count} role assignments.", 3);
    }

    /// <summary>
    /// Discover the regional compliance endpoint via 302 redirect.
    /// The base URL redirects to a regional server (e.g. nam12b.ps.compliance.protection.outlook.com).
    /// </summary>
    private async Task<string?> DiscoverComplianceEndpointAsync(ScanContext context, CancellationToken ct)
    {
        if (_regionalPrefix != null)
            return BuildComplianceUrl(_regionalPrefix, _resolvedTenantId!);

        try
        {
            var token = await _auth.GetAccessTokenAsync("compliance", ct);
            var tenantId = _auth.TenantId ?? context.TenantDomain;
            _resolvedTenantId = tenantId;

            var discoveryUrl = $"https://{ComplianceBaseHost}/adminapi/beta/{tenantId}/InvokeCommand";

            using var req = new HttpRequestMessage(HttpMethod.Post, discoveryUrl);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            req.Headers.Add("X-CmdletName", "Get-RoleGroup");
            req.Headers.Add("X-ClientApplication", "ExoManagementModule");
            req.Content = new StringContent(
                JsonSerializer.Serialize(new
                {
                    CmdletInput = new
                    {
                        CmdletName = "Get-RoleGroup",
                        Parameters = new Dictionary<string, object> { ["ResultSize"] = "1" }
                    }
                }), Encoding.UTF8, "application/json");

            var resp = await _http.SendAsync(req, ct);

            if (resp.StatusCode == HttpStatusCode.Redirect || resp.StatusCode == HttpStatusCode.MovedPermanently)
            {
                var location = resp.Headers.Location?.ToString();
                if (!string.IsNullOrEmpty(location))
                {
                    // Extract regional prefix: "https://nam12b.ps.compliance.protection.outlook.com/..."
                    // → "nam12b"
                    var uri = new Uri(location);
                    _regionalPrefix = uri.Host.Split('.')[0];
                    context.ReportProgress($"Discovered compliance endpoint region: {_regionalPrefix}", 4);
                    return BuildComplianceUrl(_regionalPrefix, tenantId);
                }
            }

            // Some tenants may not redirect — try direct
            if (resp.IsSuccessStatusCode)
            {
                context.ReportProgress("Compliance endpoint responded directly (no regional redirect).", 4);
                _regionalPrefix = "";
                return BuildComplianceUrl("", tenantId);
            }

            context.ReportProgress($"Compliance endpoint returned HTTP {(int)resp.StatusCode}. Exchange Administrator role or compliance permissions may be required.", 2);
            return null;
        }
        catch (InvalidOperationException)
        {
            context.ReportProgress("Cannot acquire compliance token. Ensure the app registration has the compliance scope configured.", 2);
            return null;
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Compliance endpoint discovery failed: {ex.Message}", 2);
            return null;
        }
    }

    private static string BuildComplianceUrl(string regionalPrefix, string tenantId)
    {
        var host = string.IsNullOrEmpty(regionalPrefix)
            ? ComplianceBaseHost
            : $"{regionalPrefix}.{ComplianceBaseHost}";
        return $"https://{host}/adminapi/beta/{tenantId}/InvokeCommand";
    }

    /// <summary>
    /// Invoke a compliance cmdlet via the InvokeCommand REST API.
    /// Handles pagination and retries, mirroring ExchangeRestClient patterns.
    /// </summary>
    private async Task<List<JsonElement>> InvokeComplianceCommandAsync(
        string url, string cmdletName, Dictionary<string, object>? parameters,
        CancellationToken ct)
    {
        var results = new List<JsonElement>();
        string? currentUrl = url;

        for (int attempt = 0; attempt < MaxRetries; attempt++)
        {
            try
            {
                while (currentUrl != null)
                {
                    ct.ThrowIfCancellationRequested();

                    var body = new
                    {
                        CmdletInput = new
                        {
                            CmdletName = cmdletName,
                            Parameters = parameters ?? new Dictionary<string, object>()
                        }
                    };

                    var token = await _auth.GetAccessTokenAsync("compliance", ct);
                    using var req = new HttpRequestMessage(HttpMethod.Post, currentUrl);
                    req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    req.Headers.Add("X-CmdletName", cmdletName);
                    req.Headers.Add("X-ClientApplication", "ExoManagementModule");
                    req.Headers.Add("Prefer", "odata.maxpagesize=1000");
                    req.Headers.Add("X-SerializationLevel", "Partial");
                    req.Content = new StringContent(
                        JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

                    var resp = await _http.SendAsync(req, ct);

                    if (!resp.IsSuccessStatusCode)
                    {
                        var errorBody = await resp.Content.ReadAsStringAsync(ct);

                        // Check for transient errors
                        if (IsTransientError(errorBody) && attempt < MaxRetries - 1)
                        {
                            await Task.Delay(TimeSpan.FromSeconds(Math.Pow(2, attempt + 1)), ct);
                            break;
                        }

                        throw new HttpRequestException(
                            $"Compliance {(int)resp.StatusCode} [{cmdletName}]: {Truncate(errorBody, 500)}",
                            null, resp.StatusCode);
                    }

                    var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
                    var root = doc.RootElement;

                    if (root.TryGetProperty("value", out var valueArray) && valueArray.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in valueArray.EnumerateArray())
                            results.Add(item.Clone());
                    }

                    // Check for pagination
                    currentUrl = null;
                    if (root.TryGetProperty("@odata.nextLink", out var nl))
                        currentUrl = nl.GetString();
                    else if (root.TryGetProperty("odata.nextLink", out var nl2))
                        currentUrl = nl2.GetString();
                }

                return results;
            }
            catch (HttpRequestException ex) when (
                attempt < MaxRetries - 1 &&
                (ex.StatusCode == null || (int)ex.StatusCode >= 500))
            {
                results.Clear();
                await Task.Delay(TimeSpan.FromSeconds((attempt + 1) * 2), ct);
                currentUrl = url;
            }
        }

        return results;
    }

    private static bool IsTransientError(string errorBody)
    {
        var transientCodes = new[] { "CmdletProxyNotAvailableFailure", "ServerBusyException",
            "TransientException", "BackendCommunicationException" };
        return transientCodes.Any(code => errorBody.Contains(code, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Enumerate all role groups from the Compliance Center.
    /// </summary>
    private async Task GetRoleGroupsAsync(ScanContext context, string complianceUrl,
        List<ComplianceRoleGroup> roleGroups, CancellationToken ct)
    {
        try
        {
            var results = await InvokeComplianceCommandAsync(complianceUrl, "Get-RoleGroup", null, ct);

            foreach (var group in results)
            {
                var name = GetStringProp(group, "Name") ?? GetStringProp(group, "DisplayName") ?? "";
                var guid = GetStringProp(group, "Guid") ?? GetStringProp(group, "ExchangeObjectId") ?? "";
                var description = GetStringProp(group, "Description") ?? "";

                // Extract assigned roles
                var roles = new List<string>();
                if (group.TryGetProperty("Roles", out var rolesVal))
                {
                    if (rolesVal.ValueKind == JsonValueKind.Array)
                        foreach (var r in rolesVal.EnumerateArray())
                            if (r.ValueKind == JsonValueKind.String)
                                roles.Add(r.GetString()!);
                    else if (rolesVal.ValueKind == JsonValueKind.String)
                        roles.Add(rolesVal.GetString()!);
                }
                if (group.TryGetProperty("RoleAssignments", out var raVal))
                {
                    if (raVal.ValueKind == JsonValueKind.Array)
                        foreach (var r in raVal.EnumerateArray())
                            if (r.ValueKind == JsonValueKind.String)
                                roles.Add(r.GetString()!);
                    else if (raVal.ValueKind == JsonValueKind.String)
                        roles.Add(raVal.GetString()!);
                }

                // Determine if this is a built-in or custom role group
                var isBuiltIn = group.TryGetProperty("IsReadOnly", out var ro) && ro.ValueKind == JsonValueKind.True;
                // Also check RoleGroupType if available
                if (!isBuiltIn && group.TryGetProperty("RoleGroupType", out var rgt) && rgt.ValueKind == JsonValueKind.String)
                    isBuiltIn = string.Equals(rgt.GetString(), "BuiltIn", StringComparison.OrdinalIgnoreCase);

                if (!string.IsNullOrEmpty(name))
                {
                    roleGroups.Add(new ComplianceRoleGroup
                    {
                        Name = name,
                        Guid = guid,
                        Description = description,
                        Roles = roles,
                        IsBuiltIn = isBuiltIn
                    });
                }
            }
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Failed to enumerate Compliance role groups: {ex.Message}", 2);
        }
    }

    /// <summary>
    /// Get members of a specific compliance role group.
    /// </summary>
    private async Task GetRoleGroupMembersAsync(ScanContext context, string complianceUrl,
        ComplianceRoleGroup group, List<PermissionEntry> results, CancellationToken ct)
    {
        var members = await InvokeComplianceCommandAsync(complianceUrl, "Get-RoleGroupMember",
            new Dictionary<string, object> { ["Identity"] = group.Name }, ct);

        foreach (var member in members)
        {
            var entry = MapComplianceRoleMember(member, group);
            if (entry != null) results.Add(entry);
        }
    }

    private static PermissionEntry? MapComplianceRoleMember(JsonElement member, ComplianceRoleGroup group)
    {
        var displayName = GetStringProp(member, "DisplayName") ?? GetStringProp(member, "Name") ?? "";
        var upn = GetStringProp(member, "WindowsLiveID")
                  ?? GetStringProp(member, "PrimarySmtpAddress") ?? "";
        var recipientType = GetStringProp(member, "RecipientType") ?? "";
        var guid = GetStringProp(member, "Guid") ?? GetStringProp(member, "ExchangeObjectId") ?? "";
        var externalId = GetStringProp(member, "ExternalDirectoryObjectId") ?? "";

        if (string.IsNullOrEmpty(displayName) && string.IsNullOrEmpty(upn))
            return null;

        var principalType = recipientType?.ToLower() switch
        {
            "usermailbox" or "mailuser" or "user" => "User",
            "group" or "mailuniversalsecuritygroup" or "mailuniversaldistributiongroup" => "SecurityGroup",
            _ => "User"
        };

        var targetType = group.IsBuiltIn ? "ComplianceBuiltInRole" : "ComplianceCustomRole";

        return new PermissionEntry
        {
            TargetPath = $"Purview/{group.Name}",
            TargetType = targetType,
            TargetId = group.Guid,
            PrincipalEntraId = externalId,
            PrincipalEntraUpn = upn,
            PrincipalSysId = guid,
            PrincipalSysName = displayName,
            PrincipalType = principalType,
            PrincipalRole = group.Name,
            Through = "RoleGroupMember",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    private static string? GetStringProp(JsonElement el, string name)
    {
        if (el.TryGetProperty(name, out var val) && val.ValueKind == JsonValueKind.String)
            return val.GetString();
        return null;
    }

    private static string Truncate(string s, int max)
        => s.Length <= max ? s : s[..max] + "...";

    private sealed class ComplianceRoleGroup
    {
        public string Name { get; set; } = "";
        public string Guid { get; set; } = "";
        public string Description { get; set; } = "";
        public List<string> Roles { get; set; } = new();
        public bool IsBuiltIn { get; set; }
    }
}
