using System.Text.Json.Serialization;

namespace M365Permissions.Engine.Models;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ScanStatus
{
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled
}

/// <summary>
/// Metadata for a single scan run.
/// </summary>
public sealed class ScanInfo
{
    public long Id { get; set; }
    public string TenantId { get; set; } = string.Empty;
    public string TenantDomain { get; set; } = string.Empty;
    public ScanStatus Status { get; set; } = ScanStatus.Pending;
    public string ScanTypes { get; set; } = string.Empty;      // Comma-separated: "SharePoint,Entra,Exchange"
    public string StartedAt { get; set; } = string.Empty;
    public string CompletedAt { get; set; } = string.Empty;
    public string StartedBy { get; set; } = string.Empty;
    public long TotalPermissions { get; set; }
    public string ConfigSnapshot { get; set; } = string.Empty;  // JSON snapshot of config at scan time
    public string ErrorMessage { get; set; } = string.Empty;
    public string ModuleVersion { get; set; } = string.Empty;
    public string Notes { get; set; } = string.Empty;
    public string Tags { get; set; } = string.Empty;           // Comma-separated tags
}
