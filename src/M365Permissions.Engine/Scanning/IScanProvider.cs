using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Interface for scan type providers.
/// Each implementation handles one category (SharePoint, Entra, Exchange).
/// </summary>
public interface IScanProvider
{
    /// <summary>Display name for the category (used in UI and DB).</summary>
    string Category { get; }

    /// <summary>
    /// Execute the scan, yielding permission entries as they are discovered.
    /// The orchestrator handles batching inserts and progress tracking.
    /// </summary>
    /// <param name="context">Shared context with auth, progress reporting, etc.</param>
    /// <param name="ct">Cancellation token for user-initiated cancellation.</param>
    IAsyncEnumerable<PermissionEntry> ScanAsync(ScanContext context, CancellationToken ct);
}

/// <summary>
/// Shared context passed to all scan providers during a scan.
/// </summary>
public sealed class ScanContext
{
    public required long ScanId { get; init; }
    public required string TenantDomain { get; init; }
    public required string UserPrincipalName { get; init; }
    public required AppConfig Config { get; init; }
    public required Action<string, int> ReportProgress { get; init; }  // (message, logLevel)

    /// <summary>Report discovery of a new target (site, mailbox, etc.).</summary>
    public required Action<int> SetTotalTargets { get; init; }

    /// <summary>Mark one target as completed.</summary>
    public required Action CompleteTarget { get; init; }

    /// <summary>Mark one target as failed.</summary>
    public required Action FailTarget { get; init; }
}
