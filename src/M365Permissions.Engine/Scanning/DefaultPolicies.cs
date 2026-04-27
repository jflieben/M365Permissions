using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Pre-seeded default policy rules that replicate the built-in risk classification logic.
/// These are created on first run if no policies exist.
/// </summary>
public static class DefaultPolicies
{
    private const string CriticalAdminRolesRegex =
        @"^(Global Administrator|Company Administrator|Exchange Administrator|SharePoint Administrator|Teams Administrator|Security Administrator|Privileged Role Administrator|Privileged Authentication Administrator|User Administrator|Application Administrator|Cloud Application Administrator|Intune Administrator|Authentication Administrator|Billing Administrator|Conditional Access Administrator|Compliance Administrator)$";

    private const string CriticalPurviewRolesRegex = @"(?i)^(Organization Management|eDiscovery Manager|eDiscovery Administrator|Compliance Administrator)$";
    private const string HighPurviewRoleGroupsRegex = @"(?i)(Compliance Management|Security Administrator|Information Protection|Data Loss Prevention|Records Management|Insider Risk Management|Data Investigator|Communication Compliance)";

    private const string CriticalAzureRolesRegex = @"^(Owner|Contributor|User Access Administrator)$";

    private const string CriticalDevOpsRolesRegex = @"(?i)(Project Collection Administrators|Project Collection Service Accounts)";
    private const string HighDevOpsRolesRegex = @"(?i)(Project Administrators|Build Administrators|Release Administrators|Endpoint Administrators)";

    private const string HighRiskAppPermsRegex =
        @"(Mail\.ReadWrite|Mail\.Send|Files\.ReadWrite\.All|Sites\.ReadWrite\.All|Sites\.FullControl\.All|Directory\.ReadWrite\.All|RoleManagement\.ReadWrite\.Directory|AppRoleAssignment\.ReadWrite\.All|Application\.ReadWrite\.All|User\.ReadWrite\.All|Group\.ReadWrite\.All|MailboxSettings\.ReadWrite|Calendars\.ReadWrite|Exchange\.ManageAsApp)";

    private const string SensitiveSubscriptionResourcesRegex =
        @"(?i)(message|mail|chatMessage|security|user|group|callRecord|driveItem)";

    private const string BroadPrincipalsRegex =
        @"(?i)(Everyone|Everyone except external users|All Users|AllInternalUsers|Anonymous|c:0\(\.s\|true|c:0-\.f\|rolemanager\|spo-grid-all-users)";

    public static List<Policy> GetAll() => new()
    {
        // ── Critical ────────────────────────────────────────────
        new Policy
        {
            Name = "Permanent active admin role",
            Description = "Permanent active assignment to a critical admin role — should use PIM",
            Severity = "Critical",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "tenure", Operator = "equals", Value = "Permanent" },
                new() { Field = "through", Operator = "regex", Value = @"^(DirectoryRole|Direct)$" },
                new() { Field = "target_path", Operator = "regex", Value = CriticalAdminRolesRegex }
            }
        },
        new Policy
        {
            Name = "Full Control to Everyone/All Users",
            Description = "Full Control permission granted to a broad principal (Everyone, All Users, etc.)",
            Severity = "Critical",
            CategoryFilter = "SharePoint",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "contains", Value = "Full Control" },
                new() { Field = "principal_sys_name", Operator = "regex", Value = BroadPrincipalsRegex }
            }
        },
        new Policy
        {
            Name = "Azure subscription-level Owner/Contributor",
            Description = "Critical Azure RBAC role at subscription scope",
            Severity = "Critical",
            CategoryFilter = "Azure",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = CriticalAzureRolesRegex },
                new() { Field = "target_type", Operator = "equals", Value = "Subscription" }
            }
        },
        new Policy
        {
            Name = "Azure DevOps Project Collection Administrator",
            Description = "Member of Project Collection Administrators — has full control over the entire Azure DevOps organization",
            Severity = "Critical",
            CategoryFilter = "AzureDevOps",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = CriticalDevOpsRolesRegex },
                new() { Field = "target_type", Operator = "equals", Value = "Organization" }
            }
        },

        // ── High ────────────────────────────────────────────────
        new Policy
        {
            Name = "PIM-eligible critical admin role",
            Description = "PIM-eligible assignment to a critical admin role",
            Severity = "High",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "tenure", Operator = "equals", Value = "Eligible" },
                new() { Field = "target_path", Operator = "regex", Value = CriticalAdminRolesRegex }
            }
        },
        new Policy
        {
            Name = "Azure resource group Owner/Contributor",
            Description = "Critical Azure RBAC role at resource group scope",
            Severity = "High",
            CategoryFilter = "Azure",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = CriticalAzureRolesRegex },
                new() { Field = "target_type", Operator = "equals", Value = "ResourceGroup" }
            }
        },
        new Policy
        {
            Name = "Azure DevOps Project Administrator",
            Description = "Member of Project Administrators or Build/Release/Endpoint Administrators — elevated project-level privileges",
            Severity = "High",
            CategoryFilter = "AzureDevOps",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = HighDevOpsRolesRegex },
                new() { Field = "target_type", Operator = "equals", Value = "Project" }
            }
        },
        new Policy
        {
            Name = "FullAccess to mailbox",
            Description = "Full access permission to an Exchange mailbox",
            Severity = "High",
            CategoryFilter = "Exchange",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "equals", Value = "FullAccess" }
            }
        },
        new Policy
        {
            Name = "SendAs permission",
            Description = "SendAs permission on an Exchange mailbox",
            Severity = "High",
            CategoryFilter = "Exchange",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "contains", Value = "SendAs" }
            }
        },
        new Policy
        {
            Name = "Anonymous sharing link",
            Description = "Content shared via anonymous sharing link",
            Severity = "High",
            CategoryFilter = "SharePoint,OneDrive",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "through", Operator = "contains", Value = "Anonymous" }
            }
        },
        new Policy
        {
            Name = "Broad principal permission",
            Description = "Permission granted to Everyone, All Users, or similar broad principal",
            Severity = "High",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_sys_name", Operator = "regex", Value = BroadPrincipalsRegex }
            }
        },
        new Policy
        {
            Name = "High-risk application permission",
            Description = "Application registration with high-risk API permission (e.g. Mail.ReadWrite.All, Files.ReadWrite.All)",
            Severity = "High",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "through", Operator = "equals", Value = "ApplicationPermission" },
                new() { Field = "principal_role", Operator = "regex", Value = HighRiskAppPermsRegex }
            }
        },
        new Policy
        {
            Name = "Admin-consented OAuth2 grant",
            Description = "Admin-consented OAuth2 grant with high-risk scope",
            Severity = "High",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "through", Operator = "equals", Value = "OAuth2Grant" },
                new() { Field = "tenure", Operator = "equals", Value = "AllPrincipals" },
                new() { Field = "principal_role", Operator = "regex", Value = HighRiskAppPermsRegex }
            }
        },
        new Policy
        {
            Name = "Subscription to sensitive resource with data",
            Description = "Graph webhook subscription monitoring a sensitive resource (mail, chat, files, users, security) with includeResourceData enabled — actual content is sent to the notification endpoint",
            Severity = "High",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "target_type", Operator = "equals", Value = "Subscription" },
                new() { Field = "target_path", Operator = "regex", Value = SensitiveSubscriptionResourcesRegex },
                new() { Field = "access_type", Operator = "equals", Value = "IncludesResourceData" }
            }
        },
        new Policy
        {
            Name = "Subscription to sensitive resource",
            Description = "Graph webhook subscription monitoring a sensitive resource (mail, chat, files, users, security). Notification-only but reveals activity patterns and metadata.",
            Severity = "Medium",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "target_type", Operator = "equals", Value = "Subscription" },
                new() { Field = "target_path", Operator = "regex", Value = SensitiveSubscriptionResourcesRegex }
            }
        },

        // ── Medium ──────────────────────────────────────────────
        new Policy
        {
            Name = "Guest/external user access",
            Description = "Permission held by a guest or external user",
            Severity = "Medium",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_type", Operator = "regex", Value = @"(?i)(Guest|External)" }
            }
        },
        new Policy
        {
            Name = "Permanent non-critical directory role",
            Description = "Permanent directory role assignment — consider using PIM for time-limited access",
            Severity = "Medium",
            CategoryFilter = "Entra",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "tenure", Operator = "equals", Value = "Permanent" },
                new() { Field = "through", Operator = "equals", Value = "DirectoryRole" },
                new() { Field = "target_type", Operator = "equals", Value = "DirectoryRole" },
                new() { Field = "target_path", Operator = "regex", Value = @"^(?!(Global Administrator|Company Administrator|Exchange Administrator|SharePoint Administrator|Teams Administrator|Security Administrator|Privileged Role Administrator|Privileged Authentication Administrator|User Administrator|Application Administrator|Cloud Application Administrator|Intune Administrator|Authentication Administrator|Billing Administrator|Conditional Access Administrator|Compliance Administrator)$)" }
            }
        },
        new Policy
        {
            Name = "Organization-wide sharing link",
            Description = "Content shared via organization-wide sharing link",
            Severity = "Medium",
            CategoryFilter = "SharePoint,OneDrive",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "through", Operator = "contains", Value = "Organization" }
            }
        },
        new Policy
        {
            Name = "SharePoint site owner/Full Control",
            Description = "Site owner or Full Control permission on SharePoint site",
            Severity = "Medium",
            CategoryFilter = "SharePoint",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = @"(?i)(Full Control|^Owner$)" }
            }
        },
        new Policy
        {
            Name = "Power Platform / PowerBI owner",
            Description = "Owner role on Power Automate flow or PowerBI workspace",
            Severity = "Medium",
            CategoryFilter = "PowerAutomate,PowerBI",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "equals", Value = "Owner" }
            }
        },
        // ── Purview Critical ────────────────────────────────
        new Policy
        {
            Name = "Critical Purview compliance role group member",
            Description = "Member of a critical Compliance Center role group (Organization Management, eDiscovery Manager, etc.)",
            Severity = "Critical",
            CategoryFilter = "Purview",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "through", Operator = "equals", Value = "RoleGroupMember" },
                new() { Field = "principal_role", Operator = "regex", Value = CriticalPurviewRolesRegex }
            }
        },

        // ── Purview High ────────────────────────────────────
        new Policy
        {
            Name = "High-privilege Purview role group member",
            Description = "Member of a high-privilege Compliance Center role group (Compliance Management, Data Loss Prevention, etc.)",
            Severity = "High",
            CategoryFilter = "Purview",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "through", Operator = "equals", Value = "RoleGroupMember" },
                new() { Field = "principal_role", Operator = "regex", Value = HighPurviewRoleGroupsRegex }
            }
        },
        // ── Low ─────────────────────────────────────────────────
        new Policy
        {
            Name = "Standard member/contributor",
            Description = "Standard member, contributor, or editor access",
            Severity = "Low",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = @"(?i)(Member|Contribute|Edit)" }
            }
        },

        // ── Info ────────────────────────────────────────────────
        new Policy
        {
            Name = "Read-only access",
            Description = "Read-only, viewer, or visitor access",
            Severity = "Info",
            IsDefault = true,
            Conditions = new()
            {
                new() { Field = "principal_role", Operator = "regex", Value = @"(?i)(Read|View|Visitor)" }
            }
        },
    };
}
