using System.Net.Http.Headers;
using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans Azure DevOps organizations, projects, and group memberships.
/// Uses the Azure DevOps REST API with delegated (user_impersonation) authentication.
/// SPN-based org enumeration is not supported by Azure DevOps, so this requires delegated auth.
/// </summary>
public sealed class AzureDevOpsScanner : IScanProvider
{
    public string Category => "AzureDevOps";

    private readonly DelegatedAuth _auth;
    private readonly HttpClient _http;

    public AzureDevOpsScanner(DelegatedAuth auth)
    {
        _auth = auth;
        _http = new HttpClient();
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Connecting to Azure DevOps...", 3);

        // Step 1: Get the authenticated user's member ID
        string memberId;
        try
        {
            memberId = await GetMemberIdAsync(ct);
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Cannot access Azure DevOps profile: {ex.Message}", 2);
            yield break;
        }

        // Step 2: Enumerate organizations the user has access to
        List<(string AccountId, string AccountName, string AccountUri)> organizations;
        try
        {
            organizations = await GetOrganizationsAsync(memberId, ct);
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Failed to enumerate Azure DevOps organizations: {ex.Message}", 2);
            yield break;
        }

        if (organizations.Count == 0)
        {
            context.ReportProgress("No Azure DevOps organizations found for this user.", 3);
            yield break;
        }

        context.ReportProgress($"Found {organizations.Count} Azure DevOps organization(s).", 3);

        var totalProjects = 0;
        var allEntries = new List<PermissionEntry>();

        foreach (var (accountId, orgName, accountUri) in organizations)
        {
            ct.ThrowIfCancellationRequested();
            context.ReportProgress($"Scanning organization: {orgName}...", 3);

            // Step 3: Get all projects in this org
            List<(string Id, string Name, string State)> projects;
            try
            {
                projects = await GetProjectsAsync(orgName, ct);
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Failed to enumerate projects in '{orgName}': {ex.Message}", 2);
                continue;
            }

            totalProjects += projects.Count;
            context.SetTotalTargets(totalProjects);
            context.ReportProgress($"Found {projects.Count} project(s) in '{orgName}'.", 4);

            // Step 4: Get all security groups in the org
            List<DevOpsGroup> groups;
            try
            {
                groups = await GetOrgGroupsAsync(orgName, ct);
                context.ReportProgress($"Found {groups.Count} security group(s) in '{orgName}'.", 4);
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Warning: Could not enumerate groups in '{orgName}': {ex.Message}", 3);
                groups = new List<DevOpsGroup>();
            }

            // Step 5: Collect memberships for all groups, recursively expanding nested groups to users
            var groupMemberships = new List<(DevOpsGroup Group, string TargetPath, string TargetType, string TargetId, List<string> UserDescriptors)>();

            // 5a: Project-scoped groups
            foreach (var (projectId, projectName, projectState) in projects)
            {
                ct.ThrowIfCancellationRequested();

                var projectGroups = groups
                    .Where(g => g.PrincipalName.StartsWith($"[{projectName}]\\", StringComparison.OrdinalIgnoreCase))
                    .ToList();

                foreach (var group in projectGroups)
                {
                    var userDescriptors = await GetRecursiveUserDescriptorsAsync(orgName, group.Descriptor, ct);
                    if (userDescriptors.Count == 0) continue; // Skip groups with no users

                    groupMemberships.Add((group, $"AzureDevOps/{orgName}/{projectName}", "Project", projectId, userDescriptors));
                }

                context.CompleteTarget();
            }

            // 5b: Org-level groups
            var orgGroups = groups
                .Where(g => g.PrincipalName.StartsWith($"[{orgName}]\\", StringComparison.OrdinalIgnoreCase)
                          || g.PrincipalName.StartsWith("[TEAM FOUNDATION]\\", StringComparison.OrdinalIgnoreCase))
                .ToList();

            foreach (var group in orgGroups)
            {
                ct.ThrowIfCancellationRequested();

                var userDescriptors = await GetRecursiveUserDescriptorsAsync(orgName, group.Descriptor, ct);
                if (userDescriptors.Count == 0) continue; // Skip groups with no users

                groupMemberships.Add((group, $"AzureDevOps/{orgName}", "Organization", accountId, userDescriptors));
            }

            // Step 6: Batch-resolve all unique user descriptors via Subject Lookup API
            var allDescriptors = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var (_, _, _, _, descs) in groupMemberships)
                foreach (var d in descs) allDescriptors.Add(d);

            context.ReportProgress($"Resolving {allDescriptors.Count} unique user(s) in '{orgName}'...", 4);
            var subjectMap = await ResolveSubjectsAsync(orgName, allDescriptors, ct);
            context.ReportProgress($"Resolved {subjectMap.Count} subject(s) in '{orgName}'.", 4);

            // Step 7: Emit permission entries (users only — nested groups have been expanded)
            foreach (var (group, targetPath, targetType, targetId, userDescs) in groupMemberships)
            {
                foreach (var memberDesc in userDescs)
                {
                    if (subjectMap.TryGetValue(memberDesc, out var subject))
                    {
                        allEntries.Add(new PermissionEntry
                        {
                            TargetPath = targetPath,
                            TargetType = targetType,
                            TargetId = targetId,
                            PrincipalEntraId = subject.OriginId,
                            PrincipalEntraUpn = subject.MailAddress,
                            PrincipalSysId = subject.Descriptor,
                            PrincipalSysName = subject.DisplayName,
                            PrincipalType = MapPrincipalType(subject.SubjectKind),
                            PrincipalRole = ExtractRoleName(group.PrincipalName),
                            Through = $"Group: {group.DisplayName}",
                            AccessType = "Allow",
                            Tenure = "Permanent"
                        });
                    }
                }
            }
        }

        foreach (var entry in allEntries)
            yield return entry;

        context.ReportProgress($"Completed Azure DevOps scan. Found {allEntries.Count} permission entries.", 3);
    }

    // ── API methods ────────────────────────────────────────────

    /// <summary>
    /// Get the authenticated user's member ID from the VSSPS profile API.
    /// </summary>
    private async Task<string> GetMemberIdAsync(CancellationToken ct)
    {
        var token = await _auth.GetAccessTokenAsync("azuredevops", ct);
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1-preview.3");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();

        var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
        return doc.RootElement.GetProperty("publicAlias").GetString()
            ?? throw new InvalidOperationException("Could not determine Azure DevOps member ID");
    }

    /// <summary>
    /// Enumerate Azure DevOps organizations accessible to the given member.
    /// </summary>
    private async Task<List<(string AccountId, string AccountName, string AccountUri)>> GetOrganizationsAsync(
        string memberId, CancellationToken ct)
    {
        var token = await _auth.GetAccessTokenAsync("azuredevops", ct);
        using var req = new HttpRequestMessage(HttpMethod.Get,
            $"https://app.vssps.visualstudio.com/_apis/accounts?memberId={Uri.EscapeDataString(memberId)}&api-version=7.1-preview.1");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();

        var results = new List<(string, string, string)>();
        var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);

        if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
        {
            foreach (var acct in val.EnumerateArray())
            {
                var accountId = acct.TryGetProperty("accountId", out var aid) ? aid.GetString() ?? "" : "";
                var accountName = acct.TryGetProperty("accountName", out var an) ? an.GetString() ?? "" : "";
                var accountUri = acct.TryGetProperty("accountUri", out var au) ? au.GetString() ?? "" : "";
                if (!string.IsNullOrEmpty(accountName))
                    results.Add((accountId, accountName, accountUri));
            }
        }

        return results;
    }

    /// <summary>
    /// Get all projects in an Azure DevOps organization.
    /// </summary>
    private async Task<List<(string Id, string Name, string State)>> GetProjectsAsync(
        string orgName, CancellationToken ct)
    {
        var token = await _auth.GetAccessTokenAsync("azuredevops", ct);
        var results = new List<(string, string, string)>();
        var url = $"https://dev.azure.com/{Uri.EscapeDataString(orgName)}/_apis/projects?$top=500&api-version=7.1";

        while (!string.IsNullOrEmpty(url))
        {
            ct.ThrowIfCancellationRequested();
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var resp = await _http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) break;

            var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
            {
                foreach (var proj in val.EnumerateArray())
                {
                    var id = proj.TryGetProperty("id", out var pid) ? pid.GetString() ?? "" : "";
                    var name = proj.TryGetProperty("name", out var pn) ? pn.GetString() ?? "" : "";
                    var state = proj.TryGetProperty("state", out var ps) ? ps.GetString() ?? "" : "";
                    if (!string.IsNullOrEmpty(id) && !string.IsNullOrEmpty(name))
                        results.Add((id, name, state));
                }
            }

            // Azure DevOps uses a continuation token, not nextLink
            url = null;
            if (doc.RootElement.TryGetProperty("continuationToken", out var contToken))
            {
                var tokenValue = contToken.GetString();
                if (!string.IsNullOrEmpty(tokenValue))
                    url = $"https://dev.azure.com/{Uri.EscapeDataString(orgName)}/_apis/projects?$top=500&continuationToken={Uri.EscapeDataString(tokenValue)}&api-version=7.1";
            }
        }

        return results;
    }

    /// <summary>
    /// Batch-resolve member descriptors to full subject details via the Graph Subject Lookup API.
    /// This is more reliable than matching against a pre-fetched user list, because it resolves
    /// the exact descriptors returned by the memberships API (avoiding format mismatches).
    /// </summary>
    private async Task<Dictionary<string, DevOpsUser>> ResolveSubjectsAsync(
        string orgName, IEnumerable<string> descriptors, CancellationToken ct)
    {
        var result = new Dictionary<string, DevOpsUser>(StringComparer.OrdinalIgnoreCase);
        var descriptorList = descriptors.ToList();
        if (descriptorList.Count == 0) return result;

        var token = await _auth.GetAccessTokenAsync("azuredevops", ct);

        // Subject Lookup accepts batches; process in chunks to stay within limits
        const int batchSize = 500;
        for (int i = 0; i < descriptorList.Count; i += batchSize)
        {
            ct.ThrowIfCancellationRequested();
            var batch = descriptorList.Skip(i).Take(batchSize).ToList();
            var bodyObj = new { lookupKeys = batch.Select(d => new { descriptor = d }).ToArray() };
            var json = JsonSerializer.Serialize(bodyObj);

            using var req = new HttpRequestMessage(HttpMethod.Post,
                $"https://vssps.dev.azure.com/{Uri.EscapeDataString(orgName)}/_apis/graph/subjectlookup?api-version=7.1-preview.1");
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            req.Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

            var resp = await _http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) continue;

            var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Object)
            {
                foreach (var prop in val.EnumerateObject())
                {
                    var subject = prop.Value;
                    result[prop.Name] = new DevOpsUser
                    {
                        Descriptor = subject.TryGetProperty("descriptor", out var d) ? d.GetString() ?? prop.Name : prop.Name,
                        DisplayName = subject.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "",
                        MailAddress = subject.TryGetProperty("mailAddress", out var ma) ? ma.GetString() ?? "" : "",
                        OriginId = subject.TryGetProperty("originId", out var oi) ? oi.GetString() ?? "" : "",
                        SubjectKind = subject.TryGetProperty("subjectKind", out var sk) ? sk.GetString() ?? "" : "",
                        DirectoryAlias = subject.TryGetProperty("directoryAlias", out var da) ? da.GetString() ?? "" : ""
                    };
                }
            }
        }

        return result;
    }

    /// <summary>
    /// Get all security groups in an Azure DevOps organization via the VSSPS Graph API.
    /// </summary>
    private async Task<List<DevOpsGroup>> GetOrgGroupsAsync(string orgName, CancellationToken ct)
    {
        var token = await _auth.GetAccessTokenAsync("azuredevops", ct);
        var results = new List<DevOpsGroup>();
        var url = $"https://vssps.dev.azure.com/{Uri.EscapeDataString(orgName)}/_apis/graph/groups?api-version=7.1-preview.1";

        while (!string.IsNullOrEmpty(url))
        {
            ct.ThrowIfCancellationRequested();
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            var resp = await _http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) break;

            var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
            {
                foreach (var group in val.EnumerateArray())
                {
                    results.Add(new DevOpsGroup
                    {
                        Descriptor = group.TryGetProperty("descriptor", out var d) ? d.GetString() ?? "" : "",
                        DisplayName = group.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "",
                        PrincipalName = group.TryGetProperty("principalName", out var pn) ? pn.GetString() ?? "" : "",
                        Domain = group.TryGetProperty("domain", out var dom) ? dom.GetString() ?? "" : "",
                        Origin = group.TryGetProperty("origin", out var orig) ? orig.GetString() ?? "" : ""
                    });
                }
            }

            // VSSPS Graph API uses continuationToken in response headers
            url = null;
            if (resp.Headers.TryGetValues("X-MS-ContinuationToken", out var tokens))
            {
                var contToken = tokens.FirstOrDefault();
                if (!string.IsNullOrEmpty(contToken))
                    url = $"https://vssps.dev.azure.com/{Uri.EscapeDataString(orgName)}/_apis/graph/groups?continuationToken={Uri.EscapeDataString(contToken)}&api-version=7.1-preview.1";
            }
        }

        return results;
    }

    /// <summary>
    /// Recursively expand a group's membership tree to collect only non-group (user/SP) descriptors.
    /// Uses Subject Lookup to determine if each member is a group or user, then recurses into groups.
    /// Tracks visited descriptors to prevent infinite loops from circular group nesting.
    /// </summary>
    private async Task<List<string>> GetRecursiveUserDescriptorsAsync(
        string orgName, string groupDescriptor, CancellationToken ct, HashSet<string>? visited = null)
    {
        visited ??= new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!visited.Add(groupDescriptor))
            return new List<string>(); // Already visited — cycle guard

        List<string> directMembers;
        try
        {
            directMembers = await GetGroupMemberDescriptorsAsync(orgName, groupDescriptor, ct);
        }
        catch
        {
            return new List<string>();
        }

        if (directMembers.Count == 0)
            return new List<string>();

        // Resolve all direct members to determine their subjectKind
        var resolved = await ResolveSubjectsAsync(orgName, directMembers, ct);

        var userDescriptors = new List<string>();
        foreach (var memberDesc in directMembers)
        {
            if (visited.Contains(memberDesc))
                continue; // Already processed

            if (resolved.TryGetValue(memberDesc, out var subject))
            {
                if (subject.SubjectKind.Equals("group", StringComparison.OrdinalIgnoreCase))
                {
                    // Recurse into nested group
                    var nested = await GetRecursiveUserDescriptorsAsync(orgName, memberDesc, ct, visited);
                    userDescriptors.AddRange(nested);
                }
                else
                {
                    // User or service principal — collect it
                    userDescriptors.Add(memberDesc);
                }
            }
            else
            {
                // Unresolved — include it (will show as Unknown in results)
                userDescriptors.Add(memberDesc);
            }
        }

        return userDescriptors;
    }

    /// <summary>
    /// Get the member descriptors for a given group (direct members only, direction=Down).
    /// </summary>
    private async Task<List<string>> GetGroupMemberDescriptorsAsync(
        string orgName, string groupDescriptor, CancellationToken ct)
    {
        var token = await _auth.GetAccessTokenAsync("azuredevops", ct);
        using var req = new HttpRequestMessage(HttpMethod.Get,
            $"https://vssps.dev.azure.com/{Uri.EscapeDataString(orgName)}/_apis/graph/memberships/{Uri.EscapeDataString(groupDescriptor)}?direction=Down&api-version=7.1-preview.1");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var resp = await _http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode)
            return new List<string>();

        var results = new List<string>();
        var doc = await JsonDocument.ParseAsync(await resp.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
        if (doc.RootElement.TryGetProperty("value", out var val) && val.ValueKind == JsonValueKind.Array)
        {
            foreach (var membership in val.EnumerateArray())
            {
                var memberDescriptor = membership.TryGetProperty("memberDescriptor", out var md)
                    ? md.GetString() ?? "" : "";
                if (!string.IsNullOrEmpty(memberDescriptor))
                    results.Add(memberDescriptor);
            }
        }

        return results;
    }

    // ── Helper types ────────────────────────────────────────────

    private sealed class DevOpsUser
    {
        public string Descriptor { get; set; } = "";
        public string DisplayName { get; set; } = "";
        public string MailAddress { get; set; } = "";
        public string OriginId { get; set; } = "";
        public string SubjectKind { get; set; } = "";
        public string DirectoryAlias { get; set; } = "";
    }

    private sealed class DevOpsGroup
    {
        public string Descriptor { get; set; } = "";
        public string DisplayName { get; set; } = "";
        public string PrincipalName { get; set; } = "";
        public string Domain { get; set; } = "";
        public string Origin { get; set; } = "";
    }

    // ── Mapping helpers ─────────────────────────────────────────

    /// <summary>
    /// Extract the role name from a principalName like "[ProjectName]\Contributors" → "Contributors"
    /// </summary>
    private static string ExtractRoleName(string principalName)
    {
        var idx = principalName.LastIndexOf('\\');
        return idx >= 0 ? principalName[(idx + 1)..] : principalName;
    }

    private static string MapPrincipalType(string? subjectKind) => subjectKind?.ToLower() switch
    {
        "user" => "User",
        "group" => "SecurityGroup",
        "serviceprincipal" => "Application",
        _ => "User"
    };
}
