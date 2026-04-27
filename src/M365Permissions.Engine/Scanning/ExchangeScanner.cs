using System.Text.Json;
using M365Permissions.Engine.Graph;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Scans Exchange Online for mailbox permissions (FullAccess, SendAs, SendOnBehalf).
/// Uses Exchange REST API (InvokeCommand pattern), matching V1's get-ExOPermissions.ps1.
/// </summary>
public sealed class ExchangeScanner : IScanProvider
{
    public string Category => "Exchange";

    private readonly ExchangeRestClient _exoClient;
    private readonly GraphClient _graphClient;

    public ExchangeScanner(ExchangeRestClient exoClient, GraphClient graphClient)
    {
        _exoClient = exoClient;
        _graphClient = graphClient;
    }

    public async IAsyncEnumerable<PermissionEntry> ScanAsync(
        ScanContext context,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        context.ReportProgress("Enumerating Exchange mailboxes...", 3);

        // Get organization domain for EXO REST calls
        var organization = context.TenantDomain;

        // Get all mailboxes
        var mailboxes = await _exoClient.GetMailboxesAsync(organization, ct);

        context.SetTotalTargets(mailboxes.Count);
        context.ReportProgress($"Found {mailboxes.Count} mailboxes to scan.", 3);

        foreach (var mailbox in mailboxes)
        {
            ct.ThrowIfCancellationRequested();

            var identity = mailbox.TryGetProperty("Identity", out var id) ? id.GetString() ?? "" : "";
            var displayName = mailbox.TryGetProperty("DisplayName", out var dn) ? dn.GetString() ?? "" : "";
            var primarySmtp = mailbox.TryGetProperty("PrimarySmtpAddress", out var smtp) ? smtp.GetString() ?? "" : "";
            var externalId = mailbox.TryGetProperty("ExternalDirectoryObjectId", out var edi) ? edi.GetString() ?? "" : "";

            if (string.IsNullOrEmpty(identity))
            {
                context.CompleteTarget();
                continue;
            }

            // Skip system mailboxes (e.g. DiscoverySearchMailbox)
            if (displayName.StartsWith("DiscoverySearchMailbox", StringComparison.OrdinalIgnoreCase))
            {
                context.CompleteTarget();
                continue;
            }

            context.ReportProgress($"Scanning mailbox: {displayName}", 5);

            // --- Mailbox permissions (FullAccess) ---
            List<JsonElement> mbxPermissions;
            try
            {
                mbxPermissions = await _exoClient.GetMailboxPermissionsAsync(organization, identity, ct);
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Failed to get mailbox permissions for {displayName}: {ex.Message}", 2);
                mbxPermissions = new();
            }

            foreach (var perm in mbxPermissions)
            {
                var entries = MapMailboxPermission(perm, primarySmtp, externalId, displayName);
                foreach (var entry in entries)
                    yield return entry;
            }

            // --- Recipient permissions (SendAs) ---
            List<JsonElement> recipientPermissions;
            try
            {
                recipientPermissions = await _exoClient.GetRecipientPermissionsAsync(organization, identity, ct);
            }
            catch (Exception ex)
            {
                context.ReportProgress($"Failed to get recipient permissions for {displayName}: {ex.Message}", 2);
                recipientPermissions = new();
            }

            foreach (var perm in recipientPermissions)
            {
                var entry = MapRecipientPermission(perm, primarySmtp, externalId, displayName);
                if (entry != null) yield return entry;
            }

            // --- SendOnBehalf (from mailbox properties) ---
            if (mailbox.TryGetProperty("GrantSendOnBehalfTo", out var delegates) &&
                delegates.ValueKind == JsonValueKind.Array)
            {
                foreach (var del in delegates.EnumerateArray())
                {
                    var delName = del.GetString() ?? "";
                    yield return new PermissionEntry
                    {
                        TargetPath = primarySmtp,
                        TargetType = "Mailbox",
                        TargetId = externalId,
                        PrincipalSysName = delName,
                        PrincipalType = "User",
                        PrincipalRole = "SendOnBehalf",
                        Through = "GrantSendOnBehalfTo",
                        AccessType = "Allow",
                        Tenure = "Permanent"
                    };
                }
            }

            context.CompleteTarget();
        }
    }

    private static List<PermissionEntry> MapMailboxPermission(JsonElement perm, string targetEmail, string targetId, string targetName)
    {
        var entries = new List<PermissionEntry>();

        var user = perm.TryGetProperty("User", out var u) ? u.GetString() ?? "" : "";

        // Skip self and inherited
        if (user.Equals("NT AUTHORITY\\SELF", StringComparison.OrdinalIgnoreCase)) return entries;
        if (perm.TryGetProperty("IsInherited", out var inh) && GetBool(inh)) return entries;

        // Skip orphaned SIDs
        if (user.StartsWith("S-1-5-21-", StringComparison.Ordinal)) return entries;

        if (perm.TryGetProperty("AccessRights", out var rights) && rights.ValueKind == JsonValueKind.Array)
        {
            foreach (var right in rights.EnumerateArray())
            {
                var rightName = right.GetString() ?? "";
                entries.Add(new PermissionEntry
                {
                    TargetPath = targetEmail,
                    TargetType = "Mailbox",
                    TargetId = targetId,
                    PrincipalSysName = user,
                    PrincipalType = MapExoUserType(user),
                    PrincipalRole = rightName,
                    Through = "MailboxPermission",
                    AccessType = perm.TryGetProperty("Deny", out var deny) && GetBool(deny) ? "Deny" : "Allow",
                    Tenure = "Permanent"
                });
            }
        }

        return entries;
    }

    private static PermissionEntry? MapRecipientPermission(JsonElement perm, string targetEmail, string targetId, string targetName)
    {
        var trustee = perm.TryGetProperty("Trustee", out var t) ? t.GetString() ?? "" : "";

        // Skip self
        if (trustee.Equals("NT AUTHORITY\\SELF", StringComparison.OrdinalIgnoreCase)) return null;

        var accessRights = perm.TryGetProperty("AccessRights", out var ar) && ar.ValueKind == JsonValueKind.Array
            ? string.Join(", ", ar.EnumerateArray().Select(a => a.GetString()))
            : "SendAs";

        return new PermissionEntry
        {
            TargetPath = targetEmail,
            TargetType = "Mailbox",
            TargetId = targetId,
            PrincipalSysName = trustee,
            PrincipalType = MapExoUserType(trustee),
            PrincipalRole = accessRights,
            Through = "RecipientPermission",
            AccessType = "Allow",
            Tenure = "Permanent"
        };
    }

    /// <summary>Read a JSON value as bool, handling both JSON booleans and string representations.</summary>
    private static bool GetBool(JsonElement el) => el.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.String => bool.TryParse(el.GetString(), out var b) && b,
        _ => false
    };

    private static string MapExoUserType(string user)
    {
        if (user.Equals("Default", StringComparison.OrdinalIgnoreCase)) return "AllInternalUsers";
        if (user.Equals("Anonymous", StringComparison.OrdinalIgnoreCase)) return "Anonymous";
        if (user.Contains("ExchangePublishedUser", StringComparison.OrdinalIgnoreCase)) return "ExternalUser";
        return "User";
    }
}
