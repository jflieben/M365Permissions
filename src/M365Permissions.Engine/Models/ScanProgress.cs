namespace M365Permissions.Engine.Models;

/// <summary>
/// Real-time progress for an active scan, per category.
/// </summary>
public sealed class ScanProgress
{
    public long ScanId { get; set; }
    public string Category { get; set; } = string.Empty;
    public int TotalTargets { get; set; }
    public int CompletedTargets { get; set; }
    public int FailedTargets { get; set; }
    public long PermissionsFound { get; set; }
    public string CurrentTarget { get; set; } = string.Empty;
    public string Status { get; set; } = "Pending";   // Pending, Running, Completed, Failed
    public string StartedAt { get; set; } = string.Empty;

    public double PercentComplete => TotalTargets > 0
        ? Math.Round(100.0 * (CompletedTargets + FailedTargets) / TotalTargets, 1)
        : 0;
}

/// <summary>
/// Aggregated progress across all categories.
/// </summary>
public sealed class AggregatedProgress
{
    public long ScanId { get; set; }
    public ScanStatus OverallStatus { get; set; }
    public List<ScanProgress> Categories { get; set; } = new();
    public List<string> RecentLogs { get; set; } = new();
    public double OverallPercent { get; set; }
    public string EstimatedTimeRemaining { get; set; } = string.Empty;
}
