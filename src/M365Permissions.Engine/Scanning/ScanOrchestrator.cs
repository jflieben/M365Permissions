using System.Collections.Concurrent;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Database;
using M365Permissions.Engine.Models;

namespace M365Permissions.Engine.Scanning;

/// <summary>
/// Manages scan lifecycle: dispatches to IScanProvider implementations,
/// collects results via TPL parallelism, streams to SQLite, tracks progress.
/// </summary>
public sealed class ScanOrchestrator
{
    private readonly SqliteDb _db;
    private readonly ScanRepository _scanRepo;
    private readonly PermissionRepository _permRepo;
    private readonly PolicyRepository _policyRepo;
    private readonly List<IScanProvider> _providers = new();

    private CancellationTokenSource? _cts;
    private Task? _scanTask;
    private readonly ConcurrentDictionary<string, ScanProgress> _progress = new();
    private readonly List<string> _logBuffer = new();
    private readonly object _logLock = new();
    private long _activeScanId;
    private ScanStatus _finalStatus = ScanStatus.Pending;

    private const int InsertBatchSize = 500;
    private const int MaxLogBufferSize = 500;
    private readonly object _insertLock = new();

    public bool IsScanning => _scanTask is { IsCompleted: false };
    public long ActiveScanId => _activeScanId;

    public ScanOrchestrator(SqliteDb db, ScanRepository scanRepo, PermissionRepository permRepo, PolicyRepository policyRepo)
    {
        _db = db;
        _scanRepo = scanRepo;
        _permRepo = permRepo;
        _policyRepo = policyRepo;
    }

    public void RegisterProvider(IScanProvider provider)
    {
        _providers.Add(provider);
    }

    /// <summary>Start a scan across the specified categories. Throws if already scanning.</summary>
    public long StartScan(ScanContext context, List<string> scanTypes)
    {
        if (IsScanning)
            throw new InvalidOperationException("A scan is already in progress.");

        _cts = new CancellationTokenSource();
        _progress.Clear();
        ClearLogBuffer();
        _activeScanId = context.ScanId;
        _finalStatus = ScanStatus.Running;

        // Initialize progress entries for each requested type
        foreach (var type in scanTypes)
        {
            _progress[type] = new ScanProgress
            {
                ScanId = context.ScanId,
                Category = type,
                Status = "Pending",
                StartedAt = DateTime.UtcNow.ToString("O")
            };
        }

        _scanTask = Task.Run(async () =>
        {
            try
            {
                _scanRepo.UpdateStatus(context.ScanId, ScanStatus.Running);
                AddLog("Scan started", 3);
                await ExecuteScanAsync(context, scanTypes, _cts.Token);

                var totalPerms = _permRepo.Count(context.ScanId);
                _scanRepo.UpdateStatus(context.ScanId, ScanStatus.Completed, totalPermissions: totalPerms);
                _finalStatus = ScanStatus.Completed;
                AddLog($"Scan completed — {totalPerms:N0} permissions found", 3);
            }
            catch (OperationCanceledException)
            {
                _scanRepo.UpdateStatus(context.ScanId, ScanStatus.Cancelled);
                _finalStatus = ScanStatus.Cancelled;
                AddLog("Scan cancelled by user", 2);
            }
            catch (Exception ex)
            {
                _scanRepo.UpdateStatus(context.ScanId, ScanStatus.Failed, error: ex.Message);
                _finalStatus = ScanStatus.Failed;
                AddLog($"Scan failed: {ex.Message}", 1);
            }
        });

        return context.ScanId;
    }

    public void CancelScan()
    {
        _cts?.Cancel();
    }

    /// <summary>Cancel any active scan and dispose resources. Safe to call multiple times.</summary>
    public void Shutdown()
    {
        CancelScan();
        try { _scanTask?.Wait(TimeSpan.FromSeconds(5)); } catch { /* best effort */ }
        _cts?.Dispose();
        _cts = null;
        _scanTask = null;
    }

    public AggregatedProgress GetProgress()
    {
        List<string> logs;
        lock (_logLock)
        {
            logs = new List<string>(_logBuffer);
        }

        var categories = _progress.Values.ToList();
        var totalTargets = categories.Sum(c => c.TotalTargets);
        var completedTargets = categories.Sum(c => c.CompletedTargets);

        // Determine overall status: use _finalStatus when scan task is done
        var overallStatus = IsScanning ? ScanStatus.Running : _finalStatus;

        // Force 100% when scan is done and was successful
        var percent = overallStatus == ScanStatus.Completed
            ? 100.0
            : totalTargets > 0 ? Math.Round(100.0 * completedTargets / totalTargets, 1) : 0;

        return new AggregatedProgress
        {
            ScanId = _activeScanId,
            OverallStatus = overallStatus,
            Categories = categories,
            RecentLogs = logs,
            OverallPercent = percent
        };
    }

    private async Task ExecuteScanAsync(ScanContext context, List<string> scanTypes, CancellationToken ct)
    {
        // Run all scan types in parallel — each category processes independently
        var tasks = new List<Task>();

        foreach (var scanType in scanTypes)
        {
            var provider = _providers.FirstOrDefault(p =>
                string.Equals(p.Category, scanType, StringComparison.OrdinalIgnoreCase));

            if (provider == null)
            {
                AddLog($"Unknown scan type: {scanType}", 2);
                continue;
            }

            tasks.Add(ExecuteCategoryAsync(context, scanType, provider, ct));
        }

        await Task.WhenAll(tasks);
    }

    private async Task ExecuteCategoryAsync(ScanContext context, string scanType, IScanProvider provider, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        if (_progress.TryGetValue(scanType, out var progress))
            progress.Status = "Running";

        AddLog($"Starting {scanType} scan...", 3);

        var catContext = new ScanContext
        {
            ScanId = context.ScanId,
            TenantDomain = context.TenantDomain,
            UserPrincipalName = context.UserPrincipalName,
            Config = context.Config,
            ReportProgress = (msg, level) => AddLog($"[{scanType}] {msg}", level),
            SetTotalTargets = count =>
            {
                if (_progress.TryGetValue(scanType, out var p)) p.TotalTargets = count;
            },
            CompleteTarget = () =>
            {
                if (_progress.TryGetValue(scanType, out var p)) p.CompletedTargets++;
            },
            FailTarget = () =>
            {
                if (_progress.TryGetValue(scanType, out var p)) p.FailedTargets++;
            }
        };

        var batch = new List<PermissionEntry>();
        var policies = _policyRepo.GetEnabled();
        var finalStatus = "Completed";

        try
        {
            await foreach (var entry in provider.ScanAsync(catContext, ct))
            {
                entry.ScanId = context.ScanId;
                entry.Category = scanType;
                batch.Add(entry);

                if (_progress.TryGetValue(scanType, out var pc))
                    pc.PermissionsFound++;

                if (batch.Count >= InsertBatchSize)
                {
                    PolicyEngine.ClassifyBatch(batch, policies);
                    lock (_insertLock) { _permRepo.BulkInsert(batch); }
                    batch.Clear();
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Cancellation should propagate to the orchestrator so it can mark the whole scan cancelled
            finalStatus = "Cancelled";
            throw;
        }
        catch (ResourcePrincipalNotFoundException ex)
        {
            // The resource (e.g. PowerBI, Azure DevOps, ASM) is not provisioned in this tenant.
            // Skip this scan but allow other scans to continue.
            finalStatus = "Skipped";
            AddLog($"[{scanType}] Skipped — {ex.Message}", 2);
        }
        catch (Exception ex)
        {
            // Per-scan failure: log and continue with other scan types.
            finalStatus = "Failed";
            AddLog($"[{scanType}] Failed: {ex.Message}", 1);
        }
        finally
        {
            if (batch.Count > 0)
            {
                try
                {
                    PolicyEngine.ClassifyBatch(batch, policies);
                    lock (_insertLock) { _permRepo.BulkInsert(batch); }
                }
                catch (Exception flushEx)
                {
                    AddLog($"[{scanType}] Failed to flush {batch.Count} remaining entries: {flushEx.Message}", 1);
                }
            }
        }

        if (_progress.TryGetValue(scanType, out var progressFinal))
            progressFinal.Status = finalStatus;

        AddLog($"{(finalStatus == "Completed" ? "Completed" : finalStatus)} {scanType} scan.", finalStatus == "Completed" ? 3 : 2);
    }

    private void AddLog(string message, int level)
    {
        var entry = $"[{DateTime.UtcNow:HH:mm:ss}] {message}";
        lock (_logLock)
        {
            _logBuffer.Add(entry);
            // Trim buffer to prevent unbounded growth
            while (_logBuffer.Count > MaxLogBufferSize)
                _logBuffer.RemoveAt(0);
        }
    }

    private void ClearLogBuffer()
    {
        lock (_logLock) { _logBuffer.Clear(); }
    }
}
