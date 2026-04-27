using Microsoft.Data.Sqlite;

namespace M365Permissions.Engine.Database;

/// <summary>
/// Key-value configuration storage backed by SQLite.
/// </summary>
public sealed class ConfigRepository
{
    private readonly SqliteDb _db;

    public ConfigRepository(SqliteDb db) => _db = db;

    public string? Get(string key)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT value FROM config WHERE key = @key";
        cmd.Parameters.AddWithValue("@key", key);
        return cmd.ExecuteScalar() as string;
    }

    public void Set(string key, string value)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            INSERT INTO config (key, value, updated_at) VALUES (@key, @value, datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value = @value, updated_at = datetime('now')";
        cmd.Parameters.AddWithValue("@key", key);
        cmd.Parameters.AddWithValue("@value", value);
        cmd.ExecuteNonQuery();
    }

    public Dictionary<string, string> GetAll()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT key, value FROM config";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            result[reader.GetString(0)] = reader.GetString(1);
        return result;
    }

    public void Delete(string key)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM config WHERE key = @key";
        cmd.Parameters.AddWithValue("@key", key);
        cmd.ExecuteNonQuery();
    }
}
