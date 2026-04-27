using M365Permissions.Engine.Database;
using M365Permissions.Engine.Export;
using M365Permissions.Engine.Models;
using Xunit;

namespace M365Permissions.Engine.Tests.Export;

public class ExportTests : IDisposable
{
    private readonly string _dbPath;
    private readonly SqliteDb _db;
    private readonly ScanRepository _scanRepo;
    private readonly PermissionRepository _permRepo;

    public ExportTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), $"m365perm_test_{Guid.NewGuid():N}.db");
        _db = new SqliteDb(_dbPath);
        _db.Initialize();
        _scanRepo = new ScanRepository(_db);
        _permRepo = new PermissionRepository(_db);
    }

    [Fact]
    public void ExcelExporter_ProducesValidXlsx()
    {
        var entries = new List<PermissionEntry>
        {
            new() { TargetPath = "https://site1", PrincipalEntraUpn = "user@test.com", PrincipalRole = "Read" },
            new() { TargetPath = "https://site2", PrincipalEntraUpn = "admin@test.com", PrincipalRole = "Full Control" }
        };

        var exporter = new ExcelExporter();
        var bytes = exporter.Export(entries);

        Assert.NotEmpty(bytes);
        // XLSX files start with PK (ZIP magic bytes)
        Assert.Equal(0x50, bytes[0]);
        Assert.Equal(0x4B, bytes[1]);
    }

    [Fact]
    public void CsvExporter_ProducesValidCsv()
    {
        var entries = new List<PermissionEntry>
        {
            new() { TargetPath = "https://site1", PrincipalEntraUpn = "user@test.com", PrincipalRole = "Read" }
        };

        var exporter = new CsvExporter();
        var bytes = exporter.Export(entries);
        var csv = System.Text.Encoding.UTF8.GetString(bytes);

        Assert.Contains("Target Path", csv);
        Assert.Contains("https://site1", csv);
        Assert.Contains("user@test.com", csv);
    }

    [Fact]
    public void ComparisonEngine_DetectsAddedAndRemoved()
    {
        // Old scan
        var oldScanId = _scanRepo.Create(new ScanInfo { TenantDomain = "test", ScanTypes = "SharePoint", StartedAt = "2026-01-01", ModuleVersion = "0.1.0" });
        _permRepo.BulkInsert(new List<PermissionEntry>
        {
            new() { ScanId = oldScanId, Category = "SharePoint", TargetPath = "https://site1", PrincipalEntraId = "user1", PrincipalRole = "Read", Through = "Direct" },
            new() { ScanId = oldScanId, Category = "SharePoint", TargetPath = "https://site2", PrincipalEntraId = "user2", PrincipalRole = "Edit", Through = "Direct" }
        });

        // New scan
        var newScanId = _scanRepo.Create(new ScanInfo { TenantDomain = "test", ScanTypes = "SharePoint", StartedAt = "2026-01-02", ModuleVersion = "0.1.0" });
        _permRepo.BulkInsert(new List<PermissionEntry>
        {
            new() { ScanId = newScanId, Category = "SharePoint", TargetPath = "https://site1", PrincipalEntraId = "user1", PrincipalRole = "Read", Through = "Direct" },
            new() { ScanId = newScanId, Category = "SharePoint", TargetPath = "https://site3", PrincipalEntraId = "user3", PrincipalRole = "Read", Through = "Direct" }
        });

        var engine = new ComparisonEngine(_permRepo);
        var result = engine.Compare(oldScanId, newScanId);

        Assert.Single(result.Added);     // site3/user3
        Assert.Single(result.Removed);   // site2/user2
        Assert.Empty(result.Changed);    // site1/user1 unchanged
    }

    public void Dispose()
    {
        _db.Dispose();
        try { File.Delete(_dbPath); } catch { }
    }
}
