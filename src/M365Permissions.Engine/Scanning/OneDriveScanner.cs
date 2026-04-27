using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Graph;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans OneDrive for Business — enumerates users, temporarily adds scanning user as site admin
/// on each OneDrive personal site, then scans permissions via SP REST and Graph drive API.
/// </summary>
public sealed class OneDriveScanner : IScanProvider
{
    public string Category => "OneDrive";

    private readonly GraphClient _graphClient;
    private readonly SharePointRestClient _spClient;
    private readonly DelegatedAuth _auth;

    public OneDriveScanner(GraphClient graphClient, SharePointRestClient spClient, DelegatedAuth auth)
    {
        _graphClient = graphClient;
        _spClient = spClient;
        _auth = auth;
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Enumerating OneDrive personal sites via user enumeration...", 3);

        var scannerUpn = _auth.UserPrincipalName ?? "";

        // Enumerate licensed users (mySite excluded from $select — it proxies to SharePoint
        // User Profile Service and causes InvalidClientQueryException in many tenants)
        var users = new List<(string UserId, string Upn, string DisplayName)>();
        try
        {
            await foreach (var user in _graphClient.GetPaginatedAsync(
                "users?$select=id,displayName,userPrincipalName,assignedLicenses&$filter=accountEnabled eq true&$count=true",
                eventualConsistency: true, ct: ct))
            {
                var userId = user.TryGetProperty("id", out var uid) ? uid.GetString() ?? "" : "";
                var upn = user.TryGetProperty("userPrincipalName", out var u) ? u.GetString() ?? "" : "";
                var displayName = user.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";

                // Only include users who have licenses (they may have OneDrive)
                if (user.TryGetProperty("assignedLicenses", out var lic) &&
                    lic.ValueKind == JsonValueKind.Array && lic.GetArrayLength() > 0 &&
                    !string.IsNullOrEmpty(userId))
                {
                    users.Add((userId, upn, displayName));
                }
            }
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Failed to enumerate users: {ex.Message}", 2);
            yield break;
        }

        context.SetTotalTargets(users.Count);
        context.ReportProgress($"Found {users.Count} licensed users. Checking OneDrive access...", 3);

        int processed = 0;
        int sitesFound = 0;
        foreach (var (userId, userUpn, displayName) in users)
        {
            ct.ThrowIfCancellationRequested();

            // Determine the OneDrive site URL via Graph drive API
            var oneDriveUrl = "";
            try
            {
                var driveResponse = await _graphClient.GetAsync($"users/{userId}/drive?$select=webUrl", ct: ct);
                if (driveResponse != null && driveResponse.Value.TryGetProperty("webUrl", out var wUrl))
                {
                    // webUrl is like https://tenant-my.sharepoint.com/personal/user_domain_com/Documents
                    // We need the site URL (remove /Documents or similar trailing path)
                    var webUrlStr = wUrl.GetString() ?? "";
                    if (!string.IsNullOrEmpty(webUrlStr))
                    {
                        var uri = new Uri(webUrlStr);
                        var segments = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
                        // personal/{encoded_upn} are the first 2 segments
                        if (segments.Length >= 2)
                            oneDriveUrl = $"{uri.Scheme}://{uri.Host}/{segments[0]}/{segments[1]}";
                    }
                }
            }
            catch
            {
                // User may not have OneDrive provisioned — skip silently
            }

            if (string.IsNullOrEmpty(oneDriveUrl))
            {
                context.CompleteTarget();
                processed++;
                continue;
            }

            // Temporarily add scanning user as site admin via tenant admin API
            // (site-level APIs return 403 on other users' personal sites)
            bool wasAdded = false;
            if (!string.IsNullOrEmpty(scannerUpn))
            {
                try
                {
                    wasAdded = await _spClient.EnsureSiteAdminViaTenantAsync(oneDriveUrl, scannerUpn, ct);
                    if (wasAdded)
                        context.ReportProgress($"Temporarily added scanner as admin on OneDrive: {displayName}", 4);
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Could not ensure admin on OneDrive of {displayName}: {ex.Message}", 3);
                }
            }

            try
            {
                sitesFound++;

                // --- Site admins via SP REST ---
                List<JsonElement> admins;
                try
                {
                    admins = await _spClient.GetSiteAdminsAsync(oneDriveUrl, ct);
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Failed to get admins for OneDrive of {displayName}: {ex.Message}", 2);
                    admins = new();
                }

                var scannerFilter = wasAdded ? scannerUpn : "";

                foreach (var admin in admins)
                {
                    var entry = MapSiteAdmin(admin, oneDriveUrl, userId, scannerFilter);
                    if (entry != null) yield return entry;
                }

                // --- Role assignments via SP REST ---
                List<JsonElement> roleAssignments;
                try
                {
                    roleAssignments = await _spClient.GetRoleAssignmentsAsync(oneDriveUrl, ct);
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Failed to get role assignments for OneDrive of {displayName}: {ex.Message}", 2);
                    roleAssignments = new();
                }

                foreach (var ra in roleAssignments)
                {
                    var entries = MapRoleAssignment(ra, oneDriveUrl, userId, scannerFilter);
                    foreach (var entry in entries)
                        yield return entry;
                }

                // --- Item-level sharing via Graph drive API ---
                var itemEntries = new List<PermissionEntry>();
                try
                {
                    var driveResponse = await _graphClient.GetAsync($"users/{userId}/drive?$select=id,webUrl", ct: ct);
                    if (driveResponse != null)
                    {
                        var driveId = driveResponse.Value.TryGetProperty("id", out var did) ? did.GetString() ?? "" : "";
                        var driveUrl = driveResponse.Value.TryGetProperty("webUrl", out var dUrl) ? dUrl.GetString() ?? "" : "";

                        if (!string.IsNullOrEmpty(driveId))
                        {
                            await foreach (var item in _graphClient.GetPaginatedAsync(
                                $"drives/{driveId}/root/children?$select=id,name,webUrl,shared,folder", ct: ct))
                            {
                                var itemId = item.TryGetProperty("id", out var iid) ? iid.GetString() ?? "" : "";
                                var itemName = item.TryGetProperty("name", out var iname) ? iname.GetString() ?? "" : "";
                                var itemUrl = item.TryGetProperty("webUrl", out var iwUrl) ? iwUrl.GetString() ?? "" : "";

                                if (!item.TryGetProperty("shared", out _) && !item.TryGetProperty("folder", out _))
                                    continue;

                                List<JsonElement>? itemPerms = null;
                                try
                                {
                                    var permsResponse = await _graphClient.GetAsync(
                                        $"drives/{driveId}/items/{itemId}/permissions?$select=id,roles,grantedToV2,grantedToIdentitiesV2,link,inheritedFrom",
                                        ct: ct);
                                    if (permsResponse != null && permsResponse.Value.TryGetProperty("value", out var permArr)
                                        && permArr.ValueKind == JsonValueKind.Array)
                                    {
                                        itemPerms = new List<JsonElement>();
                                        foreach (var p in permArr.EnumerateArray())
                                            itemPerms.Add(p.Clone());
                                    }
                                }
                                catch { }

                                if (itemPerms == null) continue;

                                foreach (var perm in itemPerms)
                                {
                                    var entry = MapDriveItemPermission(perm, driveUrl, itemName, itemUrl, userUpn, userId, driveId, scannerFilter);
                                    if (entry != null) itemEntries.Add(entry);
                                }
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Failed to scan OneDrive items for {displayName}: {ex.Message}", 3);
                }

                foreach (var ie in itemEntries)
                    yield return ie;

                context.CompleteTarget();
            }
            finally
            {
                if (wasAdded && !string.IsNullOrEmpty(scannerUpn))
                {
                    try
                    {
                        await _spClient.RemoveSiteAdminViaTenantAsync(oneDriveUrl, scannerUpn, ct);
                        context.ReportProgress($"Removed temporary admin from OneDrive: {displayName}", 4);
                    }
                    catch (Exception ex)
                    {
                        context.ReportProgress($"WARNING: Failed to remove temp admin from OneDrive of {displayName}: {ex.Message}", 2);
                    }
                }
            }

            processed++;

            if (processed % 50 == 0)
                context.ReportProgress($"Scanned {processed}/{users.Count} users ({sitesFound} OneDrive sites found)...", 4);
        }

        context.ReportProgress($"Completed scanning {sitesFound} OneDrive sites (from {processed} users).", 3);
    }

    private static PermissionEntry? MapSiteAdmin(JsonElement admin, string siteUrl, string ownerId, string scannerUpn)
    {
        var loginName = admin.TryGetProperty("LoginName", out var ln) ? ln.GetString() ?? "" : "";
        var title = admin.TryGetProperty("Title", out var t) ? t.GetString() ?? "" : "";
        var email = admin.TryGetProperty("Email", out var e) ? e.GetString() ?? "" : "";
        var id = admin.TryGetProperty("Id", out var i) ? i.GetInt32().ToString() : "";

        if (loginName.Contains("SHAREPOINT\\system", StringComparison.OrdinalIgnoreCase))
            return null;

        // Omit scanning identity (transient admin)
        if (!string.IsNullOrEmpty(scannerUpn) && email.Equals(scannerUpn, StringComparison.OrdinalIgnoreCase))
            return null;

        return new PermissionEntry
        {
            TargetPath = siteUrl,
            TargetType = "OneDrive",
            TargetId = ownerId,
            PrincipalEntraUpn = email,
            PrincipalSysId = id,
            PrincipalSysName = title,
            PrincipalType = DeterminePrincipalType(loginName),
            PrincipalRole = "Site Collection Administrator",
            Through = "Direct",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    private static List<PermissionEntry> MapRoleAssignment(JsonElement ra, string siteUrl, string ownerId, string scannerUpn)
    {
        var entries = new List<PermissionEntry>();

        if (!ra.TryGetProperty("Member", out var member)) return entries;
        if (!ra.TryGetProperty("RoleDefinitionBindings", out var bindings)) return entries;

        var principalName = member.TryGetProperty("Title", out var t) ? t.GetString() ?? "" : "";
        var principalLogin = member.TryGetProperty("LoginName", out var ln) ? ln.GetString() ?? "" : "";
        var principalId = member.TryGetProperty("Id", out var i) ? i.GetInt32().ToString() : "";

        // Omit scanning identity
        if (!string.IsNullOrEmpty(scannerUpn) && principalLogin.Contains(scannerUpn, StringComparison.OrdinalIgnoreCase))
            return entries;

        foreach (var binding in bindings.EnumerateArray())
        {
            var roleName = binding.TryGetProperty("Name", out var n) ? n.GetString() ?? "" : "";
            var roleId = binding.TryGetProperty("Id", out var rid) ? rid.GetInt64() : 0;
            var hidden = binding.TryGetProperty("Hidden", out var h) && h.ValueKind == JsonValueKind.True;

            // Skip system/hidden roles by internal ID (locale-independent):
            // 1073741825 = Limited Access, 1073741924 = Web-Only Limited Access
            if (roleId == 1073741825 || roleId == 1073741924 || hidden)
                continue;

            entries.Add(new PermissionEntry
            {
                TargetPath = siteUrl,
                TargetType = "OneDrive",
                TargetId = ownerId,
                PrincipalSysId = principalId,
                PrincipalSysName = principalName,
                PrincipalType = DeterminePrincipalType(principalLogin),
                PrincipalRole = roleName,
                Through = "Direct",
                AccessType = "Allow",
                Tenure = "Permanent"
            });
        }

        return entries;
    }

    private static PermissionEntry? MapDriveItemPermission(JsonElement perm, string driveUrl,
        string itemName, string itemUrl, string ownerUpn, string ownerId, string driveId, string scannerUpn)
    {
        var roles = new List<string>();
        if (perm.TryGetProperty("roles", out var r) && r.ValueKind == JsonValueKind.Array)
        {
            foreach (var role in r.EnumerateArray())
                roles.Add(role.GetString() ?? "");
        }

        if (perm.TryGetProperty("inheritedFrom", out var inh) && inh.ValueKind != JsonValueKind.Null)
            return null;

        string principalName = "";
        string principalId = "";
        string principalUpn = "";
        string principalType = "User";

        if (perm.TryGetProperty("grantedToV2", out var grantedTo))
        {
            if (grantedTo.TryGetProperty("user", out var user))
            {
                principalName = user.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                principalId = user.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";
                principalUpn = user.TryGetProperty("email", out var em) ? em.GetString() ?? "" : "";
                principalType = "User";
            }
            else if (grantedTo.TryGetProperty("group", out var group))
            {
                principalName = group.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                principalId = group.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";
                principalType = "SecurityGroup";
            }
            else if (grantedTo.TryGetProperty("application", out var app))
            {
                principalName = app.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                principalId = app.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";
                principalType = "Application";
            }
        }

        if (string.IsNullOrEmpty(principalName) && perm.TryGetProperty("link", out var link))
        {
            var linkType = link.TryGetProperty("type", out var lt) ? lt.GetString() ?? "" : "";
            var scope = link.TryGetProperty("scope", out var sc) ? sc.GetString() ?? "" : "";
            principalName = $"Sharing Link ({scope})";
            principalType = scope == "organization" ? "AllInternalUsers" :
                           scope == "anonymous" ? "Anonymous" : "SharingLink";
            if (roles.Count == 0) roles.Add(linkType);
        }

        if (string.IsNullOrEmpty(principalName) && perm.TryGetProperty("grantedToIdentitiesV2", out var identities)
            && identities.ValueKind == JsonValueKind.Array)
        {
            foreach (var identity in identities.EnumerateArray())
            {
                if (identity.TryGetProperty("user", out var u))
                {
                    principalName = u.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                    principalId = u.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";
                    break;
                }
            }
        }

        if (string.IsNullOrEmpty(principalName) && string.IsNullOrEmpty(principalId))
            return null;

        // Skip owner's own permission
        if (principalId == ownerId) return null;

        // Omit scanning identity
        if (!string.IsNullOrEmpty(scannerUpn) &&
            (principalUpn.Equals(scannerUpn, StringComparison.OrdinalIgnoreCase) ||
             principalName.Equals(scannerUpn, StringComparison.OrdinalIgnoreCase)))
            return null;

        var targetPath = string.IsNullOrEmpty(itemUrl) ? $"{driveUrl}/{itemName}" : itemUrl;

        return new PermissionEntry
        {
            TargetPath = targetPath,
            TargetType = "OneDriveItem",
            TargetId = driveId,
            PrincipalEntraId = principalId,
            PrincipalSysName = principalName,
            PrincipalType = principalType,
            PrincipalRole = string.Join(", ", roles),
            Through = "Direct",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    private static string DeterminePrincipalType(string loginName)
    {
        if (string.IsNullOrEmpty(loginName)) return "Unknown";
        if (loginName.StartsWith("i:0#.f|membership|", StringComparison.OrdinalIgnoreCase)) return "Internal User";
        if (loginName.Contains("#ext#", StringComparison.OrdinalIgnoreCase)) return "External User";
        if (loginName.StartsWith("c:0t.c|tenant|", StringComparison.OrdinalIgnoreCase)) return "SecurityGroup";
        if (loginName.Contains("|federateddirectoryclaimprovider|", StringComparison.OrdinalIgnoreCase)) return "SecurityGroup";
        if (loginName.Contains("c:0-.f|rolemanager|", StringComparison.OrdinalIgnoreCase)) return "SharePoint Group";
        if (loginName.StartsWith("c:0(.s|true", StringComparison.OrdinalIgnoreCase)) return "Everyone";
        if (loginName.Contains("|membership|", StringComparison.OrdinalIgnoreCase)) return "SecurityGroup";
        return "Unknown";
    }
}
