using System.Text.Json;
using M365Permissions.Engine.Graph;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans Entra ID (Azure AD) for permissions: users, groups, roles, service principals, app registrations.
/// Replaces V1's get-AllEntraPermissions.ps1.
/// </summary>
public sealed class EntraScanner : IScanProvider
{
    public string Category => "Entra";

    private readonly GraphClient _graphClient;

    public EntraScanner(GraphClient graphClient)
    {
        _graphClient = graphClient;
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        // --- Directory Roles ---
        context.ReportProgress("Scanning Entra directory roles...", 3);

        var roles = new List<JsonElement>();
        await foreach (var role in _graphClient.GetPaginatedAsync("directoryRoles?$expand=members", ct: ct))
        {
            roles.Add(role);
        }

        context.ReportProgress($"Found {roles.Count} directory roles.", 3);

        // We'll add to total targets as we discover groups later
        context.SetTotalTargets(roles.Count + 3); // roles + apps phase + OAuth2 phase + groups-enum phase

        foreach (var role in roles)
        {
            ct.ThrowIfCancellationRequested();

            var roleName = role.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
            var roleId = role.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";

            if (role.TryGetProperty("members", out var members) && members.ValueKind == JsonValueKind.Array)
            {
                foreach (var member in members.EnumerateArray())
                {
                    yield return MapDirectoryRoleMember(member, roleName, roleId);
                }
            }

            context.CompleteTarget();
        }

        // --- App Registrations with permissions ---
        context.ReportProgress("Scanning app registrations...", 3);

        int appCount = 0;
        await foreach (var app in _graphClient.GetPaginatedAsync(
            "applications?$select=id,displayName,appId,requiredResourceAccess", ct: ct))
        {
            ct.ThrowIfCancellationRequested();
            appCount++;

            var appName = app.TryGetProperty("displayName", out var dn2) ? dn2.GetString() ?? "" : "";
            var appObjId = app.TryGetProperty("id", out var id2) ? id2.GetString() ?? "" : "";
            var appClientId = app.TryGetProperty("appId", out var aid) ? aid.GetString() ?? "" : "";

            if (app.TryGetProperty("requiredResourceAccess", out var rra) && rra.ValueKind == JsonValueKind.Array)
            {
                foreach (var resource in rra.EnumerateArray())
                {
                    var resourceAppId = resource.TryGetProperty("resourceAppId", out var rai) ? rai.GetString() ?? "" : "";
                    if (resource.TryGetProperty("resourceAccess", out var accesses) && accesses.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var access in accesses.EnumerateArray())
                        {
                            var permId = access.TryGetProperty("id", out var pid) ? pid.GetString() ?? "" : "";
                            var permType = access.TryGetProperty("type", out var pt) ? pt.GetString() ?? "" : "";

                            yield return new PermissionEntry
                            {
                                TargetPath = $"AppRegistration/{appName}",
                                TargetType = "Application",
                                TargetId = appObjId,
                                PrincipalEntraId = appClientId,
                                PrincipalSysName = appName,
                                PrincipalType = "Application",
                                PrincipalRole = permId,
                                Through = permType == "Role" ? "ApplicationPermission" : "DelegatedPermission",
                                AccessType = "Allow",
                                Tenure = "Permanent"
                            };
                        }
                    }
                }
            }
        }

        context.ReportProgress($"Scanned {appCount} app registrations.", 3);
        context.CompleteTarget();

        // --- PIM: Eligible directory role assignments ---
        context.ReportProgress("Checking for PIM (Privileged Identity Management) eligible assignments...", 3);

        bool pimAvailable = false;
        int eligibleCount = 0;
        var pimRoleEntries = new List<PermissionEntry>();
        try
        {
            await foreach (var assignment in _graphClient.GetPaginatedAsync(
                "roleManagement/directory/roleEligibilityScheduleInstances?$expand=principal,roleDefinition", ct: ct))
            {
                ct.ThrowIfCancellationRequested();
                pimAvailable = true;
                eligibleCount++;

                var roleDef = assignment.TryGetProperty("roleDefinition", out var rd) ? rd : default;
                var roleName = roleDef.ValueKind != JsonValueKind.Undefined &&
                               roleDef.TryGetProperty("displayName", out var rdn) ? rdn.GetString() ?? "" : "";
                var roleDefId = assignment.TryGetProperty("roleDefinitionId", out var rdi) ? rdi.GetString() ?? "" : "";

                var principal = assignment.TryGetProperty("principal", out var pr) ? pr : default;
                var principalId = assignment.TryGetProperty("principalId", out var pid) ? pid.GetString() ?? "" : "";
                var principalUpn = principal.ValueKind != JsonValueKind.Undefined &&
                                   principal.TryGetProperty("userPrincipalName", out var pupn) ? pupn.GetString() ?? "" : "";
                var principalName = principal.ValueKind != JsonValueKind.Undefined &&
                                    principal.TryGetProperty("displayName", out var pdn) ? pdn.GetString() ?? "" : "";
                var principalOdataType = principal.ValueKind != JsonValueKind.Undefined &&
                                         principal.TryGetProperty("@odata.type", out var pot) ? pot.GetString() ?? "" : "";

                var startTime = assignment.TryGetProperty("startDateTime", out var st) ? st.GetString() ?? "" : "";
                var endTime = assignment.TryGetProperty("endDateTime", out var et) ? et.GetString() ?? "" : "";

                pimRoleEntries.Add(new PermissionEntry
                {
                    TargetPath = $"DirectoryRole/{roleName}",
                    TargetType = "DirectoryRole",
                    TargetId = roleDefId,
                    PrincipalEntraId = principalId,
                    PrincipalEntraUpn = principalUpn,
                    PrincipalSysName = principalName,
                    PrincipalType = MapMemberType(principalOdataType),
                    PrincipalRole = roleName,
                    Through = "PIM-Eligible",
                    AccessType = "Allow",
                    Tenure = string.IsNullOrEmpty(endTime) ? "Eligible-Permanent" : $"Eligible (until {endTime})"
                });
            }
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden ||
                                                ex.StatusCode == System.Net.HttpStatusCode.BadRequest)
        {
            context.ReportProgress("PIM not available in this tenant (may require P2 license).", 3);
        }
        catch (Exception ex)
        {
            context.ReportProgress($"PIM role eligibility check failed: {ex.Message}", 3);
        }

        foreach (var e in pimRoleEntries) yield return e;

        // --- PIM: Eligible group memberships ---
        var pimGroupEntries = new List<PermissionEntry>();
        try
        {
            await foreach (var assignment in _graphClient.GetPaginatedAsync(
                "identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$expand=principal,group", ct: ct))
            {
                ct.ThrowIfCancellationRequested();
                pimAvailable = true;
                eligibleCount++;

                var group = assignment.TryGetProperty("group", out var g) ? g : default;
                var groupName = group.ValueKind != JsonValueKind.Undefined &&
                                group.TryGetProperty("displayName", out var gdn) ? gdn.GetString() ?? "" : "";
                var groupId = assignment.TryGetProperty("groupId", out var gid) ? gid.GetString() ?? "" : "";
                var accessId = assignment.TryGetProperty("accessId", out var aid2) ? aid2.GetString() ?? "" : "member";

                var principal = assignment.TryGetProperty("principal", out var pr2) ? pr2 : default;
                var principalId = assignment.TryGetProperty("principalId", out var pid2) ? pid2.GetString() ?? "" : "";
                var principalUpn = principal.ValueKind != JsonValueKind.Undefined &&
                                   principal.TryGetProperty("userPrincipalName", out var pupn2) ? pupn2.GetString() ?? "" : "";
                var principalName = principal.ValueKind != JsonValueKind.Undefined &&
                                    principal.TryGetProperty("displayName", out var pdn2) ? pdn2.GetString() ?? "" : "";
                var principalOdataType = principal.ValueKind != JsonValueKind.Undefined &&
                                         principal.TryGetProperty("@odata.type", out var pot2) ? pot2.GetString() ?? "" : "";

                var endTime = assignment.TryGetProperty("endDateTime", out var et2) ? et2.GetString() ?? "" : "";

                pimGroupEntries.Add(new PermissionEntry
                {
                    TargetPath = $"Group/{groupName}",
                    TargetType = "SecurityGroup",
                    TargetId = groupId,
                    PrincipalEntraId = principalId,
                    PrincipalEntraUpn = principalUpn,
                    PrincipalSysName = principalName,
                    PrincipalType = MapMemberType(principalOdataType),
                    PrincipalRole = accessId == "owner" ? "Owner" : "Member",
                    Through = "PIM-EligibleGroupAccess",
                    AccessType = "Allow",
                    Tenure = string.IsNullOrEmpty(endTime) ? "Eligible-Permanent" : $"Eligible (until {endTime})"
                });
            }
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden ||
                                                ex.StatusCode == System.Net.HttpStatusCode.BadRequest)
        {
            // Expected if PIM for groups is not configured
        }
        catch (Exception ex)
        {
            context.ReportProgress($"PIM group eligibility check failed: {ex.Message}", 3);
        }

        foreach (var e in pimGroupEntries) yield return e;

        if (pimAvailable)
            context.ReportProgress($"PIM active: found {eligibleCount} eligible assignments.", 3);
        else
            context.ReportProgress("PIM not detected or not accessible in this tenant.", 3);

        // --- Service Principal OAuth2 grants (delegated consent) ---
        context.ReportProgress("Scanning OAuth2 permission grants...", 3);

        // Build service principal lookup cache (id → displayName) for resolving OAuth2 grant targets
        context.ReportProgress("Building service principal cache for OAuth2 grants...", 3);
        var spCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        await foreach (var sp in _graphClient.GetPaginatedAsync(
            "servicePrincipals?$select=id,displayName", ct: ct))
        {
            ct.ThrowIfCancellationRequested();
            var spId = sp.TryGetProperty("id", out var sid) ? sid.GetString() ?? "" : "";
            var spName = sp.TryGetProperty("displayName", out var sdn) ? sdn.GetString() ?? "" : "";
            if (!string.IsNullOrEmpty(spId))
                spCache[spId] = spName;
        }
        context.ReportProgress($"Cached {spCache.Count} service principals.", 3);

        int grantCount = 0;
        await foreach (var grant in _graphClient.GetPaginatedAsync(
            "oauth2PermissionGrants?$select=id,clientId,consentType,principalId,resourceId,scope", ct: ct))
        {
            ct.ThrowIfCancellationRequested();
            grantCount++;

            var clientId = grant.TryGetProperty("clientId", out var ci) ? ci.GetString() ?? "" : "";
            var resourceId = grant.TryGetProperty("resourceId", out var ri) ? ri.GetString() ?? "" : "";
            var scope = grant.TryGetProperty("scope", out var s) ? s.GetString() ?? "" : "";
            var consentType = grant.TryGetProperty("consentType", out var ct2) ? ct2.GetString() ?? "" : "";
            var principalId = grant.TryGetProperty("principalId", out var pi) ? pi.GetString() ?? "" : "";

            // Resolve display names from cache
            spCache.TryGetValue(clientId, out var clientName);
            spCache.TryGetValue(resourceId, out var resourceName);
            var targetPath = !string.IsNullOrEmpty(clientName) ? $"OAuth2PermissionGrant/{clientName}" : "OAuth2PermissionGrant";

            foreach (var permission in scope.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                yield return new PermissionEntry
                {
                    TargetPath = targetPath,
                    TargetType = "DelegatedConsent",
                    TargetId = resourceId,
                    PrincipalEntraId = clientId,
                    PrincipalSysName = clientName ?? "",
                    PrincipalType = consentType == "AllPrincipals" ? "AllPrincipals" : "User",
                    PrincipalRole = permission,
                    Through = !string.IsNullOrEmpty(resourceName) ? $"OAuth2Grant → {resourceName}" : "OAuth2Grant",
                    ParentId = principalId,
                    AccessType = "Allow",
                    Tenure = "Permanent"
                };
            }
        }

        context.ReportProgress($"Found {grantCount} OAuth2 grants.", 3);
        context.CompleteTarget();

        // --- Graph Subscriptions (webhook change notifications) ---
        context.ReportProgress("Scanning Graph webhook subscriptions...", 3);

        var subscriptionEntries = new List<PermissionEntry>();
        try
        {
            await foreach (var sub in _graphClient.GetPaginatedAsync(
                "subscriptions", ct: ct))
            {
                ct.ThrowIfCancellationRequested();

                var subId = sub.TryGetProperty("id", out var sid) ? sid.GetString() ?? "" : "";
                var resource = sub.TryGetProperty("resource", out var res) ? res.GetString() ?? "" : "";
                var changeType = sub.TryGetProperty("changeType", out var ctp) ? ctp.GetString() ?? "" : "";
                var notificationUrl = sub.TryGetProperty("notificationUrl", out var nu) ? nu.GetString() ?? "" : "";
                var expirationStr = sub.TryGetProperty("expirationDateTime", out var exp) ? exp.GetString() ?? "" : "";
                var applicationId = sub.TryGetProperty("applicationId", out var appId) ? appId.GetString() ?? "" : "";
                var creatorId = sub.TryGetProperty("creatorId", out var cid) ? cid.GetString() ?? "" : "";
                var includeResourceData = sub.TryGetProperty("includeResourceData", out var ird)
                    && ird.ValueKind == JsonValueKind.True;

                // Resolve application name from SP cache if available
                var appName = "";
                if (!string.IsNullOrEmpty(applicationId))
                    spCache.TryGetValue(applicationId, out appName);
                appName ??= "";

                // Determine tenure from expiration
                var tenure = "Permanent";
                if (!string.IsNullOrEmpty(expirationStr) && DateTimeOffset.TryParse(expirationStr, out var expDate))
                {
                    tenure = expDate > DateTimeOffset.UtcNow
                        ? $"Expires {expDate:yyyy-MM-dd HH:mm} UTC"
                        : $"Expired {expDate:yyyy-MM-dd HH:mm} UTC";
                }

                // Extract notification domain for readability
                var notifDomain = "";
                if (Uri.TryCreate(notificationUrl, UriKind.Absolute, out var notifUri))
                    notifDomain = notifUri.Host;

                var targetLabel = !string.IsNullOrEmpty(appName) ? appName : applicationId;

                subscriptionEntries.Add(new PermissionEntry
                {
                    TargetPath = $"Subscription/{targetLabel}/{resource}",
                    TargetType = "Subscription",
                    TargetId = subId,
                    PrincipalEntraId = applicationId,
                    PrincipalSysId = creatorId,
                    PrincipalSysName = !string.IsNullOrEmpty(appName) ? appName : applicationId,
                    PrincipalType = "Application",
                    PrincipalRole = changeType,
                    Through = !string.IsNullOrEmpty(notifDomain) ? $"Webhook → {notifDomain}" : "Webhook",
                    AccessType = includeResourceData ? "IncludesResourceData" : "NotificationOnly",
                    Tenure = tenure
                });
            }
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Forbidden ||
                                                ex.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            context.ReportProgress("Cannot list Graph subscriptions — Subscription.Read.All permission may be missing. Skipping.", 3);
        }
        catch (Exception ex)
        {
            context.ReportProgress($"Graph subscription enumeration failed: {ex.Message}", 3);
        }

        foreach (var e in subscriptionEntries) yield return e;
        context.ReportProgress($"Found {subscriptionEntries.Count} Graph webhook subscriptions.", 3);

        // --- Group memberships (security groups + M365 groups) ---
        context.ReportProgress("Enumerating groups...", 3);

        // First collect all groups, then set targets to include per-group progress
        var groups = new List<JsonElement>();
        await foreach (var group in _graphClient.GetPaginatedAsync(
            "groups?$select=id,displayName,groupTypes,securityEnabled,mailEnabled", ct: ct))
        {
            groups.Add(group);
        }

        context.ReportProgress($"Found {groups.Count} groups to scan for memberships.", 3);
        // Update total: roles already completed + apps + OAuth2 + individual groups
        context.SetTotalTargets(roles.Count + 2 + groups.Count);

        int groupsDone = 0;
        foreach (var group in groups)
        {
            ct.ThrowIfCancellationRequested();

            var groupId = group.TryGetProperty("id", out var gid) ? gid.GetString() ?? "" : "";
            var groupName = group.TryGetProperty("displayName", out var gdn) ? gdn.GetString() ?? "" : "";
            var secEnabled = group.TryGetProperty("securityEnabled", out var se) && se.GetBoolean();

            if (string.IsNullOrEmpty(groupId))
            {
                context.CompleteTarget();
                groupsDone++;
                continue;
            }

            // Get group members
            var memberEntries = new List<PermissionEntry>();
            bool memberFetchFailed = false;
            try
            {
                await foreach (var member in _graphClient.GetPaginatedAsync(
                    $"groups/{groupId}/members?$select=id,displayName,userPrincipalName", ct: ct))
                {
                    var memberUpn = member.TryGetProperty("userPrincipalName", out var upn) ? upn.GetString() ?? "" : "";
                    var memberName = member.TryGetProperty("displayName", out var mdn) ? mdn.GetString() ?? "" : "";
                    var memberId = member.TryGetProperty("id", out var mid) ? mid.GetString() ?? "" : "";
                    var memberType = member.TryGetProperty("@odata.type", out var ot) ? ot.GetString() ?? "" : "";

                    memberEntries.Add(new PermissionEntry
                    {
                        TargetPath = $"Group/{groupName}",
                        TargetType = secEnabled ? "SecurityGroup" : "M365Group",
                        TargetId = groupId,
                        PrincipalEntraId = memberId,
                        PrincipalEntraUpn = memberUpn,
                        PrincipalSysName = memberName,
                        PrincipalType = MapMemberType(memberType),
                        PrincipalRole = "Member",
                        Through = "Direct",
                        AccessType = "Allow",
                        Tenure = "Permanent"
                    });
                }
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Failed to get members of group '{groupName}': {ex.Message}", 2);
                memberFetchFailed = true;
            }

            // Yield whatever members we collected (even if partial due to error)
            foreach (var e in memberEntries) yield return e;

            if (memberFetchFailed)
            {
                context.FailTarget();
            }
            else
            {
                context.CompleteTarget();
            }

            groupsDone++;

            // Log progress periodically
            if (groupsDone % 50 == 0)
                context.ReportProgress($"Scanned {groupsDone}/{groups.Count} groups...", 4);
        }

        context.ReportProgress($"Completed scanning {groupsDone} groups.", 3);
    }

    private static PermissionEntry MapDirectoryRoleMember(JsonElement member, string roleName, string roleId)
    {
        var upn = member.TryGetProperty("userPrincipalName", out var u) ? u.GetString() ?? "" : "";
        var displayName = member.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
        var memberId = member.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "";
        var odataType = member.TryGetProperty("@odata.type", out var ot) ? ot.GetString() ?? "" : "";

        return new PermissionEntry
        {
            TargetPath = $"DirectoryRole/{roleName}",
            TargetType = "DirectoryRole",
            TargetId = roleId,
            PrincipalEntraId = memberId,
            PrincipalEntraUpn = upn,
            PrincipalSysName = displayName,
            PrincipalType = MapMemberType(odataType),
            PrincipalRole = roleName,
            Through = "DirectoryRoleAssignment",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    private static string MapMemberType(string odataType) => odataType switch
    {
        "#microsoft.graph.user" => "User",
        "#microsoft.graph.servicePrincipal" => "ServicePrincipal",
        "#microsoft.graph.group" => "Group",
        "#microsoft.graph.device" => "Device",
        _ => "Unknown"
    };
}
