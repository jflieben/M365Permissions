using M365Permissions.Engine.Models;
using Microsoft.Data.Sqlite;

namespace M365Permissions.Engine.Database;

/// <summary>
/// Records audit trail entries for compliance tracking.
/// </summary>
public sealed class AuditRepository
{
    private readonly SqliteDb _db;

    public AuditRepository(SqliteDb db) => _db = db;

    public void Log(string action, string userName, string details, long? scanId = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"INSERT INTO audit_log (action, user_name, details, scan_id)
            VALUES (@action, @user, @details, @scan_id)";
        cmd.Parameters.AddWithValue("@action", action);
        cmd.Parameters.AddWithValue("@user", userName);
        cmd.Parameters.AddWithValue("@details", details);
        cmd.Parameters.AddWithValue("@scan_id", (object?)scanId ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    public List<AuditEntry> GetRecent(int limit = 100, string? action = null, string? tenantId = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        var conditions = new List<string>();
        if (action != null) { conditions.Add("a.action = @action"); cmd.Parameters.AddWithValue("@action", action); }
        if (!string.IsNullOrEmpty(tenantId))
        {
            conditions.Add("(a.scan_id IS NULL OR EXISTS (SELECT 1 FROM scans s WHERE s.id = a.scan_id AND s.tenant_id = @tid))");
            cmd.Parameters.AddWithValue("@tid", tenantId);
        }
        var where = conditions.Count > 0 ? $"WHERE {string.Join(" AND ", conditions)} " : "";
        cmd.CommandText = $"SELECT * FROM audit_log a {where}ORDER BY a.id DESC LIMIT @limit";
        cmd.Parameters.AddWithValue("@limit", limit);

        var result = new List<AuditEntry>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            result.Add(new AuditEntry
            {
                Id = reader.GetInt64(reader.GetOrdinal("id")),
                Action = reader.GetString(reader.GetOrdinal("action")),
                UserName = reader.GetString(reader.GetOrdinal("user_name")),
                Details = reader.GetString(reader.GetOrdinal("details")),
                ScanId = reader.IsDBNull(reader.GetOrdinal("scan_id")) ? null : reader.GetInt64(reader.GetOrdinal("scan_id")),
                Timestamp = reader.GetString(reader.GetOrdinal("timestamp"))
            });
        }
        return result;
    }
}
