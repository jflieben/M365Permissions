using System.Text.Json;
using M365Permissions.Engine.Models;
using Microsoft.Data.Sqlite;

namespace M365Permissions.Engine.Database;

/// <summary>
/// CRUD operations for the policies table. Conditions are stored as JSON.
/// </summary>
public sealed class PolicyRepository
{
    private readonly SqliteDb _db;
    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public PolicyRepository(SqliteDb db) => _db = db;

    private const string SelectColumns = "id, name, description, enabled, severity, category_filter, conditions, is_default, created_at, updated_at";

    public List<Policy> GetAll()
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT {SelectColumns} FROM policies ORDER BY id";
        using var reader = cmd.ExecuteReader();
        var list = new List<Policy>();
        while (reader.Read())
            list.Add(ReadPolicy(reader));
        return list;
    }

    public Policy? GetById(long id)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT {SelectColumns} FROM policies WHERE id = @id";
        cmd.Parameters.AddWithValue("@id", id);
        using var reader = cmd.ExecuteReader();
        return reader.Read() ? ReadPolicy(reader) : null;
    }

    public long Create(Policy policy)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"INSERT INTO policies (name, description, enabled, severity, category_filter, conditions, is_default)
            VALUES (@name, @desc, @enabled, @severity, @catFilter, @conditions, @isDefault);
            SELECT last_insert_rowid();";
        cmd.Parameters.AddWithValue("@name", policy.Name);
        cmd.Parameters.AddWithValue("@desc", policy.Description);
        cmd.Parameters.AddWithValue("@enabled", policy.Enabled ? 1 : 0);
        cmd.Parameters.AddWithValue("@severity", policy.Severity);
        cmd.Parameters.AddWithValue("@catFilter", policy.CategoryFilter);
        cmd.Parameters.AddWithValue("@conditions", SerializeConditions(policy.Conditions));
        cmd.Parameters.AddWithValue("@isDefault", policy.IsDefault ? 1 : 0);
        return (long)cmd.ExecuteScalar()!;
    }

    public void Update(Policy policy)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"UPDATE policies SET name=@name, description=@desc, enabled=@enabled, severity=@severity,
            category_filter=@catFilter, conditions=@conditions, is_default=@isDefault, updated_at=datetime('now')
            WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", policy.Id);
        cmd.Parameters.AddWithValue("@name", policy.Name);
        cmd.Parameters.AddWithValue("@desc", policy.Description);
        cmd.Parameters.AddWithValue("@enabled", policy.Enabled ? 1 : 0);
        cmd.Parameters.AddWithValue("@severity", policy.Severity);
        cmd.Parameters.AddWithValue("@catFilter", policy.CategoryFilter);
        cmd.Parameters.AddWithValue("@conditions", SerializeConditions(policy.Conditions));
        cmd.Parameters.AddWithValue("@isDefault", policy.IsDefault ? 1 : 0);
        cmd.ExecuteNonQuery();
    }

    public void Delete(long id)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM policies WHERE id = @id";
        cmd.Parameters.AddWithValue("@id", id);
        cmd.ExecuteNonQuery();
    }

    public void DeleteDefaults()
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM policies WHERE is_default = 1";
        cmd.ExecuteNonQuery();
    }

    public int Count()
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM policies";
        return Convert.ToInt32(cmd.ExecuteScalar());
    }

    public List<Policy> GetEnabled()
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT {SelectColumns} FROM policies WHERE enabled = 1 ORDER BY id";
        using var reader = cmd.ExecuteReader();
        var list = new List<Policy>();
        while (reader.Read())
            list.Add(ReadPolicy(reader));
        return list;
    }

    private static Policy ReadPolicy(SqliteDataReader reader) => new()
    {
        Id = reader.GetInt64(0),
        Name = reader.GetString(1),
        Description = reader.GetString(2),
        Enabled = reader.GetInt64(3) == 1,
        Severity = reader.GetString(4),
        CategoryFilter = reader.GetString(5),
        Conditions = DeserializeConditions(reader.GetString(6)),
        IsDefault = reader.GetInt64(7) == 1,
        CreatedAt = reader.GetString(8),
        UpdatedAt = reader.GetString(9)
    };

    private static string SerializeConditions(List<PolicyCondition> conditions)
        => JsonSerializer.Serialize(conditions, JsonOpts);

    private static List<PolicyCondition> DeserializeConditions(string json)
    {
        if (string.IsNullOrWhiteSpace(json) || json == "[]") return new();
        try { return JsonSerializer.Deserialize<List<PolicyCondition>>(json, JsonOpts) ?? new(); }
        catch { return new(); }
    }
}
