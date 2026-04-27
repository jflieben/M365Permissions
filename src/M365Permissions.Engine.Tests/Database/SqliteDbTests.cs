using M365Permissions.Engine.Database;
using Xunit;

namespace M365Permissions.Engine.Tests.Database;

public class SqliteDbTests : IDisposable
{
    private readonly string _dbPath;
    private readonly SqliteDb _db;

    public SqliteDbTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), $"m365perm_test_{Guid.NewGuid():N}.db");
        _db = new SqliteDb(_dbPath);
    }

    [Fact]
    public void Initialize_CreatesTablesSuccessfully()
    {
        _db.Initialize();

        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name";
        using var reader = cmd.ExecuteReader();

        var tables = new List<string>();
        while (reader.Read())
            tables.Add(reader.GetString(0));

        Assert.Contains("config", tables);
        Assert.Contains("scans", tables);
        Assert.Contains("permissions", tables);
        Assert.Contains("scan_progress", tables);
        Assert.Contains("comparisons", tables);
        Assert.Contains("logs", tables);
    }

    [Fact]
    public void Initialize_IsIdempotent()
    {
        _db.Initialize();
        _db.Initialize(); // Should not throw
    }

    [Fact]
    public void CreateConnection_ReturnsOpenConnection()
    {
        _db.Initialize();
        using var conn = _db.CreateConnection();
        Assert.Equal(System.Data.ConnectionState.Open, conn.State);
    }

    public void Dispose()
    {
        _db.Dispose();
        try { File.Delete(_dbPath); } catch { }
    }
}
