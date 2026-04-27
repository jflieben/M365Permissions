using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Graph;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans SharePoint Online sites for permissions using Graph API + SharePoint REST.
/// Replaces V1's PnP.PowerShell-based get-SpOPermissions.ps1.
/// </summary>
public sealed class SharePointScanner : IScanProvider
{
    public string Category => "SharePoint";

    private readonly SharePointRestClient _spClient;
    private readonly GraphClient _graphClient;
    private readonly DelegatedAuth _auth;

    // Site templates to skip (matches V1 ignore list)
    private static readonly HashSet<string> IgnoredTemplates = new(StringComparer.OrdinalIgnoreCase)
    {
        "REDIRECTSITE", "SRCHCEN", "SPSMSITEHOST", "APPCATALOG",
        "POINTPUBLISHINGHUB", "EDISC", "STS#-1"
    };

    public SharePointScanner(SharePointRestClient spClient, GraphClient graphClient, DelegatedAuth auth)
    {
        _spClient = spClient;
        _graphClient = graphClient;
        _auth = auth;
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Enumerating SharePoint sites...", 3);

        // Collect all sites first so we know the total
        var sites = new List<JsonElement>();
        await foreach (var site in _spClient.GetAllSitesAsync(ct))
        {
            sites.Add(site);
        }

        context.SetTotalTargets(sites.Count);
        context.ReportProgress($"Found {sites.Count} sites to scan.", 3);

        foreach (var site in sites)
        {
            ct.ThrowIfCancellationRequested();

            var webUrl = site.TryGetProperty("webUrl", out var wUrl) ? wUrl.GetString() ?? "" : "";
            var siteId = site.TryGetProperty("id", out var sId) ? sId.GetString() ?? "" : "";
            var displayName = site.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? webUrl : webUrl;

            if (string.IsNullOrEmpty(webUrl))
            {
                context.CompleteTarget();
                continue;
            }

            context.ReportProgress($"Scanning: {displayName}", 4);

            // --- Temporarily add scanning user as site admin if needed (like V1) ---
            bool wasAdded = false;
            var userUpn = _auth.UserPrincipalName;

            if (!string.IsNullOrEmpty(userUpn))
            {
                try
                {
                    wasAdded = await _spClient.EnsureSiteAdminAsync(webUrl, userUpn, ct);
                    if (wasAdded)
                        context.ReportProgress($"Temporarily added {userUpn} as site admin for: {displayName}", 4);
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Could not ensure site admin for {displayName}: {ex.Message}", 3);
                }
            }

            try
            {
                // --- Site admins ---
                List<JsonElement> admins;
                try
                {
                    admins = await _spClient.GetSiteAdminsAsync(webUrl, ct);
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Failed to get admins for {displayName}: {ex.Message}", 2);
                    admins = new();
                }

                var scannerFilter = wasAdded ? (userUpn ?? "") : "";

                foreach (var admin in admins)
                {
                    var entry = MapSiteAdmin(admin, webUrl, siteId, scannerFilter);
                    if (entry != null) yield return entry;
                }

                // --- Role assignments ---
                List<JsonElement> roleAssignments;
                try
                {
                    roleAssignments = await _spClient.GetRoleAssignmentsAsync(webUrl, ct);
                }
                catch (Exception ex)
                {
                    context.ReportProgress($"Failed to get role assignments for {displayName}: {ex.Message}", 2);
                    context.FailTarget();
                    continue;
                }

                foreach (var ra in roleAssignments)
                {
                    var entries = MapRoleAssignment(ra, webUrl, siteId, scannerFilter);
                    foreach (var entry in entries)
                        yield return entry;
                }

                // --- Graph site permissions (apps, etc.) ---
                // Graph sites/{siteId}/permissions is only supported for root sites in a site collection,
                // not subsites. Detect subsites by checking if webUrl has a path beyond /sites/{name}.
                var isSubsite = IsSubsite(webUrl);
                if (!isSubsite)
                {
                    var graphPerms = new List<PermissionEntry>();
                    try
                    {
                        await foreach (var perm in _spClient.GetSitePermissionsAsync(siteId, ct))
                        {
                            var entry = MapGraphSitePermission(perm, webUrl, siteId);
                            if (entry != null) graphPerms.Add(entry);
                        }
                    }
                    catch (Exception ex)
                    {
                        context.ReportProgress($"Failed to get Graph permissions for {displayName}: {ex.Message}", 4);
                    }

                    foreach (var gp in graphPerms)
                        yield return gp;
                }

                context.CompleteTarget();
            }
            finally
            {
                // Always remove temp admin rights, even if scan threw an exception
                if (wasAdded && !string.IsNullOrEmpty(userUpn))
                {
                    try
                    {
                        await _spClient.RemoveSiteAdminAsync(webUrl, userUpn, ct);
                        context.ReportProgress($"Removed temporary site admin from: {displayName}", 4);
                    }
                    catch (Exception ex)
                    {
                        context.ReportProgress($"WARNING: Failed to remove temp admin from {displayName}: {ex.Message}", 2);
                    }
                }
            }
        }
    }

    private static PermissionEntry? MapSiteAdmin(JsonElement admin, string webUrl, string siteId, string scannerUpn)
    {
        var loginName = admin.TryGetProperty("LoginName", out var ln) ? ln.GetString() ?? "" : "";
        var title = admin.TryGetProperty("Title", out var t) ? t.GetString() ?? "" : "";
        var email = admin.TryGetProperty("Email", out var e) ? e.GetString() ?? "" : "";
        var id = admin.TryGetProperty("Id", out var i) ? i.GetInt32().ToString() : "";

        // Skip system accounts
        if (loginName.Contains("SHAREPOINT\\system", StringComparison.OrdinalIgnoreCase))
            return null;

        // Omit scanning identity (transient admin)
        if (!string.IsNullOrEmpty(scannerUpn) && email.Equals(scannerUpn, StringComparison.OrdinalIgnoreCase))
            return null;

        return new PermissionEntry
        {
            TargetPath = webUrl,
            TargetType = "Site",
            TargetId = siteId,
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

    private static List<PermissionEntry> MapRoleAssignment(JsonElement ra, string webUrl, string siteId, string scannerUpn)
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
                TargetPath = webUrl,
                TargetType = "Site",
                TargetId = siteId,
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

    private static PermissionEntry? MapGraphSitePermission(JsonElement perm, string webUrl, string siteId)
    {
        var roles = perm.TryGetProperty("roles", out var r) ? r : default;
        var grantedTo = perm.TryGetProperty("grantedToIdentitiesV2", out var g) ? g : default;

        if (roles.ValueKind != JsonValueKind.Array) return null;

        var roleList = new List<string>();
        foreach (var role in roles.EnumerateArray())
            roleList.Add(role.GetString() ?? "");

        var displayName = "";
        var appId = "";
        if (grantedTo.ValueKind == JsonValueKind.Array)
        {
            foreach (var identity in grantedTo.EnumerateArray())
            {
                if (identity.TryGetProperty("application", out var app))
                {
                    displayName = app.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                    appId = app.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";
                    break;
                }
            }
        }

        if (string.IsNullOrEmpty(displayName) && string.IsNullOrEmpty(appId))
            return null;

        return new PermissionEntry
        {
            TargetPath = webUrl,
            TargetType = "Site",
            TargetId = siteId,
            PrincipalEntraId = appId,
            PrincipalSysName = displayName,
            PrincipalType = "Application",
            PrincipalRole = string.Join(", ", roleList),
            Through = "GraphSitePermission",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    private static string DeterminePrincipalType(string loginName)
    {
        if (string.IsNullOrEmpty(loginName)) return "Unknown";
        // Order matters: more specific checks first
        // Users: i:0#.f|membership|user@domain.com
        if (loginName.StartsWith("i:0#.f|membership|", StringComparison.OrdinalIgnoreCase)) return "Internal User";
        // External users always contain #ext#
        if (loginName.Contains("#ext#", StringComparison.OrdinalIgnoreCase)) return "External User";
        // Security groups: c:0t.c|tenant|<guid> or c:0o.c|federateddirectoryclaimprovider|<guid>
        if (loginName.StartsWith("c:0t.c|tenant|", StringComparison.OrdinalIgnoreCase)) return "SecurityGroup";
        if (loginName.Contains("|federateddirectoryclaimprovider|", StringComparison.OrdinalIgnoreCase)) return "SecurityGroup";
        // SharePoint groups: c:0-.f|rolemanager|spo-grid-all-users/...
        if (loginName.Contains("c:0-.f|rolemanager|", StringComparison.OrdinalIgnoreCase)) return "SharePoint Group";
        // Everyone / Everyone except external: c:0(.s|true (all authenticated)
        if (loginName.StartsWith("c:0(.s|true", StringComparison.OrdinalIgnoreCase)) return "Everyone";
        // Remaining membership claims are typically groups
        if (loginName.Contains("|membership|", StringComparison.OrdinalIgnoreCase)) return "SecurityGroup";
        return "Unknown";
    }

    /// <summary>Detect if a URL is a subsite (has path segments beyond /sites/{name}).</summary>
    private static bool IsSubsite(string webUrl)
    {
        if (string.IsNullOrEmpty(webUrl)) return false;
        try
        {
            var uri = new Uri(webUrl);
            var path = uri.AbsolutePath.TrimEnd('/');
            // Root sites: / or /sites/SiteName or /teams/TeamName (2 segments under /sites/ or /teams/)
            // Subsites: /sites/SiteName/SubsiteName (3+ segments)
            var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            // /sites/name = 2 segments, /sites/name/sub = 3+ segments (subsite)
            return segments.Length > 2;
        }
        catch
        {
            return false;
        }
    }
}
