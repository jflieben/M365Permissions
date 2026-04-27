using M365Permissions.Engine.Models;
using Microsoft.Data.Sqlite;

namespace M365Permissions.Engine.Database;

/// <summary>
/// CRUD operations for scan metadata.
/// </summary>
public sealed class ScanRepository
{
    private readonly SqliteDb _db;

    public ScanRepository(SqliteDb db) => _db = db;

    public long Create(ScanInfo scan)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            INSERT INTO scans (tenant_id, tenant_domain, status, scan_types, started_at, started_by, config_snapshot, module_version)
            VALUES (@tid, @domain, @status, @types, @started, @by, @config, @version);
            SELECT last_insert_rowid();";
        cmd.Parameters.AddWithValue("@tid", scan.TenantId);
        cmd.Parameters.AddWithValue("@domain", scan.TenantDomain);
        cmd.Parameters.AddWithValue("@status", scan.Status.ToString());
        cmd.Parameters.AddWithValue("@types", scan.ScanTypes);
        cmd.Parameters.AddWithValue("@started", scan.StartedAt);
        cmd.Parameters.AddWithValue("@by", scan.StartedBy);
        cmd.Parameters.AddWithValue("@config", scan.ConfigSnapshot);
        cmd.Parameters.AddWithValue("@version", scan.ModuleVersion);
        return (long)cmd.ExecuteScalar()!;
    }

    public ScanInfo? GetById(long id)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM scans WHERE id = @id";
        cmd.Parameters.AddWithValue("@id", id);
        using var reader = cmd.ExecuteReader();
        return reader.Read() ? MapScan(reader) : null;
    }

    public List<ScanInfo> GetAll(int limit = 50, string? tenantId = null)
    {
        var result = new List<ScanInfo>();
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        if (!string.IsNullOrEmpty(tenantId))
        {
            cmd.CommandText = "SELECT * FROM scans WHERE tenant_id = @tid ORDER BY id DESC LIMIT @limit";
            cmd.Parameters.AddWithValue("@tid", tenantId);
        }
        else
        {
            cmd.CommandText = "SELECT * FROM scans ORDER BY id DESC LIMIT @limit";
        }
        cmd.Parameters.AddWithValue("@limit", limit);
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            result.Add(MapScan(reader));
        return result;
    }

    public void UpdateStatus(long id, ScanStatus status, string? error = null, long? totalPermissions = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            UPDATE scans SET
                status = @status,
                completed_at = CASE WHEN @status IN ('Completed','Failed','Cancelled') THEN datetime('now') ELSE completed_at END,
                error_message = COALESCE(@error, error_message),
                total_permissions = COALESCE(@total, total_permissions)
            WHERE id = @id";
        cmd.Parameters.AddWithValue("@id", id);
        cmd.Parameters.AddWithValue("@status", status.ToString());
        cmd.Parameters.AddWithValue("@error", (object?)error ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@total", (object?)totalPermissions ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    public void Delete(long id)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM scans WHERE id = @id";
        cmd.Parameters.AddWithValue("@id", id);
        cmd.ExecuteNonQuery();
    }

    public void UpdateNotes(long id, string? notes, string? tags)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        var sets = new List<string>();
        if (notes != null) { sets.Add("notes = @notes"); cmd.Parameters.AddWithValue("@notes", notes); }
        if (tags != null) { sets.Add("tags = @tags"); cmd.Parameters.AddWithValue("@tags", tags); }
        if (sets.Count == 0) return;
        cmd.CommandText = $"UPDATE scans SET {string.Join(", ", sets)} WHERE id = @id";
        cmd.Parameters.AddWithValue("@id", id);
        cmd.ExecuteNonQuery();
    }

    /// <summary>Get risk level distribution for a scan.</summary>
    public Dictionary<string, int> GetRiskSummary(long scanId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"SELECT risk_level, COUNT(*) as cnt FROM permissions
            WHERE scan_id = @scan_id AND risk_level != '' GROUP BY risk_level ORDER BY
            CASE risk_level WHEN 'Critical' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3 WHEN 'Low' THEN 4 ELSE 5 END";
        cmd.Parameters.AddWithValue("@scan_id", scanId);
        var result = new Dictionary<string, int>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            result[reader.GetString(0)] = reader.GetInt32(1);
        return result;
    }

    /// <summary>Get permission count per category over time (for trend charts).</summary>
    public List<TrendDataPoint> GetTrends(int limit = 20, string? tenantId = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        var tenantWhere = !string.IsNullOrEmpty(tenantId) ? "AND s.tenant_id = @tid " : "";
        cmd.CommandText = $@"SELECT s.id, s.started_at, s.total_permissions, s.tenant_domain,
            (SELECT COUNT(*) FROM permissions p WHERE p.scan_id = s.id AND p.risk_level = 'Critical') as critical,
            (SELECT COUNT(*) FROM permissions p WHERE p.scan_id = s.id AND p.risk_level = 'High') as high,
            (SELECT COUNT(*) FROM permissions p WHERE p.scan_id = s.id AND p.risk_level = 'Medium') as medium,
            (SELECT COUNT(*) FROM permissions p WHERE p.scan_id = s.id AND p.risk_level = 'Low') as low,
            (SELECT COUNT(*) FROM permissions p WHERE p.scan_id = s.id AND p.risk_level = 'Info') as info
            FROM scans s WHERE s.status = 'Completed' {tenantWhere}ORDER BY s.id DESC LIMIT @limit";
        if (!string.IsNullOrEmpty(tenantId))
            cmd.Parameters.AddWithValue("@tid", tenantId);
        cmd.Parameters.AddWithValue("@limit", limit);
        var result = new List<TrendDataPoint>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            result.Add(new TrendDataPoint
            {
                ScanId = reader.GetInt64(0),
                StartedAt = reader.GetString(1),
                TotalPermissions = reader.GetInt64(2),
                TenantDomain = reader.GetString(3),
                Critical = reader.GetInt32(4),
                High = reader.GetInt32(5),
                Medium = reader.GetInt32(6),
                Low = reader.GetInt32(7),
                Info = reader.GetInt32(8)
            });
        }
        result.Reverse(); // oldest first for chart
        return result;
    }

    private static ScanInfo MapScan(SqliteDataReader reader) => new()
    {
        Id = reader.GetInt64(reader.GetOrdinal("id")),
        TenantId = reader.GetString(reader.GetOrdinal("tenant_id")),
        TenantDomain = reader.GetString(reader.GetOrdinal("tenant_domain")),
        Status = Enum.Parse<ScanStatus>(reader.GetString(reader.GetOrdinal("status"))),
        ScanTypes = reader.GetString(reader.GetOrdinal("scan_types")),
        StartedAt = reader.GetString(reader.GetOrdinal("started_at")),
        CompletedAt = reader.GetString(reader.GetOrdinal("completed_at")),
        StartedBy = reader.GetString(reader.GetOrdinal("started_by")),
        TotalPermissions = reader.GetInt64(reader.GetOrdinal("total_permissions")),
        ConfigSnapshot = reader.GetString(reader.GetOrdinal("config_snapshot")),
        ErrorMessage = reader.GetString(reader.GetOrdinal("error_message")),
        ModuleVersion = reader.GetString(reader.GetOrdinal("module_version")),
        Notes = reader.GetString(reader.GetOrdinal("notes")),
        Tags = reader.GetString(reader.GetOrdinal("tags"))
    };
}
