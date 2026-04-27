using M365Permissions.Engine.Database;
using M365Permissions.Engine.Models;
using Xunit;

namespace M365Permissions.Engine.Tests.Database;

public class PermissionRepositoryTests : IDisposable
{
    private readonly string _dbPath;
    private readonly SqliteDb _db;
    private readonly ScanRepository _scanRepo;
    private readonly PermissionRepository _permRepo;
    private readonly long _scanId;

    public PermissionRepositoryTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), $"m365perm_test_{Guid.NewGuid():N}.db");
        _db = new SqliteDb(_dbPath);
        _db.Initialize();
        _scanRepo = new ScanRepository(_db);
        _permRepo = new PermissionRepository(_db);

        // Create a scan to hold permissions
        _scanId = _scanRepo.Create(new ScanInfo
        {
            TenantDomain = "test.onmicrosoft.com",
            Status = ScanStatus.Running,
            ScanTypes = "SharePoint",
            StartedAt = DateTime.UtcNow.ToString("O"),
            ModuleVersion = "0.1.0"
        });
    }

    [Fact]
    public void BulkInsert_InsertsAllEntries()
    {
        var entries = CreateTestEntries(100);
        _permRepo.BulkInsert(entries);
        Assert.Equal(100, _permRepo.Count(_scanId));
    }

    [Fact]
    public void Query_ReturnsPaginatedResults()
    {
        _permRepo.BulkInsert(CreateTestEntries(50));

        var page1 = _permRepo.Query(_scanId, pageSize: 20, page: 1);
        Assert.Equal(20, page1.Items.Count);
        Assert.Equal(50, page1.TotalCount);

        var page3 = _permRepo.Query(_scanId, pageSize: 20, page: 3);
        Assert.Equal(10, page3.Items.Count);
    }

    [Fact]
    public void Query_FiltersByCategory()
    {
        var entries = new List<PermissionEntry>
        {
            new() { ScanId = _scanId, Category = "SharePoint", TargetPath = "https://site1" },
            new() { ScanId = _scanId, Category = "Entra", TargetPath = "Group/Admins" },
            new() { ScanId = _scanId, Category = "SharePoint", TargetPath = "https://site2" }
        };
        _permRepo.BulkInsert(entries);

        var spResults = _permRepo.Query(_scanId, category: "SharePoint");
        Assert.Equal(2, spResults.TotalCount);

        var entraResults = _permRepo.Query(_scanId, category: "Entra");
        Assert.Equal(1, entraResults.TotalCount);
    }

    [Fact]
    public void Query_SearchesByText()
    {
        var entries = new List<PermissionEntry>
        {
            new() { ScanId = _scanId, Category = "SharePoint", TargetPath = "https://contoso.sharepoint.com/sites/HR", PrincipalEntraUpn = "alice@contoso.com" },
            new() { ScanId = _scanId, Category = "SharePoint", TargetPath = "https://contoso.sharepoint.com/sites/IT", PrincipalEntraUpn = "bob@contoso.com" }
        };
        _permRepo.BulkInsert(entries);

        var results = _permRepo.Query(_scanId, searchText: "alice");
        Assert.Equal(1, results.TotalCount);
    }

    [Fact]
    public void GetCategories_ReturnsDistinctCategories()
    {
        var entries = new List<PermissionEntry>
        {
            new() { ScanId = _scanId, Category = "SharePoint" },
            new() { ScanId = _scanId, Category = "Entra" },
            new() { ScanId = _scanId, Category = "SharePoint" }
        };
        _permRepo.BulkInsert(entries);

        var categories = _permRepo.GetCategories(_scanId);
        Assert.Equal(2, categories.Count);
        Assert.Contains("Entra", categories);
        Assert.Contains("SharePoint", categories);
    }

    private List<PermissionEntry> CreateTestEntries(int count)
    {
        return Enumerable.Range(0, count).Select(i => new PermissionEntry
        {
            ScanId = _scanId,
            Category = "SharePoint",
            TargetPath = $"https://contoso.sharepoint.com/sites/Site{i}",
            TargetType = "Site",
            PrincipalEntraUpn = $"user{i}@contoso.com",
            PrincipalRole = "Read",
            Through = "Direct",
            AccessType = "Allow"
        }).ToList();
    }

    public void Dispose()
    {
        _db.Dispose();
        try { File.Delete(_dbPath); } catch { }
    }
}
