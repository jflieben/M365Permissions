using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Graph;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Pre-flight check that validates the connected account has the required permissions
/// for each scan type before starting. Reports missing permissions to the caller.
/// </summary>
public sealed class PermissionPreChecker
{
    private readonly GraphClient _graphClient;
    private readonly DelegatedAuth _auth;

    public PermissionPreChecker(GraphClient graphClient, DelegatedAuth auth)
    {
        _graphClient = graphClient;
        _auth = auth;
    }

    // Well-known Entra directory role template IDs
    private static class RoleTemplateIds
    {
        public const string GlobalAdministrator = "62e90394-69f5-4237-9190-012177145e10";
        public const string GlobalReader = "f2ef992c-3afb-46b9-b7cf-a126ee74c451";
        public const string SharePointAdministrator = "f28a1f50-f6e7-4571-818b-6a12f2af6b6c";
        public const string ExchangeAdministrator = "29232cdf-9323-42fd-ade2-1d097af3e4de";
        public const string FabricAdministrator = "a9ea8996-122f-4c74-9520-8edcd192826c"; // Power BI Admin
        public const string PowerPlatformAdministrator = "11648597-926c-4cf3-9c36-bcebb0ba8dcc";
    }

    /// <summary>
    /// Check permissions for the requested scan types. 
    /// Returns a dictionary: scanType → list of issues (empty list = OK).
    /// Checks both OAuth2 API access and Entra directory roles.
    /// </summary>
    public async Task<Dictionary<string, List<string>>> CheckAsync(List<string> scanTypes, CancellationToken ct = default)
    {
        var results = new Dictionary<string, List<string>>();

        // Fetch the user's active directory roles once, reuse for all scan type checks
        var userRoles = await GetUserDirectoryRolesAsync(ct);

        foreach (var scanType in scanTypes)
        {
            var issues = new List<string>();
            try
            {
                switch (scanType.ToLower())
                {
                    case "sharepoint":
                        await CheckSharePointAsync(issues, ct);
                        CheckSharePointRoles(issues, userRoles);
                        break;
                    case "entra":
                        await CheckEntraAsync(issues, ct);
                        break;
                    case "exchange":
                        await CheckExchangeAsync(issues, ct);
                        CheckExchangeRoles(issues, userRoles);
                        break;
                    case "onedrive":
                        await CheckOneDriveAsync(issues, ct);
                        CheckOneDriveRoles(issues, userRoles);
                        break;
                    case "powerbi":
                        await CheckPowerBIAsync(issues, ct);
                        CheckPowerBIRoles(issues, userRoles);
                        break;
                    case "powerautomate":
                        await CheckPowerAutomateAsync(issues, ct);
                        CheckPowerAutomateRoles(issues, userRoles);
                        break;
                    case "azure":
                        await CheckAzureAsync(issues, ct);
                        break;
                    case "azuredevops":
                        await CheckAzureDevOpsAsync(issues, ct);
                        break;
                    case "purview":
                        await CheckPurviewAsync(issues, ct);
                        CheckPurviewRoles(issues, userRoles);
                        break;
                }
            }
            catch (Exception ex)
            {
                issues.Add($"Pre-check failed: {ex.Message}");
            }
            results[scanType] = issues;
        }

        return results;
    }

    /// <summary>
    /// Fetches the currently signed-in user's active Entra directory role template IDs.
    /// </summary>
    private async Task<HashSet<string>> GetUserDirectoryRolesAsync(CancellationToken ct)
    {
        var roleIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            await foreach (var role in _graphClient.GetPaginatedAsync(
                "me/memberOf/microsoft.graph.directoryRole?$select=roleTemplateId,displayName", ct: ct))
            {
                if (role.TryGetProperty("roleTemplateId", out var rtId) && rtId.ValueKind == JsonValueKind.String)
                {
                    var id = rtId.GetString();
                    if (!string.IsNullOrEmpty(id)) roleIds.Add(id);
                }
            }
        }
        catch
        {
            // If we can't enumerate roles, we'll skip role checks silently — the API-level checks still run
        }
        return roleIds;
    }

    private static bool HasRole(HashSet<string> userRoles, params string[] roleTemplateIds)
    {
        foreach (var id in roleTemplateIds)
            if (userRoles.Contains(id)) return true;
        return false;
    }

    private async Task CheckSharePointAsync(List<string> issues, CancellationToken ct)
    {
        // Check if we can list sites (the scanner uses sites?search=* for enumeration)
        await RunCheck(issues, "Sites.Read.All / Sites.ReadWrite.All / Sites.FullControl.All",
            "SharePoint site enumeration",
            async () => await _graphClient.GetAsync("sites?$top=1&$select=id", ct: ct));
    }

    private async Task CheckEntraAsync(List<string> issues, CancellationToken ct)
    {
        await RunCheck(issues, "Directory.Read.All",
            "Entra directory role enumeration",
            async () => await _graphClient.GetAsync("directoryRoles?$select=id", ct: ct));

        await RunCheck(issues, "Application.Read.All",
            "app registration scanning",
            async () => await _graphClient.GetAsync("applications?$top=1&$select=id", ct: ct));

        await RunCheck(issues, "GroupMember.Read.All or Group.Read.All",
            "group membership scanning",
            async () => await _graphClient.GetAsync("groups?$top=1&$select=id", ct: ct));

        // Optional: Subscription.Read.All for webhook subscription enumeration
        await RunCheck(issues, "Subscription.Read.All",
            "Graph webhook subscription scanning (subscription scanning will be skipped without this)",
            async () => await _graphClient.GetAsync("subscriptions", ct: ct),
            optional: true);

        // PIM is optional — not all tenants have it
        await RunCheck(issues, "RoleEligibilitySchedule.Read.Directory",
            "PIM eligible role assignments (PIM scanning will be skipped without this)",
            async () => await _graphClient.GetAsync("roleManagement/directory/roleEligibilityScheduleInstances?$top=1", ct: ct),
            optional: true);
    }

    private async Task CheckExchangeAsync(List<string> issues, CancellationToken ct)
    {
        // Try to get a single mailbox to verify Exchange access
        try
        {
            var organization = _auth.TenantDomain ?? "";
            using var http = new HttpClient();
            var token = await _auth.GetAccessTokenAsync("exchange", ct);

            var body = new Dictionary<string, object>
            {
                ["CmdletInput"] = new
                {
                    CmdletName = "Get-Mailbox",
                    Parameters = new Dictionary<string, object> { ["ResultSize"] = "1" }
                }
            };

            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"https://outlook.office365.com/adminapi/beta/{organization}/InvokeCommand");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            request.Headers.Add("X-CmdletName", "Get-Mailbox");
            request.Content = new StringContent(
                JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");

            var response = await http.SendAsync(request, ct);
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Missing permission: Exchange.ManageAsApp or Exchange Administrator role (needed for Exchange mailbox scanning)");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire Exchange token. The app registration may not have Exchange permissions configured.");
        }
    }

    private async Task CheckOneDriveAsync(List<string> issues, CancellationToken ct)
    {
        await RunCheck(issues, "User.Read.All",
            "OneDrive user enumeration",
            async () => await _graphClient.GetAsync("users?$top=1&$select=id", ct: ct));

        await RunCheck(issues, "Files.Read.All",
            "OneDrive file permission scanning",
            async () => await _graphClient.GetAsync("me/drive?$select=id", ct: ct),
            optional: true);
    }

    private async Task CheckPowerBIAsync(List<string> issues, CancellationToken ct)
    {
        try
        {
            var token = await _auth.GetAccessTokenAsync("powerbi", ct);
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.powerbi.com/v1.0/myorg/groups?$top=1");
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Missing permission: Workspace.Read.All on Power BI service (needed for Power BI workspace scanning)");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire Power BI token. Ensure the app registration has Power BI API permissions configured.");
        }
    }

    private async Task CheckPowerAutomateAsync(List<string> issues, CancellationToken ct)
    {
        // Check BAP API access (environment enumeration uses service.powerapps.com token)
        try
        {
            var token = await _auth.GetAccessTokenAsync("powerapps", ct);
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2016-11-01");
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Missing permission: Power Platform BAP access (needed for environment enumeration)");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire Power Platform token. Power Platform scanning may require interactive login.");
        }

        // Check Flow API access (flow scanning uses service.powerapps.com token, same as BAP)
        try
        {
            var token = await _auth.GetAccessTokenAsync("powerapps", ct);
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments?api-version=2016-11-01");
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Missing permission: Flow API access (needed for flow scanning)");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire PowerApps token. Flow scanning may require interactive login.");
        }
        catch { /* Non-critical */ }

        // Check PowerApps API access
        try
        {
            var token = await _auth.GetAccessTokenAsync("powerapps", ct);
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://api.powerapps.com/providers/Microsoft.PowerApps/apps?api-version=2016-11-01&$top=1");
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Cannot access PowerApps API (needed for Power Apps and connector scanning). PowerApps scanning will be skipped.");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire PowerApps token. PowerApps and connector scanning will be skipped.");
        }
        catch { /* Non-critical — PowerApps scanning is optional */ }
    }

    private async Task CheckAzureAsync(List<string> issues, CancellationToken ct)
    {
        try
        {
            var token = await _auth.GetAccessTokenAsync("azure", ct);
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://management.azure.com/subscriptions?api-version=2022-12-01&$top=1");
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Missing permission: Reader role on Azure subscriptions (needed for RBAC role assignment scanning)");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire Azure Management token. Ensure the user has access to Azure subscriptions.");
        }
    }

    private async Task CheckAzureDevOpsAsync(List<string> issues, CancellationToken ct)
    {
        try
        {
            var token = await _auth.GetAccessTokenAsync("azuredevops", ct);
            using var http = new HttpClient();
            using var req = new HttpRequestMessage(HttpMethod.Get,
                "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1-preview.3");
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Cannot access Azure DevOps. Ensure the user has access to at least one Azure DevOps organization.");
            }
            else if (!resp.IsSuccessStatusCode)
            {
                issues.Add($"Azure DevOps profile API returned HTTP {(int)resp.StatusCode}. Delegated authentication may not be configured.");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire Azure DevOps token. Add 'Azure DevOps' API permission (user_impersonation) to app registration 0ee7aa45-310d-4b82-9cb5-11cc01ad38e4 in Entra ID → App registrations → API permissions → Add → Azure DevOps → Delegated → user_impersonation, then grant admin consent.");
        }
    }

    /// <summary>
    /// Runs a single permission check. Catches all errors per-check so subsequent checks still run.
    /// </summary>
    private static async Task RunCheck(List<string> issues, string permissionName, string purpose,
        Func<Task> check, bool optional = false)
    {
        try
        {
            await check();
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden)
        {
            issues.Add($"Missing permission: {permissionName} (needed for {purpose})");
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            issues.Add($"Unauthorized: {permissionName} — token may lack consent or be expired (needed for {purpose})");
        }
        catch (HttpRequestException ex) when (optional)
        {
            // Optional checks: non-403/401 errors are silently ignored (e.g. endpoint not supported)
            _ = ex;
        }
        catch (HttpRequestException ex)
        {
            issues.Add($"Error checking {permissionName}: HTTP {(int?)ex.StatusCode} {ex.Message}");
        }
        catch (Exception ex) when (optional)
        {
            _ = ex;
        }
        catch (Exception ex)
        {
            issues.Add($"Error checking {permissionName}: {ex.Message}");
        }
    }

    // --- Entra directory role checks per scan type ---

    private static void CheckSharePointRoles(List<string> issues, HashSet<string> userRoles)
    {
        if (HasRole(userRoles, RoleTemplateIds.GlobalAdministrator, RoleTemplateIds.SharePointAdministrator))
            return;

        issues.Add("Missing role: SharePoint Administrator (or Global Administrator). " +
            "Without this role the scanner cannot temporarily add itself as site collection admin to scan sites you don't own. " +
            "Only sites where you are already a member or admin will be fully scanned — other sites will have incomplete permission data.");
    }

    private static void CheckExchangeRoles(List<string> issues, HashSet<string> userRoles)
    {
        if (HasRole(userRoles, RoleTemplateIds.GlobalAdministrator, RoleTemplateIds.ExchangeAdministrator))
            return;

        issues.Add("Missing role: Exchange Administrator (or Global Administrator). " +
            "Without this role, Get-RecipientPermission (SendAs) and Get-MailboxPermission may fail or return limited results. " +
            "SendAs permission data and mailbox delegate access will likely be incomplete or missing entirely.");
    }

    private static void CheckOneDriveRoles(List<string> issues, HashSet<string> userRoles)
    {
        if (HasRole(userRoles, RoleTemplateIds.GlobalAdministrator, RoleTemplateIds.SharePointAdministrator))
            return;

        issues.Add("Missing role: SharePoint Administrator (or Global Administrator). " +
            "OneDrive is managed through SharePoint. Without this role the scanner cannot elevate to site admin on OneDrive sites. " +
            "Only your own OneDrive and sites where you already have access will be scanned.");
    }

    private static void CheckPowerBIRoles(List<string> issues, HashSet<string> userRoles)
    {
        if (HasRole(userRoles, RoleTemplateIds.GlobalAdministrator, RoleTemplateIds.FabricAdministrator))
            return;

        issues.Add("Missing role: Fabric Administrator (Power BI Administrator) or Global Administrator. " +
            "Without this role the Power BI Admin API is not available. The scanner will fall back to user-scoped enumeration, " +
            "which only returns workspaces you are a direct member of. If you are not a member of any workspace, no results will be returned.");
    }

    private static void CheckPowerAutomateRoles(List<string> issues, HashSet<string> userRoles)
    {
        if (HasRole(userRoles, RoleTemplateIds.GlobalAdministrator, RoleTemplateIds.PowerPlatformAdministrator))
            return;

        issues.Add("Missing role: Power Platform Administrator (or Global Administrator). " +
            "Without this role the BAP admin API for environment enumeration may be restricted. " +
            "Only environments and flows you own or have been shared with will be scanned.");
    }

    private async Task CheckPurviewAsync(List<string> issues, CancellationToken ct)
    {
        // Check compliance endpoint access (ps.compliance.protection.outlook.com)
        try
        {
            var tenantId = _auth.TenantId ?? _auth.TenantDomain ?? "";
            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
            var token = await _auth.GetAccessTokenAsync("compliance", ct);

            var body = new Dictionary<string, object>
            {
                ["CmdletInput"] = new
                {
                    CmdletName = "Get-RoleGroup",
                    Parameters = new Dictionary<string, object> { ["ResultSize"] = "1" }
                }
            };

            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"https://ps.compliance.protection.outlook.com/adminapi/beta/{tenantId}/InvokeCommand");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            request.Headers.Add("X-CmdletName", "Get-RoleGroup");
            request.Headers.Add("X-ClientApplication", "ExoManagementModule");
            request.Content = new StringContent(
                JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");

            var response = await http.SendAsync(request, ct);
            // 302 redirect is expected (regional discovery) — that means the endpoint is reachable
            if (response.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                issues.Add("Cannot access Purview Compliance role groups (HTTP 403). Exchange Administrator or Compliance Administrator role is required.");
            }
        }
        catch (InvalidOperationException)
        {
            issues.Add("Cannot acquire compliance token. Purview scanning will be skipped. Ensure the compliance scope (ps.compliance.protection.outlook.com) is configured on the app registration.");
        }
    }

    private static void CheckPurviewRoles(List<string> issues, HashSet<string> userRoles)
    {
        if (HasRole(userRoles, RoleTemplateIds.GlobalAdministrator, RoleTemplateIds.ExchangeAdministrator))
            return;

        issues.Add("Missing role: Exchange Administrator or Global Administrator. " +
            "Without this role, Purview Compliance Center role group enumeration may return limited results.");
    }
}
