using System.Diagnostics;
using System.Text.Json;
using M365Permissions.Engine.Auth;
using M365Permissions.Engine.Database;
using M365Permissions.Engine.Export;
using M365Permissions.Engine.Graph;
using M365Permissions.Engine.Http;
using M365Permissions.Engine.Models;
using M365Permissions.Engine.Scanning;

namespace M365Permissions.Engine;

/// <summary>
/// Main entry point / facade for the M365Permissions engine.
/// Wires together all subsystems: database, auth, HTTP server, scanning, export.
/// Called from the PowerShell module wrapper.
/// </summary>
public sealed class Engine : IDisposable
{
    public static string ModuleVersion { get; } =
        typeof(Engine).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    private readonly SqliteDb _db;
    private readonly ConfigRepository _configRepo;
    private readonly ScanRepository _scanRepo;
    private readonly PermissionRepository _permRepo;
    private readonly AuditRepository _auditRepo;
    private readonly PolicyRepository _policyRepo;
    private readonly TokenCache _tokenCache;
    private readonly DelegatedAuth _auth;
    private readonly ExcelExporter _excelExporter;
    private readonly CsvExporter _csvExporter;
    private readonly ComparisonEngine _comparisonEngine;

    private GraphClient? _graphClient;
    private SharePointRestClient? _spClient;
    private ExchangeRestClient? _exoClient;
    private ScanOrchestrator? _orchestrator;
    private WebServer? _webServer;

    private AppConfig _config;
    private readonly Task _sessionRestoreTask;

    public Engine(string databasePath)
    {
        _db = new SqliteDb(databasePath);
        _db.Initialize();

        _configRepo = new ConfigRepository(_db);
        _scanRepo = new ScanRepository(_db);
        _permRepo = new PermissionRepository(_db);
        _auditRepo = new AuditRepository(_db);
        _policyRepo = new PolicyRepository(_db);

        // Persist refresh tokens alongside the database
        var persistDir = Path.GetDirectoryName(databasePath) ?? ".";
        _tokenCache = new TokenCache(persistDir);

        _auth = new DelegatedAuth(_tokenCache);
        _excelExporter = new ExcelExporter();
        _csvExporter = new CsvExporter();
        _comparisonEngine = new ComparisonEngine(_permRepo);

        _config = LoadConfig();

        // Seed default policy rules if none exist yet
        SeedDefaultPolicies();

        // Try to restore previous session from persisted refresh token
        _sessionRestoreTask = Task.Run(async () =>
        {
            try
            {
                if (await _auth.TryRestoreSessionAsync())
                    InitializeClients();
            }
            catch { /* best effort — user can connect manually */ }
        });
    }

    /// <summary>Wait for session restore to complete (up to a timeout), so status is accurate.</summary>
    public async Task EnsureSessionRestoredAsync(int timeoutMs = 5000)
    {
        await Task.WhenAny(_sessionRestoreTask, Task.Delay(timeoutMs));
    }

    // ── Status ──────────────────────────────────────────────────

    public StatusResponse GetStatus() => new()
    {
        Connected = _auth.IsConnected,
        TenantId = _auth.TenantId,
        TenantDomain = _auth.TenantDomain,
        UserPrincipalName = _auth.UserPrincipalName,
        ModuleVersion = ModuleVersion,
        Scanning = _orchestrator?.IsScanning ?? false,
        ActiveScanId = _orchestrator?.IsScanning == true ? _orchestrator.ActiveScanId : null,
        RefreshTokenExpiry = _auth.RefreshTokenExpiry?.ToString("O")
    };

    // ── Authentication ──────────────────────────────────────────

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        await _auth.AuthenticateAsync(ct);
        InitializeClients();

        // Check tenant size and return warning for large tenants
        try
        {
            var countResult = await _graphClient!.GetAsync("users/$count", eventualConsistency: true, ct: ct);
            // Note: Direct $count on users returns a plain integer, not JSON
        }
        catch { /* best effort — don't block connection */ }
    }

    /// <summary>
    /// Get the user count for the connected tenant (for licensing guidance).
    /// Returns null if the count cannot be determined.
    /// </summary>
    public async Task<UserCountInfo?> GetUserCountAsync(CancellationToken ct = default)
    {
        if (!_auth.IsConnected || _graphClient == null) return null;

        try
        {
            var result = await _graphClient.GetAsync("users?$count=true&$top=1&$select=id", eventualConsistency: true, ct: ct);
            if (result == null) return null;

            long count = 0;
            if (result.Value.TryGetProperty("@odata.count", out var countProp))
                count = countProp.GetInt64();

            string? recommendation = null;
            if (count > 1000)
                recommendation = "Your tenant has over 1,000 users. For tenants this large, consider using M365Permissions.com for faster scans, managed infrastructure, and advanced reporting.";
            else if (count > 500)
                recommendation = "Your tenant has over 500 users. For larger tenants, M365Permissions.com offers managed scanning infrastructure and is recommended for best performance.";
            else if (count > 250)
                recommendation = "For growing tenants (250+ users), M365Permissions.com offers scheduled scans and historical tracking out of the box.";

            return new UserCountInfo { UserCount = count, Recommendation = recommendation };
        }
        catch
        {
            return null;
        }
    }

    public void Disconnect()
    {
        _auth.SignOut();
        _graphClient = null;
        _spClient = null;
        _exoClient = null;
    }

    /// <summary>
    /// Trigger admin consent flow to re-grant permissions for the app registration.
    /// Opens browser with prompt=consent, then refreshes clients with new tokens.
    /// </summary>
    public async Task ReconsentAsync(CancellationToken ct = default)
    {
        await _auth.ReconsentAsync(ct);
        InitializeClients();
    }

    private void InitializeClients()
    {
        _graphClient = new GraphClient(_auth, _config.MaxThreads);
        _spClient = new SharePointRestClient(_auth, _graphClient);
        _exoClient = new ExchangeRestClient(_auth);

        _orchestrator = new ScanOrchestrator(_db, _scanRepo, _permRepo, _policyRepo);
        _orchestrator.RegisterProvider(new SharePointScanner(_spClient, _graphClient, _auth));
        _orchestrator.RegisterProvider(new EntraScanner(_graphClient));
        _orchestrator.RegisterProvider(new ExchangeScanner(_exoClient, _graphClient));
        _orchestrator.RegisterProvider(new OneDriveScanner(_graphClient, _spClient, _auth));
        _orchestrator.RegisterProvider(new PowerBIScanner(_auth));
        _orchestrator.RegisterProvider(new PowerAutomateScanner(_auth));
        _orchestrator.RegisterProvider(new AzureScanner(_auth));
        _orchestrator.RegisterProvider(new AzureDevOpsScanner(_auth));
        _orchestrator.RegisterProvider(new PurviewScanner(_auth));
    }

    // ── Configuration ───────────────────────────────────────────

    public AppConfig GetConfig() => _config;

    public void UpdateConfig(Dictionary<string, JsonElement> updates)
    {
        foreach (var (key, value) in updates)
        {
            var strValue = value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? ""
                : value.GetRawText();
            _configRepo.Set(key, strValue);
        }
        _config = LoadConfig();
    }

    public void UpdateConfig(AppConfig config)
    {
        _configRepo.Set("guiPort", config.GuiPort.ToString());
        _configRepo.Set("maxThreads", config.MaxThreads.ToString());
        _configRepo.Set("outputFormat", config.OutputFormat);
        _configRepo.Set("logLevel", config.LogLevel);
        _configRepo.Set("includeCurrentUser", config.IncludeCurrentUser.ToString());
        _configRepo.Set("defaultTimeoutMinutes", config.DefaultTimeoutMinutes.ToString());
        _configRepo.Set("maxJobRetries", config.MaxJobRetries.ToString());
        _config = LoadConfig();
    }

    private AppConfig LoadConfig()
    {
        var all = _configRepo.GetAll();
        return new AppConfig
        {
            GuiPort = GetInt(all, "guiPort", 8080),
            MaxThreads = GetInt(all, "maxThreads", 5),
            OutputFormat = GetStr(all, "outputFormat", "XLSX"),
            LogLevel = GetStr(all, "logLevel", "Minimal"),
            IncludeCurrentUser = GetBool(all, "includeCurrentUser", false),
            DefaultTimeoutMinutes = GetInt(all, "defaultTimeoutMinutes", 120),
            MaxJobRetries = GetInt(all, "maxJobRetries", 3)
        };
    }

    private static int GetInt(Dictionary<string, string> d, string key, int def)
        => d.TryGetValue(key, out var v) && int.TryParse(v, out var i) ? i : def;
    private static string GetStr(Dictionary<string, string> d, string key, string def)
        => d.TryGetValue(key, out var v) ? v : def;
    private static bool GetBool(Dictionary<string, string> d, string key, bool def)
        => d.TryGetValue(key, out var v) && bool.TryParse(v, out var b) ? b : def;

    // ── Scanning ────────────────────────────────────────────────

    public Task<long> StartScanAsync(List<string> scanTypes, CancellationToken ct = default)
    {
        if (!_auth.IsConnected)
            throw new InvalidOperationException("Not connected. Call ConnectAsync first.");

        if (_orchestrator == null)
            InitializeClients();

        var scan = new ScanInfo
        {
            TenantId = _auth.TenantId ?? "",
            TenantDomain = _auth.TenantDomain ?? "",
            Status = ScanStatus.Pending,
            ScanTypes = string.Join(",", scanTypes),
            StartedAt = DateTime.UtcNow.ToString("O"),
            StartedBy = _auth.UserPrincipalName ?? "",
            ConfigSnapshot = JsonSerializer.Serialize(_config),
            ModuleVersion = ModuleVersion
        };

        var scanId = _scanRepo.Create(scan);

        var context = new ScanContext
        {
            ScanId = scanId,
            TenantDomain = _auth.TenantDomain ?? "",
            UserPrincipalName = _auth.UserPrincipalName ?? "",
            Config = _config,
            ReportProgress = (_, _) => { },
            SetTotalTargets = _ => { },
            CompleteTarget = () => { },
            FailTarget = () => { }
        };

        _orchestrator!.StartScan(context, scanTypes);
        _auditRepo.Log("ScanStarted", _auth.UserPrincipalName ?? "", $"Scan started: {string.Join(", ", scanTypes)}", scanId);
        return Task.FromResult(scanId);
    }

    public void CancelScan() => _orchestrator?.CancelScan();

    public AggregatedProgress? GetScanProgress() => _orchestrator?.GetProgress();

    public ThrottleMetrics? GetThrottleMetrics() => _graphClient?.ThrottleManager.GetMetrics();

    /// <summary>Pre-check permissions for the requested scan types before starting.</summary>
    public async Task<Dictionary<string, List<string>>> CheckPermissionsAsync(List<string> scanTypes, CancellationToken ct = default)
    {
        if (!_auth.IsConnected || _graphClient == null)
            throw new InvalidOperationException("Not connected. Call ConnectAsync first.");

        var checker = new PermissionPreChecker(_graphClient, _auth);
        return await checker.CheckAsync(scanTypes, ct);
    }

    // ── Results ─────────────────────────────────────────────────

    public List<ScanInfo> GetScans(string? tenantId = null) => _scanRepo.GetAll(tenantId: tenantId);

    public PagedResult<PermissionEntry> QueryPermissions(long scanId, string? category = null,
        string? search = null, int page = 1, int pageSize = 100,
        string? sortColumn = null, string? sortDirection = null,
        Dictionary<string, string>? columnFilters = null)
        => _permRepo.Query(scanId, category, search, page, pageSize, sortColumn, sortDirection, columnFilters);

    public List<string> GetCategories(long scanId)
        => _permRepo.GetCategories(scanId);

    public PagedResult<PermissionEntry> QueryUserPermissions(long scanId, string userSearch, int page = 1, int pageSize = 100,
        string? sortColumn = null, string? sortDirection = null,
        Dictionary<string, string>? columnFilters = null)
        => _permRepo.QueryUserPermissions(scanId, userSearch, page, pageSize, sortColumn, sortDirection, columnFilters);

    public List<PermissionEntry> GetGroupMembers(long scanId, string groupId)
        => _permRepo.GetGroupMembers(scanId, groupId);

    public List<string> GetFilterOptions(long scanId, string column, string? category = null)
        => _permRepo.GetDistinctValues(scanId, column, category);

    // ── Export ───────────────────────────────────────────────────

    public (byte[] bytes, string fileName, string contentType) ExportScan(long scanId, string format, string? category)
    {
        var scan = _scanRepo.GetById(scanId)
            ?? throw new KeyNotFoundException($"Scan {scanId} not found");

        var entries = _permRepo.GetAll(scanId, category);
        var catSuffix = category ?? "All";

        if (format.Equals("csv", StringComparison.OrdinalIgnoreCase))
        {
            var bytes = _csvExporter.Export(entries);
            _auditRepo.Log("Export", _auth.UserPrincipalName ?? "", $"CSV export: scan {scanId}, category={catSuffix}");
            return (bytes, $"M365Permissions_{catSuffix}_{scanId}.csv", "text/csv");
        }
        else
        {
            var bytes = _excelExporter.Export(entries, catSuffix);
            _auditRepo.Log("Export", _auth.UserPrincipalName ?? "", $"XLSX export: scan {scanId}, category={catSuffix}");
            return (bytes, $"M365Permissions_{catSuffix}_{scanId}.xlsx",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        }
    }

    // ── Comparison ──────────────────────────────────────────────

    public ComparisonResult CompareScans(long oldScanId, long newScanId, string? category = null)
        => _comparisonEngine.Compare(oldScanId, newScanId, category);

    // ── Comparison Export ───────────────────────────────────────

    public (byte[] bytes, string fileName, string contentType) ExportComparison(long oldScanId, long newScanId, string? category = null)
    {
        var result = _comparisonEngine.Compare(oldScanId, newScanId, category);
        var bytes = _excelExporter.ExportComparison(result);
        _auditRepo.Log("ComparisonExport", _auth.UserPrincipalName ?? "", $"Exported comparison: scan {oldScanId} vs {newScanId}");
        return (bytes, $"M365Permissions_Compare_{oldScanId}_vs_{newScanId}.xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    }

    // ── Scan Notes & Tags ───────────────────────────────────────

    public void UpdateScanNotes(long scanId, string? notes, string? tags)
    {
        _scanRepo.UpdateNotes(scanId, notes, tags);
        _auditRepo.Log("ScanNotesUpdated", _auth.UserPrincipalName ?? "", $"Updated notes/tags on scan {scanId}", scanId);
    }

    // ── Risk Summary ────────────────────────────────────────────

    public Dictionary<string, int> GetRiskSummary(long scanId)
        => _scanRepo.GetRiskSummary(scanId);

    // ── Trends ──────────────────────────────────────────────────

    public List<TrendDataPoint> GetTrends(int limit = 20, string? tenantId = null)
        => _scanRepo.GetTrends(limit, tenantId);

    // ── Audit Log ───────────────────────────────────────────────

    public void AuditLog(string action, string details, long? scanId = null)
        => _auditRepo.Log(action, _auth.UserPrincipalName ?? "", details, scanId);

    public List<AuditEntry> GetAuditLog(int limit = 100, string? action = null, string? tenantId = null)
        => _auditRepo.GetRecent(limit, action, tenantId);

    // ── Database Management ─────────────────────────────────────

    public DatabaseInfo GetDatabaseInfo() => _db.GetDatabaseInfo();

    public void ResetDatabase()
    {
        if (_orchestrator?.IsScanning == true)
            throw new InvalidOperationException("Cannot reset database while a scan is running.");
        _db.ResetDatabase();
        AuditLog("database_reset", "Database cleared — all scans, permissions, and logs deleted");
    }

    // ── Policies ────────────────────────────────────────────────

    public List<Policy> GetPolicies() => _policyRepo.GetAll();

    public Policy? GetPolicy(long id) => _policyRepo.GetById(id);

    public long CreatePolicy(Policy policy)
    {
        var id = _policyRepo.Create(policy);
        _auditRepo.Log("PolicyCreated", _auth.UserPrincipalName ?? "", $"Created policy: {policy.Name}");
        return id;
    }

    public void UpdatePolicy(Policy policy)
    {
        _policyRepo.Update(policy);
        _auditRepo.Log("PolicyUpdated", _auth.UserPrincipalName ?? "", $"Updated policy: {policy.Name}");
    }

    public void DeletePolicy(long id)
    {
        _policyRepo.Delete(id);
        _auditRepo.Log("PolicyDeleted", _auth.UserPrincipalName ?? "", $"Deleted policy #{id}");
    }

    /// <summary>
    /// Delete all default policies and re-seed them from built-in definitions.
    /// Custom (non-default) policies are preserved.
    /// </summary>
    public int ResetDefaultPolicies()
    {
        _policyRepo.DeleteDefaults();
        var defaults = DefaultPolicies.GetAll();
        foreach (var p in defaults)
            _policyRepo.Create(p);
        _auditRepo.Log("PoliciesReset", _auth.UserPrincipalName ?? "", $"Reset {defaults.Count} default policies");
        return defaults.Count;
    }

    private void SeedDefaultPolicies()
    {
        if (_policyRepo.Count() > 0) return; // Already has policies
        var defaults = DefaultPolicies.GetAll();
        foreach (var p in defaults)
            _policyRepo.Create(p);
    }

    public PolicyEvaluationResult EvaluatePolicies(long scanId, string? category = null, int limit = 500)
    {
        var policies = _policyRepo.GetEnabled();
        if (policies.Count == 0) return new();

        var entries = _permRepo.GetAll(scanId, category);
        if (entries.Count > limit) entries = entries.Take(limit).ToList();

        var violations = PolicyEngine.EvaluateBatch(entries, policies);
        var matchingEntries = new Dictionary<int, PermissionEntry>();
        foreach (var idx in violations.Keys)
            matchingEntries[idx] = entries[idx];

        return new PolicyEvaluationResult { Violations = violations, Entries = matchingEntries };
    }

    // ── HTTP Server ─────────────────────────────────────────────

    public void StartServer(int port, string staticFilesPath, bool openBrowser = true)
    {
        // Dispose any previous server (e.g. failed start on different port)
        _webServer?.Dispose();

        var server = new WebServer(port, staticFilesPath);
        ApiRoutes.Register(server, this);
        server.Start();
        _webServer = server;

        if (openBrowser)
        {
            try
            {
                Process.Start(new ProcessStartInfo($"http://localhost:{port}") { UseShellExecute = true });
            }
            catch { /* best effort */ }
        }
    }

    public async Task StopServerAsync()
    {
        if (_webServer != null)
            await _webServer.StopAsync();
    }

    public void Dispose()
    {
        // Cancel running scans
        _orchestrator?.Shutdown();

        // Stop web server (synchronous fallback if StopServerAsync wasn't called)
        _webServer?.Dispose();

        // Close database (WAL checkpoint)
        _db.Dispose();
    }
}
