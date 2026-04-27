namespace M365Permissions.Engine.Models;

/// <summary>
/// Core permission record — matches the V1 18-field schema.
/// One row per permission assignment discovered during a scan.
/// </summary>
public sealed class PermissionEntry
{
    public long Id { get; set; }
    public long ScanId { get; set; }
    public string Category { get; set; } = string.Empty;       // SharePoint, Entra, Exchange
    public string TargetPath { get; set; } = string.Empty;     // Site URL, mailbox, etc.
    public string TargetType { get; set; } = string.Empty;     // Site, MailboxFolder, User, etc.
    public string TargetId { get; set; } = string.Empty;       // GUID of resource
    public string PrincipalEntraId { get; set; } = string.Empty;
    public string PrincipalEntraUpn { get; set; } = string.Empty;
    public string PrincipalSysId { get; set; } = string.Empty;
    public string PrincipalSysName { get; set; } = string.Empty;
    public string PrincipalType { get; set; } = string.Empty;  // Internal User, SecurityGroup, etc.
    public string PrincipalRole { get; set; } = string.Empty;  // Full Control, Read, etc.
    public string Through { get; set; } = string.Empty;        // Direct, Inherited, GroupMember, etc.
    public string AccessType { get; set; } = "Allow";          // Allow | Deny
    public string Tenure { get; set; } = "Permanent";          // Permanent | Eligible
    public string ParentId { get; set; } = string.Empty;       // For nested groups
    public string StartDateTime { get; set; } = string.Empty;
    public string EndDateTime { get; set; } = string.Empty;
    public string CreatedDateTime { get; set; } = string.Empty;
    public string ModifiedDateTime { get; set; } = string.Empty;
    public string RiskLevel { get; set; } = string.Empty;        // Critical, High, Medium, Low, Info
    public string RiskReason { get; set; } = string.Empty;
}
