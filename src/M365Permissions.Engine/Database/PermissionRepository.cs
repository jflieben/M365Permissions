using M365Permissions.Engine.Models;
using Microsoft.Data.Sqlite;

namespace M365Permissions.Engine.Database;

/// <summary>
/// High-performance permission storage — supports bulk insert and paginated queries.
/// </summary>
public sealed class PermissionRepository
{
    private readonly SqliteDb _db;

    public PermissionRepository(SqliteDb db) => _db = db;

    /// <summary>
    /// Insert a batch of permission entries in a single transaction.
    /// Optimized for high throughput during scans (1000+ entries/batch).
    /// </summary>
    public void BulkInsert(IReadOnlyList<PermissionEntry> entries)
    {
        if (entries.Count == 0) return;

        using var conn = _db.CreateConnection();
        using var tx = conn.BeginTransaction();

        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
            INSERT INTO permissions (
                scan_id, category, target_path, target_type, target_id,
                principal_entra_id, principal_entra_upn, principal_sys_id, principal_sys_name,
                principal_type, principal_role, through, access_type, tenure, parent_id,
                start_date_time, end_date_time, created_date_time, modified_date_time,
                risk_level, risk_reason
            ) VALUES (
                @scan_id, @category, @target_path, @target_type, @target_id,
                @pid, @pupn, @psid, @psname,
                @ptype, @prole, @through, @access, @tenure, @parent,
                @start_dt, @end_dt, @created_dt, @modified_dt,
                @risk_level, @risk_reason
            )";

        var pScanId = cmd.Parameters.Add("@scan_id", SqliteType.Integer);
        var pCategory = cmd.Parameters.Add("@category", SqliteType.Text);
        var pTargetPath = cmd.Parameters.Add("@target_path", SqliteType.Text);
        var pTargetType = cmd.Parameters.Add("@target_type", SqliteType.Text);
        var pTargetId = cmd.Parameters.Add("@target_id", SqliteType.Text);
        var pPid = cmd.Parameters.Add("@pid", SqliteType.Text);
        var pPupn = cmd.Parameters.Add("@pupn", SqliteType.Text);
        var pPsid = cmd.Parameters.Add("@psid", SqliteType.Text);
        var pPsname = cmd.Parameters.Add("@psname", SqliteType.Text);
        var pPtype = cmd.Parameters.Add("@ptype", SqliteType.Text);
        var pProle = cmd.Parameters.Add("@prole", SqliteType.Text);
        var pThrough = cmd.Parameters.Add("@through", SqliteType.Text);
        var pAccess = cmd.Parameters.Add("@access", SqliteType.Text);
        var pTenure = cmd.Parameters.Add("@tenure", SqliteType.Text);
        var pParent = cmd.Parameters.Add("@parent", SqliteType.Text);
        var pStartDt = cmd.Parameters.Add("@start_dt", SqliteType.Text);
        var pEndDt = cmd.Parameters.Add("@end_dt", SqliteType.Text);
        var pCreatedDt = cmd.Parameters.Add("@created_dt", SqliteType.Text);
        var pModifiedDt = cmd.Parameters.Add("@modified_dt", SqliteType.Text);
        var pRiskLevel = cmd.Parameters.Add("@risk_level", SqliteType.Text);
        var pRiskReason = cmd.Parameters.Add("@risk_reason", SqliteType.Text);

        cmd.Prepare();

        foreach (var e in entries)
        {
            pScanId.Value = e.ScanId;
            pCategory.Value = e.Category;
            pTargetPath.Value = e.TargetPath;
            pTargetType.Value = e.TargetType;
            pTargetId.Value = e.TargetId;
            pPid.Value = e.PrincipalEntraId;
            pPupn.Value = e.PrincipalEntraUpn;
            pPsid.Value = e.PrincipalSysId;
            pPsname.Value = e.PrincipalSysName;
            pPtype.Value = e.PrincipalType;
            pProle.Value = e.PrincipalRole;
            pThrough.Value = e.Through;
            pAccess.Value = e.AccessType;
            pTenure.Value = e.Tenure;
            pParent.Value = e.ParentId;
            pStartDt.Value = e.StartDateTime;
            pEndDt.Value = e.EndDateTime;
            pCreatedDt.Value = e.CreatedDateTime;
            pModifiedDt.Value = e.ModifiedDateTime;
            pRiskLevel.Value = e.RiskLevel;
            pRiskReason.Value = e.RiskReason;
            cmd.ExecuteNonQuery();
        }

        tx.Commit();
    }

    /// <summary>
    /// Paginated query with optional filters.
    /// </summary>
    public PagedResult<PermissionEntry> Query(long scanId, string? category = null,
        string? searchText = null, int page = 1, int pageSize = 100,
        string? sortColumn = null, string? sortDirection = null,
        Dictionary<string, string>? columnFilters = null)
    {
        using var conn = _db.CreateConnection();

        // Count
        using var countCmd = conn.CreateCommand();
        var where = BuildWhereClause(countCmd, scanId, category, searchText, columnFilters);
        countCmd.CommandText = $"SELECT COUNT(*) FROM permissions {where}";
        var totalCount = (long)countCmd.ExecuteScalar()!;

        // Data
        var orderBy = BuildOrderBy(sortColumn, sortDirection);
        using var dataCmd = conn.CreateCommand();
        var where2 = BuildWhereClause(dataCmd, scanId, category, searchText, columnFilters);
        dataCmd.CommandText = $"SELECT * FROM permissions {where2} {orderBy} LIMIT @limit OFFSET @offset";
        dataCmd.Parameters.AddWithValue("@limit", pageSize);
        dataCmd.Parameters.AddWithValue("@offset", (page - 1) * pageSize);

        var items = new List<PermissionEntry>();
        using var reader = dataCmd.ExecuteReader();
        while (reader.Read())
            items.Add(MapPermission(reader));

        return new PagedResult<PermissionEntry>
        {
            Items = items,
            TotalCount = totalCount,
            Page = page,
            PageSize = pageSize
        };
    }

    /// <summary>Get all permissions for a scan+category (for export).</summary>
    public List<PermissionEntry> GetAll(long scanId, string? category = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        var where = "WHERE scan_id = @scan_id";
        cmd.Parameters.AddWithValue("@scan_id", scanId);
        if (!string.IsNullOrEmpty(category))
        {
            where += " AND category = @category";
            cmd.Parameters.AddWithValue("@category", category);
        }
        cmd.CommandText = $"SELECT * FROM permissions {where} ORDER BY target_path, principal_entra_upn";

        var items = new List<PermissionEntry>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            items.Add(MapPermission(reader));
        return items;
    }

    /// <summary>Get distinct categories for a scan.</summary>
    public List<string> GetCategories(long scanId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT DISTINCT category FROM permissions WHERE scan_id = @scan_id ORDER BY category";
        cmd.Parameters.AddWithValue("@scan_id", scanId);

        var result = new List<string>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            result.Add(reader.GetString(0));
        return result;
    }

    public long Count(long scanId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM permissions WHERE scan_id = @scan_id";
        cmd.Parameters.AddWithValue("@scan_id", scanId);
        return (long)cmd.ExecuteScalar()!;
    }

    private static readonly HashSet<string> AllowedSortColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "category", "target_path", "target_type", "principal_entra_upn", "principal_sys_name",
        "principal_type", "principal_role", "through", "access_type", "tenure", "risk_level"
    };

    private static readonly HashSet<string> AllowedFilterColumns = new(StringComparer.OrdinalIgnoreCase)
    {
        "category", "target_type", "principal_type", "principal_role", "through", "access_type", "tenure", "risk_level"
    };

    private static string BuildOrderBy(string? sortColumn, string? sortDirection)
    {
        if (string.IsNullOrEmpty(sortColumn) || !AllowedSortColumns.Contains(sortColumn))
            return "ORDER BY target_path, principal_entra_upn";
        var dir = string.Equals(sortDirection, "desc", StringComparison.OrdinalIgnoreCase) ? "DESC" : "ASC";
        return $"ORDER BY {sortColumn} {dir}";
    }

    private static string BuildWhereClause(SqliteCommand cmd, long scanId, string? category, string? searchText,
        Dictionary<string, string>? columnFilters = null)
    {
        var clauses = new List<string> { "scan_id = @scan_id" };
        cmd.Parameters.AddWithValue("@scan_id", scanId);

        if (!string.IsNullOrEmpty(category))
        {
            clauses.Add("category = @category");
            cmd.Parameters.AddWithValue("@category", category);
        }
        if (!string.IsNullOrEmpty(searchText))
        {
            clauses.Add("(target_path LIKE @search OR principal_entra_upn LIKE @search OR principal_sys_name LIKE @search OR principal_role LIKE @search)");
            cmd.Parameters.AddWithValue("@search", $"%{searchText}%");
        }

        if (columnFilters != null)
        {
            int filterIdx = 0;
            foreach (var (col, values) in columnFilters)
            {
                if (!AllowedFilterColumns.Contains(col) || string.IsNullOrEmpty(values)) continue;
                // Values are pipe-separated for multi-select: "val1|val2|val3"
                var valList = values.Split('|', StringSplitOptions.RemoveEmptyEntries);
                if (valList.Length == 0) continue;

                var paramNames = new List<string>();
                for (int i = 0; i < valList.Length; i++)
                {
                    var pName = $"@cf{filterIdx}_{i}";
                    paramNames.Add(pName);
                    cmd.Parameters.AddWithValue(pName, valList[i]);
                }
                clauses.Add($"{col} IN ({string.Join(",", paramNames)})");
                filterIdx++;
            }
        }

        return "WHERE " + string.Join(" AND ", clauses);
    }

    private static PermissionEntry MapPermission(SqliteDataReader reader) => new()
    {
        Id = reader.GetInt64(reader.GetOrdinal("id")),
        ScanId = reader.GetInt64(reader.GetOrdinal("scan_id")),
        Category = reader.GetString(reader.GetOrdinal("category")),
        TargetPath = reader.GetString(reader.GetOrdinal("target_path")),
        TargetType = reader.GetString(reader.GetOrdinal("target_type")),
        TargetId = reader.GetString(reader.GetOrdinal("target_id")),
        PrincipalEntraId = reader.GetString(reader.GetOrdinal("principal_entra_id")),
        PrincipalEntraUpn = reader.GetString(reader.GetOrdinal("principal_entra_upn")),
        PrincipalSysId = reader.GetString(reader.GetOrdinal("principal_sys_id")),
        PrincipalSysName = reader.GetString(reader.GetOrdinal("principal_sys_name")),
        PrincipalType = reader.GetString(reader.GetOrdinal("principal_type")),
        PrincipalRole = reader.GetString(reader.GetOrdinal("principal_role")),
        Through = reader.GetString(reader.GetOrdinal("through")),
        AccessType = reader.GetString(reader.GetOrdinal("access_type")),
        Tenure = reader.GetString(reader.GetOrdinal("tenure")),
        ParentId = reader.GetString(reader.GetOrdinal("parent_id")),
        StartDateTime = reader.GetString(reader.GetOrdinal("start_date_time")),
        EndDateTime = reader.GetString(reader.GetOrdinal("end_date_time")),
        CreatedDateTime = reader.GetString(reader.GetOrdinal("created_date_time")),
        ModifiedDateTime = reader.GetString(reader.GetOrdinal("modified_date_time")),
        RiskLevel = reader.GetString(reader.GetOrdinal("risk_level")),
        RiskReason = reader.GetString(reader.GetOrdinal("risk_reason"))
    };

    /// <summary>Search permissions for a specific user across all categories in a scan.</summary>
    public PagedResult<PermissionEntry> QueryUserPermissions(long scanId, string userSearch, int page = 1, int pageSize = 100,
        string? sortColumn = null, string? sortDirection = null,
        Dictionary<string, string>? columnFilters = null)
    {
        using var conn = _db.CreateConnection();

        var baseWhere = @"scan_id = @scan_id AND (
            principal_entra_upn LIKE @search
            OR principal_sys_name LIKE @search
            OR principal_entra_id LIKE @search
            OR target_path IN (
                SELECT target_path FROM permissions
                WHERE scan_id = @scan_id AND category = 'Entra'
                AND target_type IN ('SecurityGroup','M365Group')
                AND (principal_entra_upn LIKE @search OR principal_sys_name LIKE @search OR principal_entra_id LIKE @search)
            )
        )";

        // Build additional column filter clauses
        var filterClauses = "";
        var filterParams = new Dictionary<string, string>();
        if (columnFilters != null)
        {
            int filterIdx = 0;
            foreach (var (col, values) in columnFilters)
            {
                if (!AllowedFilterColumns.Contains(col) || string.IsNullOrEmpty(values)) continue;
                var valList = values.Split('|', StringSplitOptions.RemoveEmptyEntries);
                if (valList.Length == 0) continue;
                var paramNames = new List<string>();
                for (int i = 0; i < valList.Length; i++)
                {
                    var pName = $"@ucf{filterIdx}_{i}";
                    paramNames.Add(pName);
                    filterParams[pName] = valList[i];
                }
                filterClauses += $" AND {col} IN ({string.Join(",", paramNames)})";
                filterIdx++;
            }
        }

        var where = $"WHERE {baseWhere}{filterClauses}";

        using var countCmd = conn.CreateCommand();
        countCmd.CommandText = $"SELECT COUNT(*) FROM permissions {where}";
        countCmd.Parameters.AddWithValue("@scan_id", scanId);
        countCmd.Parameters.AddWithValue("@search", $"%{userSearch}%");
        foreach (var (k, v) in filterParams) countCmd.Parameters.AddWithValue(k, v);
        var totalCount = (long)countCmd.ExecuteScalar()!;

        var orderBy = BuildOrderBy(sortColumn, sortDirection);
        using var dataCmd = conn.CreateCommand();
        dataCmd.CommandText = $"SELECT * FROM permissions {where} {orderBy} LIMIT @limit OFFSET @offset";
        dataCmd.Parameters.AddWithValue("@scan_id", scanId);
        dataCmd.Parameters.AddWithValue("@search", $"%{userSearch}%");
        foreach (var (k, v) in filterParams) dataCmd.Parameters.AddWithValue(k, v);
        dataCmd.Parameters.AddWithValue("@limit", pageSize);
        dataCmd.Parameters.AddWithValue("@offset", (page - 1) * pageSize);

        var items = new List<PermissionEntry>();
        using var reader = dataCmd.ExecuteReader();
        while (reader.Read())
            items.Add(MapPermission(reader));

        return new PagedResult<PermissionEntry> { Items = items, TotalCount = totalCount, Page = page, PageSize = pageSize };
    }

    /// <summary>Get members of a specific group from Entra scan results.</summary>
    public List<PermissionEntry> GetGroupMembers(long scanId, string groupId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"SELECT * FROM permissions WHERE scan_id = @scan_id
            AND category = 'Entra' AND target_id = @group_id AND principal_role = 'Member'
            ORDER BY principal_entra_upn, principal_sys_name";
        cmd.Parameters.AddWithValue("@scan_id", scanId);
        cmd.Parameters.AddWithValue("@group_id", groupId);

        var items = new List<PermissionEntry>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            items.Add(MapPermission(reader));
        return items;
    }

    /// <summary>Get distinct values for a column in a scan (for filter dropdowns).</summary>
    public List<string> GetDistinctValues(long scanId, string column, string? category = null)
    {
        // Whitelist allowed columns to prevent SQL injection
        var allowedColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "category", "target_type", "principal_type", "principal_role", "through", "access_type", "tenure", "risk_level"
        };
        if (!allowedColumns.Contains(column))
            return new List<string>();

        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        var where = "WHERE scan_id = @scan_id";
        cmd.Parameters.AddWithValue("@scan_id", scanId);
        if (!string.IsNullOrEmpty(category))
        {
            where += " AND category = @category";
            cmd.Parameters.AddWithValue("@category", category);
        }
        cmd.CommandText = $"SELECT DISTINCT {column} FROM permissions {where} ORDER BY {column}";

        var result = new List<string>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var val = reader.GetString(0);
            if (!string.IsNullOrEmpty(val)) result.Add(val);
        }
        return result;
    }
}
