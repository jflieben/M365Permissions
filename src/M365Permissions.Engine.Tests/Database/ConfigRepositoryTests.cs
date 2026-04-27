using M365Permissions.Engine.Database;
using Xunit;

namespace M365Permissions.Engine.Tests.Database;

public class ConfigRepositoryTests : IDisposable
{
    private readonly string _dbPath;
    private readonly SqliteDb _db;
    private readonly ConfigRepository _repo;

    public ConfigRepositoryTests()
    {
        _dbPath = Path.Combine(Path.GetTempPath(), $"m365perm_test_{Guid.NewGuid():N}.db");
        _db = new SqliteDb(_dbPath);
        _db.Initialize();
        _repo = new ConfigRepository(_db);
    }

    [Fact]
    public void SetAndGet_RoundTrips()
    {
        _repo.Set("testKey", "testValue");
        var result = _repo.Get("testKey");
        Assert.Equal("testValue", result);
    }

    [Fact]
    public void Set_Upserts()
    {
        _repo.Set("key", "value1");
        _repo.Set("key", "value2");
        Assert.Equal("value2", _repo.Get("key"));
    }

    [Fact]
    public void Get_ReturnsNullForMissing()
    {
        Assert.Null(_repo.Get("nonexistent"));
    }

    [Fact]
    public void GetAll_ReturnsAllEntries()
    {
        _repo.Set("a", "1");
        _repo.Set("b", "2");
        var all = _repo.GetAll();
        Assert.Equal(2, all.Count);
        Assert.Equal("1", all["a"]);
        Assert.Equal("2", all["b"]);
    }

    [Fact]
    public void Delete_RemovesEntry()
    {
        _repo.Set("key", "value");
        _repo.Delete("key");
        Assert.Null(_repo.Get("key"));
    }

    public void Dispose()
    {
        _db.Dispose();
        try { File.Delete(_dbPath); } catch { }
    }
}
